#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Merchant — Customers (Realistic Lifecycle)
#
# Endpoints:
#   GET   /v1/merchant/customers
#   GET   /v1/merchant/customers/{id}
#   POST  /v1/merchant/customers
#   PUT   /v1/merchant/customers/{id}
#   PATCH /v1/merchant/customers/{id}
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

echo -e "${CYAN}━━━ Merchant E2E — Customers (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
MERCHANT_ID="$DEMO_MERCHANT_ID"
OWNER_TOKEN="$DEMO_OWNER_TOKEN"
OWNER="Authorization: Bearer $OWNER_TOKEN"
MERCH="X-Merchant-Id: $MERCHANT_ID"
pass "Merchant: ${MERCHANT_ID:0:16}..."

step 2 "Create 3 customers"
TS=$(date +%s)

CUST1_RES=$(curl -s "$BROPAY/v1/merchant/customers" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"first_name\":\"Alice\",\"last_name\":\"Nguyen\",\"email\":\"alice-$TS@example.com\",\"phone\":\"+66811111111\"}")
CUST1_OK=$(echo "$CUST1_RES" | json "print('data' in json.load(sys.stdin))")
[ "$CUST1_OK" = "True" ] || fail "Customer 1 creation failed"
CUST1_ID=$(echo "$CUST1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
pass "Customer 1: ${CUST1_ID:0:16}... (Alice Nguyen)"

CUST2_RES=$(curl -s "$BROPAY/v1/merchant/customers" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"first_name\":\"Bob\",\"last_name\":\"Smith\",\"email\":\"bob-$TS@example.com\",\"phone\":\"+66822222222\"}")
CUST2_OK=$(echo "$CUST2_RES" | json "print('data' in json.load(sys.stdin))")
[ "$CUST2_OK" = "True" ] || fail "Customer 2 creation failed"
CUST2_ID=$(echo "$CUST2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
pass "Customer 2: ${CUST2_ID:0:16}... (Bob Smith)"

CUST3_RES=$(curl -s "$BROPAY/v1/merchant/customers" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"first_name\":\"Charlie\",\"last_name\":\"Wong\",\"email\":\"charlie-$TS@example.com\",\"phone\":\"+66833333333\"}")
CUST3_OK=$(echo "$CUST3_RES" | json "print('data' in json.load(sys.stdin))")
[ "$CUST3_OK" = "True" ] || fail "Customer 3 creation failed"
CUST3_ID=$(echo "$CUST3_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
pass "Customer 3: ${CUST3_ID:0:16}... (Charlie Wong)"

step 3 "List customers"
LIST_RES=$(curl -s "$BROPAY/v1/merchant/customers" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
LIST_HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$LIST_HAS_META" = "True" ] || fail "Customer list missing meta"
LIST_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_TOTAL" -ge 3 ] || fail "Expected at least 3 customers, got $LIST_TOTAL"
pass "Listed $LIST_TOTAL customer(s)"

step 4 "Filter by status=active"
STAT_RES=$(curl -s "$BROPAY/v1/merchant/customers?status=active" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
STAT_TOTAL=$(echo "$STAT_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$STAT_TOTAL" -ge 3 ] || fail "Expected at least 3 active customers, got $STAT_TOTAL"
pass "$STAT_TOTAL active customer(s)"

step 5 "Filter by multi-status (active,suspended)"
MULTI_STAT_RES=$(curl -s "$BROPAY/v1/merchant/customers?status=active,suspended" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
MULTI_STAT_TOTAL=$(echo "$MULTI_STAT_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$MULTI_STAT_TOTAL" -ge 3 ] || fail "Expected at least 3 customers for active/suspended, got $MULTI_STAT_TOTAL"
pass "$MULTI_STAT_TOTAL customer(s) for active/suspended"

step 6 "Filter by risk_level=low"
RISK_RES=$(curl -s "$BROPAY/v1/merchant/customers?risk_level=low" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
RISK_TOTAL=$(echo "$RISK_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$RISK_TOTAL" -ge 3 ] || fail "Expected at least 3 low-risk customers, got $RISK_TOTAL"
pass "$RISK_TOTAL low-risk customer(s)"

step 7 "Filter by multi-risk_level (low,medium)"
MULTI_RISK_RES=$(curl -s "$BROPAY/v1/merchant/customers?risk_level=low,medium" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
MULTI_RISK_TOTAL=$(echo "$MULTI_RISK_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$MULTI_RISK_TOTAL" -ge 3 ] || fail "Expected at least 3 customers for low/medium, got $MULTI_RISK_TOTAL"
pass "$MULTI_RISK_TOTAL customer(s) for low/medium risk"

step 8 "Search by q (email fragment)"
SEARCH_EMAIL_RES=$(curl -s "$BROPAY/v1/merchant/customers?q=alice-$TS" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SEARCH_EMAIL_TOTAL=$(echo "$SEARCH_EMAIL_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$SEARCH_EMAIL_TOTAL" -ge 1 ] || fail "Expected at least 1 result for email fragment, got $SEARCH_EMAIL_TOTAL"
pass "$SEARCH_EMAIL_TOTAL result(s) for email fragment"

step 9 "Search by q (name fragment)"
SEARCH_NAME_RES=$(curl -s "$BROPAY/v1/merchant/customers?q=Bob" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SEARCH_NAME_TOTAL=$(echo "$SEARCH_NAME_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$SEARCH_NAME_TOTAL" -ge 1 ] || fail "Expected at least 1 result for name fragment, got $SEARCH_NAME_TOTAL"
pass "$SEARCH_NAME_TOTAL result(s) for name fragment"

step 10 "Search by q (last name fragment)"
SEARCH_LN_RES=$(curl -s "$BROPAY/v1/merchant/customers?q=Wong" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SEARCH_LN_TOTAL=$(echo "$SEARCH_LN_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$SEARCH_LN_TOTAL" -ge 1 ] || fail "Expected at least 1 result for last name fragment, got $SEARCH_LN_TOTAL"
pass "$SEARCH_LN_TOTAL result(s) for last name fragment"

step 11 "Sort by created_at desc"
SORT_CREATED_RES=$(curl -s "$BROPAY/v1/merchant/customers?sort=created_at&order=desc" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT_CREATED_OK=$(echo "$SORT_CREATED_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_CREATED_OK" = "True" ] || fail "Sort by created_at desc failed"
pass "Sorted by created_at desc"

step 12 "Sort by first_name asc"
SORT_FN_RES=$(curl -s "$BROPAY/v1/merchant/customers?sort=first_name&order=asc" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT_FN_OK=$(echo "$SORT_FN_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_FN_OK" = "True" ] || fail "Sort by first_name asc failed"
pass "Sorted by first_name asc"

step 13 "Sort by risk_level asc"
SORT_RISK_RES=$(curl -s "$BROPAY/v1/merchant/customers?sort=risk_level&order=asc" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT_RISK_OK=$(echo "$SORT_RISK_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_RISK_OK" = "True" ] || fail "Sort by risk_level asc failed"
pass "Sorted by risk_level asc"

step 14 "Paginate customers"
PAGE_RES=$(curl -s "$BROPAY/v1/merchant/customers?limit=2&page=1" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
PAGE_LIMIT=$(echo "$PAGE_RES" | json "print(json.load(sys.stdin)['meta']['limit'])")
PAGE_COUNT=$(echo "$PAGE_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE_LIMIT" -eq 2 ] || fail "Expected limit=2, got $PAGE_LIMIT"
[ "$PAGE_COUNT" -eq 2 ] || fail "Expected 2 items in page, got $PAGE_COUNT"
pass "Pagination limit=2 works"

step 15 "GET customer detail"
DETAIL_RES=$(curl -s "$BROPAY/v1/merchant/customers/$CUST1_ID" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
DETAIL_ID=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$DETAIL_ID" = "$CUST1_ID" ] || fail "Detail ID mismatch"
DETAIL_EMAIL=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('email',''))")
[ "$DETAIL_EMAIL" = "alice-$TS@example.com" ] || fail "Detail email mismatch"
pass "Detail fetched with correct email"

step 16 "PUT update customer"
PUT_RES=$(curl -s "$BROPAY/v1/merchant/customers/$CUST1_ID" -X PUT \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{"first_name":"Updated","last_name":"Name"}')
PUT_NAME=$(echo "$PUT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('first_name',''))")
[ "$PUT_NAME" = "Updated" ] || fail "PUT update failed"
pass "Updated via PUT: first_name='Updated'"

step 17 "Verify PUT reflected in list"
VERIFY_PUT_RES=$(curl -s "$BROPAY/v1/merchant/customers?q=Updated" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
VERIFY_PUT_TOTAL=$(echo "$VERIFY_PUT_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$VERIFY_PUT_TOTAL" -ge 1 ] || fail "Expected updated customer in search results"
pass "PUT change visible in search"

step 18 "PATCH update customer external_reference_id"
PATCH_REF_ID="ext-ref-$TS"
PATCH_RES=$(curl -s "$BROPAY/v1/merchant/customers/$CUST1_ID" -X PATCH \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"external_reference_id\":\"$PATCH_REF_ID\"}")
PATCH_REF=$(echo "$PATCH_RES" | json "print(json.load(sys.stdin).get('data',{}).get('external_reference_id',''))")
[ "$PATCH_REF" = "$PATCH_REF_ID" ] || fail "PATCH update failed"
pass "Updated via PATCH: external_reference_id='$PATCH_REF_ID'"

step 19 "PATCH update customer risk_level"
PATCH2_RES=$(curl -s "$BROPAY/v1/merchant/customers/$CUST1_ID" -X PATCH \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{"risk_level":"medium"}')
PATCH2_RISK=$(echo "$PATCH2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('risk_level',''))")
[ "$PATCH2_RISK" = "medium" ] || fail "PATCH risk_level update failed"
pass "Updated via PATCH: risk_level='medium'"

step 20 "Guard: PATCH with no fields returns 400"
PATCH_EMPTY_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/customers/$CUST1_ID" -X PATCH \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{}')
PATCH_EMPTY_HTTP=$(echo "$PATCH_EMPTY_RES" | tail -n1)
[ "$PATCH_EMPTY_HTTP" = "400" ] || fail "Expected 400 for empty PATCH, got $PATCH_EMPTY_HTTP"
pass "Empty PATCH rejected with 400"

step 21 "Guard: PUT with no fields returns 400"
PUT_EMPTY_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/customers/$CUST1_ID" -X PUT \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{}')
PUT_EMPTY_HTTP=$(echo "$PUT_EMPTY_RES" | tail -n1)
[ "$PUT_EMPTY_HTTP" = "400" ] || fail "Expected 400 for empty PUT, got $PUT_EMPTY_HTTP"
pass "Empty PUT rejected with 400"

step 22 "Guard: GET non-existent customer returns 404"
NOTFOUND_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/customers/nonexistent-id" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
NOTFOUND_HTTP=$(echo "$NOTFOUND_RES" | tail -n1)
[ "$NOTFOUND_HTTP" = "404" ] || fail "Expected 404 for non-existent customer, got $NOTFOUND_HTTP"
pass "Non-existent customer returns 404"

echo -e "\n${GREEN}━━━ Customers Realistic Lifecycle Complete ━━━${NC}"
