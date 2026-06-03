#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Customers (Realistic Lifecycle)
#
# Endpoints:
#   GET /v1/admin/customers
#   GET /v1/admin/customers/{id}
#   POST /v1/merchant/customers
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

echo -e "${CYAN}━━━ Admin E2E — Customers (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
OWNER="Authorization: Bearer $DEMO_OWNER_TOKEN"
MERCH="X-Merchant-Id: $DEMO_MERCHANT_ID"
pass "Admin token acquired (super_admin)"

step 2 "Create 3 customers via merchant API"
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

step 3 "Admin lists all customers"
LIST_RES=$(curl -s "$BROPAY/v1/admin/customers" -H "$ADMIN" -H "$ORIGIN")
LIST_HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$LIST_HAS_META" = "True" ] || fail "Customer list missing meta"
LIST_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_TOTAL" -ge 3 ] || fail "Expected at least 3 customers, got $LIST_TOTAL"
pass "Listed $LIST_TOTAL customer(s)"

step 4 "Admin filters by status=active"
STAT_RES=$(curl -s "$BROPAY/v1/admin/customers?status=active" -H "$ADMIN" -H "$ORIGIN")
STAT_HAS_META=$(echo "$STAT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$STAT_HAS_META" = "True" ] || fail "Active filter missing meta"
STAT_TOTAL=$(echo "$STAT_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$STAT_TOTAL" -ge 3 ] || fail "Expected at least 3 active customers, got $STAT_TOTAL"
pass "$STAT_TOTAL active customer(s)"

step 5 "Admin filters by multi-status (active,suspended)"
MULTI_STAT_RES=$(curl -s "$BROPAY/v1/admin/customers?status=active,suspended" -H "$ADMIN" -H "$ORIGIN")
MULTI_STAT_HAS_META=$(echo "$MULTI_STAT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$MULTI_STAT_HAS_META" = "True" ] || fail "Multi-status filter missing meta"
MULTI_STAT_TOTAL=$(echo "$MULTI_STAT_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$MULTI_STAT_TOTAL" -ge 3 ] || fail "Expected at least 3 customers for active,suspended, got $MULTI_STAT_TOTAL"
pass "$MULTI_STAT_TOTAL customer(s) for active/suspended"

step 6 "Admin filters by risk_level=low"
RISK_RES=$(curl -s "$BROPAY/v1/admin/customers?risk_level=low" -H "$ADMIN" -H "$ORIGIN")
RISK_HAS_META=$(echo "$RISK_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$RISK_HAS_META" = "True" ] || fail "Low risk filter missing meta"
RISK_TOTAL=$(echo "$RISK_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$RISK_TOTAL" -ge 3 ] || fail "Expected at least 3 low-risk customers, got $RISK_TOTAL"
pass "$RISK_TOTAL low-risk customer(s)"

step 7 "Admin filters by multi-risk_level (low,medium)"
MULTI_RISK_RES=$(curl -s "$BROPAY/v1/admin/customers?risk_level=low,medium" -H "$ADMIN" -H "$ORIGIN")
MULTI_RISK_HAS_META=$(echo "$MULTI_RISK_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$MULTI_RISK_HAS_META" = "True" ] || fail "Multi-risk filter missing meta"
MULTI_RISK_TOTAL=$(echo "$MULTI_RISK_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$MULTI_RISK_TOTAL" -ge 3 ] || fail "Expected at least 3 customers for low/medium, got $MULTI_RISK_TOTAL"
pass "$MULTI_RISK_TOTAL customer(s) for low/medium risk"

step 8 "Admin filters by merchant_id"
MERCH_RES=$(curl -s "$BROPAY/v1/admin/customers?merchant_id=$DEMO_MERCHANT_ID" -H "$ADMIN" -H "$ORIGIN")
MERCH_HAS_META=$(echo "$MERCH_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$MERCH_HAS_META" = "True" ] || fail "Merchant filter missing meta"
MERCH_TOTAL=$(echo "$MERCH_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$MERCH_TOTAL" -ge 3 ] || fail "Expected at least 3 customers for merchant, got $MERCH_TOTAL"
pass "$MERCH_TOTAL customer(s) for merchant"

step 9 "Admin searches by q (email fragment)"
SEARCH_EMAIL_RES=$(curl -s "$BROPAY/v1/admin/customers?q=alice-$TS" -H "$ADMIN" -H "$ORIGIN")
SEARCH_EMAIL_HAS_META=$(echo "$SEARCH_EMAIL_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SEARCH_EMAIL_HAS_META" = "True" ] || fail "Email search missing meta"
SEARCH_EMAIL_TOTAL=$(echo "$SEARCH_EMAIL_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$SEARCH_EMAIL_TOTAL" -ge 1 ] || fail "Expected at least 1 result for email fragment, got $SEARCH_EMAIL_TOTAL"
pass "$SEARCH_EMAIL_TOTAL result(s) for email fragment"

step 10 "Admin searches by q (name fragment)"
SEARCH_NAME_RES=$(curl -s "$BROPAY/v1/admin/customers?q=Bob" -H "$ADMIN" -H "$ORIGIN")
SEARCH_NAME_HAS_META=$(echo "$SEARCH_NAME_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SEARCH_NAME_HAS_META" = "True" ] || fail "Name search missing meta"
SEARCH_NAME_TOTAL=$(echo "$SEARCH_NAME_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$SEARCH_NAME_TOTAL" -ge 1 ] || fail "Expected at least 1 result for name fragment, got $SEARCH_NAME_TOTAL"
pass "$SEARCH_NAME_TOTAL result(s) for name fragment"

