#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Merchant — Payment Intents (Realistic Lifecycle)
#
# Prerequisites: API worker, python3, curl
#
# Usage:
#   BROPAY_URL=http://localhost:8787 bash scripts/e2e/merchant/payment-intents.sh
#
# Environment:
#   BROPAY_URL, BOOTSTRAP_MERCHANT_ID, BOOTSTRAP_MERCHANT_SLUG (optional)
#
# HMAC (POST /v1/api/payment-intents):
#   Canonical: METHOD.path+query.timestamp.body — see _merchant-lib.sh hmac_sign()
#
# Endpoints:
#   GET  /v1/merchant/payment-intents
#   GET  /v1/merchant/payment-intents/{id}
#   POST /v1/merchant/payment-intents/{id}/cancel
#   POST /v1/api/payment-intents (HMAC)
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_merchant-lib.sh
source "$SCRIPT_DIR/../_merchant-lib.sh"

BROPAY="${BROPAY_URL:-http://localhost:8787}"
ORIGIN="Origin: http://localhost:3000"
CT="Content-Type: application/json"

echo -e "${CYAN}━━━ Merchant E2E — Payment Intents (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
merchant_auth_headers
pass "Merchant: ${DEMO_MERCHANT_ID:0:16}..."

step 2 "Create a customer for payment intent"
TS=$(date +%s)
CUST_RES=$(curl -s "$BROPAY/v1/merchant/customers" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"first_name\":\"Alice\",\"last_name\":\"Nguyen\",\"email\":\"alice-$TS@example.com\",\"phone\":\"+66811111111\"}")
CUST_OK=$(echo "$CUST_RES" | json "print('data' in json.load(sys.stdin))")
[ "$CUST_OK" = "True" ] || fail "Customer creation failed"
CUST_ID=$(echo "$CUST_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
pass "Customer created: ${CUST_ID:0:16}..."

step 3 "Create an integration for HMAC-authed PI creation"
INT_RES=$(curl -s "$BROPAY/v1/merchant/integrations" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"name\":\"E2E PI Integration\",\"slug\":\"e2e-pi-$TS\"}")
INT_ID=$(echo "$INT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
INT_API_KEY=$(echo "$INT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('api_key',''))")
INT_SECRET=$(echo "$INT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('secret_key',''))")
[ -n "$INT_ID" ] || fail "Integration creation failed"
[ -n "$INT_API_KEY" ] || fail "Integration api_key missing"
[ -n "$INT_SECRET" ] || fail "Integration secret_key missing"

# Activate the integration so HMAC auth succeeds
ACT_RES=$(curl -s "$BROPAY/v1/merchant/integrations/$INT_ID" -X PUT \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{"status":"active"}')
ACT_STATUS=$(echo "$ACT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$ACT_STATUS" = "active" ] || fail "Integration activation failed"
pass "Integration created and activated: ${INT_ID:0:16}..."

step 4 "Create payment intent via HMAC endpoint"
# Use the API (HMAC) to create a PI so we get a real one in requires_payment_method
PI_BODY="{\"amount\":50000,\"currency\":\"THB\",\"customer_id\":\"$CUST_ID\",\"description\":\"E2E test PI\",\"payment_method\":\"promptpay\"}"
PI_TS=$(date +%s)
PI_SIG=$(hmac_sign "$INT_SECRET" "$PI_TS" "$PI_BODY")

PI_RES=$(curl -s "$BROPAY/v1/api/payment-intents" -X POST \
  -H "X-Api-Key: $INT_API_KEY" \
  -H "X-Timestamp: $PI_TS" \
  -H "X-Signature: $PI_SIG" \
  -H "$CT" -H "$ORIGIN" \
  -d "$PI_BODY")
PI_ID=$(echo "$PI_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$PI_ID" ] || fail "Payment intent creation failed: $PI_RES"
PI_STATUS=$(echo "$PI_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
pass "Payment intent created: ${PI_ID:0:16}... (status=$PI_STATUS)"

step 5 "List payment intents — verify new PI appears"
LIST_RES=$(curl -s "$BROPAY/v1/merchant/payment-intents" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
LIST_HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$LIST_HAS_META" = "True" ] || fail "PI list missing meta"
LIST_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_TOTAL" -ge 1 ] || fail "Expected at least 1 payment intent, got $LIST_TOTAL"
pass "Listed $LIST_TOTAL payment intent(s)"

step 6 "Filter payment intents by status=requires_payment_method"
FILT_RES=$(curl -s "$BROPAY/v1/merchant/payment-intents?status=requires_payment_method" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
FILT_COUNT=$(echo "$FILT_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FILT_COUNT" -ge 1 ] || fail "Expected at least 1 PI in requires_payment_method, got $FILT_COUNT"
pass "$FILT_COUNT PI(s) with status=requires_payment_method"

step 7 "Filter payment intents by payment_method=promptpay"
FILT_PM_RES=$(curl -s "$BROPAY/v1/merchant/payment-intents?payment_method=promptpay" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
FILT_PM_COUNT=$(echo "$FILT_PM_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FILT_PM_COUNT" -ge 1 ] || fail "Expected at least 1 promptpay PI, got $FILT_PM_COUNT"
pass "$FILT_PM_COUNT promptpay PI(s)"

step 8 "Search payment intents by q (id fragment)"
Q_RES=$(curl -s "$BROPAY/v1/merchant/payment-intents?q=${PI_ID: -8}" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
Q_COUNT=$(echo "$Q_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$Q_COUNT" -ge 1 ] || fail "Expected at least 1 result for id search, got $Q_COUNT"
pass "$Q_COUNT result(s) for id search"

step 9 "Sort payment intents by amount desc"
SORT_RES=$(curl -s "$BROPAY/v1/merchant/payment-intents?sort=amount&order=desc" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT_OK=$(echo "$SORT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_OK" = "True" ] || fail "Sort by amount desc failed"
pass "Sorted by amount desc"

step 10 "Sort payment intents by status asc"
SORT2_RES=$(curl -s "$BROPAY/v1/merchant/payment-intents?sort=status&order=asc" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT2_OK=$(echo "$SORT2_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT2_OK" = "True" ] || fail "Sort by status asc failed"
pass "Sorted by status asc"

step 11 "Pagination limit=1"
PAGE_RES=$(curl -s "$BROPAY/v1/merchant/payment-intents?limit=1&page=1" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
PAGE_LIMIT=$(echo "$PAGE_RES" | json "print(json.load(sys.stdin)['meta']['limit'])")
PAGE_COUNT=$(echo "$PAGE_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE_LIMIT" -eq 1 ] || fail "Expected limit=1, got $PAGE_LIMIT"
[ "$PAGE_COUNT" -eq 1 ] || fail "Expected 1 item in page, got $PAGE_COUNT"
pass "Pagination limit=1 works"

step 12 "GET payment intent detail with transactions"
GET_RES=$(curl -s "$BROPAY/v1/merchant/payment-intents/$PI_ID" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
GET_ID=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$GET_ID" = "$PI_ID" ] || fail "GET detail mismatch"
GET_HAS_TX=$(echo "$GET_RES" | json "print('transactions' in json.load(sys.stdin).get('data',{}))")
[ "$GET_HAS_TX" = "True" ] || fail "Detail missing transactions array"
pass "Detail fetched with transactions"

step 13 "Cancel payment intent"
CANCEL_RES=$(curl -s "$BROPAY/v1/merchant/payment-intents/$PI_ID/cancel" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{"cancellation_reason":"E2E test cancellation"}')
CANCEL_STATUS=$(echo "$CANCEL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$CANCEL_STATUS" = "cancelled" ] || fail "Cancel failed, status=$CANCEL_STATUS"
pass "Payment intent cancelled"

step 14 "Verify cancelled PI no longer in requires_payment_method filter"
FILT2_RES=$(curl -s "$BROPAY/v1/merchant/payment-intents?status=requires_payment_method" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
FILT2_IDS=$(echo "$FILT2_RES" | json "print(json.dumps([d['id'] for d in json.load(sys.stdin).get('data',[])]))")
if echo "$FILT2_IDS" | grep -q "$PI_ID"; then
  fail "Cancelled PI still in requires_payment_method filter"
fi
pass "Cancelled PI no longer in requires_payment_method filter"

step 15 "Guard: cancel already-cancelled PI returns 422"
CANCEL2_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/payment-intents/$PI_ID/cancel" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d '{}')
CANCEL2_HTTP=$(echo "$CANCEL2_RES" | tail -n1)
[ "$CANCEL2_HTTP" = "422" ] || fail "Expected 422 for double cancel, got $CANCEL2_HTTP"
pass "Double cancel rejected with 422"

step 16 "Guard: GET non-existent PI returns 404"
NGET_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/payment-intents/nonexistent-id" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
NGET_HTTP=$(echo "$NGET_RES" | tail -n1)
[ "$NGET_HTTP" = "404" ] || fail "Expected 404 for missing PI, got $NGET_HTTP"
pass "GET missing PI returns 404"

echo -e "\n${GREEN}━━━ Payment Intents Realistic Lifecycle Complete ━━━${NC}"
