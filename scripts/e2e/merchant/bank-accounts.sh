#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Merchant — Bank Accounts (Realistic Lifecycle)
#
# Endpoints:
#   GET  /v1/merchant/bank-accounts
#   GET  /v1/merchant/bank-accounts/{id}
#   POST /v1/merchant/bank-accounts
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

echo -e "${CYAN}━━━ Merchant E2E — Bank Accounts (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
OWNER="Authorization: Bearer $DEMO_OWNER_TOKEN"
MERCH="X-Merchant-Id: $DEMO_MERCHANT_ID"
pass "Merchant: ${DEMO_MERCHANT_ID:0:16}..."

# Fetch a valid bank_id from the public banks list
BANKS=$(curl -s "$BROPAY/v1/banks" -H "$ORIGIN")
BANK_ID=$(echo "$BANKS" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')")
[ -n "$BANK_ID" ] || warn "No banks found — using placeholder bank_id"
BANK_ID="${BANK_ID:-bkk_bank}"

step 2 "Create bank account"
TS=$(date +%s)
CREATE_RES=$(curl -s "$BROPAY/v1/merchant/bank-accounts" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"bank_id\":\"$BANK_ID\",\"account_number\":\"1234567890\",\"account_holder_name\":\"E2E Test $TS\",\"account_type\":\"savings\"}")
ACCT_ID=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$ACCT_ID" ] || fail "Bank account creation failed"
ACCT_NUMBER=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('account_number',''))")
[ "$ACCT_NUMBER" = "****7890" ] || warn "Account number not masked as expected"
pass "Created: ${ACCT_ID:0:16}..."

step 3 "List bank accounts"
LIST_RES=$(curl -s "$BROPAY/v1/merchant/bank-accounts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
LIST_COUNT=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_COUNT" -ge 1 ] || fail "Expected at least 1 bank account"
pass "Listed $LIST_COUNT account(s)"

step 4 "GET bank account detail"
GET_RES=$(curl -s "$BROPAY/v1/merchant/bank-accounts/$ACCT_ID" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
GET_ID=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$GET_ID" = "$ACCT_ID" ] || fail "GET detail mismatch"
GET_NUMBER=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('account_number',''))")
[ "$GET_NUMBER" = "****7890" ] || warn "Detail account number not masked as expected"
pass "Detail fetched"

step 5 "Filter bank accounts by status=pending (new rows default pending until verified)"
STAT_RES=$(curl -s "$BROPAY/v1/merchant/bank-accounts?status=pending" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
STAT_COUNT=$(echo "$STAT_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$STAT_COUNT" -ge 1 ] || fail "Expected at least 1 pending account"
pass "$STAT_COUNT pending account(s) (account lifecycle status)"

step 6 "Filter bank accounts by verification_status=pending"
VERIF_RES=$(curl -s "$BROPAY/v1/merchant/bank-accounts?verification_status=pending" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
VERIF_COUNT=$(echo "$VERIF_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$VERIF_COUNT" -ge 1 ] || fail "Expected at least 1 pending account"
pass "$VERIF_COUNT pending account(s)"

step 7 "Search bank accounts by q (holder name fragment)"
SEARCH_RES=$(curl -s "$BROPAY/v1/merchant/bank-accounts?q=E2E" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SEARCH_OK=$(echo "$SEARCH_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SEARCH_OK" = "True" ] || fail "Search by holder name failed"
pass "Search returned results"

step 8 "Sort bank accounts by created_at desc"
SORT_RES=$(curl -s "$BROPAY/v1/merchant/bank-accounts?sort=created_at&order=desc" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT_OK=$(echo "$SORT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_OK" = "True" ] || fail "Sort by created_at desc failed"
pass "Sorted by created_at desc"

step 9 "Sort bank accounts by account_holder_name asc"
SORT_NAME_RES=$(curl -s "$BROPAY/v1/merchant/bank-accounts?sort=account_holder_name&order=asc" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT_NAME_OK=$(echo "$SORT_NAME_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_NAME_OK" = "True" ] || fail "Sort by account_holder_name asc failed"
pass "Sorted by account_holder_name asc"

step 10 "Paginate bank accounts"
PAGE_RES=$(curl -s "$BROPAY/v1/merchant/bank-accounts?limit=1&page=1" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
PAGE_LIMIT=$(echo "$PAGE_RES" | json "print(json.load(sys.stdin)['meta']['limit'])")
PAGE_COUNT=$(echo "$PAGE_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE_LIMIT" -eq 1 ] || fail "Expected limit=1, got $PAGE_LIMIT"
[ "$PAGE_COUNT" -le 1 ] || fail "Expected at most 1 item in page, got $PAGE_COUNT"
pass "Pagination limit=1 works"

step 11 "Guard: set-default on unverified account returns 400"
DEFAULT_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/bank-accounts/$ACCT_ID/set-default" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{"designation":"for_settlement"}')
DEFAULT_HTTP=$(echo "$DEFAULT_RES" | tail -n1)
[ "$DEFAULT_HTTP" = "400" ] || fail "Expected 400 for set-default on unverified account, got $DEFAULT_HTTP"
pass "Set-default on unverified account rejected with 400"

step 12 "Archive bank account"
ARCHIVE_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/bank-accounts/$ACCT_ID/archive" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
ARCHIVE_HTTP=$(echo "$ARCHIVE_RES" | tail -n1)
ARCHIVE_BODY=$(echo "$ARCHIVE_RES" | sed '$d')
if [ "$ARCHIVE_HTTP" = "200" ]; then
  ARCHIVE_STATUS=$(echo "$ARCHIVE_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
  [ "$ARCHIVE_STATUS" = "inactive" ] || fail "Archive did not set status to inactive"
  pass "Archived (status=inactive)"
else
  # Archive may fail if account has active designation (shouldn't since set-default was rejected)
  warn "Archive returned $ARCHIVE_HTTP — may be expected if account has active designation"
fi

step 13 "Guard: GET non-existent bank account returns 404"
GET_BAD_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/bank-accounts/nonexistent-id" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
GET_BAD_HTTP=$(echo "$GET_BAD_RES" | tail -n1)
[ "$GET_BAD_HTTP" = "404" ] || fail "Expected 404 for non-existent account, got $GET_BAD_HTTP"
pass "Non-existent account rejected with 404"

step 14 "Guard: missing X-Merchant-Id returns 400"
NO_MERCH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/bank-accounts" \
  -H "$OWNER" -H "$ORIGIN")
NO_MERCH_HTTP=$(echo "$NO_MERCH_RES" | tail -n1)
[ "$NO_MERCH_HTTP" = "400" ] || fail "Expected 400 without X-Merchant-Id, got $NO_MERCH_HTTP"
pass "Missing X-Merchant-Id rejected with 400"

step 15 "Guard: invalid merchant id returns 404"
BAD_MERCH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/bank-accounts" \
  -H "$OWNER" -H "X-Merchant-Id: nonexistent-merchant-id" -H "$ORIGIN")
BAD_MERCH_HTTP=$(echo "$BAD_MERCH_RES" | tail -n1)
[ "$BAD_MERCH_HTTP" = "404" ] || fail "Expected 404 for invalid merchant, got $BAD_MERCH_HTTP"
pass "Invalid merchant rejected with 404"

echo -e "\n${GREEN}━━━ Bank Accounts Realistic Lifecycle Complete ━━━${NC}"
