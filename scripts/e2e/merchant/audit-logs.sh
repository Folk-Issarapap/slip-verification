#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Merchant — Audit Logs (Realistic Lifecycle)
#
# Endpoints:
#   GET /v1/merchant/audit-logs
#   GET /v1/merchant/audit-logs/{id}
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

echo -e "${CYAN}━━━ Merchant E2E — Audit Logs (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
OWNER="Authorization: Bearer $DEMO_OWNER_TOKEN"
MERCH="X-Merchant-Id: $DEMO_MERCHANT_ID"
pass "Merchant: ${DEMO_MERCHANT_ID:0:16}..."

step 2 "List audit logs"
LIST_RES=$(curl -s "$BROPAY/v1/merchant/audit-logs" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$HAS_META" = "True" ] || fail "Audit log list missing meta"
LIST_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_TOTAL" -ge 0 ] || fail "Expected total >= 0"
pass "Listed $LIST_TOTAL audit log(s)"

step 3 "Search audit logs by q"
SEARCH_RES=$(curl -s "$BROPAY/v1/merchant/audit-logs?q=merchant" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SEARCH_OK=$(echo "$SEARCH_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SEARCH_OK" = "True" ] || fail "Audit log search failed"
pass "Search returned results"

step 4 "Filter audit logs by action"
ACTION_RES=$(curl -s "$BROPAY/v1/merchant/audit-logs?action=create" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
ACTION_OK=$(echo "$ACTION_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$ACTION_OK" = "True" ] || fail "Action filter failed"
pass "Action filter returned results"

step 5 "Filter audit logs by resource_type"
RT_RES=$(curl -s "$BROPAY/v1/merchant/audit-logs?resource_type=PaymentIntent" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
RT_OK=$(echo "$RT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$RT_OK" = "True" ] || fail "Resource type filter failed"
pass "Resource type filter returned results"

step 6 "Sort audit logs by created_at desc"
SORT_RES=$(curl -s "$BROPAY/v1/merchant/audit-logs?sort=created_at&order=desc" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT_OK=$(echo "$SORT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_OK" = "True" ] || fail "Sort by created_at desc failed"
pass "Sorted by created_at desc"

step 7 "Sort audit logs by created_at asc"
SORT_ASC_RES=$(curl -s "$BROPAY/v1/merchant/audit-logs?sort=created_at&order=asc" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT_ASC_OK=$(echo "$SORT_ASC_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_ASC_OK" = "True" ] || fail "Sort by created_at asc failed"
pass "Sorted by created_at asc"

step 8 "Paginate audit logs"
PAGE_RES=$(curl -s "$BROPAY/v1/merchant/audit-logs?limit=2&page=1" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
PAGE_LIMIT=$(echo "$PAGE_RES" | json "print(json.load(sys.stdin)['meta']['limit'])")
PAGE_COUNT=$(echo "$PAGE_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE_LIMIT" -eq 2 ] || fail "Expected limit=2, got $PAGE_LIMIT"
[ "$PAGE_COUNT" -le 2 ] || fail "Expected at most 2 items in page, got $PAGE_COUNT"
pass "Pagination limit=2 works"

step 9 "Get first audit log detail"
FIRST_ID=$(echo "$LIST_RES" | json "items=json.load(sys.stdin).get('data',[]); print(items[0]['id'] if items else '')")
if [ -n "$FIRST_ID" ]; then
  DETAIL_RES=$(curl -s "$BROPAY/v1/merchant/audit-logs/$FIRST_ID" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
  DETAIL_ID=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
  [ "$DETAIL_ID" = "$FIRST_ID" ] || fail "Detail ID mismatch"
  pass "Detail fetched for ${FIRST_ID:0:16}..."
else
  warn "No audit logs to fetch detail for"
fi

step 10 "Guard: missing X-Merchant-Id returns 400"
NO_MERCH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/audit-logs" \
  -H "$OWNER" -H "$ORIGIN")
NO_MERCH_HTTP=$(echo "$NO_MERCH_RES" | tail -n1)
[ "$NO_MERCH_HTTP" = "400" ] || fail "Expected 400 without X-Merchant-Id, got $NO_MERCH_HTTP"
pass "Missing X-Merchant-Id rejected with 400"

step 11 "Guard: invalid merchant id returns 404"
BAD_MERCH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/audit-logs" \
  -H "$OWNER" -H "X-Merchant-Id: nonexistent-merchant-id" -H "$ORIGIN")
BAD_MERCH_HTTP=$(echo "$BAD_MERCH_RES" | tail -n1)
[ "$BAD_MERCH_HTTP" = "404" ] || fail "Expected 404 for invalid merchant, got $BAD_MERCH_HTTP"
pass "Invalid merchant rejected with 404"

echo -e "\n${GREEN}━━━ Audit Logs Realistic Lifecycle Complete ━━━${NC}"
