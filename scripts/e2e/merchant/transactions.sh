#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Merchant — Transactions (Realistic Lifecycle)
#
# Endpoints:
#   GET /v1/merchant/transactions
#   GET /v1/merchant/transactions/{id}
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

echo -e "${CYAN}━━━ Merchant E2E — Transactions (Realistic Lifecycle) ━━━${NC}"

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

step 3 "Seed diverse transactions via DB"
TS=$(date +%s)

TX_PAYMENT=$(python3 -c "import uuid; print(uuid.uuid4())")
TX_PAYMENT_REF="pi-payment-$TS"
TX_FAILED=$(python3 -c "import uuid; print(uuid.uuid4())")
TX_FAILED_REF="pi-failed-$TS"
TX_REFUND=$(python3 -c "import uuid; print(uuid.uuid4())")
TX_REFUND_REF="ref-$TS"
TX_FEE=$(python3 -c "import uuid; print(uuid.uuid4())")
TX_FEE_REF="fee-$TS"
TX_SETTLEMENT=$(python3 -c "import uuid; print(uuid.uuid4())")
TX_SETTLEMENT_REF="settle-$TS"
TX_WITHDRAW=$(python3 -c "import uuid; print(uuid.uuid4())")
TX_WITHDRAW_REF="wd-$TS"

e2e_d1_local_sql \
  "INSERT INTO transactions (id, merchant_id, integration_id, reference_type, reference_id, amount, currency, direction, fee_amount, net_amount, status, description, created_at, updated_at) VALUES
  ('$TX_PAYMENT', '$MERCHANT_ID', '$INTEGRATION_ID', 'payment', '$TX_PAYMENT_REF', 100000, 'THB', 'credit', 1500, 98500, 'completed', 'Customer payment via PromptPay', datetime('now', '-2 hours'), datetime('now')),
  ('$TX_FAILED', '$MERCHANT_ID', '$INTEGRATION_ID', 'payment', '$TX_FAILED_REF', 50000, 'THB', 'credit', 750, 49250, 'failed', 'Failed payment - insufficient funds', datetime('now', '-1 hour'), datetime('now')),
  ('$TX_REFUND', '$MERCHANT_ID', NULL, 'refund', '$TX_REFUND_REF', 25000, 'THB', 'debit', 0, 25000, 'completed', 'Full refund to customer', datetime('now', '-30 minutes'), datetime('now')),
  ('$TX_FEE', '$MERCHANT_ID', NULL, 'fee', '$TX_FEE_REF', 1500, 'THB', 'debit', 0, 1500, 'completed', 'Platform processing fee', datetime('now', '-20 minutes'), datetime('now')),
  ('$TX_SETTLEMENT', '$MERCHANT_ID', '$INTEGRATION_ID', 'settlement', '$TX_SETTLEMENT_REF', 200000, 'THB', 'credit', 3000, 197000, 'completed', 'Daily settlement batch', datetime('now', '-10 minutes'), datetime('now')),
  ('$TX_WITHDRAW', '$MERCHANT_ID', NULL, 'withdraw', '$TX_WITHDRAW_REF', 300000, 'THB', 'debit', 4500, 295500, 'completed', 'Merchant withdrawal to bank', datetime('now', '-5 minutes'), datetime('now'))"

# Seed events for the payment transaction
EVT1=$(python3 -c "import uuid; print(uuid.uuid4())")
EVT2=$(python3 -c "import uuid; print(uuid.uuid4())")
e2e_d1_local_sql \
  "INSERT INTO transaction_events (id, transaction_id, event_type, status, description, created_at) VALUES
  ('$EVT1', '$TX_PAYMENT', 'created', 'completed', 'Payment intent created', datetime('now', '-2 hours')),
  ('$EVT2', '$TX_PAYMENT', 'completed', 'completed', 'Funds credited to wallet', datetime('now', '-118 minutes'))"
pass "6 transactions + 2 events seeded"

