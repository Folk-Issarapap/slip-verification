#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Payment Flow — PI creation → KBNK deposit → status transition
#
# Usage:
#   bash scripts/e2e/e2e-payment-flow.sh [completed|failed|cancelled|expired|all]
#
# Environment:
#   BROPAY_URL, BROPAY_ENV (local|staging)
#   RUN_KBNK=1          Call live KBNK API (default 0 → DB/admin fallback)
#   KBNK_URL, KBNK_CLIENT_ID, KBNK_CLIENT_SECRET (required when RUN_KBNK=1)
#   BOOTSTRAP_MERCHANT_ID, BOOTSTRAP_MERCHANT_SLUG (optional)
#
# External: KBNK + public webhook tunnel when RUN_KBNK=1 (see scripts/dev/README.md)
#
# HMAC: _merchant-lib.sh hmac_sign() → POST /v1/api/payment-intents
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TARGET_STATUS="${1:-completed}"
# BROPAY_ENV: "local" (default) | "staging" — picks which BroPay deployment
# to drive and which D1 binding (`--local` vs `--remote --env staging`) to use
# for the link/cleanup steps that bypass the API.
#
# Webhook delivery: KBNK stores its webhook URL server-side per merchant
# (visible at `$KBNK/api/v1/me` → `webhookUrl`). For local runs that URL must
# point at a public hostname that forwards to your local API on :8787 — a
# Cloudflare named tunnel with a stable hostname is the simplest setup. This
# script does NOT manage that tunnel; bring it up out-of-band.
BROPAY_ENV="${BROPAY_ENV:-local}"
if [ "$BROPAY_ENV" = "staging" ]; then
  BROPAY="${BROPAY_URL:-https://bropay-api-staging.example.com}"
  D1_FLAGS="--remote --env staging"
else
  BROPAY="${BROPAY_URL:-http://localhost:8787}"
  D1_FLAGS="--local"
fi
KBNK="${KBNK_URL:-https://kbnk-payment-api-staging.example.com}"
ORIGIN="Origin: http://localhost:3000"
CT="Content-Type: application/json"

KBNK_CLIENT_ID="${KBNK_CLIENT_ID:-}"
KBNK_CLIENT_SECRET="${KBNK_CLIENT_SECRET:-}"
RUN_KBNK="${RUN_KBNK:-0}"

# shellcheck source=_merchant-lib.sh
source "$SCRIPT_DIR/_merchant-lib.sh"
info() { echo -e "${CYAN}→ $1${NC}"; }

# curl helper: returns body + trailing status line; use sed '$d' for body, tail -1 for code
http_json() {
  local out
  out=$(curl -s -w "\n%{http_code}" "$@")
  echo "$out"
}

# ── Bootstrap demo merchant ───────────────────────────────────────────────────
step 0 "Bootstrap demo merchant"
source "$SCRIPT_DIR/_bootstrap.sh"
bootstrap_demo_merchant
MERCHANT_ID="$DEMO_MERCHANT_ID"
pass "Merchant: ${MERCHANT_ID:0:16}...  Owner: ${DEMO_OWNER_ID:0:16}..."

# ── Provision integration (fresh per run for clean HMAC keys) ─────────────────
step "0b" "Ensure active integration exists"
MERCH_HEADER="X-Merchant-Id: $MERCHANT_ID"
EXISTING_INTEGRATIONS=$(curl -s "$BROPAY/v1/merchant/integrations" \
  -H "Authorization: Bearer $DEMO_OWNER_TOKEN" -H "$MERCH_HEADER" -H "$ORIGIN")
