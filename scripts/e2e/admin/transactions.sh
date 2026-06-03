#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Transactions (Realistic Lifecycle)
#
# Endpoints:
#   GET /v1/admin/transactions
#   GET /v1/admin/transactions/{id}
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

echo -e "${CYAN}━━━ Admin E2E — Transactions (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
OWNER="Authorization: Bearer $DEMO_OWNER_TOKEN"
MERCH="X-Merchant-Id: $DEMO_MERCHANT_ID"
pass "Admin token acquired (super_admin)"

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

step 3 "Seed diverse transactions via DB"
TS=$(date +%s)

# Generate IDs
TX_PAYMENT=$(python3 -c "import uuid; print(uuid.uuid4())")
TX_PAYMENT_REF="pi-payment-$TS"
TX_FAILED=$(python3 -c "import uuid; print(uuid.uuid4())")
TX_FAILED_REF="pi-failed-$TS"
TX_REVERSED=$(python3 -c "import uuid; print(uuid.uuid4())")
TX_REVERSED_REF="pi-reversed-$TS"
TX_REFUND=$(python3 -c "import uuid; print(uuid.uuid4())")
TX_REFUND_REF="ref-$TS"
TX_FEE=$(python3 -c "import uuid; print(uuid.uuid4())")
TX_FEE_REF="fee-$TS"
TX_SETTLEMENT=$(python3 -c "import uuid; print(uuid.uuid4())")
TX_SETTLEMENT_REF="settle-$TS"
TX_ADJUST=$(python3 -c "import uuid; print(uuid.uuid4())")
TX_ADJUST_REF="adj-$TS"
TX_CHARGEBACK=$(python3 -c "import uuid; print(uuid.uuid4())")
TX_CHARGEBACK_REF="cb-$TS"
TX_WITHDRAW=$(python3 -c "import uuid; print(uuid.uuid4())")
TX_WITHDRAW_REF="wd-$TS"

pushd "$REPO_ROOT/apps/api" > /dev/null

if ! wrangler d1 execute bropay-db --local --command "INSERT INTO transactions (id, merchant_id, integration_id, reference_type, reference_id, amount, currency, direction, fee_amount, net_amount, status, description, created_at, updated_at) VALUES ('$TX_PAYMENT', '$DEMO_MERCHANT_ID', '$INTEGRATION_ID', 'payment', '$TX_PAYMENT_REF', 100000, 'THB', 'credit', 1500, 98500, 'completed', 'Customer payment via PromptPay', datetime('now', '-2 hours'), datetime('now')), ('$TX_FAILED', '$DEMO_MERCHANT_ID', '$INTEGRATION_ID', 'payment', '$TX_FAILED_REF', 50000, 'THB', 'credit', 750, 49250, 'failed', 'Failed payment - insufficient funds', datetime('now', '-1 hour'), datetime('now')), ('$TX_REVERSED', '$DEMO_MERCHANT_ID', '$INTEGRATION_ID', 'payment', '$TX_REVERSED_REF', 75000, 'THB', 'credit', 1125, 73875, 'reversed', 'Reversed payment - customer dispute', datetime('now', '-30 minutes'), datetime('now')), ('$TX_REFUND', '$DEMO_MERCHANT_ID', NULL, 'refund', '$TX_REFUND_REF', 25000, 'THB', 'debit', 0, 25000, 'completed', 'Full refund to customer', datetime('now', '-20 minutes'), datetime('now')), ('$TX_FEE', '$DEMO_MERCHANT_ID', NULL, 'fee', '$TX_FEE_REF', 1500, 'THB', 'debit', 0, 1500, 'completed', 'Platform processing fee', datetime('now', '-15 minutes'), datetime('now')), ('$TX_SETTLEMENT', '$DEMO_MERCHANT_ID', '$INTEGRATION_ID', 'settlement', '$TX_SETTLEMENT_REF', 200000, 'THB', 'credit', 3000, 197000, 'completed', 'Daily settlement batch', datetime('now', '-10 minutes'), datetime('now')), ('$TX_ADJUST', '$DEMO_MERCHANT_ID', NULL, 'adjustment', '$TX_ADJUST_REF', 500000, 'THB', 'credit', 0, 500000, 'completed', 'Manual adjustment - promo credit', datetime('now', '-5 minutes'), datetime('now')), ('$TX_CHARGEBACK', '$DEMO_MERCHANT_ID', NULL, 'chargeback', '$TX_CHARGEBACK_REF', 100000, 'THB', 'debit', 0, 100000, 'completed', 'Chargeback from issuing bank', datetime('now', '-3 minutes'), datetime('now')), ('$TX_WITHDRAW', '$DEMO_MERCHANT_ID', NULL, 'withdraw', '$TX_WITHDRAW_REF', 300000, 'THB', 'debit', 4500, 295500, 'completed', 'Merchant withdrawal to bank', datetime('now', '-1 minutes'), datetime('now'));" --json 2>/dev/null | grep -q '"success": true'; then
  popd > /dev/null
  fail "wrangler seed transactions failed"