step 4 "List transactions"
LIST_RES=$(curl -s "$BROPAY/v1/merchant/transactions" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$HAS_META" = "True" ] || fail "Transaction list missing meta"
LIST_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_TOTAL" -ge 6 ] || fail "Expected at least 6 transactions, got $LIST_TOTAL"
pass "Listed $LIST_TOTAL transaction(s)"

step 5 "Filter by status=completed"
COMP_RES=$(curl -s "$BROPAY/v1/merchant/transactions?status=completed" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
COMP_TOTAL=$(echo "$COMP_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$COMP_TOTAL" -ge 4 ] || fail "Expected at least 4 completed, got $COMP_TOTAL"
pass "$COMP_TOTAL completed transaction(s)"

step 6 "Filter by multi-status (completed,failed)"
MULTI_STAT_RES=$(curl -s "$BROPAY/v1/merchant/transactions?status=completed,failed" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
MULTI_STAT_TOTAL=$(echo "$MULTI_STAT_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$MULTI_STAT_TOTAL" -ge 5 ] || fail "Expected at least 5 completed/failed, got $MULTI_STAT_TOTAL"
pass "$MULTI_STAT_TOTAL completed/failed transaction(s)"

step 7 "Filter by direction=credit"
CREDIT_RES=$(curl -s "$BROPAY/v1/merchant/transactions?direction=credit" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
CREDIT_TOTAL=$(echo "$CREDIT_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$CREDIT_TOTAL" -ge 3 ] || fail "Expected at least 3 credit transactions, got $CREDIT_TOTAL"
pass "$CREDIT_TOTAL credit transaction(s)"

step 8 "Filter by direction=debit"
DEBIT_RES=$(curl -s "$BROPAY/v1/merchant/transactions?direction=debit" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
DEBIT_TOTAL=$(echo "$DEBIT_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$DEBIT_TOTAL" -ge 3 ] || fail "Expected at least 3 debit transactions, got $DEBIT_TOTAL"
pass "$DEBIT_TOTAL debit transaction(s)"

step 9 "Filter by reference_type=payment"
PAY_RES=$(curl -s "$BROPAY/v1/merchant/transactions?reference_type=payment" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
PAY_TOTAL=$(echo "$PAY_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$PAY_TOTAL" -ge 2 ] || fail "Expected at least 2 payment transactions, got $PAY_TOTAL"
pass "$PAY_TOTAL payment transaction(s)"

step 10 "Filter by multiple reference_types"
MULTI_REF_RES=$(curl -s "$BROPAY/v1/merchant/transactions?reference_type=payment,fee" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
MULTI_REF_TOTAL=$(echo "$MULTI_REF_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$MULTI_REF_TOTAL" -ge 3 ] || fail "Expected at least 3 payment/fee transactions, got $MULTI_REF_TOTAL"
pass "$MULTI_REF_TOTAL payment/fee transaction(s)"

step 11 "Filter by integration_id"
INT_RES=$(curl -s "$BROPAY/v1/merchant/transactions?integration_id=$INTEGRATION_ID" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
INT_TOTAL=$(echo "$INT_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$INT_TOTAL" -ge 3 ] || fail "Expected at least 3 transactions for integration, got $INT_TOTAL"
pass "$INT_TOTAL transaction(s) for integration"

step 12 "Filter by date range"
DATE_FROM="2025-01-01%2000:00:00"
DATE_TO="2027-12-31%2023:59:59"
DATE_RES=$(curl -s "$BROPAY/v1/merchant/transactions?date_from=$DATE_FROM&date_to=$DATE_TO" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
DATE_TOTAL=$(echo "$DATE_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$DATE_TOTAL" -ge 6 ] || fail "Expected at least 6 transactions in date range, got $DATE_TOTAL"
pass "$DATE_TOTAL transaction(s) in date range"

step 13 "Search transactions by q (reference_id)"
SEARCH_REF_RES=$(curl -s "$BROPAY/v1/merchant/transactions?q=$TX_FAILED_REF" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SEARCH_REF_TOTAL=$(echo "$SEARCH_REF_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$SEARCH_REF_TOTAL" -ge 1 ] || fail "Expected at least 1 result for reference_id search"
pass "$SEARCH_REF_TOTAL result(s) for reference_id"

step 14 "Search transactions by q (id fragment)"
SEARCH_ID_FRAG="${TX_PAYMENT:0:8}"
SEARCH_ID_RES=$(curl -s "$BROPAY/v1/merchant/transactions?q=$SEARCH_ID_FRAG" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SEARCH_ID_TOTAL=$(echo "$SEARCH_ID_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$SEARCH_ID_TOTAL" -ge 1 ] || fail "Expected at least 1 result for id fragment search"
pass "$SEARCH_ID_TOTAL result(s) for id fragment"

step 15 "Sort by amount desc"
SORT_RES=$(curl -s "$BROPAY/v1/merchant/transactions?sort=amount&order=desc" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT_FIRST=$(echo "$SORT_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['amount'] if d else 0)")
[ "$SORT_FIRST" -ge 300000 ] || fail "Expected highest amount >= 300000 first, got $SORT_FIRST"
pass "Sorted by amount desc, highest first ($SORT_FIRST)"

step 16 "Sort by amount asc"
SORT_ASC_RES=$(curl -s "$BROPAY/v1/merchant/transactions?sort=amount&order=asc" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT_ASC_FIRST=$(echo "$SORT_ASC_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['amount'] if d else 999999)")
[ "$SORT_ASC_FIRST" -le 1500 ] || fail "Expected lowest amount <= 1500 first, got $SORT_ASC_FIRST"
pass "Sorted by amount asc, lowest first ($SORT_ASC_FIRST)"

step 17 "Sort by status asc"
SORT_STATUS_RES=$(curl -s "$BROPAY/v1/merchant/transactions?sort=status&order=asc" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT_STATUS_FIRST=$(echo "$SORT_STATUS_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['status'] if d else '')")
[ -n "$SORT_STATUS_FIRST" ] || fail "Expected status sorted results to have data"
pass "Sorted by status asc, first status='$SORT_STATUS_FIRST'"

step 18 "Sort by created_at asc"
SORT_CREATED_RES=$(curl -s "$BROPAY/v1/merchant/transactions?sort=created_at&order=asc" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT_CREATED_FIRST=$(echo "$SORT_CREATED_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['created_at'] if d else '')")
SORT_CREATED_LAST=$(echo "$SORT_CREATED_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[-1]['created_at'] if d else '')")
[ "$SORT_CREATED_FIRST" \< "$SORT_CREATED_LAST" ] || fail "Expected first created_at < last created_at when sorting asc"
pass "Sorted by created_at asc, oldest first"

step 19 "Paginate transactions"
PAGE_RES=$(curl -s "$BROPAY/v1/merchant/transactions?limit=2&page=1" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
PAGE_LIMIT=$(echo "$PAGE_RES" | json "print(json.load(sys.stdin)['meta']['limit'])")
PAGE_COUNT=$(echo "$PAGE_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE_LIMIT" -eq 2 ] || fail "Expected limit=2"
[ "$PAGE_COUNT" -eq 2 ] || fail "Expected 2 items in page"
pass "Pagination limit=2 works"

step 20 "Combined filter: status=completed&direction=credit"
COMB_RES=$(curl -s "$BROPAY/v1/merchant/transactions?status=completed&direction=credit" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
COMB_TOTAL=$(echo "$COMB_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$COMB_TOTAL" -ge 2 ] || fail "Expected at least 2 completed credit transactions, got $COMB_TOTAL"
COMB_FIRST_STATUS=$(echo "$COMB_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['status'] if d else '')")
COMB_FIRST_DIR=$(echo "$COMB_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['direction'] if d else '')")
[ "$COMB_FIRST_STATUS" = "completed" ] || fail "Expected status=completed in combined filter results"
[ "$COMB_FIRST_DIR" = "credit" ] || fail "Expected direction=credit in combined filter results"
pass "$COMB_TOTAL completed credit transaction(s)"

step 21 "Combined filter: reference_type=payment&direction=credit"
COMB2_RES=$(curl -s "$BROPAY/v1/merchant/transactions?reference_type=payment&direction=credit" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
COMB2_TOTAL=$(echo "$COMB2_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$COMB2_TOTAL" -ge 1 ] || fail "Expected at least 1 payment credit transaction, got $COMB2_TOTAL"
COMB2_FIRST_REF=$(echo "$COMB2_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['reference_type'] if d else '')")
COMB2_FIRST_DIR=$(echo "$COMB2_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['direction'] if d else '')")
[ "$COMB2_FIRST_REF" = "payment" ] || fail "Expected reference_type=payment in combined filter results"
[ "$COMB2_FIRST_DIR" = "credit" ] || fail "Expected direction=credit in combined filter results"
pass "$COMB2_TOTAL payment credit transaction(s)"

step 22 "GET transaction detail with events"
DETAIL_RES=$(curl -s "$BROPAY/v1/merchant/transactions/$TX_PAYMENT" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
DETAIL_ID=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$DETAIL_ID" = "$TX_PAYMENT" ] || fail "Detail ID mismatch"
DETAIL_EVENTS=$(echo "$DETAIL_RES" | json "print(len(json.load(sys.stdin).get('data',{}).get('events',[])))")
[ "$DETAIL_EVENTS" -eq 2 ] || fail "Expected 2 events, got $DETAIL_EVENTS"
pass "Detail with $DETAIL_EVENTS event(s) fetched"

step 23 "Verify transaction event types"
EVT_TYPES=$(echo "$DETAIL_RES" | json "print([e['event_type'] for e in json.load(sys.stdin).get('data',{}).get('events',[])])")
echo "$EVT_TYPES" | grep -q "created" || fail "Missing 'created' event"
echo "$EVT_TYPES" | grep -q "completed" || fail "Missing 'completed' event"
pass "Events: created → completed"

step 24 "Verify fee breakdown in detail"
DETAIL_FEE=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('fee_amount',-1))")
DETAIL_NET=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('net_amount',-1))")
[ "$DETAIL_FEE" -eq 1500 ] || fail "Expected fee_amount=1500, got $DETAIL_FEE"
[ "$DETAIL_NET" -eq 98500 ] || fail "Expected net_amount=98500, got $DETAIL_NET"
pass "Fee breakdown correct (fee=$DETAIL_FEE, net=$DETAIL_NET)"

step 25 "Verify detail has provider_id, external_reference_id, wallet_id, customer_id"
DETAIL_PROVIDER=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('provider_id','__missing__'))")
DETAIL_EXT_REF=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('external_reference_id','__missing__'))")
DETAIL_WALLET=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('wallet_id','__missing__'))")
DETAIL_CUSTOMER=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('customer_id','__missing__'))")
[ "$DETAIL_PROVIDER" != "__missing__" ] || fail "Missing provider_id in detail"
[ "$DETAIL_EXT_REF" != "__missing__" ] || fail "Missing external_reference_id in detail"
[ "$DETAIL_WALLET" != "__missing__" ] || fail "Missing wallet_id in detail"
[ "$DETAIL_CUSTOMER" != "__missing__" ] || fail "Missing customer_id in detail"
pass "Detail has provider_id, external_reference_id, wallet_id, customer_id"

step 26 "Verify detail metadata field"
DETAIL_META=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('metadata','__missing__'))")
[ "$DETAIL_META" != "__missing__" ] || fail "Missing metadata in detail"
pass "Detail has metadata field"

step 27 "Paginate with order=asc"
PAGE_ASC_RES=$(curl -s "$BROPAY/v1/merchant/transactions?limit=2&page=1&sort=created_at&order=asc" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
PAGE_ASC_FIRST=$(echo "$PAGE_ASC_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['created_at'] if d else '')")
PAGE_ASC_LAST=$(echo "$PAGE_ASC_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[-1]['created_at'] if d else '')")
[ "$PAGE_ASC_FIRST" \< "$PAGE_ASC_LAST" ] || fail "Expected first created_at < last created_at in asc pagination"
pass "Pagination with order=asc works, oldest first"

step 28 "Guard: GET non-existent transaction returns 404"
BAD_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/transactions/nonexistent-123" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
BAD_HTTP=$(echo "$BAD_RES" | tail -n1)
[ "$BAD_HTTP" = "404" ] || fail "Expected 404 for non-existent transaction, got $BAD_HTTP"
pass "Non-existent transaction returns 404"

echo -e "\n${GREEN}━━━ Transactions Realistic Lifecycle Complete ━━━${NC}"
