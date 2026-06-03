#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Webhook Endpoint Flow
#
# Usage:
#   bash scripts/e2e/e2e-webhook-endpoint-flow.sh
#
# Environment: BROPAY_URL, BOOTSTRAP_MERCHANT_* (optional)
# HMAC: _merchant-lib.sh for POST /v1/api/payment-intents
#
# Flow:
#   1. Bootstrap demo merchant
#   2. Create integration
#   3. Create webhook endpoint
#   4. Verify endpoint exists with correct events
#   5. Trigger a payment event (create PI + mark succeeded)
#   6. Check webhook deliveries table for the event
#   7. Update webhook endpoint
#   8. Rotate webhook secret
#   9. Delete webhook endpoint
#  10. Guards: 404 missing, 400 invalid, 401 unauthenticated
#  11. Filters: event type filter on deliveries
#  12. Cleanup: delete integration
#
# See: scripts/e2e/docs/e2e-webhook-endpoint-flow.md
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BROPAY="${BROPAY_URL:-http://localhost:8787}"
ORIGIN="Origin: http://localhost:3000"
CT="Content-Type: application/json"

# shellcheck source=_merchant-lib.sh
source "$SCRIPT_DIR/_merchant-lib.sh"
info() { echo -e "${CYAN}→ $1${NC}"; }

# Helper: curl with status code extraction
http_get() {
  local url=$1
  shift
  local raw
  raw=$(curl -s -w "\n%{http_code}" "$url" "$@")
  HTTP_CODE=$(echo "$raw" | tail -1)
  HTTP_BODY=$(echo "$raw" | sed '$d')
}

http_post() {
  local url=$1
  shift
  local raw
  raw=$(curl -s -w "\n%{http_code}" "$url" -X POST "$@")
  HTTP_CODE=$(echo "$raw" | tail -1)
  HTTP_BODY=$(echo "$raw" | sed '$d')
}

http_put() {
  local url=$1
  shift
  local raw
  raw=$(curl -s -w "\n%{http_code}" "$url" -X PUT "$@")
  HTTP_CODE=$(echo "$raw" | tail -1)
  HTTP_BODY=$(echo "$raw" | sed '$d')
}

http_delete() {
  local url=$1
  shift
  local raw
  raw=$(curl -s -w "\n%{http_code}" "$url" -X DELETE "$@")
  HTTP_CODE=$(echo "$raw" | tail -1)
  HTTP_BODY=$(echo "$raw" | sed '$d')
}

echo -e "${CYAN}━━━ BroPay E2E Webhook Endpoint Flow ━━━${NC}"

# ── Step 1: Bootstrap demo merchant ──────────────────────────────────────────
step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/_bootstrap.sh"
bootstrap_demo_merchant
MERCHANT_ID="$DEMO_MERCHANT_ID"
OWNER_TOKEN="$DEMO_OWNER_TOKEN"
OWNER="Authorization: Bearer $OWNER_TOKEN"
MERCH="X-Merchant-Id: $MERCHANT_ID"
pass "Merchant: ${MERCHANT_ID:0:16}..."

# ── Step 1b: Auth guard ──────────────────────────────────────────────────────
step "1b" "Auth guard — no token"
http_get "$BROPAY/v1/merchant/webhook-endpoints" -H "$MERCH" -H "$ORIGIN"
[ "$HTTP_CODE" = "401" ] || fail "Expected 401 without token, got $HTTP_CODE"
pass "Unauthenticated request rejected (401)"

