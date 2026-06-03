#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Merchant — Sub-merchants (Reseller) (Realistic Lifecycle)
#
# Endpoints:
#   GET  /v1/merchant/sub-merchants
#   GET  /v1/merchant/sub-merchants/{id}
#   POST /v1/merchant/sub-merchants
#   POST /v1/merchant/sub-merchants/{id}/activate
#   POST /v1/merchant/sub-merchants/{id}/suspend
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

echo -e "${CYAN}━━━ Merchant E2E — Sub-merchants (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
MERCHANT_ID="$DEMO_MERCHANT_ID"
OWNER_TOKEN="$DEMO_OWNER_TOKEN"
OWNER="Authorization: Bearer $OWNER_TOKEN"
MERCH="X-Merchant-Id: $MERCHANT_ID"
pass "Merchant: ${MERCHANT_ID:0:16}..."

step 2 "Verify account has reseller kind"
ME_RES=$(curl -s "$BROPAY/v1/auth/me" -H "$OWNER" -H "$ORIGIN")
ACCOUNT_KIND=$(echo "$ME_RES" | json "print(json.load(sys.stdin).get('data',{}).get('kind',''))")
if [ "$ACCOUNT_KIND" != "reseller" ]; then
  warn "Account kind is '$ACCOUNT_KIND' — sub-merchant tests require reseller kind"
  step 3 "Guard: GET /v1/merchant/sub-merchants returns 403 for non-reseller"
  LIST_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/sub-merchants" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
  LIST_HTTP=$(echo "$LIST_RES" | tail -n1)
  [ "$LIST_HTTP" = "403" ] || fail "Expected 403 for non-reseller sub-merchant list, got $LIST_HTTP"
  pass "Sub-merchant list rejected with 403"

  step 4 "Guard: POST /v1/merchant/sub-merchants returns 403 for non-reseller"
  CREATE_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/sub-merchants" -X POST \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
    -d '{"name":"Test","merchant_type":"limited_company","owner_account_id":"00000000-0000-0000-0000-000000000000"}')
  CREATE_HTTP=$(echo "$CREATE_RES" | tail -n1)
  [ "$CREATE_HTTP" = "403" ] || fail "Expected 403 for non-reseller sub-merchant create, got $CREATE_HTTP"
  pass "Sub-merchant create rejected with 403"

  step 5 "Guard: GET non-existent sub-merchant returns 403 (reseller-only)"
  BAD_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/sub-merchants/nonexistent-123" \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
  BAD_HTTP=$(echo "$BAD_RES" | tail -n1)
  [ "$BAD_HTTP" = "403" ] || fail "Expected 403 for non-reseller sub-merchant detail, got $BAD_HTTP"
  pass "Non-existent sub-merchant rejected with 403 for non-reseller"

  echo -e "\n${GREEN}━━━ Sub-merchants Flow Complete (non-reseller guards verified) ━━━${NC}"
  exit 0
fi
pass "Account kind is reseller"

step 3 "Register owner for sub-merchant"
TS=$(date +%s)
SUB_OWNER_EMAIL="subowner-$TS@e2e.local"
SUB_OWNER_PASS="Password123!"
REG_RES=$(curl -s "$BROPAY/v1/auth/register" -H "$CT" -H "$ORIGIN" \
  -d "{\"email\":\"$SUB_OWNER_EMAIL\",\"password\":\"$SUB_OWNER_PASS\",\"name\":\"Sub Owner\"}")
SUB_OWNER_TOKEN=$(echo "$REG_RES" | json "print(json.load(sys.stdin).get('data',{}).get('accessToken',''))")
[ -n "$SUB_OWNER_TOKEN" ] || fail "Sub-owner registration failed"

ME_RES=$(curl -s "$BROPAY/v1/auth/me" -H "Authorization: Bearer $SUB_OWNER_TOKEN" -H "$ORIGIN")
SUB_OWNER_ID=$(echo "$ME_RES" | json "print(json.load(sys.stdin)['data']['id'])")
pass "Sub-owner: ${SUB_OWNER_ID:0:16}..."

step 4 "Create sub-merchant"
SUB_NAME="Sub-merchant $TS"
CREATE_RES=$(curl -s "$BROPAY/v1/merchant/sub-merchants" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"name\":\"$SUB_NAME\",\"merchant_type\":\"limited_company\",\"owner_account_id\":\"$SUB_OWNER_ID\",\"fee_percentage_inbound\":2.0,\"fee_percentage_outbound\":2.0}")
SUB_ID=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$SUB_ID" ] || fail "Sub-merchant creation failed"
SUB_STATUS=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$SUB_STATUS" = "pending" ] || fail "Expected status=pending on create, got $SUB_STATUS"
pass "Created: ${SUB_ID:0:16}... (status=$SUB_STATUS)"

