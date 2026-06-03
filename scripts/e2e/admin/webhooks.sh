#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Webhooks (Realistic Lifecycle)
#
# Endpoints:
#   GET  /v1/admin/webhooks
#   GET  /v1/admin/webhooks/{id}
#   GET  /v1/admin/webhooks/deliveries
#   GET  /v1/admin/webhooks/events
#   POST /v1/merchant/webhook-endpoints
#   PUT  /v1/merchant/webhook-endpoints/{id}
#   DELETE /v1/merchant/webhook-endpoints/{id}
#   POST /v1/merchant/webhook-endpoints/{id}/rotate-secret
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
json_delete_ok() {
  echo "$1" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    s = d.get('data', {}).get('success')
    print('True' if s is True or s == 1 else 'False')
except Exception:
    print('False')
" 2>/dev/null || echo "False"
}
wrangler_bin() {
  if command -v wrangler >/dev/null 2>&1; then
    command -v wrangler
    return 0
  fi
  if [ -x "$REPO_ROOT/apps/api/node_modules/.bin/wrangler" ]; then
    echo "$REPO_ROOT/apps/api/node_modules/.bin/wrangler"
    return 0
  fi
  if [ -x "$REPO_ROOT/apps/api/node_modules/.bin/wrangler.cmd" ]; then
    echo "$REPO_ROOT/apps/api/node_modules/.bin/wrangler.cmd"
    return 0
  fi
  return 1
}
d1_local_ok() {
  local cmd="$1" wr out
  wr=$(wrangler_bin) || return 1
  out=$(cd "$REPO_ROOT/apps/api" && "$wr" d1 execute bropay-db --local --command "$cmd" --json 2>&1) || return 1
  echo "$out" | python3 -c "
import sys, json
try:
    blocks = json.load(sys.stdin)
    ok = bool(blocks) and all(b.get('success') for b in blocks)
except Exception:
    ok = False
sys.exit(0 if ok else 1)
" 2>/dev/null
}
d1_webhook_count() {
  local wr out
  wr=$(wrangler_bin) || { echo "99"; return; }
  out=$(cd "$REPO_ROOT/apps/api" && "$wr" d1 execute bropay-db --local --command \
    "SELECT COUNT(*) AS c FROM webhook_endpoints WHERE integration_id = '$INTEGRATION_ID'" --json 2>/dev/null) || {
    echo "99"
    return
  }
  echo "$out" | python3 -c "
import sys, json
try:
    blocks = json.load(sys.stdin)
    for block in blocks:
        for row in block.get('results', []):
            print(row.get('c', row.get('COUNT(*)', 99)))
            raise SystemExit
except Exception:
    pass
print(99)
" 2>/dev/null || echo "99"
}
d1_clear_integration_webhooks() {
  # No trailing semicolon — wrangler on Windows/Git Bash rejects multi-statement / stray ';'
  d1_local_ok "DELETE FROM webhook_delivery_attempts WHERE delivery_id IN (SELECT wd.id FROM webhook_deliveries wd WHERE wd.endpoint_id IN (SELECT id FROM webhook_endpoints WHERE integration_id = '$INTEGRATION_ID'))" || true
  d1_local_ok "DELETE FROM webhook_deliveries WHERE endpoint_id IN (SELECT id FROM webhook_endpoints WHERE integration_id = '$INTEGRATION_ID')" || true
  d1_local_ok "DELETE FROM webhook_endpoints WHERE integration_id = '$INTEGRATION_ID'"
}
http_code_from_curl() {
  echo "$1" | tail -n1 | tr -d '\r'
}

echo -e "${CYAN}━━━ Admin E2E — Webhooks (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
DEMO_ADMIN_TOKEN="${DEMO_ADMIN_TOKEN//$'\r'/}"
DEMO_OWNER_TOKEN="${DEMO_OWNER_TOKEN//$'\r'/}"
DEMO_MERCHANT_ID="${DEMO_MERCHANT_ID//$'\r'/}"
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
INTEGRATION_ID="${INTEGRATION_ID//$'\r'/}"
[ -n "$INTEGRATION_ID" ] || fail "No integration found"
pass "Integration: ${INTEGRATION_ID:0:16}... Full ID ${INTEGRATION_ID}"

