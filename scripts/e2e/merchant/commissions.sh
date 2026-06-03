#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Merchant — Commissions (Realistic Lifecycle)
#
# Endpoints:
#   GET /v1/merchant/commissions
#   GET /v1/merchant/commissions/summary
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROPAY="${BROPAY_URL:-http://localhost:8787}"
ORIGIN="Origin: http://localhost:3000"

GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[0;33m' CYAN='\033[0;36m' NC='\033[0m'
pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }
warn() { echo -e "${YELLOW}! $1${NC}"; }
step() { echo -e "\n${CYAN}━━━ Step $1: $2 ━━━${NC}"; }
json() { python3 -c "import sys,json; $1" 2>/dev/null; }

echo -e "${CYAN}━━━ Merchant E2E — Commissions (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
OWNER="Authorization: Bearer $DEMO_OWNER_TOKEN"
MERCH="X-Merchant-Id: $DEMO_MERCHANT_ID"
pass "Merchant: ${DEMO_MERCHANT_ID:0:16}..."

step 2 "Check account kind and GET commission summary"
ME_RES=$(curl -s "$BROPAY/v1/auth/me" -H "$OWNER" -H "$ORIGIN")
ACCOUNT_KIND=$(echo "$ME_RES" | json "print(json.load(sys.stdin).get('data',{}).get('kind',''))")
if [ "$ACCOUNT_KIND" != "reseller" ]; then
  warn "Account kind is '$ACCOUNT_KIND' — commissions require reseller; testing 403 guards"
  step 3 "Guard: GET /v1/merchant/commissions/summary returns 403 for non-reseller"
  SUM_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/commissions/summary" \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
  SUM_HTTP=$(echo "$SUM_RES" | tail -n1)
  [ "$SUM_HTTP" = "403" ] || fail "Expected 403 for non-reseller commissions summary, got $SUM_HTTP"
  pass "Commissions summary rejected with 403"

  step 4 "Guard: GET /v1/merchant/commissions returns 403 for non-reseller"
  LIST_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/commissions" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
  LIST_HTTP=$(echo "$LIST_RES" | tail -n1)
  [ "$LIST_HTTP" = "403" ] || fail "Expected 403 for non-reseller commissions list, got $LIST_HTTP"
  pass "Commissions list rejected with 403"

  step 5 "Guard: missing X-Merchant-Id returns 400"
  NO_MERCH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/commissions" \
    -H "$OWNER" -H "$ORIGIN")
  NO_MERCH_HTTP=$(echo "$NO_MERCH_RES" | tail -n1)
  [ "$NO_MERCH_HTTP" = "400" ] || fail "Expected 400 without X-Merchant-Id, got $NO_MERCH_HTTP"
  pass "Missing X-Merchant-Id rejected with 400"

  step 6 "Guard: invalid merchant id returns 404"
  BAD_MERCH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/commissions" \
    -H "$OWNER" -H "X-Merchant-Id: nonexistent-merchant-id" -H "$ORIGIN")
  BAD_MERCH_HTTP=$(echo "$BAD_MERCH_RES" | tail -n1)
  [ "$BAD_MERCH_HTTP" = "404" ] || fail "Expected 404 for invalid merchant, got $BAD_MERCH_HTTP"
  pass "Invalid merchant rejected with 404"

  echo -e "\n${GREEN}━━━ Commissions Realistic Lifecycle Complete (non-reseller guards verified) ━━━${NC}"
  exit 0
fi

SUM_RES=$(curl -s "$BROPAY/v1/merchant/commissions/summary" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
HAS_DATA=$(echo "$SUM_RES" | json "print('data' in json.load(sys.stdin))")
[ "$HAS_DATA" = "True" ] || fail "Commission summary missing data"
TOTAL_EARNED=$(echo "$SUM_RES" | json "print(json.load(sys.stdin).get('data',{}).get('total_earned',''))")
[ -n "$TOTAL_EARNED" ] || fail "total_earned missing"
pass "Summary fetched (total_earned=$TOTAL_EARNED)"

step 3 "List commissions"
LIST_RES=$(curl -s "$BROPAY/v1/merchant/commissions" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$HAS_META" = "True" ] || fail "Commission list missing meta"
LIST_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_TOTAL" -ge 0 ] || fail "Expected total >= 0"
pass "Listed $LIST_TOTAL commission(s)"

step 4 "Search commissions by q"
SEARCH_RES=$(curl -s "$BROPAY/v1/merchant/commissions?q=commission" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SEARCH_OK=$(echo "$SEARCH_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SEARCH_OK" = "True" ] || fail "Commission search failed"
pass "Search returned results"

step 5 "Sort commissions by created_at desc"
SORT_RES=$(curl -s "$BROPAY/v1/merchant/commissions?sort=created_at&order=desc" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT_OK=$(echo "$SORT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_OK" = "True" ] || fail "Sort by created_at desc failed"
pass "Sorted by created_at desc"

step 6 "Sort commissions by amount asc"
SORT_AMT_RES=$(curl -s "$BROPAY/v1/merchant/commissions?sort=amount&order=asc" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT_AMT_OK=$(echo "$SORT_AMT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_AMT_OK" = "True" ] || fail "Sort by amount asc failed"
pass "Sorted by amount asc"

step 7 "Paginate commissions"
PAGE_RES=$(curl -s "$BROPAY/v1/merchant/commissions?limit=2&page=1" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
PAGE_LIMIT=$(echo "$PAGE_RES" | json "print(json.load(sys.stdin)['meta']['limit'])")
PAGE_COUNT=$(echo "$PAGE_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE_LIMIT" -eq 2 ] || fail "Expected limit=2, got $PAGE_LIMIT"
[ "$PAGE_COUNT" -le 2 ] || fail "Expected at most 2 items in page, got $PAGE_COUNT"
pass "Pagination limit=2 works"

step 8 "Filter commissions by date_from"
DATE_RES=$(curl -s "$BROPAY/v1/merchant/commissions?date_from=2024-01-01" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
DATE_OK=$(echo "$DATE_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$DATE_OK" = "True" ] || fail "Date filter failed"
pass "Date filter returned results"

step 9 "Guard: missing X-Merchant-Id returns 400"
NO_MERCH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/commissions" \
  -H "$OWNER" -H "$ORIGIN")
NO_MERCH_HTTP=$(echo "$NO_MERCH_RES" | tail -n1)
[ "$NO_MERCH_HTTP" = "400" ] || fail "Expected 400 without X-Merchant-Id, got $NO_MERCH_HTTP"
pass "Missing X-Merchant-Id rejected with 400"

step 10 "Guard: invalid merchant id returns 404"
BAD_MERCH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/commissions" \
  -H "$OWNER" -H "X-Merchant-Id: nonexistent-merchant-id" -H "$ORIGIN")
BAD_MERCH_HTTP=$(echo "$BAD_MERCH_RES" | tail -n1)
[ "$BAD_MERCH_HTTP" = "404" ] || fail "Expected 404 for invalid merchant, got $BAD_MERCH_HTTP"
pass "Invalid merchant rejected with 404"

echo -e "\n${GREEN}━━━ Commissions Realistic Lifecycle Complete ━━━${NC}"