fi

EVT1=$(python3 -c "import uuid; print(uuid.uuid4())")
EVT2=$(python3 -c "import uuid; print(uuid.uuid4())")
EVT3=$(python3 -c "import uuid; print(uuid.uuid4())")
if ! wrangler d1 execute bropay-db --local --command "INSERT INTO transaction_events (id, transaction_id, event_type, status, description, created_at) VALUES ('$EVT1', '$TX_PAYMENT', 'created', 'completed', 'Payment intent created', datetime('now', '-2 hours')), ('$EVT2', '$TX_PAYMENT', 'processing', 'completed', 'Provider processing initiated', datetime('now', '-119 minutes')), ('$EVT3', '$TX_PAYMENT', 'completed', 'completed', 'Funds credited to wallet', datetime('now', '-118 minutes'));" --json 2>/dev/null | grep -q '"success": true'; then
  popd > /dev/null
  fail "wrangler seed transaction_events failed"
fi

popd > /dev/null
pass "9 transactions + 3 events seeded"

step 4 "Admin lists all transactions"
LIST_RES=$(curl -s "$BROPAY/v1/admin/transactions" -H "$ADMIN" -H "$ORIGIN")
LIST_HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$LIST_HAS_META" = "True" ] || fail "List missing meta"
LIST_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_TOTAL" -ge 9 ] || fail "Expected at least 9 transactions, got $LIST_TOTAL"
pass "Listed $LIST_TOTAL transaction(s)"

step 5 "Admin filters by status=completed"
COMP_RES=$(curl -s "$BROPAY/v1/admin/transactions?status=completed" -H "$ADMIN" -H "$ORIGIN")
COMP_TOTAL=$(echo "$COMP_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$COMP_TOTAL" -ge 7 ] || fail "Expected at least 7 completed, got $COMP_TOTAL"
pass "$COMP_TOTAL completed transaction(s)"

step 6 "Admin filters by status=failed,reversed"
FAILREV_RES=$(curl -s "$BROPAY/v1/admin/transactions?status=failed,reversed" -H "$ADMIN" -H "$ORIGIN")
FAILREV_TOTAL=$(echo "$FAILREV_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FAILREV_TOTAL" -ge 2 ] || fail "Expected at least 2 failed/reversed, got $FAILREV_TOTAL"
pass "$FAILREV_TOTAL failed/reversed transaction(s)"

step 7 "Admin filters by direction=credit"
CREDIT_RES=$(curl -s "$BROPAY/v1/admin/transactions?direction=credit" -H "$ADMIN" -H "$ORIGIN")
CREDIT_TOTAL=$(echo "$CREDIT_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$CREDIT_TOTAL" -ge 5 ] || fail "Expected at least 5 credit transactions, got $CREDIT_TOTAL"
pass "$CREDIT_TOTAL credit transaction(s)"

step 8 "Admin filters by direction=debit"
DEBIT_RES=$(curl -s "$BROPAY/v1/admin/transactions?direction=debit" -H "$ADMIN" -H "$ORIGIN")
DEBIT_TOTAL=$(echo "$DEBIT_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$DEBIT_TOTAL" -ge 4 ] || fail "Expected at least 4 debit transactions, got $DEBIT_TOTAL"
pass "$DEBIT_TOTAL debit transaction(s)"

step 9 "Admin filters by reference_type=payment"
PAY_RES=$(curl -s "$BROPAY/v1/admin/transactions?reference_type=payment" -H "$ADMIN" -H "$ORIGIN")
PAY_TOTAL=$(echo "$PAY_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$PAY_TOTAL" -ge 3 ] || fail "Expected at least 3 payment transactions, got $PAY_TOTAL"
pass "$PAY_TOTAL payment transaction(s)"