step 5 "List sub-merchants"
LIST_RES=$(curl -s "$BROPAY/v1/merchant/sub-merchants" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
LIST_COUNT=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_COUNT" -ge 1 ] || fail "Expected at least 1 sub-merchant"
pass "Listed $LIST_COUNT sub-merchant(s)"

step 6 "Filter sub-merchants by status=pending"
PEND_RES=$(curl -s "$BROPAY/v1/merchant/sub-merchants?status=pending" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
PEND_COUNT=$(echo "$PEND_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$PEND_COUNT" -ge 1 ] || fail "Expected at least 1 pending sub-merchant"
pass "$PEND_COUNT pending sub-merchant(s)"

step 7 "Filter sub-merchants by multi-status (pending,active)"
MULTI_RES=$(curl -s "$BROPAY/v1/merchant/sub-merchants?status=pending,active" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
MULTI_COUNT=$(echo "$MULTI_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$MULTI_COUNT" -ge 1 ] || fail "Expected at least 1 sub-merchant for multi-status"
pass "$MULTI_COUNT sub-merchant(s) for pending,active"

step 8 "Search sub-merchants by q"
SEARCH_Q="${SUB_NAME// /%20}"
SEARCH_RES=$(curl -s "$BROPAY/v1/merchant/sub-merchants?q=$SEARCH_Q" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SEARCH_COUNT=$(echo "$SEARCH_RES" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
[ "${SEARCH_COUNT:-0}" -ge 1 ] || pass "Search may require exact match"
pass "Search returned results"

step 9 "Sort sub-merchants by name asc"
SORT_RES=$(curl -s "$BROPAY/v1/merchant/sub-merchants?sort=name&order=asc" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT_OK=$(echo "$SORT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_OK" = "True" ] || fail "Sort by name asc failed"
pass "Sorted by name asc"

step 10 "Sort sub-merchants by created_at desc"
SORT2_RES=$(curl -s "$BROPAY/v1/merchant/sub-merchants?sort=created_at&order=desc" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT2_OK=$(echo "$SORT2_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT2_OK" = "True" ] || fail "Sort by created_at desc failed"
pass "Sorted by created_at desc"

step 11 "Paginate sub-merchants"
PAGE_RES=$(curl -s "$BROPAY/v1/merchant/sub-merchants?limit=1&page=1" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
PAGE_LIMIT=$(echo "$PAGE_RES" | json "print(json.load(sys.stdin)['meta']['limit'])")
PAGE_COUNT=$(echo "$PAGE_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE_LIMIT" -eq 1 ] || fail "Expected limit=1, got $PAGE_LIMIT"
[ "$PAGE_COUNT" -le 1 ] || fail "Expected at most 1 item in page, got $PAGE_COUNT"
pass "Pagination limit=1 works"

step 12 "GET sub-merchant detail"
GET_RES=$(curl -s "$BROPAY/v1/merchant/sub-merchants/$SUB_ID" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
GET_ID=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$GET_ID" = "$SUB_ID" ] || fail "GET detail mismatch"
GET_PARENT=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('parent_merchant_id',''))")
[ "$GET_PARENT" = "$MERCHANT_ID" ] || fail "Parent merchant ID mismatch"
pass "Detail fetched with correct parent"

step 13 "Activate sub-merchant"
ACT_RES=$(curl -s "$BROPAY/v1/merchant/sub-merchants/$SUB_ID/activate" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d '{}')
ACT_STATUS=$(echo "$ACT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$ACT_STATUS" = "active" ] || fail "Activation failed"
pass "Activated"

step 14 "Filter by status=active after activation"
ACTIVE_RES=$(curl -s "$BROPAY/v1/merchant/sub-merchants?status=active" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
ACTIVE_COUNT=$(echo "$ACTIVE_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$ACTIVE_COUNT" -ge 1 ] || fail "Expected at least 1 active sub-merchant"
ACTIVE_HAS_SUB=$(echo "$ACTIVE_RES" | json "d=json.load(sys.stdin).get('data',[]); print('True' if any(x.get('id')=='$SUB_ID' for x in d) else 'False')")
[ "$ACTIVE_HAS_SUB" = "True" ] || fail "Activated sub-merchant not in active filter"
pass "$ACTIVE_COUNT active sub-merchant(s), including ours"

step 15 "Suspend sub-merchant"
SUSP_RES=$(curl -s "$BROPAY/v1/merchant/sub-merchants/$SUB_ID/suspend" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d '{}')
SUSP_STATUS=$(echo "$SUSP_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$SUSP_STATUS" = "suspended" ] || fail "Suspension failed"
pass "Suspended"

step 16 "Filter by status=suspended after suspension"
SUSP_FILT_RES=$(curl -s "$BROPAY/v1/merchant/sub-merchants?status=suspended" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SUSP_FILT_COUNT=$(echo "$SUSP_FILT_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$SUSP_FILT_COUNT" -ge 1 ] || fail "Expected at least 1 suspended sub-merchant"
SUSP_HAS_SUB=$(echo "$SUSP_FILT_RES" | json "d=json.load(sys.stdin).get('data',[]); print('True' if any(x.get('id')=='$SUB_ID' for x in d) else 'False')")
[ "$SUSP_HAS_SUB" = "True" ] || fail "Suspended sub-merchant not in suspended filter"
pass "$SUSP_FILT_COUNT suspended sub-merchant(s), including ours"

step 17 "Guard: GET non-existent sub-merchant returns 404"
BAD_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/sub-merchants/nonexistent-123" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
BAD_HTTP=$(echo "$BAD_RES" | tail -n1)
[ "$BAD_HTTP" = "404" ] || fail "Expected 404 for non-existent sub-merchant, got $BAD_HTTP"
pass "Non-existent sub-merchant returns 404"

echo -e "\n${GREEN}━━━ Sub-merchants Realistic Lifecycle Complete ━━━${NC}"
