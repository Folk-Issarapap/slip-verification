#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# Seed realistic Payment Intents for the demo merchant.
#
# Usage:
#   bash scripts/e2e/seed-realistic-pis.sh
#   COUNT=50 bash scripts/e2e/seed-realistic-pis.sh
#
# Environment:
#   BROPAY_URL, COUNT (default 25)
#   RUN_KBNK=1, KBNK_URL, KBNK_CLIENT_ID, KBNK_CLIENT_SECRET (optional; DB fallback when unset)
#   HMAC: _merchant-lib.sh
#
# Status mix (per 100):
#   succeeded  ~75 %
#   failed     ~15 %
#   cancelled   ~7 %
#   expired     ~3 %
#
# Amount: 10,000 – 200,000 satang  (฿100 – ฿2,000), log-skewed toward small carts.
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
COUNT="${COUNT:-25}"
BROPAY="${BROPAY_URL:-http://localhost:8787}"
KBNK="${KBNK_URL:-https://kbnk-payment-api-staging.example.com}"
ORIGIN="Origin: http://localhost:3000"
CT="Content-Type: application/json"

KBNK_CLIENT_ID="${KBNK_CLIENT_ID:-}"
KBNK_CLIENT_SECRET="${KBNK_CLIENT_SECRET:-}"
RUN_KBNK="${RUN_KBNK:-0}"

# shellcheck source=_merchant-lib.sh
source "$SCRIPT_DIR/_merchant-lib.sh"
info() { echo -e "${CYAN}→ $1${NC}"; }

# ── Realistic helpers ─────────────────────────────────────────────────────────

random_amount() {
  # Log-skew toward smaller amounts: pick uniform in [log(min), log(max)] then exp.
  python3 -c "
import math, random, sys
lo, hi = 10000, 200000   # 100 THB to 2,000 THB
v = math.exp(random.uniform(math.log(lo), math.log(hi)))
print(int(round(v / 100) * 100))   # round to nearest 1 THB
"
}

# Picks a status from the realistic mix.
random_status() {
  python3 -c "
import random
r = random.random()
if r < 0.75: print('completed')
elif r < 0.90: print('failed')
elif r < 0.97: print('cancelled')
else: print('expired')
"
}

DESCRIPTIONS=(
  "Order #INV-{n}"
  "Subscription — Pro plan"
  "Top-up wallet"
  "Coffee + pastries"
  "Online purchase"
  "Service fee"
  "Delivery — Bangkok"
  "Booking deposit"
  "Donation"
  "Membership renewal"
  "Storefront — POS sale"
  "Refundable deposit"
)