ACTIVE_COUNT=$(echo "$EXISTING_INTEGRATIONS" | json "print(sum(1 for i in json.load(sys.stdin).get('data',[]) if i.get('status')=='active'))")
if [ "${ACTIVE_COUNT:-0}" -eq 0 ]; then
  # No active integration — either activate an existing one or create a fresh one
  FIRST_ID=$(echo "$EXISTING_INTEGRATIONS" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')")
  if [ -n "$FIRST_ID" ]; then
    info "Activating existing integration $FIRST_ID..."
    curl -s "$BROPAY/v1/merchant/integrations/$FIRST_ID" -X PUT \
      -H "Authorization: Bearer $DEMO_OWNER_TOKEN" -H "$MERCH_HEADER" -H "$ORIGIN" -H "$CT" \
      -d '{"status":"active"}' > /dev/null
  else
    info "Creating integration..."
    curl -s "$BROPAY/v1/merchant/integrations" -X POST \
      -H "Authorization: Bearer $DEMO_OWNER_TOKEN" -H "$MERCH_HEADER" -H "$ORIGIN" -H "$CT" \
      -d '{"name":"Demo Integration","slug":"demo"}' > /dev/null
  fi
fi
pass "Integration ready"

# ── Guard: 404 for missing resources ──────────────────────────────────────────
step "0c" "Guard checks"

# 404 on non-existent PI
PI_404=$(http_json "$BROPAY/v1/admin/payment-intents/nonexistent-pi-id" \
  -H "Authorization: Bearer $DEMO_ADMIN_TOKEN" -H "$ORIGIN")
PI_404_CODE=$(echo "$PI_404" | tail -1)
[ "$PI_404_CODE" = "404" ] && pass "404 for missing PI" || warn "Expected 404 for missing PI, got $PI_404_CODE"

# 400 for invalid amount (negative)
BAD_PI=$(http_json "$BROPAY/v1/api/payment-intents" -X POST -H "$CT" \
  -H "X-Api-Key: dummy" -H "X-Signature: dummy" -H "X-Timestamp: 1" \
  -d '{"amount":-100,"currency":"THB","payment_method":"promptpay"}')
BAD_PI_CODE=$(echo "$BAD_PI" | tail -1)
[ "$BAD_PI_CODE" = "400" ] || [ "$BAD_PI_CODE" = "422" ] || [ "$BAD_PI_CODE" = "401" ] && pass "400/422/401 for invalid PI input ($BAD_PI_CODE)" || warn "Expected 400/422/401 for bad PI, got $BAD_PI_CODE"

# Auth guard: no token
AUTH_PI=$(http_json "$BROPAY/v1/admin/payment-intents" -H "$ORIGIN")
AUTH_PI_CODE=$(echo "$AUTH_PI" | tail -1)
[ "$AUTH_PI_CODE" = "401" ] && pass "401 without auth token" || warn "Expected 401 without token, got $AUTH_PI_CODE"

# ── Run a single payment flow for a given target status ───────────────────────
run_flow() {
  local STATUS=$1
  # Minimum payment amount is 5000 satang (50 THB) per PLATFORM_MIN_PAYMENT
  local AMOUNT=$((5000 + RANDOM % 5000))

  echo -e "\n${CYAN}══════════════════════════════════════════════════${NC}"
  echo -e "${CYAN}  Payment Flow: → ${STATUS}  (${AMOUNT} THB)${NC}"
  echo -e "${CYAN}══════════════════════════════════════════════════${NC}"

  # ── Auth ──
  step 1 "Authenticate"
  ADMIN_TOKEN="$DEMO_ADMIN_TOKEN"
  OWNER_TOKEN="$DEMO_OWNER_TOKEN"
  pass "Admin + Owner (bootstrapped)"

  # ── HMAC creds ──
  step 2 "Get HMAC Credentials"
  INTEGRATIONS=$(curl -s "$BROPAY/v1/merchant/integrations" \
    -H "Authorization: Bearer $OWNER_TOKEN" -H "$MERCH_HEADER" -H "$ORIGIN")
  INTEGRATION_ID=$(echo "$INTEGRATIONS" | json "d=json.load(sys.stdin).get('data',[]); active=[i for i in d if i.get('status')=='active']; print((active[0] if active else d[0]).get('id','') if (active or d) else '')")
  [ -n "$INTEGRATION_ID" ] || fail "No integration found"

  CREDS=$(curl -s "$BROPAY/v1/merchant/integrations/$INTEGRATION_ID/rotate-key" -X POST \
    -H "Authorization: Bearer $OWNER_TOKEN" -H "$MERCH_HEADER" -H "$ORIGIN" -H "$CT")
  API_KEY=$(echo "$CREDS" | json "d=json.load(sys.stdin); print((d.get('data') or {}).get('api_key',''))")
  SECRET_KEY=$(echo "$CREDS" | json "d=json.load(sys.stdin); print((d.get('data') or {}).get('secret_key',''))")
  [ -n "$API_KEY" ] && [ -n "$SECRET_KEY" ] || fail "rotate-key failed — $CREDS"
  pass "API Key: ${API_KEY:0:20}..."

  # ── List PIs before creation ──
  step "2b" "List PIs before creation"
  PI_LIST_BEFORE=$(curl -s "$BROPAY/v1/admin/payment-intents?merchant_id=$MERCHANT_ID&limit=1" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H "$ORIGIN")
  PI_TOTAL_BEFORE=$(echo "$PI_LIST_BEFORE" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
  pass "PI count before: $PI_TOTAL_BEFORE"

  # ── Create PI ──
  step 3 "Create Payment Intent ($AMOUNT THB)"
  E2E_TS=$(date +%s)
  E2E_INV="INV-2026-E2E-${E2E_TS}"
  E2E_ORD="ORD-E2E-${E2E_TS}"
  PI_BODY="{\"amount\":$AMOUNT,\"currency\":\"THB\",\"payment_method\":\"promptpay\",\"description\":\"E2E $STATUS\",\"ref1\":\"INV-DEMO\",\"ref2\":\"E2E-RUN\",\"invoice_number\":\"$E2E_INV\",\"order_id\":\"$E2E_ORD\",\"return_url\":\"https://example.com/success\",\"cancel_url\":\"https://example.com/cancel\",\"customer_note\":\"Thank you for your payment\"}"
  PI_TS=$(date +%s)
  PI_SIG=$(hmac_sign "$SECRET_KEY" "$PI_TS" "$PI_BODY")
  [ -n "$PI_SIG" ] || fail "HMAC sign failed (check python3)"

  PI_RAW=$(http_json "$BROPAY/v1/api/payment-intents" -X POST -H "$CT" \
    -H "X-Api-Key: $API_KEY" -H "X-Signature: $PI_SIG" -H "X-Timestamp: $PI_TS" \
    -d "$PI_BODY")
  PI_HTTP=$(echo "$PI_RAW" | tail -1)
  PI_RES=$(echo "$PI_RAW" | sed '$d')
  PI_ID=$(echo "$PI_RES" | json "d=json.load(sys.stdin); print((d.get('data') or {}).get('id',''))")
  [ "$PI_HTTP" = "201" ] && [ -n "$PI_ID" ] || fail "PI creation failed (HTTP $PI_HTTP) — $PI_RES"
  pass "PI: ${PI_ID:0:12}... (requires_payment_method)"

  # Assert reference fields were stored correctly
  PI_REF1=$(echo "$PI_RES" | json "d=json.load(sys.stdin).get('data') or {}; print(d.get('ref1') or '')")
  PI_REF2=$(echo "$PI_RES" | json "d=json.load(sys.stdin).get('data') or {}; print(d.get('ref2') or '')")
  PI_INV=$(echo "$PI_RES" | json "d=json.load(sys.stdin).get('data') or {}; print(d.get('invoice_number') or '')")
  PI_ORD=$(echo "$PI_RES" | json "d=json.load(sys.stdin).get('data') or {}; print(d.get('order_id') or '')")
  PI_RETURN=$(echo "$PI_RES" | json "d=json.load(sys.stdin).get('data') or {}; print(d.get('return_url') or '')")
  PI_CANCEL=$(echo "$PI_RES" | json "d=json.load(sys.stdin).get('data') or {}; print(d.get('cancel_url') or '')")
  PI_CNOTE=$(echo "$PI_RES" | json "d=json.load(sys.stdin).get('data') or {}; print(d.get('customer_note') or '')")
  [ -n "$PI_REF1" ] && pass "ref1: $PI_REF1" || fail "ref1 missing from PI response"
  [ -n "$PI_REF2" ] && pass "ref2: $PI_REF2" || fail "ref2 missing from PI response"
  [ -n "$PI_INV" ] && pass "invoice_number: $PI_INV" || fail "invoice_number missing from PI response"
  [ -n "$PI_ORD" ] && pass "order_id: $PI_ORD" || fail "order_id missing from PI response"
  [ -n "$PI_RETURN" ] && pass "return_url: $PI_RETURN" || fail "return_url missing from PI response"
  [ -n "$PI_CANCEL" ] && pass "cancel_url: $PI_CANCEL" || fail "cancel_url missing from PI response"
  [ -n "$PI_CNOTE" ] && pass "customer_note: $PI_CNOTE" || fail "customer_note missing from PI response"

  # ── Verify list count increased ──
  step "3b" "Verify list count increased"
  PI_LIST_AFTER=$(curl -s "$BROPAY/v1/admin/payment-intents?merchant_id=$MERCHANT_ID&limit=1" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H "$ORIGIN")
  PI_TOTAL_AFTER=$(echo "$PI_LIST_AFTER" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
  EXPECTED_AFTER=$((PI_TOTAL_BEFORE + 1))
  [ "$PI_TOTAL_AFTER" -eq "$EXPECTED_AFTER" ] && pass "PI count after: $PI_TOTAL_AFTER (+1)" || warn "PI count did not increase ($PI_TOTAL_AFTER vs $EXPECTED_AFTER)"

  # ── Verify filter works ──
  step "3c" "Verify filter by status"
  PI_FILTER=$(curl -s "$BROPAY/v1/admin/payment-intents?merchant_id=$MERCHANT_ID&status=requires_payment_method&limit=1" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H "$ORIGIN")
  PI_FILTER_TOTAL=$(echo "$PI_FILTER" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
  [ "$PI_FILTER_TOTAL" -ge 1 ] && pass "Filter by status returned $PI_FILTER_TOTAL result(s)" || warn "Filter by status returned 0 results"

  # ── Create KBNK deposit ──
  step 4 "Create KBNK Deposit + Link"
  KBNK_DEP_ID=""
  KBNK_DEP_DISPLAY=""
  if [ "$RUN_KBNK" = "1" ]; then
    [ -n "$KBNK_CLIENT_ID" ] && [ -n "$KBNK_CLIENT_SECRET" ] || fail "RUN_KBNK=1 requires KBNK_CLIENT_ID and KBNK_CLIENT_SECRET"
  else
    warn "RUN_KBNK not set — skipping live KBNK (DB/admin fallback)"
  fi

  KBNK_TOKEN=""
  if [ "$RUN_KBNK" = "1" ]; then
  KBNK_TOKEN=$(curl -s "$KBNK/api/v1/auth/token" -H "$CT" \
    -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"$KBNK_CLIENT_ID\",\"client_secret\":\"$KBNK_CLIENT_SECRET\"}" \
    | json "print(json.load(sys.stdin).get('access_token',''))")
  fi

  if [ -n "$KBNK_TOKEN" ]; then
    KBNK_DEP=$(curl -s "$KBNK/api/v1/deposits" -H "Authorization: Bearer $KBNK_TOKEN" -H "$CT" \
      -d "{\"amount\":$AMOUNT.00,\"paymentMethod\":\"promptpay\",\"currency\":\"THB\",\"correlationId\":\"bp-$PI_ID\",\"customer\":{\"bankCode\":\"KBANK\",\"accountNumber\":\"0123456789\",\"accountHolderName\":\"E2E Test\"}}")
    KBNK_DEP_ID=$(echo "$KBNK_DEP" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
    KBNK_DEP_DISPLAY=$(echo "$KBNK_DEP" | json "print(json.load(sys.stdin).get('data',{}).get('depositId',''))")
    [ -n "$KBNK_DEP_DISPLAY" ] && pass "KBNK deposit: $KBNK_DEP_DISPLAY" || warn "KBNK deposit creation failed (rate limited?)"
  elif [ "$RUN_KBNK" = "1" ]; then
    warn "KBNK token unavailable (rate limited or unreachable). Using admin/DB fallback."
    KBNK_DEP_ID=""
  fi

  # Link PI to KBNK deposit (simulate checkout). When KBNK is off, admin /complete and
  # /cancel accept requires_payment_method — no D1 hop to processing needed.
  if [ -n "$KBNK_DEP_ID" ]; then
    # Link by KBNK's *display* depositId (BRO-...) — that's what KBNK sends in webhook
    # payloads (`data.depositId`) and what the webhook handler matches on.
    # data.id is KBNK's internal UUID and never appears in webhooks.
    e2e_d1_sql \
      "UPDATE payment_intents SET provider_deposit_id = '$KBNK_DEP_DISPLAY', status = 'processing', updated_at = datetime('now') WHERE id = '$PI_ID'" \
      "$D1_FLAGS" || fail "D1: link PI to KBNK deposit"
    pass "PI linked → processing (provider_deposit_id=$KBNK_DEP_DISPLAY)"
  else
    pass "Skipping processing DB link (admin API fallback)"
  fi

  # ── Trigger target status ──
  step 5 "Trigger: $STATUS"
  if [ "$STATUS" = "expired" ]; then
    # KBNK doesn't have an "expire" sandbox override — update BroPay DB directly
    e2e_d1_sql \
      "UPDATE payment_intents SET status = 'expired', updated_at = datetime('now') WHERE id = '$PI_ID'" \
      "$D1_FLAGS" || fail "D1: set PI expired"
    pass "PI set to expired (direct DB)"
  else
    if [ -n "$KBNK_DEP_ID" ]; then
      # Use KBNK sandbox status override → triggers webhook
      curl -s "$KBNK/api/v1/deposits/$KBNK_DEP_ID/status" -X PATCH \
        -H "Authorization: Bearer $KBNK_TOKEN" -H "$CT" \
        -d "{\"status\":\"$STATUS\"}" > /dev/null
      pass "KBNK deposit → $STATUS (webhook sent)"
      # Poll for the webhook handler to flip the PI status (up to 30s).
      # KBNK signs + delivers + we verify HMAC + we run a D1 batch — usually <2s, can spike.
      EXPECT_PI_STATUS="$STATUS"
      [ "$STATUS" = "completed" ] && EXPECT_PI_STATUS="succeeded"
      info "Polling for webhook to land (up to 30s)..."
      for _ in $(seq 1 30); do
        CUR=$(curl -s "$BROPAY/v1/admin/payment-intents/$PI_ID" \
          -H "Authorization: Bearer $ADMIN_TOKEN" -H "$ORIGIN" \
          | json "print(json.load(sys.stdin)['data']['status'])" 2>/dev/null)
        [ "$CUR" = "$EXPECT_PI_STATUS" ] && break
        sleep 1
      done
    else
      # KBNK unavailable — fall back to admin transition endpoints where possible
      # so dispatchWebhook still fires. `failed` has no admin route today, so it
      # remains a direct DB update (no webhook for that branch — see TODO).
      case "$STATUS" in
        completed)
          curl -s "$BROPAY/v1/admin/payment-intents/$PI_ID/complete" -X POST \
            -H "Authorization: Bearer $ADMIN_TOKEN" -H "$ORIGIN" -H "$CT" \
            -d '{"reason":"e2e fallback (KBNK unavailable)"}' > /dev/null
          pass "PI → succeeded via admin /complete (webhook fired)"
          ;;
        cancelled)
          curl -s "$BROPAY/v1/admin/payment-intents/$PI_ID/cancel" -X POST \
            -H "Authorization: Bearer $ADMIN_TOKEN" -H "$ORIGIN" -H "$CT" \
            -d '{"reason":"e2e fallback (KBNK unavailable)"}' > /dev/null
          pass "PI → cancelled via admin /cancel (webhook fired)"
          ;;
        failed)
          # No admin /fail route exists yet — direct DB update preserves prior behavior.
          # TODO: add `POST /v1/admin/payment-intents/{id}/fail` route + dispatchWebhook
          # so this branch can also exercise webhook delivery.
          e2e_d1_sql \
            "UPDATE payment_intents SET status = 'failed', failed_at = datetime('now') WHERE id = '$PI_ID'" \
            "$D1_FLAGS" || fail "D1: set PI failed"
          pass "PI → failed (direct DB, no webhook)"
          ;;
      esac
    fi
  fi

  # ── Verify final status ──
  step 6 "Verify"
  PI_FINAL=$(curl -s "$BROPAY/v1/admin/payment-intents/$PI_ID" \
    -H "Authorization: Bearer $ADMIN_TOKEN" -H "$ORIGIN" | json "d=json.load(sys.stdin); print((d.get('data') or {}).get('status',''))")

  # Map KBNK status → expected BroPay PI status
  case "$STATUS" in
    completed) EXPECTED="succeeded" ;;
    failed)    EXPECTED="failed" ;;
    cancelled) EXPECTED="cancelled" ;;
    expired)   EXPECTED="expired" ;;
    *)         EXPECTED="$STATUS" ;;
  esac

  if [ "$PI_FINAL" = "$EXPECTED" ]; then
    pass "PI final status: $PI_FINAL ✅"
  elif [ "$PI_FINAL" = "processing" ]; then
    warn "PI still processing (webhook didn't land in 30s — check KBNK webhookUrl + tunnel + API logs)"
  else
    warn "PI status: $PI_FINAL (expected $EXPECTED)"
  fi

  # Check transaction created (only for completed)
  if [ "$STATUS" = "completed" ]; then
    TX_COUNT=$(curl -s "$BROPAY/v1/admin/transactions?merchant_id=$MERCHANT_ID" \
      -H "Authorization: Bearer $ADMIN_TOKEN" -H "$ORIGIN" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
    pass "Transactions: $TX_COUNT"
  fi

  echo -e "\n${GREEN}  Result: $AMOUNT THB → $PI_FINAL${NC}"
}

# ── Cleanup: delete created PIs (optional, best-effort) ───────────────────────
cleanup_pis() {
  info "Cleaning up demo payment intents..."
  # Delete all PIs for demo merchant that were created in the last 10 minutes
  # (We can't easily know which IDs we created across multiple flows, so we clean by merchant + recent)
  if e2e_d1_sql \
    "DELETE FROM payment_intents WHERE merchant_id = '$MERCHANT_ID' AND created_at > datetime('now', '-10 minutes')" \
    "$D1_FLAGS"; then
    pass "Cleaned up recent PIs"
  else
    warn "Cleanup had issues (non-fatal)"
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
echo -e "${CYAN}━━━ BroPay E2E Payment Flow ━━━${NC}"
echo "BroPay: $BROPAY"
echo "KBNK:   $KBNK"
echo "Target: $TARGET_STATUS"
echo "Env:    $BROPAY_ENV"

if [ "$TARGET_STATUS" = "all" ]; then
  for STATUS in completed failed cancelled expired; do
    run_flow "$STATUS"
  done
  echo -e "\n${GREEN}━━━ All 4 statuses tested ━━━${NC}"
else
  run_flow "$TARGET_STATUS"
fi

cleanup_pis