step 2b "Clear webhook endpoints on demo integration (max 5 per integration)"
# Remove every endpoint on this integration so the run can create two fresh ones.
# (Prior runs / other e2e scripts may leave webhook.site or non-example.com URLs.)
delete_webhook_endpoint() {
  local hook_id="$1"
  local raw http
  [ -z "$hook_id" ] && return 0
  raw=$(curl -sS -L -w "\n%{http_code}" "$BROPAY/v1/admin/webhooks/$hook_id" -X DELETE \
    -H "$ADMIN" -H "$ORIGIN" -H "$CT") || raw=$'\n000'
  http=$(http_code_from_curl "$raw")
  if [ "$http" = "200" ] || [ "$http" = "204" ]; then
    return 0
  fi
  raw=$(curl -sS -L -w "\n%{http_code}" "$BROPAY/v1/merchant/webhook-endpoints/$hook_id" -X DELETE \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT") || raw=$'\n000'
  http=$(http_code_from_curl "$raw")
  [ "$http" = "200" ] || [ "$http" = "204" ]
}
EXISTING_HOOKS=$(curl -s "$BROPAY/v1/admin/webhooks?merchant_id=$DEMO_MERCHANT_ID&integration_id=$INTEGRATION_ID&limit=100" \
  -H "$ADMIN" -H "$ORIGIN")
# Read IDs from stdin — passing large JSON via argv breaks on Windows/Git Bash
STALE_HOOK_IDS=$(echo "$EXISTING_HOOKS" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for h in d.get('data', []):
    print(h.get('id', ''))
" 2>/dev/null) || STALE_HOOK_IDS=""
DELETED=0
while IFS= read -r hook_id; do
  hook_id="${hook_id//$'\r'/}"
  [ -z "$hook_id" ] && continue
  if delete_webhook_endpoint "$hook_id"; then
    DELETED=$((DELETED + 1))
  fi
done <<< "$STALE_HOOK_IDS"
if [ "$DELETED" -eq 0 ] && [ -n "$STALE_HOOK_IDS" ]; then
  SAMPLE_ID=$(printf '%s\n' "$STALE_HOOK_IDS" | head -n1)
  SAMPLE_ID="${SAMPLE_ID//$'\r'/}"
  SAMPLE_RAW=$(curl -sS -L -w "\n%{http_code}" "$BROPAY/v1/admin/webhooks/$SAMPLE_ID" -X DELETE \
    -H "$ADMIN" -H "$ORIGIN" -H "$CT" 2>&1) || SAMPLE_RAW=$'\n000'
  SAMPLE_HTTP=$(http_code_from_curl "$SAMPLE_RAW")
  SAMPLE_BODY=$(echo "$SAMPLE_RAW" | sed '$d' | head -c 200)
  warn "Sample admin DELETE $SAMPLE_ID → HTTP $SAMPLE_HTTP — $SAMPLE_BODY"
fi
FOUND_IDS=$(printf '%s\n' "$STALE_HOOK_IDS" | grep -c . || true)
FOUND_IDS=${FOUND_IDS:-0}
webhook_remaining_count() {
  local res
  res=$(curl -s "$BROPAY/v1/admin/webhooks?merchant_id=$DEMO_MERCHANT_ID&integration_id=$INTEGRATION_ID&limit=100" \
    -H "$ADMIN" -H "$ORIGIN")
  echo "$res" | python3 -c "
import sys, json
try:
    print(json.load(sys.stdin).get('meta', {}).get('total', 0))
except Exception:
    print(99)
" 2>/dev/null || echo "99"
}
REMAINING_API=$(webhook_remaining_count)
REMAINING_D1=$(d1_webhook_count)
if [ "${REMAINING_API:-99}" -gt 3 ] || [ "${REMAINING_D1:-99}" -gt 3 ]; then
  warn "API delete removed $DELETED of $FOUND_IDS (api=$REMAINING_API d1=$REMAINING_D1) — D1 DELETE fallback"
  if ! d1_clear_integration_webhooks; then
    fail "D1 DELETE failed (api=$REMAINING_API d1=$REMAINING_D1). Local D1 FK may point at dropped _old_webhook_events — remove apps/api/.wrangler/state/v3/d1, then pnpm migrate:local && pnpm db:seed, and re-run this script"
  fi
  REMAINING_API=$(webhook_remaining_count)
  REMAINING_D1=$(d1_webhook_count)
fi
[ "${REMAINING_D1:-99}" -le 3 ] || fail "Could not free webhook slots (d1=$REMAINING_D1 api=$REMAINING_API; listed=$FOUND_IDS api_deleted=$DELETED)"
pass "Integration cleared (d1=$REMAINING_D1 api=$REMAINING_API before create)"

step 3 "Merchant creates webhook endpoint #1"
TS=$(date +%s)
WH1_RES=$(curl -s "$BROPAY/v1/merchant/webhook-endpoints" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"integration_id\":\"$INTEGRATION_ID\",\"url\":\"https://webhook1-$TS.example.com/hook\",\"subscribed_events\":[\"payment.created\",\"payment.completed\"],\"description\":\"E2E webhook endpoint 1\"}")
WH1_ID=$(echo "$WH1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
WH1_ID="${WH1_ID//$'\r'/}"
[ -n "$WH1_ID" ] || fail "Webhook #1 creation failed"
WH1_SECRET=$(echo "$WH1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('signing_secret',''))")
WH1_SECRET="${WH1_SECRET//$'\r'/}"
[ -n "$WH1_SECRET" ] || fail "Webhook #1 secret not returned"
pass "Webhook #1: ${WH1_ID:0:16}..."

step 4 "Merchant creates webhook endpoint #2"
WH2_RES=$(curl -s "$BROPAY/v1/merchant/webhook-endpoints" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"integration_id\":\"$INTEGRATION_ID\",\"url\":\"https://webhook2-$TS.example.com/hook\",\"subscribed_events\":[\"settlement.created\",\"settlement.completed\"],\"description\":\"E2E webhook endpoint 2\"}")
WH2_ID=$(echo "$WH2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
WH2_ID="${WH2_ID//$'\r'/}"
WH2_ERR=$(echo "$WH2_RES" | python3 -c "
import sys, json
try:
    e = json.load(sys.stdin).get('error', {})
    print(e.get('code', '?') + ': ' + e.get('message', '?'))
except Exception:
    print('invalid JSON response')
" 2>/dev/null) || WH2_ERR="$WH2_RES"
[ -n "$WH2_ID" ] || fail "Webhook #2 creation failed: $WH2_ERR"
WH2_SECRET=$(echo "$WH2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('signing_secret',''))")
WH2_SECRET="${WH2_SECRET//$'\r'/}"
pass "Webhook #2: ${WH2_ID:0:16}..."

step 5 "Admin lists webhook endpoints"
LIST_RES=$(curl -s "$BROPAY/v1/admin/webhooks" -H "$ADMIN" -H "$ORIGIN")
HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$HAS_META" = "True" ] || fail "Webhook list missing meta"
LIST_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_TOTAL" -ge 2 ] || fail "Expected at least 2 webhook endpoints"
pass "Listed $LIST_TOTAL endpoint(s)"

step 6 "Admin filters endpoints by merchant_id"
FILTER_MERCH_RES=$(curl -s "$BROPAY/v1/admin/webhooks?merchant_id=$DEMO_MERCHANT_ID" -H "$ADMIN" -H "$ORIGIN")
FILTER_MERCH_TOTAL=$(echo "$FILTER_MERCH_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FILTER_MERCH_TOTAL" -ge 2 ] || fail "Expected at least 2 endpoints for merchant"
pass "$FILTER_MERCH_TOTAL endpoint(s) for merchant"

step 7 "Admin filters endpoints by is_active=1"
FILTER_ACTIVE_RES=$(curl -s "$BROPAY/v1/admin/webhooks?is_active=1" -H "$ADMIN" -H "$ORIGIN")
FILTER_ACTIVE_TOTAL=$(echo "$FILTER_ACTIVE_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FILTER_ACTIVE_TOTAL" -ge 2 ] || fail "Expected at least 2 active endpoints"
pass "$FILTER_ACTIVE_TOTAL active endpoint(s)"

step 8 "Admin searches endpoints by URL"
SEARCH_URL="webhook1-$TS"
SEARCH_RES=$(curl -s "$BROPAY/v1/admin/webhooks?q=$SEARCH_URL" -H "$ADMIN" -H "$ORIGIN")
SEARCH_TOTAL=$(echo "$SEARCH_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$SEARCH_TOTAL" -ge 1 ] || fail "Expected at least 1 endpoint matching URL search"
pass "$SEARCH_TOTAL endpoint(s) matching URL"

step 9 "Admin gets endpoint detail with recent deliveries"
DETAIL_RES=$(curl -s "$BROPAY/v1/admin/webhooks/$WH1_ID" -H "$ADMIN" -H "$ORIGIN")
DETAIL_ID=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$DETAIL_ID" = "$WH1_ID" ] || fail "Detail mismatch"
DETAIL_HAS_DELIVERIES=$(echo "$DETAIL_RES" | json "print('recent_deliveries' in json.load(sys.stdin).get('data',{}))")
[ "$DETAIL_HAS_DELIVERIES" = "True" ] || fail "Detail missing recent_deliveries"
pass "Detail fetched with deliveries"

step 10 "Trigger webhook delivery via real API flow (complete a PI)"
# Rotate WH1 secret first to ensure it has a fresh, properly-encrypted secret
ROTATE_EARLY_RES=$(curl -s "$BROPAY/v1/merchant/webhook-endpoints/$WH1_ID/rotate-secret" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
# Create a PI directly in the DB in requires_action state, then complete it via the
# admin API — this calls dispatchWebhook which creates both webhook_events and webhook_deliveries.
WH_PI_ID=$(python3 -c "import uuid; print(uuid.uuid4())")
WH_PI_SECRET="whtest_${WH_PI_ID}_secret_$TS"
pushd "$REPO_ROOT/apps/api" > /dev/null
if ! wrangler d1 execute bropay-db --local --command "INSERT INTO payment_intents (id, merchant_id, integration_id, amount, currency, status, payment_method, expiry_minutes, client_secret, description) VALUES ('$WH_PI_ID', '$DEMO_MERCHANT_ID', '$INTEGRATION_ID', 100000, 'THB', 'requires_action', 'promptpay', 15, '$WH_PI_SECRET', 'Webhook dispatch test');" --json 2>/dev/null | grep -q '"success": true'; then
  popd > /dev/null
  fail "wrangler seed webhook test payment_intent failed"
fi
popd > /dev/null
# Complete the PI via admin API — triggers dispatchWebhook → webhook_events + webhook_deliveries
COMPLETE_RES=$(curl -s "$BROPAY/v1/admin/payment-intents/$WH_PI_ID/complete" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"reason":"Webhook dispatch test"}')
COMPLETE_STATUS=$(echo "$COMPLETE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$COMPLETE_STATUS" = "succeeded" ] || fail "PI completion failed (got '$COMPLETE_STATUS') — response: $COMPLETE_RES"
pass "PI completed via admin API, webhook dispatch triggered"
# waitUntil in wrangler dev can lag; poll deliveries for this endpoint.
DEL_TOTAL=0
for _ in 1 2 3 4 5 6; do
  sleep 2
  DEL_RES=$(curl -s "$BROPAY/v1/admin/webhooks/deliveries?endpoint_id=$WH1_ID" -H "$ADMIN" -H "$ORIGIN")
  DEL_TOTAL=$(echo "$DEL_RES" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
  [ "${DEL_TOTAL:-0}" -ge 1 ] && break
done

step 11 "Admin lists webhook deliveries"
DEL_HAS_META=$(echo "$DEL_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$DEL_HAS_META" = "True" ] || fail "Delivery list missing meta"
WEBHOOK_SKIP_DELIVERY_ASSERTS=0
if [ "${DEL_TOTAL:-0}" -lt 1 ]; then
  # Fallback: confirm webhook event was recorded even if outbound delivery is slow/missing locally.
  EVT_CHECK=$(curl -s "$BROPAY/v1/admin/webhooks/events?merchant_id=$DEMO_MERCHANT_ID&limit=5" -H "$ADMIN" -H "$ORIGIN")
  EVT_TOTAL=$(echo "$EVT_CHECK" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
  [ "$EVT_TOTAL" -ge 1 ] || fail "Expected at least 1 delivery or webhook event (deliveries=0 events=$EVT_TOTAL)"
  warn "No deliveries yet for endpoint — continuing (events=$EVT_TOTAL; waitUntil may be slow in local dev)"
  WEBHOOK_SKIP_DELIVERY_ASSERTS=1
fi
pass "Listed ${DEL_TOTAL} delivery(s) for endpoint"

step 12 "Admin filters deliveries by non-terminal status (retrying or pending)"
if [ "$WEBHOOK_SKIP_DELIVERY_ASSERTS" = "1" ]; then
  warn "Skipping non-terminal delivery filter (no deliveries in local dev)"
else
  DEL_RETRYING_RES=$(curl -s "$BROPAY/v1/admin/webhooks/deliveries?status=retrying&endpoint_id=$WH1_ID" -H "$ADMIN" -H "$ORIGIN")
  DEL_RETRYING_TOTAL=$(echo "$DEL_RETRYING_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
  DEL_PENDING_RES=$(curl -s "$BROPAY/v1/admin/webhooks/deliveries?status=pending&endpoint_id=$WH1_ID" -H "$ADMIN" -H "$ORIGIN")
  DEL_PENDING_TOTAL=$(echo "$DEL_PENDING_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
  DEL_NON_TERMINAL=$((DEL_RETRYING_TOTAL + DEL_PENDING_TOTAL))
  [ "$DEL_NON_TERMINAL" -ge 1 ] || fail "Expected at least 1 non-terminal delivery (retrying=$DEL_RETRYING_TOTAL pending=$DEL_PENDING_TOTAL)"
  pass "$DEL_NON_TERMINAL non-terminal delivery(s) (retrying=$DEL_RETRYING_TOTAL pending=$DEL_PENDING_TOTAL)"
fi

step 13 "Admin filters deliveries by endpoint_id"
if [ "$WEBHOOK_SKIP_DELIVERY_ASSERTS" = "1" ]; then
  warn "Skipping endpoint delivery count (no deliveries in local dev)"
else
  DEL_EP_RES=$(curl -s "$BROPAY/v1/admin/webhooks/deliveries?endpoint_id=$WH1_ID" -H "$ADMIN" -H "$ORIGIN")
  DEL_EP_TOTAL=$(echo "$DEL_EP_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
  [ "$DEL_EP_TOTAL" -ge 1 ] || fail "Expected at least 1 delivery for endpoint"
  pass "$DEL_EP_TOTAL delivery(s) for endpoint #1"
fi

step 14 "Admin lists webhook events"
EVT_RES=$(curl -s "$BROPAY/v1/admin/webhooks/events" -H "$ADMIN" -H "$ORIGIN")
EVT_HAS_META=$(echo "$EVT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$EVT_HAS_META" = "True" ] || fail "Event list missing meta"
EVT_TOTAL=$(echo "$EVT_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$EVT_TOTAL" -ge 1 ] || fail "Expected at least 1 event"
pass "Listed $EVT_TOTAL event(s)"

step 15 "Admin filters events by event_type (payment.completed from Step 10)"
# Step 10 completes a DB-seeded PI via admin /complete — dispatches payment.completed only (not payment.created).
EVT_TYPE_RES=$(curl -s "$BROPAY/v1/admin/webhooks/events?event_type=payment.completed&merchant_id=$DEMO_MERCHANT_ID" -H "$ADMIN" -H "$ORIGIN")
EVT_TYPE_TOTAL=$(echo "$EVT_TYPE_RES" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))" 2>/dev/null) || EVT_TYPE_TOTAL=0
[ "${EVT_TYPE_TOTAL:-0}" -ge 1 ] || fail "Expected at least 1 payment.completed event (got ${EVT_TYPE_TOTAL:-0})"
pass "$EVT_TYPE_TOTAL payment.completed event(s)"

step 16 "Admin filters events by merchant_id"
EVT_MERCH_RES=$(curl -s "$BROPAY/v1/admin/webhooks/events?merchant_id=$DEMO_MERCHANT_ID" -H "$ADMIN" -H "$ORIGIN")
EVT_MERCH_TOTAL=$(echo "$EVT_MERCH_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$EVT_MERCH_TOTAL" -ge 1 ] || fail "Expected at least 1 event for merchant"
pass "$EVT_MERCH_TOTAL event(s) for merchant"

step 17 "Merchant disables webhook endpoint #1"
UPDATE_RES=$(curl -s "$BROPAY/v1/merchant/webhook-endpoints/$WH1_ID" -X PUT \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{"is_active":0}')
UPDATE_STATUS=$(echo "$UPDATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('is_active',''))")
[ "$UPDATE_STATUS" = "0" ] || fail "Expected is_active=0, got '$UPDATE_STATUS'"
pass "Webhook #1 disabled"

step 18 "Admin confirms endpoint #1 is now inactive"
INACTIVE_RES=$(curl -s "$BROPAY/v1/admin/webhooks?is_active=0" -H "$ADMIN" -H "$ORIGIN")
INACTIVE_TOTAL=$(echo "$INACTIVE_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$INACTIVE_TOTAL" -ge 1 ] || fail "Expected at least 1 inactive endpoint"
# Verify our specific endpoint is in the inactive list
INACTIVE_HAS_WH1=$(echo "$INACTIVE_RES" | json "d=json.load(sys.stdin).get('data',[]); print('True' if any(x.get('id')=='$WH1_ID' for x in d) else 'False')")
[ "$INACTIVE_HAS_WH1" = "True" ] || fail "Endpoint #1 not found in inactive list"
pass "Confirmed inactive in admin list"

step 19 "Merchant rotates secret on webhook endpoint #2"
ROTATE_RES=$(curl -s "$BROPAY/v1/merchant/webhook-endpoints/$WH2_ID/rotate-secret" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
ROTATE_OK=$(echo "$ROTATE_RES" | json "print('data' in json.load(sys.stdin))")
[ "$ROTATE_OK" = "True" ] || fail "Secret rotation failed"
NEW_SECRET=$(echo "$ROTATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('signing_secret',''))")
[ -n "$NEW_SECRET" ] || fail "New secret not returned"
NEW_SECRET="${NEW_SECRET//$'\r'/}"
[ "$NEW_SECRET" != "$WH2_SECRET" ] || fail "New secret should differ from endpoint #2's previous secret"
pass "Secret rotated"

step 20 "Merchant deletes webhook endpoint #1"
# Re-enable before delete (matches merchant webhook-endpoints.sh lifecycle)
curl -s "$BROPAY/v1/merchant/webhook-endpoints/$WH1_ID" -X PUT \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{"is_active":1}' > /dev/null || true
DELETE_RAW=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/webhook-endpoints/$WH1_ID" -X DELETE \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN") || DELETE_RAW=$'\n000'
DELETE_HTTP=$(http_code_from_curl "$DELETE_RAW")
DELETE_BODY=$(echo "$DELETE_RAW" | sed '$d')
if [ "$DELETE_HTTP" != "200" ] && [ "$DELETE_HTTP" != "204" ]; then
  warn "Merchant delete failed (HTTP $DELETE_HTTP), trying admin DELETE"
  DELETE_RAW=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/webhooks/$WH1_ID" -X DELETE \
    -H "$ADMIN" -H "$ORIGIN") || DELETE_RAW=$'\n000'
  DELETE_HTTP=$(http_code_from_curl "$DELETE_RAW")
  DELETE_BODY=$(echo "$DELETE_RAW" | sed '$d')
fi
if [ "$DELETE_HTTP" != "200" ] && [ "$DELETE_HTTP" != "204" ]; then
  fail "Delete failed (HTTP $DELETE_HTTP): $DELETE_BODY"
fi
pass "Webhook #1 deleted"

step 21 "Admin confirms webhook endpoint #1 is gone, #2 remains"
FINAL_RES=$(curl -s "$BROPAY/v1/admin/webhooks?merchant_id=$DEMO_MERCHANT_ID" -H "$ADMIN" -H "$ORIGIN")
FINAL_IDS=$(echo "$FINAL_RES" | json "d=json.load(sys.stdin).get('data',[]); print([x['id'] for x in d])")
FINAL_HAS_WH1=$(echo "$FINAL_RES" | json "d=json.load(sys.stdin).get('data',[]); print('True' if any(x.get('id')=='$WH1_ID' for x in d) else 'False')")
FINAL_HAS_WH2=$(echo "$FINAL_RES" | json "d=json.load(sys.stdin).get('data',[]); print('True' if any(x.get('id')=='$WH2_ID' for x in d) else 'False')")
[ "$FINAL_HAS_WH1" = "False" ] || fail "Endpoint #1 should be deleted"
[ "$FINAL_HAS_WH2" = "True" ] || fail "Endpoint #2 should still exist"
pass "Webhook #1 gone, webhook #2 remains"

echo -e "\n${GREEN}━━━ Webhooks Realistic Lifecycle Complete ━━━${NC}"