random_description() {
  local n="$1"
  local idx=$((RANDOM % ${#DESCRIPTIONS[@]}))
  local tpl="${DESCRIPTIONS[$idx]}"
  echo "${tpl//\{n\}/$n}"
}

# ── Bootstrap (once) ──────────────────────────────────────────────────────────

echo -e "${CYAN}━━━ Realistic PI Seeder — $COUNT PIs ━━━${NC}"
source "$SCRIPT_DIR/_bootstrap.sh"
bootstrap_demo_merchant
MERCHANT_ID="$DEMO_MERCHANT_ID"
ADMIN_TOKEN="$DEMO_ADMIN_TOKEN"
OWNER_TOKEN="$DEMO_OWNER_TOKEN"
MERCH_HEADER="X-Merchant-Id: $MERCHANT_ID"
pass "Merchant: ${MERCHANT_ID:0:16}…"

# Ensure active integration
EXISTING=$(curl -s "$BROPAY/v1/merchant/integrations" \
  -H "Authorization: Bearer $OWNER_TOKEN" -H "$MERCH_HEADER" -H "$ORIGIN")
ACTIVE_COUNT=$(echo "$EXISTING" | json "print(sum(1 for i in json.load(sys.stdin).get('data',[]) if i.get('status')=='active'))")
if [ "${ACTIVE_COUNT:-0}" -eq 0 ]; then
  FIRST_ID=$(echo "$EXISTING" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')")
  if [ -n "$FIRST_ID" ]; then
    info "Activating existing integration $FIRST_ID…"
    curl -s "$BROPAY/v1/merchant/integrations/$FIRST_ID" -X PUT \
      -H "Authorization: Bearer $OWNER_TOKEN" -H "$MERCH_HEADER" -H "$ORIGIN" -H "$CT" \
      -d '{"status":"active"}' > /dev/null
  else
    info "Creating integration…"
    curl -s "$BROPAY/v1/merchant/integrations" -X POST \
      -H "Authorization: Bearer $OWNER_TOKEN" -H "$MERCH_HEADER" -H "$ORIGIN" -H "$CT" \
      -d '{"name":"Demo Integration","slug":"demo"}' > /dev/null
  fi
fi

INTEGRATIONS=$(curl -s "$BROPAY/v1/merchant/integrations" \
  -H "Authorization: Bearer $OWNER_TOKEN" -H "$MERCH_HEADER" -H "$ORIGIN")
INTEGRATION_ID=$(echo "$INTEGRATIONS" | json "d=json.load(sys.stdin)['data']; active=[i for i in d if i.get('status')=='active']; print((active[0] if active else d[0])['id'] if (active or d) else '')")
[ -n "$INTEGRATION_ID" ] || fail "No integration found"

CREDS=$(curl -s "$BROPAY/v1/merchant/integrations/$INTEGRATION_ID/rotate-key" -X POST \
  -H "Authorization: Bearer $OWNER_TOKEN" -H "$MERCH_HEADER" -H "$ORIGIN" -H "$CT")
API_KEY=$(echo "$CREDS" | json "print(json.load(sys.stdin)['data']['api_key'])")
SECRET_KEY=$(echo "$CREDS" | json "print(json.load(sys.stdin)['data']['secret_key'])")
pass "Integration ready"

KBNK_TOKEN=$(curl -s "$KBNK/api/v1/auth/token" -H "$CT" \
  -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"$KBNK_CLIENT_ID\",\"client_secret\":\"$KBNK_CLIENT_SECRET\"}" \
  | json "print(json.load(sys.stdin).get('access_token',''))")
[ -n "$KBNK_TOKEN" ] && pass "KBNK token obtained" || warn "KBNK token unavailable — will use direct DB updates"

# ── Loop: create N PIs with realistic distribution ────────────────────────────

declare -A SUMMARY=([completed]=0 [failed]=0 [cancelled]=0 [expired]=0)
TOTAL_SUCCEEDED_AMT=0

echo ""
echo -e "${CYAN}━━━ Creating $COUNT PIs ━━━${NC}"

for i in $(seq 1 "$COUNT"); do
  AMOUNT=$(random_amount)
  STATUS=$(random_status)
  DESC=$(random_description "$i")

  # Merchant-side identifiers — populated so admin demo surfaces non-empty
  # Invoice / Refs / Order columns.
  INV="INV-2026-$(printf '%05d' "$i")"
  REF1="ORD$(printf '%07d' "$((100000 + i))")"
  ORDER_ID="ord-$(printf '%07d' "$((100000 + i))")"
  DESCRIPTOR="DEMO MERCHANT"
  PI_BODY="{\"amount\":$AMOUNT,\"currency\":\"THB\",\"payment_method\":\"promptpay\",\"description\":\"$DESC\",\"invoice_number\":\"$INV\",\"ref1\":\"$REF1\",\"order_id\":\"$ORDER_ID\",\"statement_descriptor\":\"$DESCRIPTOR\"}"
  PI_TS=$(date +%s)
  PI_SIG=$(hmac_sign "$SECRET_KEY" "$PI_TS" "$PI_BODY")

  PI_RES=$(curl -s "$BROPAY/v1/api/payment-intents" -X POST -H "$CT" \
    -H "X-Api-Key: $API_KEY" -H "X-Signature: $PI_SIG" -H "X-Timestamp: $PI_TS" \
    -d "$PI_BODY")
  PI_ID=$(echo "$PI_RES" | json "print(json.load(sys.stdin)['data']['id'])")
  if [ -z "$PI_ID" ]; then
    warn "PI #$i creation failed: $(echo "$PI_RES" | head -c 160)"
    continue
  fi

  THB=$(python3 -c "print(f'{$AMOUNT/100:.2f}')")
  printf "  [%2d/%d] %-30s ฿%8s → %s\n" "$i" "$COUNT" "$DESC" "$THB" "$STATUS"

  # For terminal-without-KBNK statuses, use direct DB update — fast.
  if [ "$STATUS" = "expired" ] || [ -z "$KBNK_TOKEN" ]; then
    pushd "$REPO_ROOT/apps/api" > /dev/null
    case "$STATUS" in
      completed)
        wrangler d1 execute bropay-db --local --command \
          "UPDATE payment_intents SET status='succeeded', succeeded_at=datetime('now') WHERE id='$PI_ID'" --json 2>/dev/null > /dev/null
        # Also create the transaction so settlement has something to batch
        wrangler d1 execute bropay-db --local --command \
          "INSERT INTO transactions (merchant_id, integration_id, reference_type, reference_id, amount, currency, direction, fee_amount, net_amount, status, description) VALUES ('$MERCHANT_ID', '$INTEGRATION_ID', 'payment', '$PI_ID', $AMOUNT, 'THB', 'credit', 0, $AMOUNT, 'completed', '$DESC')" --json 2>/dev/null > /dev/null
        TOTAL_SUCCEEDED_AMT=$((TOTAL_SUCCEEDED_AMT + AMOUNT))
        ;;
      failed)
        wrangler d1 execute bropay-db --local --command \
          "UPDATE payment_intents SET status='failed', failed_at=datetime('now') WHERE id='$PI_ID'" --json 2>/dev/null > /dev/null
        ;;
      cancelled)
        wrangler d1 execute bropay-db --local --command \
          "UPDATE payment_intents SET status='cancelled', cancelled_at=datetime('now'), cancellation_reason='customer_abandoned' WHERE id='$PI_ID'" --json 2>/dev/null > /dev/null
        ;;
      expired)
        wrangler d1 execute bropay-db --local --command \
          "UPDATE payment_intents SET status='expired', updated_at=datetime('now') WHERE id='$PI_ID'" --json 2>/dev/null > /dev/null
        ;;
    esac
    popd > /dev/null
  else
    # Real KBNK round-trip for completed/failed/cancelled
    KBNK_DEP=$(curl -s "$KBNK/api/v1/deposits" -H "Authorization: Bearer $KBNK_TOKEN" -H "$CT" \
      -d "{\"amount\":$AMOUNT.00,\"paymentMethod\":\"promptpay\",\"currency\":\"THB\",\"correlationId\":\"seed-$PI_ID\",\"customer\":{\"bankCode\":\"KBANK\",\"accountNumber\":\"0123456789\",\"accountHolderName\":\"E2E Test\"}}")
    KBNK_DEP_ID=$(echo "$KBNK_DEP" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
    KBNK_DEP_DISPLAY=$(echo "$KBNK_DEP" | json "print(json.load(sys.stdin).get('data',{}).get('depositId',''))")

    if [ -n "$KBNK_DEP_ID" ]; then
      pushd "$REPO_ROOT/apps/api" > /dev/null
      wrangler d1 execute bropay-db --local --command \
        "UPDATE payment_intents SET provider_deposit_id='$KBNK_DEP_DISPLAY', status='processing', updated_at=datetime('now') WHERE id='$PI_ID'" --json 2>/dev/null > /dev/null
      popd > /dev/null

      curl -s "$KBNK/api/v1/deposits/$KBNK_DEP_ID/status" -X PATCH \
        -H "Authorization: Bearer $KBNK_TOKEN" -H "$CT" -d "{\"status\":\"$STATUS\"}" > /dev/null

      [ "$STATUS" = "completed" ] && TOTAL_SUCCEEDED_AMT=$((TOTAL_SUCCEEDED_AMT + AMOUNT))
    else
      warn "KBNK deposit creation failed (rate limited?), falling back to direct DB"
      pushd "$REPO_ROOT/apps/api" > /dev/null
      case "$STATUS" in
        completed)
          wrangler d1 execute bropay-db --local --command \
            "UPDATE payment_intents SET status='succeeded', succeeded_at=datetime('now') WHERE id='$PI_ID'" --json 2>/dev/null > /dev/null
          wrangler d1 execute bropay-db --local --command \
            "INSERT INTO transactions (merchant_id, integration_id, reference_type, reference_id, amount, currency, direction, fee_amount, net_amount, status, description) VALUES ('$MERCHANT_ID', '$INTEGRATION_ID', 'payment', '$PI_ID', $AMOUNT, 'THB', 'credit', 0, $AMOUNT, 'completed', '$DESC')" --json 2>/dev/null > /dev/null
          TOTAL_SUCCEEDED_AMT=$((TOTAL_SUCCEEDED_AMT + AMOUNT))
          ;;
        failed)
          wrangler d1 execute bropay-db --local --command \
            "UPDATE payment_intents SET status='failed', failed_at=datetime('now') WHERE id='$PI_ID'" --json 2>/dev/null > /dev/null
          ;;
        cancelled)
          wrangler d1 execute bropay-db --local --command \
            "UPDATE payment_intents SET status='cancelled', cancelled_at=datetime('now'), cancellation_reason='customer_abandoned' WHERE id='$PI_ID'" --json 2>/dev/null > /dev/null
          ;;
      esac
      popd > /dev/null
    fi
  fi

  SUMMARY[$STATUS]=$((SUMMARY[$STATUS] + 1))
done

# ── Wait for any in-flight webhooks to land (KBNK statuses go async) ──────────
if [ -n "$KBNK_TOKEN" ]; then
  info "Waiting 8s for in-flight KBNK webhooks to settle…"
  sleep 8
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${CYAN}━━━ Summary ━━━${NC}"
printf "  succeeded  %3d\n  failed     %3d\n  cancelled  %3d\n  expired    %3d\n" \
  "${SUMMARY[completed]}" "${SUMMARY[failed]}" "${SUMMARY[cancelled]}" "${SUMMARY[expired]}"
echo ""
TOTAL_THB=$(python3 -c "print(f'{$TOTAL_SUCCEEDED_AMT/100:,.2f}')")
pass "Gross succeeded volume: ฿$TOTAL_THB"
pass "Ready for settlement — run: bash scripts/e2e/e2e-settlement-flow.sh"
