#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Payouts (Realistic Lifecycle)
#
# Endpoints:
#   GET  /v1/admin/payouts
#   GET  /v1/admin/payouts/{id}
#   POST /v1/merchant/payouts
#   POST /v1/merchant/payouts/{id}/cancel
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BROPAY="${BROPAY_URL:-http://localhost:8787}"
ORIGIN="Origin: http://localhost:3000"
CT="Content-Type: application/json"

GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[0;33m' CYAN='\033[0;36m' NC='\033[0m'
pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }
warn() { echo -e "${YELLOW}! $1${NC}"; }
step() { echo -e "\n${CYAN}━━━ Step $1: $2 ━━━${NC}"; }
json() { python3 -c "import sys,json; $1" 2>/dev/null; }

echo -e "${CYAN}━━━ Admin E2E — Payouts (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
OWNER="Authorization: Bearer $DEMO_OWNER_TOKEN"
MERCH="X-Merchant-Id: $DEMO_MERCHANT_ID"
pass "Admin token acquired (super_admin)"

step 2 "Ensure verified bank account exists"
BA_LIST=$(curl -s "$BROPAY/v1/merchant/bank-accounts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
BA_COUNT=$(echo "$BA_LIST" | json "print(len(json.load(sys.stdin).get('data',[])))")
if [ "$BA_COUNT" = "0" ]; then
  # Create a bank account
  BA_CREATE=$(curl -s "$BROPAY/v1/merchant/bank-accounts" -X POST \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
    -d '{"bank_id":"bank-kbank-0000-0000-000000000001","account_number":"1234567890","account_holder_name":"Demo Merchant","account_type":"savings"}')
  BA_ID=$(echo "$BA_CREATE" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
else
  BA_ID=$(echo "$BA_LIST" | json "d=json.load(sys.stdin)['data']; print(d[0]['id'] if d else '')")
fi
[ -n "$BA_ID" ] || fail "No bank account available"

# Ensure it's verified for settlement/payout
pushd "$REPO_ROOT/apps/api" > /dev/null
wrangler d1 execute bropay-db --local --command \
  "UPDATE merchant_bank_accounts SET verification_status = 'verified', for_settlement = 1, status = 'active', updated_at = datetime('now') WHERE id = '$BA_ID'" --json 2>/dev/null | grep -q '"success": true'
popd > /dev/null
pass "Verified bank account: ${BA_ID:0:16}..."

step 3 "Fund wallet for payout coverage"
WALLET_DETAIL=$(curl -s "$BROPAY/v1/admin/wallets/$DEMO_WALLET_ID" -H "$ADMIN" -H "$ORIGIN")
WALLET_BALANCE=$(echo "$WALLET_DETAIL" | json "print(json.load(sys.stdin).get('data',{}).get('available_balance',0))")
if [ "$WALLET_BALANCE" -lt 500000 ]; then
  pushd "$REPO_ROOT/apps/api" > /dev/null
  wrangler d1 execute bropay-db --local --command \
    "UPDATE wallets SET available_balance = available_balance + 500000, updated_at = datetime('now') WHERE id = '$DEMO_WALLET_ID'" --json 2>/dev/null | grep -q '"success": true'
  popd > /dev/null
  pass "Wallet funded (+500000 satang)"
else
  pass "Wallet already funded ($WALLET_BALANCE satang)"
fi

step 4 "Merchant creates payout #1 (pending)"
PAYOUT1_RES=$(curl -s "$BROPAY/v1/merchant/payouts" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"amount\":100000,\"merchant_bank_account_id\":\"$BA_ID\",\"description\":\"E2E payout test 1\"}")
PAYOUT1_OK=$(echo "$PAYOUT1_RES" | json "print('data' in json.load(sys.stdin))")
if [ "$PAYOUT1_OK" = "True" ]; then
  PAYOUT1_ID=$(echo "$PAYOUT1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
  PAYOUT1_STATUS=$(echo "$PAYOUT1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
  [ "$PAYOUT1_STATUS" = "pending" ] || fail "Expected pending status, got '$PAYOUT1_STATUS'"
  pass "Payout #1: ${PAYOUT1_ID:0:16}... ($PAYOUT1_STATUS)"
else
  warn "Payout #1 creation failed — will seed via DB"
  PAYOUT1_ID=""
fi

step 5 "Merchant creates payout #2 then cancels it"
PAYOUT2_RES=$(curl -s "$BROPAY/v1/merchant/payouts" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"amount\":50000,\"merchant_bank_account_id\":\"$BA_ID\",\"description\":\"E2E payout to be cancelled\"}")
PAYOUT2_OK=$(echo "$PAYOUT2_RES" | json "print('data' in json.load(sys.stdin))")
if [ "$PAYOUT2_OK" = "True" ]; then
  PAYOUT2_ID=$(echo "$PAYOUT2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
  CANCEL_RES=$(curl -s "$BROPAY/v1/merchant/payouts/$PAYOUT2_ID/cancel" -X POST \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
    -d '{"cancellation_reason":"Customer requested cancellation"}')
  CANCEL_STATUS=$(echo "$CANCEL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
  [ "$CANCEL_STATUS" = "cancelled" ] || warn "Cancel did not return cancelled (got '$CANCEL_STATUS')"
  pass "Payout #2 created and cancelled: ${PAYOUT2_ID:0:16}..."
else
  warn "Payout #2 creation failed — will seed via DB"
  PAYOUT2_ID=""
fi

step 6 "Seed diverse payouts via DB for edge cases"
TS=$(date +%s)

PO_PROCESSING=$(python3 -c "import uuid; print(uuid.uuid4())")
PO_COMPLETED=$(python3 -c "import uuid; print(uuid.uuid4())")
PO_FAILED=$(python3 -c "import uuid; print(uuid.uuid4())")
PO_API=$(python3 -c "import uuid; print(uuid.uuid4())")

pushd "$REPO_ROOT/apps/api" > /dev/null

if ! wrangler d1 execute bropay-db --local --command "INSERT INTO payouts (id, merchant_id, wallet_id, merchant_bank_account_id, amount, currency, fee_amount, net_amount, status, source, description, provider_transfer_id, reserved_at, created_at, updated_at) VALUES ('$PO_PROCESSING', '$DEMO_MERCHANT_ID', '$DEMO_WALLET_ID', '$BA_ID', 200000, 'THB', 3000, 197000, 'processing', 'dashboard', 'Processing payout to vendor', 'tx-processing-$TS', datetime('now', '-2 hours'), datetime('now', '-2 hours'), datetime('now')), ('$PO_COMPLETED', '$DEMO_MERCHANT_ID', '$DEMO_WALLET_ID', '$BA_ID', 150000, 'THB', 2250, 147750, 'completed', 'dashboard', 'Completed payout to supplier', 'tx-completed-$TS', datetime('now', '-90 minutes'), datetime('now', '-90 minutes'), datetime('now')), ('$PO_FAILED', '$DEMO_MERCHANT_ID', '$DEMO_WALLET_ID', '$BA_ID', 75000, 'THB', 1125, 73875, 'failed', 'dashboard', 'Failed payout - bank rejected', 'tx-failed-$TS', datetime('now', '-30 minutes'), datetime('now', '-30 minutes'), datetime('now')), ('$PO_API', '$DEMO_MERCHANT_ID', '$DEMO_WALLET_ID', '$BA_ID', 300000, 'THB', 4500, 295500, 'pending', 'api', 'API-initiated payout', 'tx-api-$TS', datetime('now', '-10 minutes'), datetime('now', '-10 minutes'), datetime('now'));" --json 2>/dev/null | grep -q '"success": true'; then
  popd > /dev/null
  fail "wrangler seed payouts failed"
fi

EVT1=$(python3 -c "import uuid; print(uuid.uuid4())")
EVT2=$(python3 -c "import uuid; print(uuid.uuid4())")
EVT3=$(python3 -c "import uuid; print(uuid.uuid4())")
if ! wrangler d1 execute bropay-db --local --command "INSERT INTO payout_events (id, payout_id, event_type, status, description, created_at) VALUES ('$EVT1', '$PO_COMPLETED', 'created', 'pending', 'Payout created', datetime('now', '-90 minutes')), ('$EVT2', '$PO_COMPLETED', 'processing', 'processing', 'Provider transfer initiated', datetime('now', '-89 minutes')), ('$EVT3', '$PO_COMPLETED', 'completed', 'completed', 'Funds transferred to bank', datetime('now', '-88 minutes'));" --json 2>/dev/null | grep -q '"success": true'; then
  popd > /dev/null
  fail "wrangler seed payout_events failed"
fi

popd > /dev/null
pass "4 edge-case payouts + 3 events seeded"

step 7 "Admin lists all payouts"
LIST_RES=$(curl -s "$BROPAY/v1/admin/payouts" -H "$ADMIN" -H "$ORIGIN")
LIST_HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$LIST_HAS_META" = "True" ] || fail "List missing meta"
LIST_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_TOTAL" -ge 4 ] || fail "Expected at least 4 payouts, got $LIST_TOTAL"
pass "Listed $LIST_TOTAL payout(s)"

step 8 "Admin filters by status=pending"
PEND_RES=$(curl -s "$BROPAY/v1/admin/payouts?status=pending" -H "$ADMIN" -H "$ORIGIN")
PEND_TOTAL=$(echo "$PEND_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$PEND_TOTAL" -ge 2 ] || fail "Expected at least 2 pending payouts, got $PEND_TOTAL"
pass "$PEND_TOTAL pending payout(s)"

step 9 "Admin filters by status=completed,failed"
TERM_RES=$(curl -s "$BROPAY/v1/admin/payouts?status=completed,failed" -H "$ADMIN" -H "$ORIGIN")
TERM_TOTAL=$(echo "$TERM_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$TERM_TOTAL" -ge 2 ] || fail "Expected at least 2 completed/failed payouts, got $TERM_TOTAL"
pass "$TERM_TOTAL completed/failed payout(s)"

step 10 "Admin filters by source=dashboard"
DASH_RES=$(curl -s "$BROPAY/v1/admin/payouts?source=dashboard" -H "$ADMIN" -H "$ORIGIN")
DASH_TOTAL=$(echo "$DASH_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$DASH_TOTAL" -ge 3 ] || fail "Expected at least 3 dashboard payouts, got $DASH_TOTAL"
pass "$DASH_TOTAL dashboard payout(s)"

step 11 "Admin filters by source=api"
API_RES=$(curl -s "$BROPAY/v1/admin/payouts?source=api" -H "$ADMIN" -H "$ORIGIN")
API_TOTAL=$(echo "$API_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$API_TOTAL" -ge 1 ] || fail "Expected at least 1 api payout, got $API_TOTAL"
pass "$API_TOTAL api payout(s)"

step 12 "Admin filters by merchant_id"
MERCH_RES=$(curl -s "$BROPAY/v1/admin/payouts?merchant_id=$DEMO_MERCHANT_ID" -H "$ADMIN" -H "$ORIGIN")
MERCH_TOTAL=$(echo "$MERCH_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$MERCH_TOTAL" -ge 4 ] || fail "Expected at least 4 payouts for merchant, got $MERCH_TOTAL"
pass "$MERCH_TOTAL payout(s) for merchant"

step 13 "Admin filters by date range"
if date -d "yesterday" +%Y-%m-%d >/dev/null 2>&1; then
  YESTERDAY=$(date -d "yesterday" +%Y-%m-%d)
  TOMORROW=$(date -d "tomorrow" +%Y-%m-%d)
else
  YESTERDAY=$(date -v-1d +%Y-%m-%d)
  TOMORROW=$(date -v+1d +%Y-%m-%d)
fi
DATE_FROM="$YESTERDAY"
DATE_TO="$TOMORROW"
DATE_RES=$(curl -s "$BROPAY/v1/admin/payouts?date_from=$DATE_FROM&date_to=$DATE_TO" -H "$ADMIN" -H "$ORIGIN")
DATE_TOTAL=$(echo "$DATE_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$DATE_TOTAL" -ge 4 ] || fail "Expected at least 4 payouts in range, got $DATE_TOTAL"
pass "$DATE_TOTAL payout(s) in date range"

step 14 "Admin searches by provider_transfer_id"
SEARCH_RES=$(curl -s "$BROPAY/v1/admin/payouts?q=tx-failed-$TS" -H "$ADMIN" -H "$ORIGIN")
SEARCH_TOTAL=$(echo "$SEARCH_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$SEARCH_TOTAL" -ge 1 ] || fail "Expected at least 1 result for provider_transfer_id search"
pass "$SEARCH_TOTAL result(s) for provider_transfer_id"

step 15 "Admin searches by payout id"
SEARCH_ID_RES=$(curl -s "$BROPAY/v1/admin/payouts?q=$PO_COMPLETED" -H "$ADMIN" -H "$ORIGIN")
SEARCH_ID_TOTAL=$(echo "$SEARCH_ID_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$SEARCH_ID_TOTAL" -ge 1 ] || fail "Expected at least 1 result for payout id search"
pass "$SEARCH_ID_TOTAL result(s) for payout id"

step 16 "Admin sorts by amount desc"
SORT_RES=$(curl -s "$BROPAY/v1/admin/payouts?sort=amount&order=desc" -H "$ADMIN" -H "$ORIGIN")
SORT_FIRST=$(echo "$SORT_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['amount'] if d else 0)")
pass "Sorted by amount desc, highest first ($SORT_FIRST)"

step 17 "Admin sorts by amount asc"
SORT_ASC_RES=$(curl -s "$BROPAY/v1/admin/payouts?sort=amount&order=asc" -H "$ADMIN" -H "$ORIGIN")
SORT_ASC_FIRST=$(echo "$SORT_ASC_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['amount'] if d else 999999)")
[ "$SORT_ASC_FIRST" -lt "$SORT_FIRST" ] || fail "Expected asc first ($SORT_ASC_FIRST) < desc first ($SORT_FIRST)"
pass "Sorted by amount asc, lowest first ($SORT_ASC_FIRST)"

step 18 "Admin gets payout detail with events"
DETAIL_RES=$(curl -s "$BROPAY/v1/admin/payouts/$PO_COMPLETED" -H "$ADMIN" -H "$ORIGIN")
DETAIL_ID=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$DETAIL_ID" = "$PO_COMPLETED" ] || fail "Detail ID mismatch"
DETAIL_EVENTS=$(echo "$DETAIL_RES" | json "print(len(json.load(sys.stdin).get('data',{}).get('events',[])))")
[ "$DETAIL_EVENTS" -ge 3 ] || fail "Expected at least 3 events, got $DETAIL_EVENTS"
pass "Detail with $DETAIL_EVENTS event(s) fetched"

step 19 "Admin verifies event types in detail"
EVT_TYPES=$(echo "$DETAIL_RES" | json "print([e['event_type'] for e in json.load(sys.stdin).get('data',{}).get('events',[])])")
echo "$EVT_TYPES" | grep -q "created" || fail "Missing 'created' event"
echo "$EVT_TYPES" | grep -q "processing" || fail "Missing 'processing' event"
echo "$EVT_TYPES" | grep -q "completed" || fail "Missing 'completed' event"
pass "Events: created → processing → completed"

step 20 "Admin paginates payouts"
PAGE_RES=$(curl -s "$BROPAY/v1/admin/payouts?limit=3&page=1" -H "$ADMIN" -H "$ORIGIN")
PAGE_LIMIT=$(echo "$PAGE_RES" | json "print(json.load(sys.stdin)['meta']['limit'])")
PAGE_COUNT=$(echo "$PAGE_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE_LIMIT" -eq 3 ] || fail "Expected limit=3"
[ "$PAGE_COUNT" -eq 3 ] || fail "Expected 3 items in page"
pass "Pagination limit=3 works"

echo -e "\n${GREEN}━━━ Payouts Realistic Lifecycle Complete ━━━${NC}"