step 11 "Admin searches by q (phone fragment)"
SEARCH_PHONE_RES=$(curl -s "$BROPAY/v1/admin/customers?q=33333333" -H "$ADMIN" -H "$ORIGIN")
SEARCH_PHONE_HAS_META=$(echo "$SEARCH_PHONE_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SEARCH_PHONE_HAS_META" = "True" ] || fail "Phone search missing meta"
SEARCH_PHONE_TOTAL=$(echo "$SEARCH_PHONE_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$SEARCH_PHONE_TOTAL" -ge 1 ] || fail "Expected at least 1 result for phone fragment, got $SEARCH_PHONE_TOTAL"
pass "$SEARCH_PHONE_TOTAL result(s) for phone fragment"

step 12 "Admin sorts by created_at desc"
SORT_CREATED_RES=$(curl -s "$BROPAY/v1/admin/customers?sort=created_at&order=desc" -H "$ADMIN" -H "$ORIGIN")
SORT_CREATED_HAS_META=$(echo "$SORT_CREATED_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_CREATED_HAS_META" = "True" ] || fail "Sort by created_at desc missing meta"
pass "Sorted by created_at desc"

step 13 "Admin sorts by risk_level asc"
SORT_RISK_RES=$(curl -s "$BROPAY/v1/admin/customers?sort=risk_level&order=asc" -H "$ADMIN" -H "$ORIGIN")
SORT_RISK_HAS_META=$(echo "$SORT_RISK_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_RISK_HAS_META" = "True" ] || fail "Sort by risk_level asc missing meta"
pass "Sorted by risk_level asc"

step 14 "Admin sorts by total_transactions desc"
SORT_TX_RES=$(curl -s "$BROPAY/v1/admin/customers?sort=total_transactions&order=desc" -H "$ADMIN" -H "$ORIGIN")
SORT_TX_HAS_META=$(echo "$SORT_TX_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_TX_HAS_META" = "True" ] || fail "Sort by total_transactions desc missing meta"
pass "Sorted by total_transactions desc"

step 15 "Admin paginates customers"
PAGE_RES=$(curl -s "$BROPAY/v1/admin/customers?limit=2&page=1" -H "$ADMIN" -H "$ORIGIN")
PAGE_LIMIT=$(echo "$PAGE_RES" | json "print(json.load(sys.stdin)['meta']['limit'])")
PAGE_COUNT=$(echo "$PAGE_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE_LIMIT" -eq 2 ] || fail "Expected limit=2, got $PAGE_LIMIT"
[ "$PAGE_COUNT" -eq 2 ] || fail "Expected 2 items in page, got $PAGE_COUNT"
pass "Pagination limit=2 works"

step 16 "Admin gets customer detail — verify ID, merchants, bank_accounts"
DETAIL_RES=$(curl -s "$BROPAY/v1/admin/customers/$CUST1_ID" -H "$ADMIN" -H "$ORIGIN")
DETAIL_ID=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$DETAIL_ID" = "$CUST1_ID" ] || fail "Detail ID mismatch"
DETAIL_HAS_MERCHANTS=$(echo "$DETAIL_RES" | json "print('merchants' in json.load(sys.stdin).get('data',{}))")
[ "$DETAIL_HAS_MERCHANTS" = "True" ] || fail "Detail missing merchants array"
DETAIL_HAS_BANKS=$(echo "$DETAIL_RES" | json "print('bank_accounts' in json.load(sys.stdin).get('data',{}))")
[ "$DETAIL_HAS_BANKS" = "True" ] || fail "Detail missing bank_accounts array"
MERCHANTS_COUNT=$(echo "$DETAIL_RES" | json "print(len(json.load(sys.stdin).get('data',{}).get('merchants',[])))")
[ "$MERCHANTS_COUNT" -ge 1 ] || fail "Expected at least 1 linked merchant, got $MERCHANTS_COUNT"
pass "Detail fetched with $MERCHANTS_COUNT merchant(s) and bank_accounts array"

step 17 "Admin gets detail for a customer with no bank accounts"
NO_BANK_RES=$(curl -s "$BROPAY/v1/admin/customers/$CUST2_ID" -H "$ADMIN" -H "$ORIGIN")
NO_BANK_ID=$(echo "$NO_BANK_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$NO_BANK_ID" = "$CUST2_ID" ] || fail "No-bank detail ID mismatch"
NO_BANK_BANKS=$(echo "$NO_BANK_RES" | json "print(len(json.load(sys.stdin).get('data',{}).get('bank_accounts',[])))")
[ "$NO_BANK_BANKS" -eq 0 ] || fail "Expected 0 bank accounts for fresh customer, got $NO_BANK_BANKS"
NO_BANK_MERCHANTS=$(echo "$NO_BANK_RES" | json "print(len(json.load(sys.stdin).get('data',{}).get('merchants',[])))")
[ "$NO_BANK_MERCHANTS" -ge 1 ] || fail "Expected at least 1 linked merchant for fresh customer, got $NO_BANK_MERCHANTS"
pass "Fresh customer detail: $NO_BANK_MERCHANTS merchant(s), 0 bank accounts"

echo -e "\n${GREEN}━━━ Customers Realistic Lifecycle Complete ━━━${NC}"
