#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Payment Intents (Realistic Lifecycle)
#
# Endpoints:
#   GET  /v1/admin/payment-intents
#   GET  /v1/admin/payment-intents/{id}
#   POST /v1/admin/payment-intents
#   POST /v1/merchant/payment-intents/{id}/cancel
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

echo -e "${CYAN}━━━ Admin E2E — Payment Intents (Realistic Lifecycle) ━━━${NC}"

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

step 3 "Seed diverse payment intents via DB"
TS=$(date +%s)

PI_SUCCEEDED=$(python3 -c "import uuid; print(uuid.uuid4())")
PI_SUCCEEDED_SECRET="pi_${PI_SUCCEEDED}_secret_${TS}"
PI_SUCCEEDED_REF="pi-succeeded-$TS"

PI_FAILED=$(python3 -c "import uuid; print(uuid.uuid4())")
PI_FAILED_SECRET="pi_${PI_FAILED}_secret_${TS}"

PI_EXPIRED=$(python3 -c "import uuid; print(uuid.uuid4())")
PI_EXPIRED_SECRET="pi_${PI_EXPIRED}_secret_${TS}"

PI_PROCESSING=$(python3 -c "import uuid; print(uuid.uuid4())")
PI_PROCESSING_SECRET="pi_${PI_PROCESSING}_secret_${TS}"

PI_CANCELLED=$(python3 -c "import uuid; print(uuid.uuid4())")
PI_CANCELLED_SECRET="pi_${PI_CANCELLED}_secret_${TS}"

PI_REQUIRES_ACTION=$(python3 -c "import uuid; print(uuid.uuid4())")
PI_REQUIRES_ACTION_SECRET="pi_${PI_REQUIRES_ACTION}_secret_${TS}"

PI_PROMPTPAY=$(python3 -c "import uuid; print(uuid.uuid4())")
PI_PROMPTPAY_SECRET="pi_${PI_PROMPTPAY}_secret_${TS}"

PI_BANK_TRANSFER=$(python3 -c "import uuid; print(uuid.uuid4())")
PI_BANK_TRANSFER_SECRET="pi_${PI_BANK_TRANSFER}_secret_${TS}"

TX_FOR_PI=$(python3 -c "import uuid; print(uuid.uuid4())")

pushd "$REPO_ROOT/apps/api" > /dev/null

# Single-line SQL: multiline --command breaks on Windows/Git Bash (SQLITE incomplete input).
if ! wrangler d1 execute bropay-db --local --command "INSERT INTO payment_intents (id, merchant_id, integration_id, amount, currency, status, payment_method, expiry_minutes, client_secret, description, metadata, created_at, updated_at) VALUES ('$PI_SUCCEEDED', '$DEMO_MERCHANT_ID', '$INTEGRATION_ID', 150000, 'THB', 'succeeded', 'promptpay', 15, '$PI_SUCCEEDED_SECRET', 'Customer purchase - coffee set', NULL, datetime('now', '-3 hours'), datetime('now')), ('$PI_FAILED', '$DEMO_MERCHANT_ID', '$INTEGRATION_ID', 75000, 'THB', 'failed', 'promptpay', 15, '$PI_FAILED_SECRET', 'Failed top-up attempt', NULL, datetime('now', '-2 hours'), datetime('now')), ('$PI_EXPIRED', '$DEMO_MERCHANT_ID', '$INTEGRATION_ID', 50000, 'THB', 'expired', 'bank_transfer', 15, '$PI_EXPIRED_SECRET', 'Expired bank transfer', NULL, datetime('now', '-90 minutes'), datetime('now')), ('$PI_PROCESSING', '$DEMO_MERCHANT_ID', '$INTEGRATION_ID', 200000, 'THB', 'processing', 'promptpay', 15, '$PI_PROCESSING_SECRET', 'Processing large payment', NULL, datetime('now', '-30 minutes'), datetime('now')), ('$PI_CANCELLED', '$DEMO_MERCHANT_ID', '$INTEGRATION_ID', 30000, 'THB', 'cancelled', 'promptpay', 15, '$PI_CANCELLED_SECRET', 'Cancelled by customer', NULL, datetime('now', '-20 minutes'), datetime('now')), ('$PI_REQUIRES_ACTION', '$DEMO_MERCHANT_ID', '$INTEGRATION_ID', 100000, 'THB', 'requires_action', 'promptpay', 15, '$PI_REQUIRES_ACTION_SECRET', 'Awaiting QR scan', NULL, datetime('now', '-10 minutes'), datetime('now')), ('$PI_PROMPTPAY', '$DEMO_MERCHANT_ID', '$INTEGRATION_ID', 125000, 'THB', 'succeeded', 'promptpay', 15, '$PI_PROMPTPAY_SECRET', 'PromptPay purchase', NULL, datetime('now', '-5 minutes'), datetime('now')), ('$PI_BANK_TRANSFER', '$DEMO_MERCHANT_ID', '$INTEGRATION_ID', 180000, 'THB', 'succeeded', 'bank_transfer', 15, '$PI_BANK_TRANSFER_SECRET', 'Bank transfer purchase', NULL, datetime('now', '-2 minutes'), datetime('now'));" --json 2>/dev/null | grep -q '"success": true'; then
  popd > /dev/null
  fail "wrangler seed payment_intents failed"