step 10 "Admin filters by multiple reference_types"
MULTI_REF_RES=$(curl -s "$BROPAY/v1/admin/transactions?reference_type=payment,fee" -H "$ADMIN" -H "$ORIGIN")
MULTI_REF_TOTAL=$(echo "$MULTI_REF_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$MULTI_REF_TOTAL" -ge 4 ] || fail "Expected at least 4 payment+fee transactions, got $MULTI_REF_TOTAL"
pass "$MULTI_REF_TOTAL payment/fee transaction(s)"

step 11 "Admin filters by merchant_id"
MERCH_RES=$(curl -s "$BROPAY/v1/admin/transactions?merchant_id=$DEMO_MERCHANT_ID" -H "$ADMIN" -H "$ORIGIN")
MERCH_TOTAL=$(echo "$MERCH_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$MERCH_TOTAL" -ge 9 ] || fail "Expected at least 9 transactions for merchant, got $MERCH_TOTAL"
pass "$MERCH_TOTAL transaction(s) for merchant"

step 12 "Admin filters by date range"
if date -d "yesterday" +%Y-%m-%d >/dev/null 2>&1; then
  YESTERDAY=$(date -d "yesterday" +%Y-%m-%d)
  TOMORROW=$(date -d "tomorrow" +%Y-%m-%d)
else
  YESTERDAY=$(date -v-1d +%Y-%m-%d)
  TOMORROW=$(date -v+1d +%Y-%m-%d)
fi
DATE_FROM="$YESTERDAY"
DATE_TO="$TOMORROW"
DATE_RES=$(curl -s "$BROPAY/v1/admin/transactions?date_from=$DATE_FROM&date_to=$DATE_TO" -H "$ADMIN" -H "$ORIGIN")
DATE_TOTAL=$(echo "$DATE_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$DATE_TOTAL" -ge 9 ] || fail "Expected at least 9 transactions in range, got $DATE_TOTAL"
pass "$DATE_TOTAL transaction(s) in date range"

step 13 "Admin searches by description"
SEARCH_DESC="PromptPay"
SEARCH_RES=$(curl -s "$BROPAY/v1/admin/transactions?q=$SEARCH_DESC" -H "$ADMIN" -H "$ORIGIN")
SEARCH_TOTAL=$(echo "$SEARCH_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$SEARCH_TOTAL" -ge 1 ] || fail "Expected at least 1 result for '$SEARCH_DESC'"
pass "$SEARCH_TOTAL result(s) for '$SEARCH_DESC'"

step 14 "Admin searches by reference_id"
SEARCH_REF_RES=$(curl -s "$BROPAY/v1/admin/transactions?q=$TX_FAILED_REF" -H "$ADMIN" -H "$ORIGIN")
SEARCH_REF_TOTAL=$(echo "$SEARCH_REF_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$SEARCH_REF_TOTAL" -ge 1 ] || fail "Expected at least 1 result for reference_id search"
pass "$SEARCH_REF_TOTAL result(s) for reference_id"

