#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Settlement Flow — eligible txns → preview → create → slip → complete
#
# Usage:
#   bash scripts/e2e/e2e-settlement-flow.sh
#
# Environment:
#   BROPAY_URL, RUN_KBNK=1, KBNK_URL, KBNK_CLIENT_ID, KBNK_CLIENT_SECRET (optional)
#   HMAC: _merchant-lib.sh
#
# Flow:
#   1. Bootstrap demo merchant
#   2. Ensure integration + guard checks
#   3. Create completed payment transactions (local D1)
#   4. Verified settlement bank account + wallet fee coverage
#   4c–d. Preview + summary endpoints
#   4e–f. Partial settlement → admin cancel (frees transactions)
#   5. Create full settlement
#   5b–c. Detail (items/events) + complete-without-slip guard
#   6. Admin slip upload + merchant slip read
#   7. Admin complete + bulk preflight + stats
#   8. Admin + merchant list verification
#   9. Cleanup
#
# Amounts are in satang (100 satang = ฿1).
#
# See: scripts/e2e/docs/e2e-settlement-flow.md
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
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

# curl helper: returns body + trailing status line; use sed '$d' for body, tail -1 for code
http_json() {
  local out
  out=$(curl -s -w "\n%{http_code}" "$@")
  echo "$out"
}
body() { sed '$d'; }
status() { tail -n1; }

# Minimal 1×1 JPEG for slip upload (matches admin/settlements.test.ts pattern)
make_slip_jpeg() {
  local dest="$1"
  python3 -c "
import base64, sys
data = base64.b64decode(
    '/9j/4AAQSkZJRgABAQEASABIAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRof'
    'Hh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwh'
    'MjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/'
    'wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAn/xAAUEAEAAAAA'
    'AAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAA'
    'AAAAAAAAAAAA/9oADAMBAAIRAxEAPwCwAA8A/9k='
)
open(sys.argv[1], 'wb').write(data)
" "$dest"
}

echo -e "${CYAN}━━━ BroPay E2E Settlement Flow ━━━${NC}"

# ── Step 1: Bootstrap demo merchant ──────────────────────────────────────────
step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/_bootstrap.sh"
bootstrap_demo_merchant
MERCHANT_ID="$DEMO_MERCHANT_ID"
WALLET_ID="$DEMO_WALLET_ID"
MERCH_HEADER="X-Merchant-Id: $MERCHANT_ID"
ADMIN_TOKEN="$DEMO_ADMIN_TOKEN"
OWNER_TOKEN="$DEMO_OWNER_TOKEN"
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
OWNER="Authorization: Bearer $OWNER_TOKEN"
MERCH="$MERCH_HEADER"
pass "Merchant: ${MERCHANT_ID:0:16}...  Wallet: ${WALLET_ID:0:16}..."

PARTIAL_ID=""
SETTLEMENT_ID=""
COMPLETE_STATUS=""