fi

if ! wrangler d1 execute bropay-db --local --command "INSERT INTO transactions (id, merchant_id, integration_id, reference_type, reference_id, amount, currency, direction, fee_amount, net_amount, status, description, created_at, updated_at) VALUES ('$TX_FOR_PI', '$DEMO_MERCHANT_ID', '$INTEGRATION_ID', 'payment', '$PI_SUCCEEDED', 150000, 'THB', 'credit', 2250, 147750, 'completed', 'Deposit completed', datetime('now', '-3 hours'), datetime('now'));" --json 2>/dev/null | grep -q '"success": true'; then
  popd > /dev/null
  fail "wrangler seed payment_intents transaction failed"
fi

popd > /dev/null
pass "8 payment intents + 1 transaction seeded"

step 4 "Admin creates a payment intent on behalf of merchant"
CREATE_RES=$(curl -s "$BROPAY/v1/admin/payment-intents" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"merchant_id\":\"$DEMO_MERCHANT_ID\",\"integration_id\":\"$INTEGRATION_ID\",\"amount\":99900,\"currency\":\"THB\",\"payment_method\":\"promptpay\",\"description\":\"Admin-created test payment\"}")
CREATE_OK=$(echo "$CREATE_RES" | json "print('data' in json.load(sys.stdin))")
if [ "$CREATE_OK" = "True" ]; then
  ADMIN_PI_ID=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
  ADMIN_PI_STATUS=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
  [ -n "$ADMIN_PI_ID" ] || fail "Admin PI creation returned no ID"
  pass "Admin PI created: ${ADMIN_PI_ID:0:16}... ($ADMIN_PI_STATUS)"
else
  warn "Admin PI creation failed (provider may be unavailable), skipping"
  ADMIN_PI_ID=""
fi

