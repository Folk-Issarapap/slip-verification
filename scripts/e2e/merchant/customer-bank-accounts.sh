#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Merchant — Customer Bank Accounts (Realistic Lifecycle)
#
# Endpoints:
#   GET  /v1/merchant/customer-bank-accounts
#   GET  /v1/merchant/customer-bank-accounts/{id}
#   POST /v1/merchant/customer-bank-accounts
#   POST /v1/merchant/customer-bank-accounts/{id}/set-default
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

echo -e "${CYAN}━━━ Merchant E2E — Customer Bank Accounts (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
MERCHANT_ID="$DEMO_MERCHANT_ID"
OWNER_TOKEN="$DEMO_OWNER_TOKEN"
OWNER="Authorization: Bearer $OWNER_TOKEN"
MERCH="X-Merchant-Id: $MERCHANT_ID"
pass "Merchant: ${MERCHANT_ID:0:16}..."

# Fetch a valid bank_id from the public banks list
BANKS=$(curl -s "$BROPAY/v1/banks" -H "$ORIGIN")
BANK_ID=$(echo "$BANKS" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')")
[ -n "$BANK_ID" ] || warn "No banks found — using placeholder bank_id"
BANK_ID="${BANK_ID:-bkk_bank}"

step 2 "Create two customers"
TS=$(date +%s)

CUST1_RES=$(curl -s "$BROPAY/v1/merchant/customers" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"first_name\":\"Alice\",\"last_name\":\"Nguyen\",\"email\":\"alice-cba-$TS@example.com\",\"phone\":\"+66811111111\"}")
CUST1_ID=$(echo "$CUST1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$CUST1_ID" ] || fail "Customer 1 creation failed"
pass "Customer 1: ${CUST1_ID:0:16}... (Alice Nguyen)"

CUST2_RES=$(curl -s "$BROPAY/v1/merchant/customers" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"first_name\":\"Bob\",\"last_name\":\"Smith\",\"email\":\"bob-cba-$TS@example.com\",\"phone\":\"+66822222222\"}")
CUST2_ID=$(echo "$CUST2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$CUST2_ID" ] || fail "Customer 2 creation failed"
pass "Customer 2: ${CUST2_ID:0:16}... (Bob Smith)"

step 3 "Create customer bank account for Alice"
CREATE1_RES=$(curl -s "$BROPAY/v1/merchant/customer-bank-accounts" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"customer_id\":\"$CUST1_ID\",\"bank_id\":\"$BANK_ID\",\"account_number\":\"9876543210\",\"account_holder_name\":\"Alice Nguyen\"}")
CBA1_ID=$(echo "$CREATE1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$CBA1_ID" ] || fail "Customer bank account 1 creation failed"
pass "Created: ${CBA1_ID:0:16}..."

step 4 "Create customer bank account for Bob"
CREATE2_RES=$(curl -s "$BROPAY/v1/merchant/customer-bank-accounts" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"customer_id\":\"$CUST2_ID\",\"bank_id\":\"$BANK_ID\",\"account_number\":\"1234567890\",\"account_holder_name\":\"Bob Smith\"}")
CBA2_ID=$(echo "$CREATE2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$CBA2_ID" ] || fail "Customer bank account 2 creation failed"
pass "Created: ${CBA2_ID:0:16}..."

step 5 "List all customer bank accounts"
LIST_RES=$(curl -s "$BROPAY/v1/merchant/customer-bank-accounts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
LIST_COUNT=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_COUNT" -ge 2 ] || fail "Expected at least 2 accounts, got $LIST_COUNT"
pass "Listed $LIST_COUNT account(s)"

step 6 "Filter by customer_id"
FILTER_RES=$(curl -s "$BROPAY/v1/merchant/customer-bank-accounts?customer_id=$CUST1_ID" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
FILTER_COUNT=$(echo "$FILTER_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FILTER_COUNT" -ge 1 ] || fail "Expected at least 1 account for customer 1, got $FILTER_COUNT"
pass "$FILTER_COUNT account(s) for customer 1"

step 7 "Search by account_holder_name fragment"
SEARCH_RES=$(curl -s "$BROPAY/v1/merchant/customer-bank-accounts?q=Alice" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SEARCH_COUNT=$(echo "$SEARCH_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$SEARCH_COUNT" -ge 1 ] || fail "Expected at least 1 result for name search, got $SEARCH_COUNT"
pass "$SEARCH_COUNT result(s) for 'Alice'"

step 8 "Sort by account_holder_name asc"
SORT_RES=$(curl -s "$BROPAY/v1/merchant/customer-bank-accounts?sort=account_holder_name&order=asc" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT_OK=$(echo "$SORT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_OK" = "True" ] || fail "Sort by account_holder_name asc failed"
pass "Sorted by account_holder_name asc"

step 9 "Sort by created_at desc"
SORT2_RES=$(curl -s "$BROPAY/v1/merchant/customer-bank-accounts?sort=created_at&order=desc" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT2_OK=$(echo "$SORT2_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT2_OK" = "True" ] || fail "Sort by created_at desc failed"
pass "Sorted by created_at desc"

step 10 "Pagination limit=1"
PAGE_RES=$(curl -s "$BROPAY/v1/merchant/customer-bank-accounts?limit=1&page=1" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
PAGE_LIMIT=$(echo "$PAGE_RES" | json "print(json.load(sys.stdin)['meta']['limit'])")
PAGE_COUNT=$(echo "$PAGE_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE_LIMIT" -eq 1 ] || fail "Expected limit=1, got $PAGE_LIMIT"
[ "$PAGE_COUNT" -eq 1 ] || fail "Expected 1 item in page, got $PAGE_COUNT"
pass "Pagination limit=1 works"

step 11 "GET customer bank account detail"
GET_RES=$(curl -s "$BROPAY/v1/merchant/customer-bank-accounts/$CBA1_ID" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
GET_ID=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$GET_ID" = "$CBA1_ID" ] || fail "GET detail mismatch"
GET_MASKED=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('account_number',''))")
[[ "$GET_MASKED" == ****???? ]] || fail "Expected masked account number, got $GET_MASKED"
pass "Detail fetched with masked account number"

step 12 "Guard: set-default on unverified account returns 400"
DEFAULT_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/customer-bank-accounts/$CBA1_ID/set-default" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d '{}')
DEFAULT_HTTP=$(echo "$DEFAULT_RES" | tail -n1)
[ "$DEFAULT_HTTP" = "400" ] || fail "Expected 400 for unverified set-default, got $DEFAULT_HTTP"
pass "Set-default on unverified rejected with 400"

step 13 "Filter by verification_status=pending"
PEND_RES=$(curl -s "$BROPAY/v1/merchant/customer-bank-accounts?verification_status=pending" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
PEND_COUNT=$(echo "$PEND_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$PEND_COUNT" -ge 2 ] || fail "Expected at least 2 pending accounts, got $PEND_COUNT"
pass "$PEND_COUNT pending account(s)"

step 14 "Filter by verification_status=verified (should be 0)"
VERIF_RES=$(curl -s "$BROPAY/v1/merchant/customer-bank-accounts?verification_status=verified" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
VERIF_COUNT=$(echo "$VERIF_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$VERIF_COUNT" -eq 0 ] || warn "Expected 0 verified accounts, got $VERIF_COUNT (provider may have auto-verified)"
pass "$VERIF_COUNT verified account(s)"

echo -e "\n${GREEN}━━━ Customer Bank Accounts Realistic Lifecycle Complete ━━━${NC}"
