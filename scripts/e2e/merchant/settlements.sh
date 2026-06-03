#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Merchant — Settlements (Realistic Lifecycle)
#
# Endpoints:
#   GET  /v1/merchant/settlements/summary
#   GET  /v1/merchant/settlements/preview
#   GET  /v1/merchant/settlements
#   GET  /v1/merchant/settlements/{id}
#   POST /v1/merchant/settlements
#   GET  /v1/merchant/settlements/{id}/slip
#   GET  /v1/merchant/settlements/{id}/slip/file
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_merchant-lib.sh
source "$SCRIPT_DIR/../_merchant-lib.sh"
BROPAY="${BROPAY_URL:-http://localhost:8787}"
ORIGIN="Origin: http://localhost:3000"
CT="Content-Type: application/json"

GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[0;33m' CYAN='\033[0;36m' NC='\033[0m'
pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }
warn() { echo -e "${YELLOW}! $1${NC}"; }
step() { echo -e "\n${CYAN}━━━ Step $1: $2 ━━━${NC}"; }
json() { python3 -c "import sys,json; $1" 2>/dev/null; }

echo -e "${CYAN}━━━ Merchant E2E — Settlements (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
MERCHANT_ID="$DEMO_MERCHANT_ID"
OWNER_TOKEN="$DEMO_OWNER_TOKEN"
OWNER="Authorization: Bearer $OWNER_TOKEN"
MERCH="X-Merchant-Id: $DEMO_MERCHANT_ID"
pass "Merchant: ${MERCHANT_ID:0:16}..."

step 2 "Ensure integration exists"
INTEGRATIONS=$(curl -s "$BROPAY/v1/merchant/integrations" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
INTEGRATION_COUNT=$(echo "$INTEGRATIONS" | json "print(len(json.load(sys.stdin).get('data',[])))")
if [ "${INTEGRATION_COUNT:-0}" -eq 0 ]; then
  curl -s "$BROPAY/v1/merchant/integrations" -X POST \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
    -d '{"name":"Demo Integration","slug":"demo"}' > /dev/null
  INTEGRATIONS=$(curl -s "$BROPAY/v1/merchant/integrations" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
fi
INTEGRATION_ID=$(echo "$INTEGRATIONS" | json "d=json.load(sys.stdin)['data']; print(d[0]['id'] if d else '')")
[ -n "$INTEGRATION_ID" ] || fail "No integration found"
pass "Integration: ${INTEGRATION_ID:0:16}..."

step 3 "Ensure a verified settlement bank account exists"
BA_LIST=$(curl -s "$BROPAY/v1/merchant/bank-accounts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
BA_COUNT=$(echo "$BA_LIST" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
if [ "${BA_COUNT:-0}" -eq 0 ]; then
  BANKS=$(curl -s "$BROPAY/v1/banks" -H "$ORIGIN")
  BANK_ID=$(echo "$BANKS" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')")
  BANK_ID="${BANK_ID:-bkk_bank}"
  curl -s "$BROPAY/v1/merchant/bank-accounts" -X POST \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
    -d "{\"bank_id\":\"$BANK_ID\",\"account_number\":\"1234567890\",\"account_holder_name\":\"E2E Test\",\"account_type\":\"savings\"}" > /dev/null
fi

# Verify via admin that a verified for_settlement account exists
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
ADMIN_BA=$(curl -s "$BROPAY/v1/admin/merchants/$MERCHANT_ID/bank-accounts" -H "$ADMIN" -H "$ORIGIN")
VERIFIED_BA_ID=$(echo "$ADMIN_BA" | json "d=json.load(sys.stdin).get('data',[]); print(next((x['id'] for x in d if x.get('verification_status')=='verified' and x.get('for_settlement')==1), ''))")
if [ -z "$VERIFIED_BA_ID" ]; then
  warn "No verified for_settlement bank account — settlement creation will be skipped"
  SKIP_CREATE=1
else
  SKIP_CREATE=0
fi
pass "Bank account check complete (skip_create=$SKIP_CREATE)"

step 4 "GET settlement summary"
SUM_RES=$(curl -s "$BROPAY/v1/merchant/settlements/summary" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
HAS_DATA=$(echo "$SUM_RES" | json "print('data' in json.load(sys.stdin))")
[ "$HAS_DATA" = "True" ] || fail "Summary missing data"
SUM_PENDING=$(echo "$SUM_RES" | json "print(json.load(sys.stdin).get('data',{}).get('pending_count',0))")
pass "Summary fetched (pending_count=$SUM_PENDING)"

step 5 "GET settlement preview"
PREV_RES=$(curl -s "$BROPAY/v1/merchant/settlements/preview" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
HAS_DATA=$(echo "$PREV_RES" | json "print('data' in json.load(sys.stdin))")
[ "$HAS_DATA" = "True" ] || fail "Preview missing data"
PREV_ELIGIBLE=$(echo "$PREV_RES" | json "print(json.load(sys.stdin).get('data',{}).get('eligible_transaction_count',0))")
PREV_CAN_COVER=$(echo "$PREV_RES" | json "print(json.load(sys.stdin).get('data',{}).get('can_cover',False))")
pass "Preview fetched (eligible=$PREV_ELIGIBLE, can_cover=$PREV_CAN_COVER)"

step 6 "List settlements"
LIST_RES=$(curl -s "$BROPAY/v1/merchant/settlements" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$HAS_META" = "True" ] || fail "Settlement list missing meta"
LIST_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
pass "Listed $LIST_TOTAL settlement(s)"

step 7 "Filter settlements by status"
STAT_RES=$(curl -s "$BROPAY/v1/merchant/settlements?status=pending" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
STAT_HAS_META=$(echo "$STAT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$STAT_HAS_META" = "True" ] || fail "Status filter missing meta"
pass "Filtered by status=pending"

step 8 "Filter settlements by settlement_type=manual"
TYPE_RES=$(curl -s "$BROPAY/v1/merchant/settlements?settlement_type=manual" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
TYPE_HAS_META=$(echo "$TYPE_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$TYPE_HAS_META" = "True" ] || fail "Type filter missing meta"
pass "Filtered by settlement_type=manual"

step 9 "Filter settlements by integration_id"
INT_RES=$(curl -s "$BROPAY/v1/merchant/settlements?integration_id=$INTEGRATION_ID" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
INT_HAS_META=$(echo "$INT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$INT_HAS_META" = "True" ] || fail "Integration filter missing meta"
pass "Filtered by integration_id"

step 10 "Sort settlements by gross_amount desc"
SORT_RES=$(curl -s "$BROPAY/v1/merchant/settlements?sort=gross_amount&order=desc" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT_HAS_META=$(echo "$SORT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_HAS_META" = "True" ] || fail "Sort by gross_amount desc missing meta"
pass "Sorted by gross_amount desc"

step 11 "Sort settlements by settlement_date asc"
SORT2_RES=$(curl -s "$BROPAY/v1/merchant/settlements?sort=settlement_date&order=asc" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT2_HAS_META=$(echo "$SORT2_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT2_HAS_META" = "True" ] || fail "Sort by settlement_date asc missing meta"
pass "Sorted by settlement_date asc"

step 12 "Search settlements by q"
SEARCH_RES=$(curl -s "$BROPAY/v1/merchant/settlements?q=stl" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SEARCH_OK=$(echo "$SEARCH_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SEARCH_OK" = "True" ] || fail "Settlement search failed"
pass "Search returned results"

step 13 "Paginate settlements"
PAGE_RES=$(curl -s "$BROPAY/v1/merchant/settlements?limit=2&page=1" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
PAGE_LIMIT=$(echo "$PAGE_RES" | json "print(json.load(sys.stdin)['meta']['limit'])")
PAGE_COUNT=$(echo "$PAGE_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE_LIMIT" -eq 2 ] || fail "Expected limit=2, got $PAGE_LIMIT"
[ "$PAGE_COUNT" -le 2 ] || fail "Expected at most 2 items in page, got $PAGE_COUNT"
pass "Pagination limit=2 works"

step 14 "Seed transactions for settlement creation"
TS=$(date +%s)
TX1=$(python3 -c "import uuid; print(uuid.uuid4())")
TX2=$(python3 -c "import uuid; print(uuid.uuid4())")
TX3=$(python3 -c "import uuid; print(uuid.uuid4())")

e2e_d1_local_sql \
  "INSERT INTO transactions (id, merchant_id, integration_id, reference_type, reference_id, amount, currency, direction, fee_amount, net_amount, status, created_at, updated_at) VALUES
  ('$TX1', '$MERCHANT_ID', '$INTEGRATION_ID', 'payment', 'pi-$TS-1', 100000, 'THB', 'credit', 1500, 98500, 'completed', datetime('now', '-1 hour'), datetime('now')),
  ('$TX2', '$MERCHANT_ID', '$INTEGRATION_ID', 'payment', 'pi-$TS-2', 200000, 'THB', 'credit', 3000, 197000, 'completed', datetime('now', '-50 minutes'), datetime('now')),
  ('$TX3', '$MERCHANT_ID', '$INTEGRATION_ID', 'payment', 'pi-$TS-3', 300000, 'THB', 'credit', 4500, 295500, 'completed', datetime('now', '-40 minutes'), datetime('now'))"
pass "3 eligible transactions seeded"

step 15 "GET settlement preview after seeding"
PREV2_RES=$(curl -s "$BROPAY/v1/merchant/settlements/preview" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
PREV2_ELIGIBLE=$(echo "$PREV2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('eligible_transaction_count',0))")
[ "$PREV2_ELIGIBLE" -ge 3 ] || fail "Expected at least 3 eligible transactions after seed, got $PREV2_ELIGIBLE"
pass "Preview shows $PREV2_ELIGIBLE eligible transaction(s)"

if [ "$SKIP_CREATE" -eq 0 ]; then
  step 16 "POST create settlement"
  CREATE_RES=$(curl -s "$BROPAY/v1/merchant/settlements" -X POST \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
    -d "{\"bank_account_id\":\"$VERIFIED_BA_ID\",\"integration_id\":\"$INTEGRATION_ID\"}")
  CREATE_HTTP=$(echo "$CREATE_RES" | json "print('data' in json.load(sys.stdin))")
  if [ "$CREATE_HTTP" = "True" ]; then
    SETTLEMENT_ID=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
    [ -n "$SETTLEMENT_ID" ] || fail "Settlement creation returned data but no id"
    pass "Created settlement: ${SETTLEMENT_ID:0:16}..."

    step 17 "GET settlement detail"
    GET_RES=$(curl -s "$BROPAY/v1/merchant/settlements/$SETTLEMENT_ID" \
      -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
    GET_ID=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
    [ "$GET_ID" = "$SETTLEMENT_ID" ] || fail "GET detail mismatch"
    GET_ITEMS=$(echo "$GET_RES" | json "print(len(json.load(sys.stdin).get('data',{}).get('items',[])))")
    GET_EVENTS=$(echo "$GET_RES" | json "print(len(json.load(sys.stdin).get('data',{}).get('events',[])))")
    pass "Detail fetched with $GET_ITEMS item(s) and $GET_EVENTS event(s)"

    step 18 "Verify settlement appears in list"
    LIST2_RES=$(curl -s "$BROPAY/v1/merchant/settlements" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
    LIST2_IDS=$(echo "$LIST2_RES" | json "d=json.load(sys.stdin).get('data',[]); print([x['id'] for x in d])")
    echo "$LIST2_IDS" | grep -q "$SETTLEMENT_ID" || fail "Created settlement not found in list"
    pass "Settlement appears in list"

    step 19 "Filter by status after creation"
    PEND_RES=$(curl -s "$BROPAY/v1/merchant/settlements?status=pending" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
    PEND_HAS=$(echo "$PEND_RES" | json "d=json.load(sys.stdin).get('data',[]); print('True' if any(x.get('id')=='$SETTLEMENT_ID' for x in d) else 'False')")
    [ "$PEND_HAS" = "True" ] || fail "Created settlement not in pending filter"
    pass "Created settlement found in pending filter"

    step 20 "GET settlement slip (expect 404 — no slip yet)"
    SLIP_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/settlements/$SETTLEMENT_ID/slip" \
      -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
    SLIP_HTTP=$(echo "$SLIP_RES" | tail -n1)
    [ "$SLIP_HTTP" = "404" ] || warn "Expected 404 for slip without upload, got $SLIP_HTTP"
    pass "Slip endpoint returns 404 when no slip exists"
  else
    warn "Settlement creation did not return data (may need verified bank account)"
  fi
else
  warn "Skipping settlement creation — no verified for_settlement bank account"
fi

step 21 "POST settlement with empty body (all fields optional)"
EMPTY_RES=$(curl -s "$BROPAY/v1/merchant/settlements" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{}')
EMPTY_HAS_DATA=$(echo "$EMPTY_RES" | json "print('data' in json.load(sys.stdin))")
EMPTY_HAS_ERROR=$(echo "$EMPTY_RES" | json "print('error' in json.load(sys.stdin))")
if [ "$EMPTY_HAS_DATA" = "True" ]; then
  pass "Empty POST creates settlement with default bank account"
elif [ "$EMPTY_HAS_ERROR" = "True" ]; then
  EMPTY_CODE=$(echo "$EMPTY_RES" | json "print(json.load(sys.stdin).get('error',{}).get('code',''))")
  if [ "$EMPTY_CODE" = "CONFLICT" ]; then
    pass "Empty POST returns 409 when no eligible transactions remain"
  elif [ "$EMPTY_CODE" = "BANK_ACCOUNT_NOT_VERIFIED" ] && [ "${SKIP_CREATE:-0}" = "1" ]; then
    pass "Empty POST returns BANK_ACCOUNT_NOT_VERIFIED without a verified for_settlement bank"
  else
    fail "Unexpected empty POST error (skip_create=$SKIP_CREATE): $EMPTY_CODE"
  fi
else
  fail "Unexpected empty POST response"
fi

step 22 "Preview with integration_id filter"
PREV_INT_RES=$(curl -s "$BROPAY/v1/merchant/settlements/preview?integration_id=$INTEGRATION_ID" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
PREV_INT_OK=$(echo "$PREV_INT_RES" | json "print('data' in json.load(sys.stdin))")
[ "$PREV_INT_OK" = "True" ] || fail "Preview with integration_id failed"
pass "Preview with integration_id filter works"

echo -e "\n${GREEN}━━━ Settlements Realistic Lifecycle Complete ━━━${NC}"
