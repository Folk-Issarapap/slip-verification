#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Customer Bank Accounts (Realistic Lifecycle)
#
# Usage:
#   BROPAY_URL=http://localhost:8787 bash scripts/e2e/admin/customer-bank-accounts.sh
#
# Required env: BROPAY_URL (default http://localhost:8787)
# External deps: none (BAV override via admin API; no KBNK tunnel required)
#
# Endpoints:
#   POST   /v1/admin/customer-bank-accounts
#   GET    /v1/admin/customer-bank-accounts/{bankAccountId}
#   PATCH  /v1/admin/customer-bank-accounts/{bankAccountId}
#   POST   /v1/admin/customer-bank-accounts/{bankAccountId}/set-default
#   POST   /v1/admin/customer-bank-accounts/{bankAccountId}/reveal-account-number
#   DELETE /v1/admin/customer-bank-accounts/{bankAccountId}
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROPAY="${BROPAY_URL:-http://localhost:8787}"
ORIGIN="Origin: http://localhost:3000"
CT="Content-Type: application/json"

GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[0;33m' CYAN='\033[0;36m' NC='\033[0m'
pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }
warn() { echo -e "${YELLOW}! $1${NC}"; }
step() { echo -e "\n${CYAN}━━━ Step $1: $2 ━━━${NC}"; }
json() { python3 -c "import sys,json; $1" 2>/dev/null; }

# Approve pending BAV for a customer bank account (sets verification_status + status active).
bav_verify_customer_cba() {
  local cba_id="$1"
  local pending ver_id override_res ov_status
  pending=$(curl -s "$BROPAY/v1/admin/bank-account-verifications?status=pending&customer_bank_account_id=$cba_id" \
    -H "$ADMIN" -H "$ORIGIN")
  ver_id=$(echo "$pending" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')")
  if [ -z "$ver_id" ]; then
    pending=$(curl -s "$BROPAY/v1/admin/bank-account-verifications?status=pending" -H "$ADMIN" -H "$ORIGIN")
    ver_id=$(echo "$pending" | json "d=json.load(sys.stdin).get('data',[]); print(next((x['id'] for x in d if x.get('customer_bank_account_id')=='$cba_id'), ''))")
  fi
  [ -n "$ver_id" ] || return 1
  override_res=$(curl -s "$BROPAY/v1/admin/bank-account-verifications/$ver_id/override" -X POST \
    -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
    -d '{"status":"verified","override_reason":"E2E admin CBA script"}')
  ov_status=$(echo "$override_res" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
  [ "$ov_status" = "verified" ] || return 1
  echo "$ver_id"
}

echo -e "${CYAN}━━━ Admin E2E — Customer Bank Accounts (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
OWNER="Authorization: Bearer $DEMO_OWNER_TOKEN"
MERCH="X-Merchant-Id: $DEMO_MERCHANT_ID"
pass "Admin token acquired (super_admin)"

TS=$(date +%s)

step 2 "Create customer via merchant API"
CUST_RES=$(curl -s "$BROPAY/v1/merchant/customers" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"first_name\":\"CBA\",\"last_name\":\"E2E-$TS\",\"email\":\"cba-e2e-$TS@example.com\",\"phone\":\"+6689${TS: -8}\"}")
CUST_ID=$(echo "$CUST_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$CUST_ID" ] || fail "Customer creation failed: $CUST_RES"
pass "Customer: ${CUST_ID:0:16}..."

step 3 "Resolve bank id"
BANKS=$(curl -s "$BROPAY/v1/banks" -H "$ORIGIN")
BANK_ID=$(echo "$BANKS" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')")
BANK_ID="${BANK_ID:-bank-kbank-0000-0000-000000000001}"
pass "Bank: $BANK_ID"

step 4 "Admin creates customer bank account #1 (becomes default)"
CBA1_RES=$(curl -s "$BROPAY/v1/admin/customer-bank-accounts" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"customer_id\":\"$CUST_ID\",\"bank_id\":\"$BANK_ID\",\"account_number\":\"1111222233\",\"account_holder_name\":\"CBA E2E One $TS\"}")
CBA1_ID=$(echo "$CBA1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
CBA1_DEFAULT=$(echo "$CBA1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('is_default',''))")
[ -n "$CBA1_ID" ] || fail "CBA #1 creation failed: $CBA1_RES"
[ "$CBA1_DEFAULT" = "1" ] || fail "Expected first CBA to be default, got is_default=$CBA1_DEFAULT"
pass "CBA #1: ${CBA1_ID:0:16}... (default)"

step 5 "Admin creates customer bank account #2 (non-default)"
CBA2_RES=$(curl -s "$BROPAY/v1/admin/customer-bank-accounts" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"customer_id\":\"$CUST_ID\",\"bank_id\":\"$BANK_ID\",\"account_number\":\"4444555566\",\"account_holder_name\":\"CBA E2E Two $TS\",\"is_default\":0}")
CBA2_ID=$(echo "$CBA2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$CBA2_ID" ] || fail "CBA #2 creation failed: $CBA2_RES"
pass "CBA #2: ${CBA2_ID:0:16}..."

step 6 "Admin approves BAV for CBA #1 (default must be active before PATCH)"
VER1_ID=$(bav_verify_customer_cba "$CBA1_ID") || fail "Could not verify BAV for CBA #1"
pass "BAV $VER1_ID verified for CBA #1 (default + active)"

step 7 "Admin GET detail — masked account number"
GET1_RES=$(curl -s "$BROPAY/v1/admin/customer-bank-accounts/$CBA1_ID" -H "$ADMIN" -H "$ORIGIN")
GET1_ID=$(echo "$GET1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
GET1_ACCT=$(echo "$GET1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('account_number',''))")
[ "$GET1_ID" = "$CBA1_ID" ] || fail "GET #1 id mismatch"
[[ "$GET1_ACCT" == **** ]] || fail "Expected masked account_number, got '$GET1_ACCT'"
pass "GET detail masks account number"

step 8 "Admin PATCH noop on default active CBA #1"
PATCH_RES=$(curl -s "$BROPAY/v1/admin/customer-bank-accounts/$CBA1_ID" -X PATCH \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"account_holder_name\":\"CBA E2E One $TS\"}")
PATCH_ID=$(echo "$PATCH_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$PATCH_ID" = "$CBA1_ID" ] || fail "PATCH noop failed: $PATCH_RES"
pass "PATCH noop on default active CBA #1"

step 9 "Negative: set-default on unverified CBA #2 → 422"
NEG_SETDEF=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/customer-bank-accounts/$CBA2_ID/set-default" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
NEG_SD_HTTP=$(echo "$NEG_SETDEF" | tail -n1 | tr -d '\r')
[ "$NEG_SD_HTTP" = "422" ] || fail "Expected 422 set-default on unverified CBA #2, got $NEG_SD_HTTP"
pass "set-default on unverified rejected (422)"

step 10 "Admin approves BAV for CBA #2 (required before set-default)"
VER2_ID=$(bav_verify_customer_cba "$CBA2_ID") || fail "Could not verify BAV for CBA #2"
pass "BAV $VER2_ID verified for CBA #2"

step 11 "Admin set-default on verified CBA #2"
SETDEF_RES=$(curl -s "$BROPAY/v1/admin/customer-bank-accounts/$CBA2_ID/set-default" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
SETDEF_DEFAULT=$(echo "$SETDEF_RES" | json "print(json.load(sys.stdin).get('data',{}).get('is_default',''))")
[ "$SETDEF_DEFAULT" = "1" ] || fail "set-default failed: $SETDEF_RES"
pass "CBA #2 is now default"

step 12 "Admin reveal account number on CBA #2"
REVEAL_RES=$(curl -s "$BROPAY/v1/admin/customer-bank-accounts/$CBA2_ID/reveal-account-number" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
REVEAL_NUM=$(echo "$REVEAL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('account_number',''))")
[ "$REVEAL_NUM" = "4444555566" ] || fail "Reveal mismatch (got '$REVEAL_NUM')"
pass "Account number revealed"

step 13 "Admin DELETE non-default CBA #1"
DEL_RES=$(curl -s "$BROPAY/v1/admin/customer-bank-accounts/$CBA1_ID" -X DELETE \
  -H "$ADMIN" -H "$ORIGIN")
DEL_OK=$(echo "$DEL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('success',''))")
[ "$DEL_OK" = "True" ] || fail "DELETE CBA #1 failed: $DEL_RES"
pass "Non-default CBA #1 deleted"

step 14 "Negative: DELETE default CBA #2 → 422"
NEG_DEL=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/customer-bank-accounts/$CBA2_ID" -X DELETE \
  -H "$ADMIN" -H "$ORIGIN")
NEG_DEL_HTTP=$(echo "$NEG_DEL" | tail -n1 | tr -d '\r')
[ "$NEG_DEL_HTTP" = "422" ] || fail "Expected 422 deleting default CBA, got $NEG_DEL_HTTP"
pass "Default CBA delete correctly rejected (422)"

step 15 "GET deleted CBA #1 → 404"
GET_GONE=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/customer-bank-accounts/$CBA1_ID" -H "$ADMIN" -H "$ORIGIN")
GONE_HTTP=$(echo "$GET_GONE" | tail -n1 | tr -d '\r')
[ "$GONE_HTTP" = "404" ] || fail "Expected 404 for deleted CBA #1, got $GONE_HTTP"
pass "Deleted CBA #1 returns 404"

echo -e "\n${GREEN}━━━ Customer Bank Accounts Realistic Lifecycle Complete ━━━${NC}"