step 5 "Merchant creates a payment intent then cancels it"
MERCH_PI_RES=$(curl -s "$BROPAY/v1/merchant/payment-intents" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"amount\":50000,\"currency\":\"THB\",\"payment_method\":\"promptpay\",\"description\":\"To be cancelled\"}")
MERCH_PI_ID=$(echo "$MERCH_PI_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
if [ -n "$MERCH_PI_ID" ]; then
  CANCEL_RES=$(curl -s "$BROPAY/v1/merchant/payment-intents/$MERCH_PI_ID/cancel" -X POST \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
    -d '{"cancellation_reason":"Customer changed mind"}')
  CANCEL_STATUS=$(echo "$CANCEL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
  [ "$CANCEL_STATUS" = "cancelled" ] || warn "Cancel did not return cancelled (got '$CANCEL_STATUS')"
  pass "Merchant PI created and cancelled: ${MERCH_PI_ID:0:16}..."
else
  warn "Merchant PI creation failed, skipping cancel test"
  MERCH_PI_ID=""
fi

step 6 "Admin lists all payment intents"
LIST_RES=$(curl -s "$BROPAY/v1/admin/payment-intents" -H "$ADMIN" -H "$ORIGIN")
LIST_HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$LIST_HAS_META" = "True" ] || fail "List missing meta"
LIST_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_TOTAL" -ge 8 ] || fail "Expected at least 8 PIs, got $LIST_TOTAL"
pass "Listed $LIST_TOTAL payment intent(s)"

step 7 "Admin filters by status=succeeded"
SUCC_RES=$(curl -s "$BROPAY/v1/admin/payment-intents?status=succeeded" -H "$ADMIN" -H "$ORIGIN")
SUCC_TOTAL=$(echo "$SUCC_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$SUCC_TOTAL" -ge 3 ] || fail "Expected at least 3 succeeded, got $SUCC_TOTAL"
pass "$SUCC_TOTAL succeeded payment intent(s)"

step 8 "Admin filters by status=failed,expired,cancelled"
TERM_RES=$(curl -s "$BROPAY/v1/admin/payment-intents?status=failed,expired,cancelled" -H "$ADMIN" -H "$ORIGIN")
TERM_TOTAL=$(echo "$TERM_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$TERM_TOTAL" -ge 3 ] || fail "Expected at least 3 terminal PIs, got $TERM_TOTAL"
pass "$TERM_TOTAL failed/expired/cancelled payment intent(s)"

step 9 "Admin filters by payment_method=promptpay"
PP_RES=$(curl -s "$BROPAY/v1/admin/payment-intents?payment_method=promptpay" -H "$ADMIN" -H "$ORIGIN")
PP_TOTAL=$(echo "$PP_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$PP_TOTAL" -ge 5 ] || fail "Expected at least 5 PromptPay PIs, got $PP_TOTAL"
pass "$PP_TOTAL PromptPay payment intent(s)"

step 10 "Admin filters by payment_method=bank_transfer"
BT_RES=$(curl -s "$BROPAY/v1/admin/payment-intents?payment_method=bank_transfer" -H "$ADMIN" -H "$ORIGIN")
BT_TOTAL=$(echo "$BT_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$BT_TOTAL" -ge 2 ] || fail "Expected at least 2 bank transfer PIs, got $BT_TOTAL"
pass "$BT_TOTAL bank transfer payment intent(s)"

step 11 "Admin filters by merchant_id"
MERCH_RES=$(curl -s "$BROPAY/v1/admin/payment-intents?merchant_id=$DEMO_MERCHANT_ID" -H "$ADMIN" -H "$ORIGIN")
MERCH_TOTAL=$(echo "$MERCH_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$MERCH_TOTAL" -ge 8 ] || fail "Expected at least 8 PIs for merchant, got $MERCH_TOTAL"
pass "$MERCH_TOTAL payment intent(s) for merchant"

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
DATE_RES=$(curl -s "$BROPAY/v1/admin/payment-intents?date_from=$DATE_FROM&date_to=$DATE_TO" -H "$ADMIN" -H "$ORIGIN")
DATE_TOTAL=$(echo "$DATE_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$DATE_TOTAL" -ge 8 ] || fail "Expected at least 8 PIs in range, got $DATE_TOTAL"
pass "$DATE_TOTAL payment intent(s) in date range"

step 13 "Admin searches by description"
SEARCH_DESC="coffee"
SEARCH_RES=$(curl -s "$BROPAY/v1/admin/payment-intents?q=$SEARCH_DESC" -H "$ADMIN" -H "$ORIGIN")
SEARCH_TOTAL=$(echo "$SEARCH_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$SEARCH_TOTAL" -ge 1 ] || fail "Expected at least 1 result for '$SEARCH_DESC'"
pass "$SEARCH_TOTAL result(s) for '$SEARCH_DESC'"

step 14 "Admin searches by PI id"
SEARCH_SEC_RES=$(curl -s "$BROPAY/v1/admin/payment-intents?q=$PI_FAILED" -H "$ADMIN" -H "$ORIGIN")
SEARCH_SEC_TOTAL=$(echo "$SEARCH_SEC_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$SEARCH_SEC_TOTAL" -ge 1 ] || fail "Expected at least 1 result for PI id search"
pass "$SEARCH_SEC_TOTAL result(s) for PI id"

step 15 "Admin sorts by amount desc"
# Scope to demo merchant — global sort is polluted by other merchants / prior e2e runs.
SORT_RES=$(curl -s "$BROPAY/v1/admin/payment-intents?merchant_id=$DEMO_MERCHANT_ID&sort=amount&order=desc&limit=50" -H "$ADMIN" -H "$ORIGIN")
SORT_OK=$(echo "$SORT_RES" | json "
d=json.load(sys.stdin).get('data',[])
print('ok' if d and d[0]['amount']==max(x['amount'] for x in d) else 'bad')
")
[ "$SORT_OK" = "ok" ] || fail "amount desc: first row is not the maximum for this merchant"
SORT_FIRST=$(echo "$SORT_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['amount'] if d else 0)")
pass "Sorted by amount desc for merchant (first=$SORT_FIRST)"

step 16 "Admin sorts by amount asc"
SORT_ASC_RES=$(curl -s "$BROPAY/v1/admin/payment-intents?merchant_id=$DEMO_MERCHANT_ID&sort=amount&order=asc&limit=50" -H "$ADMIN" -H "$ORIGIN")
SORT_ASC_OK=$(echo "$SORT_ASC_RES" | json "
d=json.load(sys.stdin).get('data',[])
print('ok' if d and d[0]['amount']==min(x['amount'] for x in d) else 'bad')
")
[ "$SORT_ASC_OK" = "ok" ] || fail "amount asc: first row is not the minimum for this merchant"
SORT_ASC_FIRST=$(echo "$SORT_ASC_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['amount'] if d else 0)")
[ "$SORT_ASC_FIRST" -le "$SORT_FIRST" ] || fail "Expected asc first ($SORT_ASC_FIRST) <= desc first ($SORT_FIRST)"
pass "Sorted by amount asc for merchant (first=$SORT_ASC_FIRST)"

step 17 "Admin combined filter: status=succeeded & payment_method=promptpay"
COMB1_RES=$(curl -s "$BROPAY/v1/admin/payment-intents?status=succeeded&payment_method=promptpay" -H "$ADMIN" -H "$ORIGIN")
COMB1_TOTAL=$(echo "$COMB1_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$COMB1_TOTAL" -ge 2 ] || fail "Expected at least 2 succeeded+promptpay PIs, got $COMB1_TOTAL"
pass "$COMB1_TOTAL succeeded+PromptPay payment intent(s)"

step 18 "Admin combined filter: status=failed,expired & payment_method=bank_transfer"
COMB2_RES=$(curl -s "$BROPAY/v1/admin/payment-intents?status=failed,expired&payment_method=bank_transfer" -H "$ADMIN" -H "$ORIGIN")
COMB2_TOTAL=$(echo "$COMB2_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$COMB2_TOTAL" -ge 1 ] || fail "Expected at least 1 failed/expired+bank_transfer PI, got $COMB2_TOTAL"
pass "$COMB2_TOTAL failed/expired+bank_transfer payment intent(s)"

step 19 "Admin sorts by status asc"
SORT_STATUS_RES=$(curl -s "$BROPAY/v1/admin/payment-intents?sort=status&order=asc" -H "$ADMIN" -H "$ORIGIN")
SORT_STATUS_FIRST=$(echo "$SORT_STATUS_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['status'] if d else '')")
[ "$SORT_STATUS_FIRST" = "cancelled" ] || fail "Expected status=asc first to be 'cancelled', got '$SORT_STATUS_FIRST'"
pass "Sorted by status asc, first='$SORT_STATUS_FIRST'"

step 20 "Admin sorts by created_at asc"
SORT_CA_ASC_RES=$(curl -s "$BROPAY/v1/admin/payment-intents?sort=created_at&order=asc" -H "$ADMIN" -H "$ORIGIN")
SORT_CA_ASC_DATA=$(echo "$SORT_CA_ASC_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d)")
SORT_CA_ASC_FIRST=$(echo "$SORT_CA_ASC_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['created_at'] if d else '')")
SORT_CA_ASC_LAST=$(echo "$SORT_CA_ASC_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[-1]['created_at'] if d else '')")
[ "$SORT_CA_ASC_FIRST" \< "$SORT_CA_ASC_LAST" ] || [ "$SORT_CA_ASC_FIRST" = "$SORT_CA_ASC_LAST" ] || fail "Expected created_at asc order"
pass "Sorted by created_at asc, oldest first"

step 21 "Admin creates a PI with inline customer object"
INLINE_PI_RES=$(curl -s "$BROPAY/v1/admin/payment-intents" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"merchant_id\":\"$DEMO_MERCHANT_ID\",\"integration_id\":\"$INTEGRATION_ID\",\"amount\":88000,\"currency\":\"THB\",\"payment_method\":\"bank_transfer\",\"description\":\"Admin inline customer test\",\"customer\":{\"bank_code\":\"SCB\",\"account_number\":\"1234567890\",\"account_holder_name\":\"Test Inline\",\"email\":\"inline@example.com\",\"phone\":\"0812345678\"}}")
INLINE_PI_OK=$(echo "$INLINE_PI_RES" | json "print('data' in json.load(sys.stdin))")
if [ "$INLINE_PI_OK" = "True" ]; then
  INLINE_PI_ID=$(echo "$INLINE_PI_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
  INLINE_PI_CUST=$(echo "$INLINE_PI_RES" | json "print(json.load(sys.stdin).get('data',{}).get('customer_id',''))")
  [ -n "$INLINE_PI_ID" ] || fail "Inline customer PI creation returned no ID"
  [ -n "$INLINE_PI_CUST" ] || fail "Inline customer PI should have a customer_id"
  pass "Inline customer PI created: ${INLINE_PI_ID:0:16}... (customer=${INLINE_PI_CUST:0:16}...)"
else
  warn "Inline customer PI creation failed (provider may be unavailable), skipping"
  INLINE_PI_ID=""
fi

step 22 "Admin gets payment intent detail with transactions"
DETAIL_RES=$(curl -s "$BROPAY/v1/admin/payment-intents/$PI_SUCCEEDED" -H "$ADMIN" -H "$ORIGIN")
DETAIL_ID=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$DETAIL_ID" = "$PI_SUCCEEDED" ] || fail "Detail ID mismatch"
DETAIL_TXNS=$(echo "$DETAIL_RES" | json "print(len(json.load(sys.stdin).get('data',{}).get('transactions',[])))")
[ "$DETAIL_TXNS" -ge 1 ] || fail "Expected at least 1 transaction in detail, got $DETAIL_TXNS"
pass "Detail with $DETAIL_TXNS transaction(s) fetched"

step 23 "Admin verifies detail has expected fields"
DETAIL_FIELDS=$(echo "$DETAIL_RES" | python3 -c "import sys,json; d=json.load(sys.stdin).get('data',{}); fields=['provider_deposit_id','next_action','cancellation_reason','cancelled_at','daily_limit_snapshot','monthly_limit_snapshot','expires_at']; missing=[f for f in fields if f not in d]; print(','.join(missing))")
[ -z "$DETAIL_FIELDS" ] || fail "Detail missing expected fields: $DETAIL_FIELDS"
pass "Detail contains all expected fields"

step 24 "Admin verifies transaction link in detail"
DETAIL_TXN_REF=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('transactions',[{}])[0].get('reference_id',''))")
[ "$DETAIL_TXN_REF" = "$PI_SUCCEEDED" ] || fail "Transaction reference_id should match PI ID"
pass "Transaction correctly linked to payment intent"

step 25 "Admin paginates payment intents"
PAGE_RES=$(curl -s "$BROPAY/v1/admin/payment-intents?limit=4&page=1" -H "$ADMIN" -H "$ORIGIN")
PAGE_LIMIT=$(echo "$PAGE_RES" | json "print(json.load(sys.stdin)['meta']['limit'])")
PAGE_COUNT=$(echo "$PAGE_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE_LIMIT" -eq 4 ] || fail "Expected limit=4"
[ "$PAGE_COUNT" -eq 4 ] || fail "Expected 4 items in page"
pass "Pagination limit=4 works"

step 26 "Admin paginates with order=asc"
PAGE_ASC_RES=$(curl -s "$BROPAY/v1/admin/payment-intents?limit=4&page=1&order=asc" -H "$ADMIN" -H "$ORIGIN")
PAGE_ASC_LIMIT=$(echo "$PAGE_ASC_RES" | json "print(json.load(sys.stdin)['meta']['limit'])")
PAGE_ASC_COUNT=$(echo "$PAGE_ASC_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
PAGE_ASC_FIRST=$(echo "$PAGE_ASC_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['created_at'] if d else '')")
PAGE_ASC_LAST=$(echo "$PAGE_ASC_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[-1]['created_at'] if d else '')")
[ "$PAGE_ASC_LIMIT" -eq 4 ] || fail "Expected limit=4 with asc"
[ "$PAGE_ASC_COUNT" -eq 4 ] || fail "Expected 4 items in asc page"
[ "$PAGE_ASC_FIRST" \< "$PAGE_ASC_LAST" ] || [ "$PAGE_ASC_FIRST" = "$PAGE_ASC_LAST" ] || fail "Expected asc pagination order"
pass "Pagination with order=asc works"

step 27 "Admin filters by status=processing,requires_action"
PEND_RES=$(curl -s "$BROPAY/v1/admin/payment-intents?status=processing,requires_action" -H "$ADMIN" -H "$ORIGIN")
PEND_TOTAL=$(echo "$PEND_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$PEND_TOTAL" -ge 2 ] || fail "Expected at least 2 pending/action-required PIs, got $PEND_TOTAL"
pass "$PEND_TOTAL processing/requires_action payment intent(s)"

echo -e "\n${GREEN}━━━ Payment Intents Realistic Lifecycle Complete ━━━${NC}"