# ── Step 2: Ensure integration exists ────────────────────────────────────────
step 2 "Ensure integration"
INTEGRATIONS=$(curl -s "$BROPAY/v1/merchant/integrations" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
INTEGRATION_COUNT=$(echo "$INTEGRATIONS" | json "print(len(json.load(sys.stdin).get('data',[])))")
if [ "${INTEGRATION_COUNT:-0}" -eq 0 ]; then
  info "Creating integration..."
  curl -s "$BROPAY/v1/merchant/integrations" -X POST \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
    -d '{"name":"Demo Integration","slug":"demo"}' > /dev/null
  INTEGRATIONS=$(curl -s "$BROPAY/v1/merchant/integrations" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
fi
INTEGRATION_ID=$(echo "$INTEGRATIONS" | json "d=json.load(sys.stdin)['data']; print(d[0]['id'] if d else '')")
[ -n "$INTEGRATION_ID" ] || fail "No integration found"
pass "Integration: ${INTEGRATION_ID:0:16}..."

# ── Step 2b: Guard checks ────────────────────────────────────────────────────
step "2b" "Guard checks"

SETTLE_404=$(http_json "$BROPAY/v1/admin/settlements/nonexistent-id" -H "$ADMIN" -H "$ORIGIN")
SETTLE_404_CODE=$(echo "$SETTLE_404" | status)
[ "$SETTLE_404_CODE" = "404" ] && pass "404 for missing settlement" || warn "Expected 404 for missing settlement, got $SETTLE_404_CODE"

BAD_SETTLE=$(http_json "$BROPAY/v1/merchant/settlements" -X POST -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d '{}')
BAD_SETTLE_CODE=$(echo "$BAD_SETTLE" | status)
[ "$BAD_SETTLE_CODE" = "400" ] || [ "$BAD_SETTLE_CODE" = "422" ] && pass "400/422 for invalid settlement input ($BAD_SETTLE_CODE)" || warn "Expected 400/422 for bad settlement, got $BAD_SETTLE_CODE"

AUTH_SETTLE=$(http_json "$BROPAY/v1/admin/settlements" -H "$ORIGIN")
AUTH_SETTLE_CODE=$(echo "$AUTH_SETTLE" | status)
[ "$AUTH_SETTLE_CODE" = "401" ] && pass "401 without auth token" || warn "Expected 401 without token, got $AUTH_SETTLE_CODE"

# ── Step 3: Create completed payments ────────────────────────────────────────
step 3 "Create completed payments (3 × PI)"

CREDS=$(curl -s "$BROPAY/v1/merchant/integrations/$INTEGRATION_ID/rotate-key" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT")
API_KEY=$(echo "$CREDS" | json "d=json.load(sys.stdin); print(d.get('data',{}).get('api_key',''))")
SECRET_KEY=$(echo "$CREDS" | json "d=json.load(sys.stdin); print(d.get('data',{}).get('secret_key',''))")
[ -n "$API_KEY" ] && [ -n "$SECRET_KEY" ] || fail "Integration rotate-key failed: $CREDS"

KBNK_TOKEN=$(curl -s "$KBNK/api/v1/auth/token" -H "$CT" \
  -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"$KBNK_CLIENT_ID\",\"client_secret\":\"$KBNK_CLIENT_SECRET\"}" \
  | json "print(json.load(sys.stdin).get('access_token',''))")
if [ -z "$KBNK_TOKEN" ]; then
  warn "KBNK token unavailable (rate limited or unreachable). Skipping KBNK-dependent steps and using direct DB completion."
fi

TX_LIST_BEFORE=$(curl -s "$BROPAY/v1/admin/transactions?merchant_id=$MERCHANT_ID&limit=1" -H "$ADMIN" -H "$ORIGIN")
TX_TOTAL_BEFORE=$(echo "$TX_LIST_BEFORE" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
pass "Transactions before: $TX_TOTAL_BEFORE"

wrangler_bin >/dev/null 2>&1 || fail "wrangler not found — run pnpm install in apps/api (needed for local D1 seeding in step 3)"

TOTAL_AMOUNT=0
PI_IDS=()
for i in 1 2 3; do
  AMOUNT=$((5000 + RANDOM % 5000))
  TOTAL_AMOUNT=$((TOTAL_AMOUNT + AMOUNT))
  PI_BODY="{\"amount\":$AMOUNT,\"currency\":\"THB\",\"payment_method\":\"promptpay\",\"description\":\"Settlement test $i\"}"
  PI_TS=$(date +%s)
  PI_SIG=$(hmac_sign "$SECRET_KEY" "$PI_TS" "$PI_BODY")

  PI_RES=$(curl -s "$BROPAY/v1/api/payment-intents" -X POST -H "$CT" \
    -H "X-Api-Key: $API_KEY" -H "X-Signature: $PI_SIG" -H "X-Timestamp: $PI_TS" -d "$PI_BODY")
  PI_ID=$(echo "$PI_RES" | json "d=json.load(sys.stdin); print(d.get('data',{}).get('id',''))")
  [ -n "$PI_ID" ] || fail "Payment intent $i failed (HMAC/API): $PI_RES"
  PI_IDS+=("$PI_ID")

  if [ -n "$KBNK_TOKEN" ]; then
    KBNK_DEP=$(curl -s "$KBNK/api/v1/deposits" -H "Authorization: Bearer $KBNK_TOKEN" -H "$CT" \
      -d "{\"amount\":$AMOUNT.00,\"paymentMethod\":\"promptpay\",\"currency\":\"THB\",\"correlationId\":\"stl-$PI_ID\",\"customer\":{\"bankCode\":\"KBANK\",\"accountNumber\":\"0123456789\",\"accountHolderName\":\"Test\"}}")
    KBNK_DEP_ID=$(echo "$KBNK_DEP" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
    KBNK_DEP_DISPLAY=$(echo "$KBNK_DEP" | json "print(json.load(sys.stdin).get('data',{}).get('depositId',''))")
    if [ -n "$KBNK_DEP_ID" ]; then
      d1_local_ok "UPDATE payment_intents SET provider_deposit_id = '$KBNK_DEP_DISPLAY', status = 'processing', updated_at = datetime('now') WHERE id = '$PI_ID'" \
        || fail "Failed to link PI $i to KBNK deposit in local D1"
      curl -s "$KBNK/api/v1/deposits/$KBNK_DEP_ID/status" -X PATCH \
        -H "Authorization: Bearer $KBNK_TOKEN" -H "$CT" -d '{"status":"completed"}' > /dev/null
    fi
  fi

  d1_local_ok "INSERT INTO transactions (merchant_id, integration_id, reference_type, reference_id, amount, currency, direction, fee_amount, net_amount, status, description) VALUES ('$MERCHANT_ID', '$INTEGRATION_ID', 'payment', '$PI_ID', $AMOUNT, 'THB', 'credit', 0, $AMOUNT, 'completed', 'Settlement test $i')" \
    || fail "Failed to insert transaction for PI $i in local D1"
  d1_local_ok "UPDATE payment_intents SET status = 'succeeded', succeeded_at = datetime('now'), updated_at = datetime('now') WHERE id = '$PI_ID'" \
    || fail "Failed to mark PI $i succeeded in local D1"

  pass "PI $i: $AMOUNT satang → succeeded"
done
pass "Total: $TOTAL_AMOUNT satang across 3 transactions"

# Resolve transaction ids for explicit settlement_ids body
TX_RECENT=$(curl -s "$BROPAY/v1/admin/transactions?merchant_id=$MERCHANT_ID&limit=20&sort=created_at&order=desc" -H "$ADMIN" -H "$ORIGIN")
TX_IDS=($(echo "$TX_RECENT" | python3 -c "
import json, sys
pis = set(sys.argv[1:])
ids = [t['id'] for t in json.load(sys.stdin).get('data', []) if t.get('reference_id') in pis]
print(' '.join(ids))
" "${PI_IDS[@]}"))
[ "${#TX_IDS[@]}" -ge 3 ] || fail "Expected 3 transaction ids for PIs, got ${#TX_IDS[@]}"

# ── Step 3b: Verify transaction list increased ───────────────────────────────
step "3b" "Verify transaction list increased"
TX_LIST_AFTER=$(curl -s "$BROPAY/v1/admin/transactions?merchant_id=$MERCHANT_ID&limit=1" -H "$ADMIN" -H "$ORIGIN")
TX_TOTAL_AFTER=$(echo "$TX_LIST_AFTER" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
EXPECTED_AFTER=$((TX_TOTAL_BEFORE + 3))
[ "$TX_TOTAL_AFTER" -eq "$EXPECTED_AFTER" ] && pass "Transaction count after: $TX_TOTAL_AFTER (+3)" || warn "Transaction count did not increase ($TX_TOTAL_AFTER vs $EXPECTED_AFTER)"

# ── Step 3c: Verify filter works ─────────────────────────────────────────────
step "3c" "Verify transaction filter by status"
TX_FILTER=$(curl -s "$BROPAY/v1/admin/transactions?merchant_id=$MERCHANT_ID&status=completed&limit=1" -H "$ADMIN" -H "$ORIGIN")
TX_FILTER_TOTAL=$(echo "$TX_FILTER" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
[ "$TX_FILTER_TOTAL" -ge 3 ] && pass "Filter by status returned $TX_FILTER_TOTAL result(s)" || warn "Filter by status returned fewer than 3 results"

# ── Step 4: Ensure bank account exists, verified, and flagged for settlement ─
step 4 "Ensure verified settlement bank account"
BA_CHECK=$(curl -s "$BROPAY/v1/merchant/bank-accounts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
BA_COUNT=$(echo "$BA_CHECK" | json "print(len(json.load(sys.stdin).get('data',[])))")
if [ "$BA_COUNT" = "0" ]; then
  info "Creating bank account..."
  curl -s "$BROPAY/v1/merchant/bank-accounts" -X POST \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
    -d '{"bank_id":"bank-kbank-0000-0000-000000000001","account_number":"9876543210","account_holder_name":"Demo Merchant","account_type":"savings"}' > /dev/null
fi
BA_ID=$(curl -s "$BROPAY/v1/merchant/bank-accounts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" \
  | json "d=json.load(sys.stdin)['data']; print(d[0]['id'] if d else '')")
[ -n "$BA_ID" ] || fail "Bank account creation failed"
d1_local_ok "INSERT INTO bank_account_verifications (merchant_bank_account_id, provider_id, status, similarity_score, manually_overridden, override_reason, overridden_by, overridden_at, completed_at) SELECT '$BA_ID', 'prov-kbnk-000000-0000-000000000001', 'verified', 100.0, 1, 'e2e-test-bypass', (SELECT id FROM accounts WHERE staff_role='super_admin' LIMIT 1), datetime('now'), datetime('now') WHERE NOT EXISTS (SELECT 1 FROM bank_account_verifications WHERE merchant_bank_account_id='$BA_ID' AND status='verified');
 UPDATE merchant_bank_accounts SET verification_status='verified', status='active', for_settlement=1 WHERE id='$BA_ID';" \
  || fail "Failed to verify bank account in local D1"
pass "Bank account ${BA_ID:0:16}… verified + for_settlement=1"

# ── Step 4b: Pre-fund wallet to cover settlement fee ─────────────────────────
step "4b" "Pre-fund wallet for fee coverage"
WALLET_BEFORE=$(curl -s "$BROPAY/v1/merchant/wallets" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" | json "
d=json.load(sys.stdin).get('data',{})
print(d.get('available_balance',0) if isinstance(d,dict) else 0)
")
if [ "${WALLET_BEFORE:-0}" -lt 50000 ]; then
  info "Topping up wallet from ${WALLET_BEFORE:-0} → 100000 satang"
  d1_local_ok "UPDATE wallets SET available_balance=100000, updated_at=datetime('now') WHERE merchant_id='$MERCHANT_ID'" \
    || fail "Failed to top up wallet in local D1"
fi
pass "Wallet funded for fee coverage"

# ── Step 4c: Preview (merchant + admin) ──────────────────────────────────────
step "4c" "Preview settlement (merchant + admin)"
MERCH_PREVIEW=$(http_json "$BROPAY/v1/merchant/settlements/preview?integration_id=$INTEGRATION_ID" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
[ "$(echo "$MERCH_PREVIEW" | status)" = "200" ] || fail "Merchant preview failed: $(echo "$MERCH_PREVIEW" | status)"
PREVIEW_ELIGIBLE=$(echo "$MERCH_PREVIEW" | body | json "print(json.load(sys.stdin).get('data',{}).get('eligible_transaction_count',0))")
PREVIEW_COVER=$(echo "$MERCH_PREVIEW" | body | json "print(json.load(sys.stdin).get('data',{}).get('can_cover',False))")
[ "$PREVIEW_ELIGIBLE" -ge 3 ] && pass "Merchant preview: $PREVIEW_ELIGIBLE eligible, can_cover=$PREVIEW_COVER" || warn "Merchant preview eligible=$PREVIEW_ELIGIBLE (expected ≥3)"

ADMIN_PREVIEW=$(http_json "$BROPAY/v1/admin/settlements/preview?merchant_id=$MERCHANT_ID&integration_id=$INTEGRATION_ID" -H "$ADMIN" -H "$ORIGIN")
[ "$(echo "$ADMIN_PREVIEW" | status)" = "200" ] && pass "Admin preview OK" || warn "Admin preview HTTP $(echo "$ADMIN_PREVIEW" | status)"

# ── Step 4d: Summary endpoints ───────────────────────────────────────────────
step "4d" "Settlement summary"
SUMMARY=$(http_json "$BROPAY/v1/merchant/settlements/summary" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
[ "$(echo "$SUMMARY" | status)" = "200" ] && pass "GET /summary OK (pending_count=$(echo "$SUMMARY" | body | json "print(json.load(sys.stdin).get('data',{}).get('pending_count',0))"))" || warn "Summary failed"

SUMMARY_INT=$(http_json "$BROPAY/v1/merchant/settlements/summary-by-integration" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
[ "$(echo "$SUMMARY_INT" | status)" = "200" ] && pass "GET /summary-by-integration OK" || warn "summary-by-integration failed"

# ── Step 4e–f: Partial settlement → cancel (frees transactions) ──────────────
step "4e" "Create partial settlement (1 txn) for cancel test"
PARTIAL_BODY="{\"integration_id\":\"$INTEGRATION_ID\",\"transaction_ids\":[\"${TX_IDS[0]}\"]}"
PARTIAL_RES=$(http_json "$BROPAY/v1/merchant/settlements" -X POST -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d "$PARTIAL_BODY")
PARTIAL_CODE=$(echo "$PARTIAL_RES" | status)
PARTIAL_ID=$(echo "$PARTIAL_RES" | body | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$PARTIAL_CODE" = "201" ] && [ -n "$PARTIAL_ID" ] && pass "Partial settlement created: ${PARTIAL_ID:0:16}…" || warn "Partial settlement: HTTP $PARTIAL_CODE"

step "4f" "Admin cancel partial settlement"
if [ -n "$PARTIAL_ID" ]; then
  CANCEL_RES=$(http_json "$BROPAY/v1/admin/settlements/$PARTIAL_ID/cancel" -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
    -d '{"cancellation_reason":"E2E cancel test — freeing transactions"}')
  CANCEL_STATUS=$(echo "$CANCEL_RES" | body | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
  [ "$(echo "$CANCEL_RES" | status)" = "200" ] && [ "$CANCEL_STATUS" = "cancelled" ] && pass "Settlement cancelled" || warn "Cancel failed: HTTP $(echo "$CANCEL_RES" | status) status=$CANCEL_STATUS"
fi

# ── Step 5: Create full settlement ───────────────────────────────────────────
step 5 "Create settlement"
SETTLEMENT_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/settlements" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"integration_id\":\"$INTEGRATION_ID\"}")
SETTLEMENT_BODY=$(echo "$SETTLEMENT_RES" | body)
SETTLEMENT_HTTP=$(echo "$SETTLEMENT_RES" | status)

echo "$SETTLEMENT_BODY" | python3 -c "
import sys, json
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print('  (unparseable response)')
    sys.exit(0)
data = d.get('data') or {}
err  = d.get('error') or {}
if data.get('id'):
    print(f'  ID:     {data[\"id\"][:20]}…')
    print(f'  Status: {data.get(\"status\")}')
    for k in ('gross_amount','fee_amount','net_amount'):
        v = data.get(k)
        print(f'  {k:6s}: ฿{v/100:,.2f}' if isinstance(v,(int,float)) else f'  {k}: {v}')
    print(f'  Tx:     {data.get(\"transaction_count\")} transactions')
elif data:
    print('  Preview only — wallet cannot cover fee')
    for k in ('eligible_transaction_count','gross_amount','fee_amount','net_amount','wallet_balance','can_cover'):
        v = data.get(k)
        if isinstance(v,(int,float)) and (k.endswith('_amount') or k=='wallet_balance'):
            print(f'  {k:32s}: ฿{v/100:,.2f}')
        else:
            print(f'  {k:32s}: {v}')
elif err:
    print(f'  Error: {err.get(\"code\",\"?\")} — {err.get(\"message\",\"?\")}')
"

SETTLEMENT_ID=$(echo "$SETTLEMENT_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))" 2>/dev/null)
[ "$SETTLEMENT_HTTP" = "201" ] && [ -n "$SETTLEMENT_ID" ] && pass "Settlement created (HTTP 201)" || warn "Settlement creation: HTTP $SETTLEMENT_HTTP"

# ── Step 5b: Verify settlement detail (merchant + admin) ─────────────────────
step "5b" "Verify settlement detail (items + events)"
if [ -n "$SETTLEMENT_ID" ]; then
  MERCH_DETAIL=$(curl -s "$BROPAY/v1/merchant/settlements/$SETTLEMENT_ID" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
  ITEM_COUNT=$(echo "$MERCH_DETAIL" | json "print(len(json.load(sys.stdin).get('data',{}).get('items',[])))")
  EVENT_TYPES=$(echo "$MERCH_DETAIL" | json "print(','.join(e.get('event_type','') for e in json.load(sys.stdin).get('data',{}).get('events',[])))")
  SETTLE_STATUS=$(echo "$MERCH_DETAIL" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
  [ "$ITEM_COUNT" -ge 1 ] && pass "Merchant detail: status=$SETTLE_STATUS items=$ITEM_COUNT events=[$EVENT_TYPES]" || warn "Merchant detail missing items"

  SETTLE_DETAIL=$(curl -s "$BROPAY/v1/admin/settlements/$SETTLEMENT_ID" -H "$ADMIN" -H "$ORIGIN")
  SETTLE_GROSS=$(echo "$SETTLE_DETAIL" | json "print(json.load(sys.stdin).get('data',{}).get('gross_amount',''))")
  [ -n "$SETTLE_STATUS" ] && pass "Admin detail: gross=$SETTLE_GROSS satang" || warn "Could not fetch admin settlement detail"
fi

# ── Step 5c: Complete without slip → 422 ─────────────────────────────────────
step "5c" "Guard: complete without slip"
if [ -n "$SETTLEMENT_ID" ]; then
  NO_SLIP=$(http_json "$BROPAY/v1/admin/settlements/$SETTLEMENT_ID/complete" -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
  [ "$(echo "$NO_SLIP" | status)" = "422" ] && pass "422 SLIP_REQUIRED without upload" || warn "Expected 422 without slip, got $(echo "$NO_SLIP" | status)"
fi

# ── Step 6: Upload slip + read metadata ────────────────────────────────────────
step 6 "Admin slip upload + slip metadata"
SLIP_FILE=""
if [ -n "$SETTLEMENT_ID" ]; then
  SLIP_FILE=$(mktemp /tmp/e2e-settlement-slip-XXXX.jpg 2>/dev/null || echo "/tmp/e2e-settlement-slip.jpg")
  make_slip_jpeg "$SLIP_FILE"

  UPLOAD=$(http_json "$BROPAY/v1/admin/settlements/$SETTLEMENT_ID/slip" -H "$ADMIN" -H "$ORIGIN" \
    -F "file=@$SLIP_FILE;type=image/jpeg;filename=slip.jpg")
  [ "$(echo "$UPLOAD" | status)" = "200" ] && pass "Slip uploaded" || warn "Slip upload HTTP $(echo "$UPLOAD" | status)"

  SLIP_META=$(http_json "$BROPAY/v1/admin/settlements/$SETTLEMENT_ID/slip" -H "$ADMIN" -H "$ORIGIN")
  [ "$(echo "$SLIP_META" | status)" = "200" ] && pass "GET admin slip metadata" || warn "Admin slip GET failed"

  MERCH_SLIP=$(http_json "$BROPAY/v1/merchant/settlements/$SETTLEMENT_ID/slip" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
  [ "$(echo "$MERCH_SLIP" | status)" = "200" ] && pass "GET merchant slip metadata" || warn "Merchant slip GET failed"
fi

# ── Step 7: Admin complete settlement ────────────────────────────────────────
step 7 "Admin complete settlement"
if [ -n "$SETTLEMENT_ID" ]; then
  COMPLETE=$(http_json "$BROPAY/v1/admin/settlements/$SETTLEMENT_ID/complete" -X POST \
    -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
    -d '{"bank_reference":"E2E-BANK-REF-001","notes":"E2E settlement completion"}')
  COMPLETE_STATUS=$(echo "$COMPLETE" | body | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
  [ "$(echo "$COMPLETE" | status)" = "200" ] && [ "$COMPLETE_STATUS" = "completed" ] && pass "Settlement completed" || warn "Complete failed: HTTP $(echo "$COMPLETE" | status) status=$COMPLETE_STATUS"

  HAS_COMPLETED_EVENT=$(echo "$COMPLETE" | body | json "
d=json.load(sys.stdin).get('data',{})
print('yes' if any(e.get('event_type')=='completed' for e in d.get('events',[])) else 'no')
")
  [ "$HAS_COMPLETED_EVENT" = "yes" ] && pass "Events include completed" || warn "Missing completed event"

  WALLET_AFTER=$(curl -s "$BROPAY/v1/merchant/wallets" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" | json "
d=json.load(sys.stdin).get('data',{})
print(d.get('available_balance',0) if isinstance(d,dict) else 0)
")
  pass "Wallet balance after fee debit: ${WALLET_AFTER:-?} satang"

  BULK_PF=$(http_json "$BROPAY/v1/admin/settlements/bulk-complete-preflight" -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
    -d "{\"ids\":[\"$SETTLEMENT_ID\"]}")
  [ "$(echo "$BULK_PF" | status)" = "200" ] && pass "bulk-complete-preflight OK" || warn "bulk-complete-preflight HTTP $(echo "$BULK_PF" | status)"

  MERCH_STATS=$(http_json "$BROPAY/v1/merchant/settlements/stats?integration_id=$INTEGRATION_ID" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
  [ "$(echo "$MERCH_STATS" | status)" = "200" ] && pass "GET /merchant/settlements/stats OK" || warn "Merchant stats failed"

  ADMIN_STATS=$(http_json "$BROPAY/v1/admin/settlements/stats?merchant_id=$MERCHANT_ID" -H "$ADMIN" -H "$ORIGIN")
  [ "$(echo "$ADMIN_STATS" | status)" = "200" ] && pass "GET /admin/settlements/stats OK" || warn "Admin stats failed"

  # Guard: cannot complete again
  RE_COMPLETE=$(http_json "$BROPAY/v1/admin/settlements/$SETTLEMENT_ID/complete" -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
  [ "$(echo "$RE_COMPLETE" | status)" = "422" ] && pass "422 re-completing settled settlement" || warn "Expected 422 on re-complete, got $(echo "$RE_COMPLETE" | status)"
fi

# ── Step 8: List verification ─────────────────────────────────────────────────
step 8 "Admin + merchant list verification"
ADMIN_SETTLE_LIST=$(curl -s "$BROPAY/v1/admin/settlements?merchant_id=$MERCHANT_ID&limit=5" -H "$ADMIN" -H "$ORIGIN")
echo "$ADMIN_SETTLE_LIST" | json "
d = json.load(sys.stdin)
print(f'Settlements: {d[\"meta\"][\"total\"]}')
for s in d['data'][:3]:
    g = s.get('gross_amount', 0)
    print(f'  ฿{g/100:,.2f}  fee={s.get(\"fee_amount\",\"?\")}  net={s.get(\"net_amount\",\"?\")}  {s[\"status\"]}')
"

MERCH_SETTLE_LIST=$(curl -s "$BROPAY/v1/merchant/settlements?integration_id=$INTEGRATION_ID&limit=5" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
MERCH_SETTLE_TOTAL=$(echo "$MERCH_SETTLE_LIST" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
pass "Merchant settlements (filtered): $MERCH_SETTLE_TOTAL"

# ── Step 9: Cleanup ───────────────────────────────────────────────────────────
step 9 "Cleanup"
info "Deleting created transactions, settlements, and payment intents..."
for pid in "${PI_IDS[@]}"; do
  d1_local_ok "DELETE FROM transactions WHERE reference_id = '$pid'" || true
  d1_local_ok "DELETE FROM payment_intents WHERE id = '$pid'" || true
done
for sid in "$PARTIAL_ID" "$SETTLEMENT_ID"; do
  [ -z "$sid" ] && continue
  d1_local_ok "DELETE FROM settlement_events WHERE settlement_id = '$sid';
 DELETE FROM settlement_items WHERE settlement_id = '$sid';
 DELETE FROM settlement_slips WHERE settlement_id = '$sid';
 DELETE FROM settlements WHERE id = '$sid';" || true
done
# Remove fee ledger rows tied to the completed settlement
if [ -n "$SETTLEMENT_ID" ]; then
  d1_local_ok "DELETE FROM wallet_ledger_entries WHERE reference_id = '$SETTLEMENT_ID'" || true
fi
[ -n "$SLIP_FILE" ] && [ -f "$SLIP_FILE" ] && rm -f "$SLIP_FILE"
pass "Cleanup complete"

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}━━━ Settlement Flow Complete ━━━${NC}"
echo "Merchant:    Demo Merchant"
echo "Payments:    3 × succeeded ($TOTAL_AMOUNT satang)"
echo "Settlement:  ${SETTLEMENT_ID:-none} (${COMPLETE_STATUS:-skipped})"