step 15 "Admin sorts by amount desc"
SORT_RES=$(curl -s "$BROPAY/v1/admin/transactions?merchant_id=$DEMO_MERCHANT_ID&sort=amount&order=desc&limit=50" -H "$ADMIN" -H "$ORIGIN")
SORT_OK=$(echo "$SORT_RES" | json "
d=json.load(sys.stdin).get('data',[])
print('ok' if d and d[0]['amount']==max(x['amount'] for x in d) else 'bad')
")
[ "$SORT_OK" = "ok" ] || fail "amount desc: first row is not the maximum for this merchant"
SORT_FIRST=$(echo "$SORT_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['amount'] if d else 0)")
pass "Sorted by amount desc for merchant (first=$SORT_FIRST)"

step 16 "Admin sorts by amount asc"
SORT_ASC_RES=$(curl -s "$BROPAY/v1/admin/transactions?merchant_id=$DEMO_MERCHANT_ID&sort=amount&order=asc&limit=50" -H "$ADMIN" -H "$ORIGIN")
SORT_ASC_OK=$(echo "$SORT_ASC_RES" | json "
d=json.load(sys.stdin).get('data',[])
print('ok' if d and d[0]['amount']==min(x['amount'] for x in d) else 'bad')
")
[ "$SORT_ASC_OK" = "ok" ] || fail "amount asc: first row is not the minimum for this merchant"
SORT_ASC_FIRST=$(echo "$SORT_ASC_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['amount'] if d else 0)")
pass "Sorted by amount asc for merchant (first=$SORT_ASC_FIRST)"

step 17 "Admin gets transaction detail with events"
DETAIL_RES=$(curl -s "$BROPAY/v1/admin/transactions/$TX_PAYMENT" -H "$ADMIN" -H "$ORIGIN")
DETAIL_ID=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$DETAIL_ID" = "$TX_PAYMENT" ] || fail "Detail ID mismatch"
DETAIL_EVENTS=$(echo "$DETAIL_RES" | json "print(len(json.load(sys.stdin).get('data',{}).get('events',[])))")
[ "$DETAIL_EVENTS" -eq 3 ] || fail "Expected 3 events, got $DETAIL_EVENTS"
pass "Detail with $DETAIL_EVENTS event(s) fetched"

step 18 "Admin verifies transaction event types"
EVT_TYPES=$(echo "$DETAIL_RES" | json "print([e['event_type'] for e in json.load(sys.stdin).get('data',{}).get('events',[])])")
echo "$EVT_TYPES" | grep -q "created" || fail "Missing 'created' event"
echo "$EVT_TYPES" | grep -q "processing" || fail "Missing 'processing' event"
echo "$EVT_TYPES" | grep -q "completed" || fail "Missing 'completed' event"
pass "Events: created → processing → completed"

step 19 "Admin verifies fee breakdown in detail"
DETAIL_FEE=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('fee_amount',-1))")
DETAIL_NET=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('net_amount',-1))")
[ "$DETAIL_FEE" -eq 1500 ] || fail "Expected fee_amount=1500, got $DETAIL_FEE"
[ "$DETAIL_NET" -eq 98500 ] || fail "Expected net_amount=98500, got $DETAIL_NET"
pass "Fee breakdown correct (fee=$DETAIL_FEE, net=$DETAIL_NET)"

step 20 "Admin paginates transactions"
PAGE_RES=$(curl -s "$BROPAY/v1/admin/transactions?limit=3&page=1" -H "$ADMIN" -H "$ORIGIN")
PAGE_LIMIT=$(echo "$PAGE_RES" | json "print(json.load(sys.stdin)['meta']['limit'])")
PAGE_COUNT=$(echo "$PAGE_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE_LIMIT" -eq 3 ] || fail "Expected limit=3"
[ "$PAGE_COUNT" -eq 3 ] || fail "Expected 3 items in page"
pass "Pagination limit=3 works"

step 21 "Admin combined filter: status=completed&direction=credit&merchant_id"
COMB_RES=$(curl -s "$BROPAY/v1/admin/transactions?status=completed&direction=credit&merchant_id=$DEMO_MERCHANT_ID" -H "$ADMIN" -H "$ORIGIN")
COMB_TOTAL=$(echo "$COMB_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$COMB_TOTAL" -ge 4 ] || fail "Expected at least 4 completed credit transactions for merchant, got $COMB_TOTAL"
COMB_FIRST_STATUS=$(echo "$COMB_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['status'] if d else '')")
COMB_FIRST_DIR=$(echo "$COMB_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['direction'] if d else '')")
[ "$COMB_FIRST_STATUS" = "completed" ] || fail "Expected status=completed in combined filter results"
[ "$COMB_FIRST_DIR" = "credit" ] || fail "Expected direction=credit in combined filter results"
pass "$COMB_TOTAL completed credit transaction(s) for merchant"

step 22 "Admin combined filter: reference_type=payment&direction=credit"
COMB2_RES=$(curl -s "$BROPAY/v1/admin/transactions?reference_type=payment&direction=credit" -H "$ADMIN" -H "$ORIGIN")
COMB2_TOTAL=$(echo "$COMB2_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$COMB2_TOTAL" -ge 3 ] || fail "Expected at least 3 payment credit transactions, got $COMB2_TOTAL"
COMB2_FIRST_REF=$(echo "$COMB2_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['reference_type'] if d else '')")
COMB2_FIRST_DIR=$(echo "$COMB2_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['direction'] if d else '')")
[ "$COMB2_FIRST_REF" = "payment" ] || fail "Expected reference_type=payment in combined filter results"
[ "$COMB2_FIRST_DIR" = "credit" ] || fail "Expected direction=credit in combined filter results"
pass "$COMB2_TOTAL payment credit transaction(s)"