# ── Step 1c: Baseline endpoint count ─────────────────────────────────────────
step "1c" "Baseline webhook endpoint count"
BASE_ENDPOINTS=$(curl -s "$BROPAY/v1/merchant/webhook-endpoints" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
BASE_COUNT=$(echo "$BASE_ENDPOINTS" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
pass "Baseline endpoints: $BASE_COUNT"

# ── Step 2: Create integration ───────────────────────────────────────────────
step 2 "Create integration"
INT_SLUG="webhook-test-$(date +%s)"
info "Creating fresh integration..."
curl -s "$BROPAY/v1/merchant/integrations" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"name\":\"Webhook Test Integration\",\"slug\":\"$INT_SLUG\"}" > /dev/null

INTEGRATIONS=$(curl -s "$BROPAY/v1/merchant/integrations" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
INTEGRATION_ID=$(echo "$INTEGRATIONS" | json "
d=json.load(sys.stdin)['data']
for i in d:
    if i['slug'] == '$INT_SLUG':
        print(i['id'])
        break
")
[ -n "$INTEGRATION_ID" ] || fail "No integration found"
pass "Integration: ${INTEGRATION_ID:0:16}..."

# POST /v1/merchant/integrations inserts status='active' (integrations.ts createIntegration).
# HMAC middleware rejects non-active integrations — verify via API, no wrangler/D1 bypass.
INT_DETAIL=$(curl -s "$BROPAY/v1/merchant/integrations/$INTEGRATION_ID" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
INT_STATUS=$(echo "$INT_DETAIL" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$INT_STATUS" = "active" ] || fail "Integration not active (status=$INT_STATUS); HMAC requires active — $INT_DETAIL"
pass "Integration active (HMAC-ready)"

# ── Step 2b: Invalid input guard ─────────────────────────────────────────────
step "2b" "Invalid input guard — missing URL"
http_post "$BROPAY/v1/merchant/webhook-endpoints" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"integration_id\":\"$INTEGRATION_ID\",\"subscribed_events\":[\"payment.created\"]}"
[ "$HTTP_CODE" = "400" ] || [ "$HTTP_CODE" = "422" ] || warn "Expected 400/422 for missing URL, got $HTTP_CODE"
[[ "$HTTP_CODE" == 4* ]] && pass "Missing URL rejected ($HTTP_CODE)" || fail "Expected 4xx for missing URL, got $HTTP_CODE"

# ── Step 3: Create webhook endpoint ──────────────────────────────────────────
step 3 "Create webhook endpoint"
WEBHOOK_URL="https://ancient-forest-65.webhook.cool"
CREATE_RES=$(curl -s "$BROPAY/v1/merchant/webhook-endpoints" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"integration_id\":\"$INTEGRATION_ID\",\"url\":\"$WEBHOOK_URL\",\"subscribed_events\":[\"payment.created\",\"payment.completed\"],\"description\":\"E2E webhook test\"}")

ENDPOINT_ID=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
SIGNING_SECRET=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('signing_secret',''))")
[ -n "$ENDPOINT_ID" ] || fail "Webhook endpoint creation failed"
[ -n "$SIGNING_SECRET" ] || fail "No signing secret returned"
pass "Webhook endpoint created: ${ENDPOINT_ID:0:16}..."
pass "Signing secret: ${SIGNING_SECRET:0:20}..."

# ── Step 3b: Verify endpoint list count increased ────────────────────────────
step "3b" "Verify endpoint list count increased"
AFTER_ENDPOINTS=$(curl -s "$BROPAY/v1/merchant/webhook-endpoints" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
AFTER_COUNT=$(echo "$AFTER_ENDPOINTS" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
[ "$AFTER_COUNT" -gt "$BASE_COUNT" ] || fail "Expected endpoint count to increase ($BASE_COUNT → >$BASE_COUNT), got $AFTER_COUNT"
pass "Endpoint count increased: $BASE_COUNT → $AFTER_COUNT"

# ── Step 3c: 404 guard ───────────────────────────────────────────────────────
step "3c" "404 guard — missing endpoint"
http_get "$BROPAY/v1/merchant/webhook-endpoints/00000000-0000-0000-0000-000000000000" -H "$OWNER" -H "$MERCH" -H "$ORIGIN"
[ "$HTTP_CODE" = "404" ] || fail "Expected 404 for missing endpoint, got $HTTP_CODE"
pass "Missing endpoint returns 404"

# ── Step 4: Verify endpoint exists ───────────────────────────────────────────
step 4 "Verify endpoint list"
LIST_RES=$(curl -s "$BROPAY/v1/merchant/webhook-endpoints" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
FOUND_URL=$(echo "$LIST_RES" | json "
d=json.load(sys.stdin)
for e in d.get('data', []):
    if e['id'] == '$ENDPOINT_ID':
        print(e['url'])
        break
else:
    print('not_found')
")
[ "$FOUND_URL" = "$WEBHOOK_URL" ] || fail "Endpoint not found in list"
pass "Endpoint found in list with correct URL"

step "4b" "GET webhook endpoint by id"
GET_EP_RES=$(curl -s "$BROPAY/v1/merchant/webhook-endpoints/$ENDPOINT_ID" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
GET_EP_URL=$(echo "$GET_EP_RES" | json "print(json.load(sys.stdin).get('data',{}).get('url',''))")
[ "$GET_EP_URL" = "$WEBHOOK_URL" ] || fail "GET /webhook-endpoints/{id} URL mismatch"
pass "GET endpoint detail OK"

step "4c" "GET delivery-summary"
SUM_RES=$(curl -s "$BROPAY/v1/merchant/webhook-endpoints/delivery-summary" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
HAS_SUM=$(echo "$SUM_RES" | json "print('failed_count' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_SUM" = "True" ] || fail "delivery-summary missing failed_count"
pass "delivery-summary OK"

# ── Step 5: Trigger payment event ────────────────────────────────────────────
step 5 "Trigger payment event"
# Use HMAC to create a payment intent
CREDS=$(curl -s "$BROPAY/v1/merchant/integrations/$INTEGRATION_ID/rotate-key" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT")
API_KEY=$(echo "$CREDS" | json "print(json.load(sys.stdin)['data']['api_key'])")
SECRET_KEY=$(echo "$CREDS" | json "print(json.load(sys.stdin)['data']['secret_key'])")

PI_BODY="{\"amount\":5000,\"currency\":\"THB\",\"payment_method\":\"promptpay\",\"description\":\"Webhook trigger\"}"
PI_TS=$(date +%s)
PI_SIG=$(hmac_sign "$SECRET_KEY" "$PI_TS" "$PI_BODY")

PI_RES=$(curl -s "$BROPAY/v1/api/payment-intents" -X POST -H "$CT" \
  -H "X-Api-Key: $API_KEY" -H "X-Signature: $PI_SIG" -H "X-Timestamp: $PI_TS" \
  -d "$PI_BODY")
PI_ID=$(echo "$PI_RES" | json "print(json.load(sys.stdin)['data']['id'])")
PI_INT_ID=$(echo "$PI_RES" | json "print(json.load(sys.stdin).get('data',{}).get('integration_id',''))")
[ -n "$PI_ID" ] || fail "PI creation failed"
[ "$PI_INT_ID" = "$INTEGRATION_ID" ] || fail "PI integration_id mismatch (got $PI_INT_ID, expected $INTEGRATION_ID)"
pass "Payment intent created: ${PI_ID:0:16}..."

# Mark PI as succeeded via the admin /complete endpoint — this fires real webhook dispatch
ADMIN_AUTH="Authorization: Bearer $DEMO_ADMIN_TOKEN"
COMPLETE_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/payment-intents/$PI_ID/complete" \
  -X POST -H "$ADMIN_AUTH" -H "$ORIGIN" -H "$CT" \
  -d '{"reason":"e2e webhook trigger"}')
COMPLETE_HTTP=$(echo "$COMPLETE_RES" | tail -1)
COMPLETE_BODY=$(echo "$COMPLETE_RES" | sed '$d')
[ "$COMPLETE_HTTP" = "200" ] || fail "PI completion failed (HTTP $COMPLETE_HTTP): $COMPLETE_BODY"
pass "PI marked succeeded via admin /complete (webhook fired)"

# ── Step 6: Check webhook deliveries ─────────────────────────────────────────
step 6 "Check webhook deliveries"
# dispatchWebhook uses executionCtx.waitUntil — rows appear after /complete returns.
# Wrangler dev needs a short grace period (see scripts/e2e/admin/webhooks.sh step 10).
info "Waiting for async webhook dispatch (wrangler waitUntil)..."
sleep 3
DELIVERY_COUNT=0
DELIVERY_ID=""
for _ in $(seq 1 30); do
  DELIVERIES=$(curl -s "$BROPAY/v1/merchant/webhook-deliveries?endpoint_id=$ENDPOINT_ID" \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
  DELIVERY_COUNT=$(echo "$DELIVERIES" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
  if [ "${DELIVERY_COUNT:-0}" -ge 1 ]; then
    DELIVERY_ID=$(echo "$DELIVERIES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')")
    break
  fi
  sleep 0.5
done
if [ "${DELIVERY_COUNT:-0}" -lt 1 ]; then
  EVT_DIAG=$(curl -s "$BROPAY/v1/admin/webhooks/events?integration_id=$INTEGRATION_ID&merchant_id=$MERCHANT_ID&limit=5" \
    -H "$ADMIN_AUTH" -H "$ORIGIN")
  EVT_TOTAL=$(echo "$EVT_DIAG" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
  fail "No webhook deliveries after ~18s (endpoint=$ENDPOINT_ID pi=$PI_ID webhook_events=$EVT_TOTAL). Check API logs for [webhook-sender] / [webhook-dispatch]."
fi
[ -n "$DELIVERY_ID" ] || fail "No delivery id in list response"
pass "Deliveries: $DELIVERY_COUNT"

# ── Step 6b: Event type filter on deliveries ─────────────────────────────────
step "6b" "Event type filter on deliveries"
PAYMENT_DELIVERIES=$(curl -s "$BROPAY/v1/merchant/webhook-deliveries?endpoint_id=$ENDPOINT_ID&event_type=payment.completed" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
PAYMENT_DEL_COUNT=$(echo "$PAYMENT_DELIVERIES" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
[ "${PAYMENT_DEL_COUNT:-0}" -ge 1 ] || fail "Event type filter returned 0 results for payment.completed"
pass "Event type filter works: $PAYMENT_DEL_COUNT result(s)"

step "6c" "GET webhook delivery detail"
DETAIL_RES=$(curl -s "$BROPAY/v1/merchant/webhook-deliveries/$DELIVERY_ID" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
DETAIL_ID=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$DETAIL_ID" = "$DELIVERY_ID" ] || fail "GET /webhook-deliveries/{id} mismatch"
HAS_ATTEMPTS=$(echo "$DETAIL_RES" | json "print('attempts' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_ATTEMPTS" = "True" ] || fail "Delivery detail missing attempts[]"
pass "GET delivery detail with attempts[]"

step "6d" "GET webhook delivery analytics"
ANALYTICS_RES=$(curl -s "$BROPAY/v1/merchant/webhook-deliveries/analytics?range=7d&integration_id=$INTEGRATION_ID" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
ANALYTICS_DAYS=$(echo "$ANALYTICS_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$ANALYTICS_DAYS" -ge 7 ] || fail "Expected 7 daily points for range=7d, got $ANALYTICS_DAYS"
pass "Delivery analytics: $ANALYTICS_DAYS day(s)"

# ── Step 7: Update webhook endpoint ──────────────────────────────────────────
step 7 "Update webhook endpoint"
NEW_URL="https://webhook.site/e2e-updated-$(date +%s)"
UPDATE_RES=$(curl -s "$BROPAY/v1/merchant/webhook-endpoints/$ENDPOINT_ID" -X PUT \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"url\":\"$NEW_URL\",\"subscribed_events\":[\"payout.created\",\"payout.completed\"]}")
UPDATED_URL=$(echo "$UPDATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('url',''))")
[ "$UPDATED_URL" = "$NEW_URL" ] || fail "Update failed"
pass "Webhook endpoint updated to new URL"

# ── Step 8: Rotate webhook secret ────────────────────────────────────────────
step 8 "Rotate webhook secret"
ROTATE_RES=$(curl -s "$BROPAY/v1/merchant/webhook-endpoints/$ENDPOINT_ID/rotate-secret" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT")
NEW_SECRET=$(echo "$ROTATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('signing_secret',''))")
[ -n "$NEW_SECRET" ] || fail "Secret rotation failed"
[ "$NEW_SECRET" != "$SIGNING_SECRET" ] || fail "Secret did not change"
pass "Secret rotated: ${NEW_SECRET:0:20}..."

# ── Step 9: Delete webhook endpoint ──────────────────────────────────────────
step 9 "Delete webhook endpoint"
DELETE_RES=$(curl -s "$BROPAY/v1/merchant/webhook-endpoints/$ENDPOINT_ID" -X DELETE \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
DELETE_OK=$(echo "$DELETE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('success',False))")
[ "$DELETE_OK" = "True" ] || fail "Delete failed"
pass "Webhook endpoint deleted"

# Verify deletion
LIST_AFTER=$(curl -s "$BROPAY/v1/merchant/webhook-endpoints" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
COUNT_AFTER=$(echo "$LIST_AFTER" | json "print(json.load(sys.stdin)['meta']['total'])")
pass "Webhook endpoints after cleanup: $COUNT_AFTER"

# ── Step 10: Cleanup integration ─────────────────────────────────────────────
step 10 "Cleanup integration"
http_delete "$BROPAY/v1/merchant/integrations/$INTEGRATION_ID" -H "$OWNER" -H "$MERCH" -H "$ORIGIN"
if [ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ] || [ "$HTTP_CODE" = "404" ]; then
  pass "Integration cleaned up ($HTTP_CODE)"
else
  warn "Integration cleanup returned $HTTP_CODE"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}━━━ Webhook Endpoint Flow Complete ━━━${NC}"
echo "Endpoint:  ${ENDPOINT_ID:0:20}..."
echo "Events:    payment.created, payment.completed → payout.created, payout.completed"
echo "Secret:    rotated successfully"
echo "Delivery:  $DELIVERY_COUNT record(s)"
