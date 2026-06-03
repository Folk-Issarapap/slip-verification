#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Bank Account Verifications (Realistic Lifecycle)
#
# Endpoints:
#   GET  /v1/admin/bank-account-verifications
#   GET  /v1/admin/bank-account-verifications/{id}
#   POST /v1/admin/bank-account-verifications/{id}/override
#   POST /v1/merchant/bank-accounts
#   GET  /v1/merchant/bank-accounts
#   POST /v1/merchant/bank-accounts/{id}/set-default
#   POST /v1/merchant/bank-accounts/{id}/archive
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

echo -e "${CYAN}━━━ Admin E2E — Bank Account Verifications (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
OWNER="Authorization: Bearer $DEMO_OWNER_TOKEN"
MERCH="X-Merchant-Id: $DEMO_MERCHANT_ID"
pass "Admin token acquired (super_admin)"

step 2 "Resolve a real bank"
BANKS=$(curl -s "$BROPAY/v1/banks" -H "$ORIGIN")
BANK_ID=$(echo "$BANKS" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')")
BANK_ID="${BANK_ID:-bkk_bank}"
pass "Bank: $BANK_ID"

step 3 "Merchant creates bank account #1"
BA1_RES=$(curl -s "$BROPAY/v1/merchant/bank-accounts" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"bank_id\":\"$BANK_ID\",\"account_number\":\"1111222233\",\"account_holder_name\":\"Test Merchant One\",\"account_type\":\"savings\"}")
BA1_ID=$(echo "$BA1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$BA1_ID" ] || fail "Bank account #1 creation failed"
BA1_VS=$(echo "$BA1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('verification_status',''))")
[ "$BA1_VS" = "pending" ] || fail "Expected pending verification status"
pass "Bank account #1: ${BA1_ID:0:16}... ($BA1_VS)"

step 4 "Admin lists verifications"
LIST_RES=$(curl -s "$BROPAY/v1/admin/bank-account-verifications" -H "$ADMIN" -H "$ORIGIN")
HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$HAS_META" = "True" ] || fail "Verification list missing meta"
LIST_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_TOTAL" -ge 1 ] || fail "Expected at least 1 verification"
pass "Listed $LIST_TOTAL verification(s)"

step 5 "Admin filters by pending status"
PENDING_RES=$(curl -s "$BROPAY/v1/admin/bank-account-verifications?status=pending" -H "$ADMIN" -H "$ORIGIN")
PENDING_TOTAL=$(echo "$PENDING_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$PENDING_TOTAL" -ge 1 ] || fail "Expected at least 1 pending verification"
pass "$PENDING_TOTAL pending verification(s)"

step 6 "Admin gets verification detail for bank account #1"
VER1_ID=$(echo "$PENDING_RES" | json "d=json.load(sys.stdin).get('data',[]); print(next((x['id'] for x in d if x.get('merchant_bank_account_id')=='$BA1_ID'), ''))")
[ -n "$VER1_ID" ] || fail "Could not find verification for bank account #1"
GET_RES=$(curl -s "$BROPAY/v1/admin/bank-account-verifications/$VER1_ID" -H "$ADMIN" -H "$ORIGIN")
GET_ID=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$GET_ID" = "$VER1_ID" ] || fail "GET detail mismatch"
GET_STATUS=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$GET_STATUS" = "pending" ] || fail "Expected pending status in detail"
pass "Detail fetched: ${VER1_ID:0:16}... ($GET_STATUS)"

step 7 "Admin rejects verification #1 (override to failed)"
REJECT_RES=$(curl -s "$BROPAY/v1/admin/bank-account-verifications/$VER1_ID/override" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"status":"failed","override_reason":"Name mismatch with tax records"}')
REJECT_STATUS=$(echo "$REJECT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$REJECT_STATUS" = "failed" ] || fail "Expected failed status, got '$REJECT_STATUS'"
REJECT_MO=$(echo "$REJECT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('manually_overridden',''))")
[ "$REJECT_MO" = "1" ] || fail "Expected manually_overridden=1"
pass "Verification #1 rejected"

step 8 "Merchant sees bank account #1 as failed"
BA1_GET_RES=$(curl -s "$BROPAY/v1/merchant/bank-accounts/$BA1_ID" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
BA1_GET_VS=$(echo "$BA1_GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('verification_status',''))")
[ "$BA1_GET_VS" = "failed" ] || fail "Expected merchant view to show failed, got '$BA1_GET_VS'"
pass "Merchant view shows failed"

step 9 "Merchant creates bank account #2"
BA2_RES=$(curl -s "$BROPAY/v1/merchant/bank-accounts" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"bank_id\":\"$BANK_ID\",\"account_number\":\"4444555566\",\"account_holder_name\":\"Test Merchant Two\",\"account_type\":\"savings\"}")
BA2_ID=$(echo "$BA2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$BA2_ID" ] || fail "Bank account #2 creation failed"
pass "Bank account #2: ${BA2_ID:0:16}..."

step 10 "Admin approves verification #2 (override to verified)"
VER2_ID=$(echo "$PENDING_RES" | json "d=json.load(sys.stdin).get('data',[]); print(next((x['id'] for x in d if x.get('merchant_bank_account_id')=='$BA2_ID'), ''))")
if [ -z "$VER2_ID" ]; then
  # Fetch from list again since BA2 was created after pending list
  ALL_PENDING=$(curl -s "$BROPAY/v1/admin/bank-account-verifications?status=pending" -H "$ADMIN" -H "$ORIGIN")
  VER2_ID=$(echo "$ALL_PENDING" | json "d=json.load(sys.stdin).get('data',[]); print(next((x['id'] for x in d if x.get('merchant_bank_account_id')=='$BA2_ID'), ''))")
fi
[ -n "$VER2_ID" ] || fail "Could not find verification for bank account #2"

APPROVE_RES=$(curl -s "$BROPAY/v1/admin/bank-account-verifications/$VER2_ID/override" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"status":"verified","override_reason":"Verified via phone confirmation"}')
APPROVE_STATUS=$(echo "$APPROVE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$APPROVE_STATUS" = "verified" ] || fail "Expected verified status, got '$APPROVE_STATUS'"
pass "Verification #2 approved"

step 11 "Merchant sets bank account #2 as default for settlement"
SETTLE_RES=$(curl -s "$BROPAY/v1/merchant/bank-accounts/$BA2_ID/set-default" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{"designation":"for_settlement"}')
SETTLE_OK=$(echo "$SETTLE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('for_settlement',''))")
[ "$SETTLE_OK" = "1" ] || fail "Set default for settlement failed"
pass "Bank account #2 set for settlement"

step 12 "Merchant tries to archive bank account #2 → should fail"
ARCH_FAIL_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/bank-accounts/$BA2_ID/archive" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
ARCH_FAIL_HTTP=$(echo "$ARCH_FAIL_RES" | tail -n1)
[ "$ARCH_FAIL_HTTP" = "400" ] || fail "Expected 400 when archiving active-designation account, got $ARCH_FAIL_HTTP"
pass "Archive correctly rejected (active designation)"

step 13 "Merchant creates bank account #3"
BA3_RES=$(curl -s "$BROPAY/v1/merchant/bank-accounts" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"bank_id\":\"$BANK_ID\",\"account_number\":\"7777888899\",\"account_holder_name\":\"Test Merchant Three\",\"account_type\":\"checking\"}")
BA3_ID=$(echo "$BA3_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$BA3_ID" ] || fail "Bank account #3 creation failed"
pass "Bank account #3: ${BA3_ID:0:16}..."

step 14 "Admin approves verification #3"
ALL_PENDING2=$(curl -s "$BROPAY/v1/admin/bank-account-verifications?status=pending" -H "$ADMIN" -H "$ORIGIN")
VER3_ID=$(echo "$ALL_PENDING2" | json "d=json.load(sys.stdin).get('data',[]); print(next((x['id'] for x in d if x.get('merchant_bank_account_id')=='$BA3_ID'), ''))")
[ -n "$VER3_ID" ] || fail "Could not find verification for bank account #3"

APPROVE3_RES=$(curl -s "$BROPAY/v1/admin/bank-account-verifications/$VER3_ID/override" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"status":"verified","override_reason":"Document review passed"}')
APPROVE3_STATUS=$(echo "$APPROVE3_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$APPROVE3_STATUS" = "verified" ] || fail "Expected verified status, got '$APPROVE3_STATUS'"
pass "Verification #3 approved"

step 15 "Merchant sets bank account #3 as default for settlement (unsets #2)"
SETTLE3_RES=$(curl -s "$BROPAY/v1/merchant/bank-accounts/$BA3_ID/set-default" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{"designation":"for_settlement"}')
SETTLE3_OK=$(echo "$SETTLE3_RES" | json "print(json.load(sys.stdin).get('data',{}).get('for_settlement',''))")
[ "$SETTLE3_OK" = "1" ] || fail "Set default for settlement failed"
pass "Bank account #3 set for settlement (unsets #2)"

step 16 "Merchant archives bank account #2 → should succeed"
ARCH2_RES=$(curl -s "$BROPAY/v1/merchant/bank-accounts/$BA2_ID/archive" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
ARCH2_STATUS=$(echo "$ARCH2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$ARCH2_STATUS" = "inactive" ] || fail "Expected inactive status, got '$ARCH2_STATUS'"
pass "Bank account #2 archived"

step 17 "Admin filters verifications by status=verified"
VERIFIED_RES=$(curl -s "$BROPAY/v1/admin/bank-account-verifications?status=verified" -H "$ADMIN" -H "$ORIGIN")
VERIFIED_TOTAL=$(echo "$VERIFIED_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$VERIFIED_TOTAL" -ge 2 ] || fail "Expected at least 2 verified verifications"
pass "$VERIFIED_TOTAL verified verification(s)"

step 18 "Admin filters verifications by manually_overridden=1"
OVERRIDE_RES=$(curl -s "$BROPAY/v1/admin/bank-account-verifications?manually_overridden=1" -H "$ADMIN" -H "$ORIGIN")
OVERRIDE_TOTAL=$(echo "$OVERRIDE_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$OVERRIDE_TOTAL" -ge 3 ] || fail "Expected at least 3 overridden verifications"
pass "$OVERRIDE_TOTAL overridden verification(s)"

step 19 "Admin searches verifications by q"
SEARCH_RES=$(curl -s "$BROPAY/v1/admin/bank-account-verifications?q=verified" -H "$ADMIN" -H "$ORIGIN")
SEARCH_HAS_META=$(echo "$SEARCH_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SEARCH_HAS_META" = "True" ] || fail "Search missing meta"
pass "Search returned results"

step 20 "Admin filters by merchant_bank_account_id"
FILTER_BA_RES=$(curl -s "$BROPAY/v1/admin/bank-account-verifications?merchant_bank_account_id=$BA1_ID" -H "$ADMIN" -H "$ORIGIN")
FILTER_BA_TOTAL=$(echo "$FILTER_BA_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FILTER_BA_TOTAL" -ge 1 ] || fail "Expected at least 1 verification for BA1"
pass "$FILTER_BA_TOTAL verification(s) for bank account #1"

step 21 "Guard: cannot override already-terminal verification"
TERMINAL_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/bank-account-verifications/$VER1_ID/override" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"status":"verified","override_reason":"Should fail"}')
TERMINAL_HTTP=$(echo "$TERMINAL_RES" | tail -n1)
[ "$TERMINAL_HTTP" = "409" ] || fail "Expected 409 for terminal-state override, got $TERMINAL_HTTP"
pass "Correctly rejected override of terminal verification"

echo -e "\n${GREEN}━━━ Bank Account Verifications Realistic Lifecycle Complete ━━━${NC}"