step 23 "Admin sorts by status asc"
SORT_STATUS_RES=$(curl -s "$BROPAY/v1/admin/transactions?sort=status&order=asc" -H "$ADMIN" -H "$ORIGIN")
SORT_STATUS_FIRST=$(echo "$SORT_STATUS_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['status'] if d else '')")
[ -n "$SORT_STATUS_FIRST" ] || fail "Expected status sorted results to have data"
pass "Sorted by status asc, first status='$SORT_STATUS_FIRST'"

step 24 "Admin sorts by created_at asc"
SORT_CREATED_RES=$(curl -s "$BROPAY/v1/admin/transactions?sort=created_at&order=asc" -H "$ADMIN" -H "$ORIGIN")
SORT_CREATED_FIRST=$(echo "$SORT_CREATED_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['created_at'] if d else '')")
SORT_CREATED_LAST=$(echo "$SORT_CREATED_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[-1]['created_at'] if d else '')")
[ "$SORT_CREATED_FIRST" \< "$SORT_CREATED_LAST" ] || fail "Expected first created_at < last created_at when sorting asc"
pass "Sorted by created_at asc, oldest first"

step 25 "Admin verifies detail has provider_id, external_reference_id, wallet_id, customer_id"
DETAIL_FIELDS_RES=$(curl -s "$BROPAY/v1/admin/transactions/$TX_PAYMENT" -H "$ADMIN" -H "$ORIGIN")
DETAIL_PROVIDER=$(echo "$DETAIL_FIELDS_RES" | json "print(json.load(sys.stdin).get('data',{}).get('provider_id','__missing__'))")
DETAIL_EXT_REF=$(echo "$DETAIL_FIELDS_RES" | json "print(json.load(sys.stdin).get('data',{}).get('external_reference_id','__missing__'))")
DETAIL_WALLET=$(echo "$DETAIL_FIELDS_RES" | json "print(json.load(sys.stdin).get('data',{}).get('wallet_id','__missing__'))")
DETAIL_CUSTOMER=$(echo "$DETAIL_FIELDS_RES" | json "print(json.load(sys.stdin).get('data',{}).get('customer_id','__missing__'))")
[ "$DETAIL_PROVIDER" != "__missing__" ] || fail "Missing provider_id in detail"
[ "$DETAIL_EXT_REF" != "__missing__" ] || fail "Missing external_reference_id in detail"
[ "$DETAIL_WALLET" != "__missing__" ] || fail "Missing wallet_id in detail"
[ "$DETAIL_CUSTOMER" != "__missing__" ] || fail "Missing customer_id in detail"
pass "Detail has provider_id, external_reference_id, wallet_id, customer_id"

step 26 "Admin verifies detail metadata field"
DETAIL_META=$(echo "$DETAIL_FIELDS_RES" | json "print(json.load(sys.stdin).get('data',{}).get('metadata','__missing__'))")
[ "$DETAIL_META" != "__missing__" ] || fail "Missing metadata in detail"
pass "Detail has metadata field (value='$DETAIL_META')"

step 27 "Admin paginates with order=asc"
PAGE_ASC_RES=$(curl -s "$BROPAY/v1/admin/transactions?limit=2&page=1&sort=created_at&order=asc" -H "$ADMIN" -H "$ORIGIN")
PAGE_ASC_FIRST=$(echo "$PAGE_ASC_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['created_at'] if d else '')")
PAGE_ASC_LAST=$(echo "$PAGE_ASC_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[-1]['created_at'] if d else '')")
[ "$PAGE_ASC_FIRST" \< "$PAGE_ASC_LAST" ] || fail "Expected first created_at < last created_at in asc pagination"
pass "Pagination with order=asc works, oldest first"

step 28 "Admin filters by multiple directions: credit,debit"
MULTI_DIR_RES=$(curl -s "$BROPAY/v1/admin/transactions?direction=credit,debit" -H "$ADMIN" -H "$ORIGIN")
MULTI_DIR_TOTAL=$(echo "$MULTI_DIR_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$MULTI_DIR_TOTAL" -ge 9 ] || fail "Expected at least 9 transactions for credit+debit, got $MULTI_DIR_TOTAL"
pass "$MULTI_DIR_TOTAL transaction(s) for credit,debit directions"

echo -e "\n${GREEN}━━━ Transactions Realistic Lifecycle Complete ━━━${NC}"
