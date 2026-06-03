#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Reseller Hierarchy Flow
#
# Usage:
#   bash scripts/e2e/e2e-reseller-hierarchy.sh
#
# Environment: BROPAY_URL, RUN_KBNK=1, KBNK_* (optional), HMAC via _merchant-lib.sh
#
# Flow:
#   1. Bootstrap demo merchant (this becomes the reseller)
#   2. Admin sets can_resell=1 on demo merchant
#   3. Guard: non-reseller cannot create sub-merchant
#   4. Register sub-owner account
#   5. Reseller creates sub-merchant
#   6. Guard: 400/422 on invalid fee percentages
#   7. Reseller activates sub-merchant
#   8. Sub-owner creates integration + bank account
#   9. Guard: 404 on missing sub-merchant, auth checks
#  10. Complete a payment on sub-merchant (HMAC)
#  11. Sub-owner creates settlement
#  12. Admin uploads slip + completes settlement (triggers commission cascade)
#  13. Verify commission ledger + commissions API (detail, timeseries, filters)
#  14. Verify admin tree + merchant downline + downline stats
#  15. Verify sub-merchant list filters + PATCH update
#  16. Cleanup
#
# Amounts are in satang (100 satang = ฿1).
#
# See: scripts/e2e/docs/e2e-reseller-hierarchy.md
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Trap: restore owner account kind to 'merchant' on exit so bootstrap works
# on the next run even if this script fails mid-way (before Step 16 cleanup).
# Uses OWNER_ID when available; falls back to the demo owner email so the
# restore fires even when the script bails out during bootstrap itself.
_restore_owner_kind() {
  local _filter
  [ -n "${REPO_ROOT:-}" ] || return 0
  if [ -n "${OWNER_ID:-}" ]; then
    _filter="id = '${OWNER_ID}'"
  else
    _filter="email = 'merchant.owner@bropay.com'"
  fi
  d1_local_quiet "UPDATE accounts SET kind = 'merchant' WHERE $_filter AND kind = 'reseller'"
}
trap _restore_owner_kind EXIT
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

# Helper: curl with status code extraction
http_get() {
  local url="$1"; shift
  curl -s -w "\n%{http_code}" "$url" "$@"
}
http_post() {
  local url="$1"; shift
  curl -s -w "\n%{http_code}" "$url" -X POST "$@"
}
http_put() {
  local url="$1"; shift
  curl -s -w "\n%{http_code}" "$url" -X PUT "$@"
}

status() { tail -n1; }
body() { sed '$d'; }

echo -e "${CYAN}━━━ BroPay E2E Reseller Hierarchy ━━━${NC}"

# ── Step 0: Ensure platform wallet exists ────────────────────────────────────
step 0 "Ensure platform wallet"
wrangler_bin >/dev/null 2>&1 || fail "wrangler not found — run pnpm install in apps/api"
d1_local_ok "INSERT OR IGNORE INTO merchants (id, name, slug, merchant_type, status, risk_level, risk_score, primary_currency, settlement_frequency, settlement_method, auto_settlement_enabled, daily_transaction_limit, monthly_transaction_limit, daily_transaction_count_limit, monthly_transaction_count_limit, can_resell, allow_auto_customer_creation, created_at, updated_at, deleted_at) VALUES ('__platform__', 'Bro Pay Platform', 'bro-pay-platform', 'other', 'closed', 'low', 0, 'THB', 'manual', 'transaction_based', 0, 0, 0, 0, 0, 0, 0, datetime('now'), datetime('now'), datetime('now'))" \
  || fail "Failed to seed platform merchant in local D1"
d1_local_ok "INSERT OR IGNORE INTO wallets (id, merchant_id, currency, status, available_balance, reserved_balance, allocated_balance, unallocated_balance, low_balance_threshold, alert_enabled, daily_deposit_limit, monthly_deposit_limit, daily_withdrawal_limit, monthly_withdrawal_limit, created_at, updated_at) VALUES ('wallet__platform__', '__platform__', 'THB', 'active', 0, 0, 0, 0, 0, 0, NULL, NULL, NULL, NULL, datetime('now'), datetime('now'))" \
  || fail "Failed to seed platform wallet in local D1"
pass "Platform wallet ready"

# ── Step 1: Bootstrap demo merchant ──────────────────────────────────────────
step 1 "Bootstrap demo merchant (becomes reseller)"
source "$SCRIPT_DIR/_bootstrap.sh"
bootstrap_demo_merchant
RESELLER_ID="$DEMO_MERCHANT_ID"
RESELLER_WALLET_ID="$DEMO_WALLET_ID"
OWNER_ID="$DEMO_OWNER_ID"
ADMIN_TOKEN="$DEMO_ADMIN_TOKEN"
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
RESELLER_HEADER="X-Merchant-Id: $RESELLER_ID"
pass "Reseller: ${RESELLER_ID:0:16}...  Wallet: ${RESELLER_WALLET_ID:0:16}..."

SUB_MERCHANT_ID=""
SETTLEMENT_ID=""
PI_ID=""
SLIP_FILE=""
COMM_ENTRY_ID=""

# ── Step 2: Admin enables can_resell ─────────────────────────────────────────
step 2 "Enable can_resell on reseller"
UPDATE_RES=$(curl -s "$BROPAY/v1/admin/merchants/$RESELLER_ID" -X PUT \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"can_resell":1}')
CAN_RESELL=$(echo "$UPDATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('can_resell',''))")
[ "$CAN_RESELL" = "1" ] || fail "Failed to enable can_resell"
pass "can_resell enabled"

# Reseller endpoints require accountKind='reseller' in the JWT (requireReseller middleware).
# Bootstrap uses merchant/login (kind='merchant'), so we temporarily upgrade the owner's
# account kind to 'reseller', obtain a reseller JWT, then restore on cleanup.
d1_local_ok "UPDATE accounts SET kind = 'reseller' WHERE id = '$OWNER_ID'" \
  || fail "Failed to set owner account kind=reseller in local D1"

# Must match _bootstrap.sh (_DEMO_EMAIL / _DEMO_PASSWORD).
DEMO_OWNER_EMAIL="merchant.owner@bropay.com"
DEMO_OWNER_PASSWORD="password123"
OWNER_EMAIL=$(curl -s "$BROPAY/v1/auth/me" -H "Authorization: Bearer $DEMO_OWNER_TOKEN" -H "$ORIGIN" | json "print(json.load(sys.stdin).get('data',{}).get('email',''))")
OWNER_EMAIL="${OWNER_EMAIL:-$DEMO_OWNER_EMAIL}"
RESELLER_LOGIN_RES=$(curl -s "$BROPAY/v1/auth/reseller/login" -H "$CT" -H "$ORIGIN" \
  -d "{\"email\":\"$OWNER_EMAIL\",\"password\":\"$DEMO_OWNER_PASSWORD\"}")
OWNER_TOKEN=$(echo "$RESELLER_LOGIN_RES" | json "print(json.load(sys.stdin).get('data',{}).get('accessToken',''))")
[ -n "$OWNER_TOKEN" ] || fail "Reseller login failed after kind upgrade — $RESELLER_LOGIN_RES"
OWNER="Authorization: Bearer $OWNER_TOKEN"
pass "Reseller JWT obtained (kind=reseller)"

# ── Step 3: Guard: non-reseller cannot create sub-merchant ───────────────────
step 3 "Guard: non-reseller cannot create sub-merchant"

# Create a plain merchant that is NOT a reseller
PLAIN_EMAIL="plain-$(date +%s)@e2e.local"
PLAIN_PASSWORD="Password123!"
PLAIN_NAME="Plain Owner"

REG_RES=$(curl -s "$BROPAY/v1/auth/register" -H "$CT" -H "$ORIGIN" \
  -d "{\"email\":\"$PLAIN_EMAIL\",\"password\":\"$PLAIN_PASSWORD\",\"name\":\"$PLAIN_NAME\"}")
PLAIN_TOKEN=$(echo "$REG_RES" | json "print(json.load(sys.stdin).get('data',{}).get('accessToken',''))")
[ -n "$PLAIN_TOKEN" ] || fail "Plain owner registration failed"

ME_RES=$(curl -s "$BROPAY/v1/auth/me" -H "Authorization: Bearer $PLAIN_TOKEN" -H "$ORIGIN")
PLAIN_OWNER_ID=$(echo "$ME_RES" | json "print(json.load(sys.stdin)['data']['id'])")
[ -n "$PLAIN_OWNER_ID" ] || fail "Could not get plain owner ID"

# Admin creates a plain merchant for this owner
PLAIN_MERCHANT_RES=$(curl -s "$BROPAY/v1/admin/merchants" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"name\":\"Plain Merchant $(date +%s)\",\"slug\":\"plain-$(date +%s)\",\"merchant_type\":\"limited_company\",\"primary_currency\":\"THB\",\"can_resell\":0,\"owner_account_id\":\"$PLAIN_OWNER_ID\"}")
PLAIN_MERCHANT_ID=$(echo "$PLAIN_MERCHANT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$PLAIN_MERCHANT_ID" ] || fail "Plain merchant creation failed"

# Activate plain merchant
curl -s "$BROPAY/v1/admin/merchants/$PLAIN_MERCHANT_ID/activate" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}' > /dev/null

# Attempt to create sub-merchant as plain merchant owner → should fail with 403
PLAIN_HEADER="X-Merchant-Id: $PLAIN_MERCHANT_ID"
FORBIDDEN_RES=$(http_post "$BROPAY/v1/merchant/sub-merchants" \
  -H "Authorization: Bearer $PLAIN_TOKEN" -H "$PLAIN_HEADER" -H "$ORIGIN" -H "$CT" \
  -d "{\"name\":\"Should Fail\",\"merchant_type\":\"limited_company\",\"owner_account_id\":\"$PLAIN_OWNER_ID\",\"fee_percentage_inbound\":1.5,\"fee_percentage_outbound\":1.5}")
FORBIDDEN_STATUS=$(echo "$FORBIDDEN_RES" | status)
[ "$FORBIDDEN_STATUS" = "403" ] || fail "Expected 403 for non-reseller, got $FORBIDDEN_STATUS"
pass "403 for non-reseller creating sub-merchant"

DOWNLINE_FORBIDDEN=$(http_get "$BROPAY/v1/merchant/downline" \
  -H "Authorization: Bearer $PLAIN_TOKEN" -H "$PLAIN_HEADER" -H "$ORIGIN")
[ "$(echo "$DOWNLINE_FORBIDDEN" | status)" = "403" ] || fail "Expected 403 on downline for plain merchant"
pass "403 for plain merchant on downline"

COMM_FORBIDDEN=$(http_get "$BROPAY/v1/merchant/commissions" \
  -H "Authorization: Bearer $PLAIN_TOKEN" -H "$PLAIN_HEADER" -H "$ORIGIN")
[ "$(echo "$COMM_FORBIDDEN" | status)" = "403" ] || fail "Expected 403 on commissions for plain merchant"
pass "403 for plain merchant on commissions"

# ── Step 4: Register sub-owner ───────────────────────────────────────────────
step 4 "Register sub-owner"
# Must be a NEW account — not merchant.owner@bropay.com (demo reseller owner from bootstrap).
SUB_OWNER_EMAIL="sub-owner-$(date +%s)@e2e.local"
# register validates strength (uppercase + digit); bootstrap seed uses password123 for demo owner only.
SUB_OWNER_PASSWORD="Password123!"
SUB_OWNER_NAME="E2E Sub Owner"

REG_RES=$(curl -s "$BROPAY/v1/auth/register" -H "$CT" -H "$ORIGIN" \
  -d "{\"email\":\"$SUB_OWNER_EMAIL\",\"password\":\"$SUB_OWNER_PASSWORD\",\"name\":\"$SUB_OWNER_NAME\"}")
SUB_OWNER_TOKEN=$(echo "$REG_RES" | json "print(json.load(sys.stdin).get('data',{}).get('accessToken',''))")
[ -n "$SUB_OWNER_TOKEN" ] || fail "Sub-owner registration failed — $REG_RES"

ME_RES=$(curl -s "$BROPAY/v1/auth/me" -H "Authorization: Bearer $SUB_OWNER_TOKEN" -H "$ORIGIN")
SUB_OWNER_ID=$(echo "$ME_RES" | json "print(json.load(sys.stdin)['data']['id'])")
[ -n "$SUB_OWNER_ID" ] || fail "Could not get sub-owner ID"
pass "Sub-owner: ${SUB_OWNER_ID:0:16}... ($SUB_OWNER_EMAIL)"

# ── Step 5: Reseller creates sub-merchant ────────────────────────────────────
step 5 "Reseller creates sub-merchant"
# Get reseller's resolved fee rates (what the API validates against)
FEE_RES=$(curl -s "$BROPAY/v1/merchant/fee-configurations/self" \
  -H "$OWNER" -H "$RESELLER_HEADER" -H "$ORIGIN")
INBOUND_FEE=$(echo "$FEE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('inbound',{}).get('fee_percentage', 1.5))")
OUTBOUND_FEE=$(echo "$FEE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('outbound',{}).get('fee_percentage', 1.5))")

SUB_NAME="E2E Sub Merchant $(date +%s)"
SUB_CREATE=$(curl -s "$BROPAY/v1/merchant/sub-merchants" -X POST \
  -H "$OWNER" -H "$RESELLER_HEADER" -H "$ORIGIN" -H "$CT" \
  -d "{\"name\":\"$SUB_NAME\",\"merchant_type\":\"limited_company\",\"owner_account_id\":\"$SUB_OWNER_ID\",\"fee_percentage_inbound\":$INBOUND_FEE,\"fee_percentage_outbound\":$OUTBOUND_FEE}")

SUB_MERCHANT_ID=$(echo "$SUB_CREATE" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$SUB_MERCHANT_ID" ] || fail "Sub-merchant creation failed"
pass "Sub-merchant created: ${SUB_MERCHANT_ID:0:16}..."

# ── Step 6: Guard: invalid fee percentages ───────────────────────────────────
step 6 "Guard: invalid fee percentages"

# Fee below parent floor (0% is below parent's 1.5%)
BAD_FEE_RES=$(http_post "$BROPAY/v1/merchant/sub-merchants" \
  -H "$OWNER" -H "$RESELLER_HEADER" -H "$ORIGIN" -H "$CT" \
  -d "{\"name\":\"Bad Fee\",\"merchant_type\":\"limited_company\",\"owner_account_id\":\"$SUB_OWNER_ID\",\"fee_percentage_inbound\":0.0,\"fee_percentage_outbound\":0.0}")
BAD_FEE_STATUS=$(echo "$BAD_FEE_RES" | status)
[ "$BAD_FEE_STATUS" = "400" ] || fail "Expected 400 for fee below floor, got $BAD_FEE_STATUS"
pass "400 for fee below parent floor"

# ── Step 7: Reseller activates sub-merchant ──────────────────────────────────
step 7 "Activate sub-merchant"
ACTIVATE_RES=$(curl -s "$BROPAY/v1/merchant/sub-merchants/$SUB_MERCHANT_ID/activate" -X POST \
  -H "$OWNER" -H "$RESELLER_HEADER" -H "$ORIGIN" -H "$CT" -d '{}')
SUB_STATUS=$(echo "$ACTIVATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$SUB_STATUS" = "active" ] || fail "Expected status 'active', got '$SUB_STATUS'"
pass "Sub-merchant activated"

# Set commission percentage on hierarchy edge so completion distributes commission
d1_local_ok "UPDATE merchant_hierarchy SET commission_percentage = 100.0 WHERE descendant_id = '$SUB_MERCHANT_ID' AND ancestor_id = '$RESELLER_ID'" \
  || fail "Failed to set commission percentage in local D1"
pass "Commission percentage set: 100%"

step "7b" "GET sub-merchant detail"
SUB_DETAIL=$(http_get "$BROPAY/v1/merchant/sub-merchants/$SUB_MERCHANT_ID" \
  -H "$OWNER" -H "$RESELLER_HEADER" -H "$ORIGIN")
[ "$(echo "$SUB_DETAIL" | status)" = "200" ] || fail "GET sub-merchant detail failed"
SUB_DETAIL_STATUS=$(echo "$SUB_DETAIL" | body | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$SUB_DETAIL_STATUS" = "active" ] && pass "Sub-merchant detail: status=$SUB_DETAIL_STATUS" || warn "Detail status=$SUB_DETAIL_STATUS"

# ── Step 8: Sub-owner creates integration + bank account ─────────────────────
step 8 "Sub-owner creates integration and bank account"
SUB_OWNER_HEADER="X-Merchant-Id: $SUB_MERCHANT_ID"

# Create integration
SUB_INT_SLUG="sub-int-$(date +%s)"
curl -s "$BROPAY/v1/merchant/integrations" -X POST \
  -H "Authorization: Bearer $SUB_OWNER_TOKEN" -H "$SUB_OWNER_HEADER" -H "$ORIGIN" -H "$CT" \
  -d "{\"name\":\"Sub Integration\",\"slug\":\"$SUB_INT_SLUG\"}" > /dev/null

SUB_INTEGRATIONS=$(curl -s "$BROPAY/v1/merchant/integrations" \
  -H "Authorization: Bearer $SUB_OWNER_TOKEN" -H "$SUB_OWNER_HEADER" -H "$ORIGIN")
SUB_INTEGRATION_ID=$(echo "$SUB_INTEGRATIONS" | json "
d=json.load(sys.stdin)['data']
for i in d:
    if i['slug'] == '$SUB_INT_SLUG':
        print(i['id'])
        break
")
[ -n "$SUB_INTEGRATION_ID" ] || fail "No integration found for sub-merchant"
pass "Integration: ${SUB_INTEGRATION_ID:0:16}..."

# Activate integration for HMAC
d1_local_ok "UPDATE integrations SET status = 'active' WHERE id = '$SUB_INTEGRATION_ID'" \
  || fail "Failed to activate integration in local D1"
pass "Integration activated"

# Create bank account
curl -s "$BROPAY/v1/merchant/bank-accounts" -X POST \
  -H "Authorization: Bearer $SUB_OWNER_TOKEN" -H "$SUB_OWNER_HEADER" -H "$ORIGIN" -H "$CT" \
  -d '{"bank_id":"bank-kbank-0000-0000-000000000001","account_number":"1111111111","account_holder_name":"Sub Merchant","account_type":"savings"}' > /dev/null

# Verify bank account via DB
SUB_BA_RES=$(curl -s "$BROPAY/v1/merchant/bank-accounts" \
  -H "Authorization: Bearer $SUB_OWNER_TOKEN" -H "$SUB_OWNER_HEADER" -H "$ORIGIN")
SUB_BA_ID=$(echo "$SUB_BA_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')")
[ -n "$SUB_BA_ID" ] || fail "No bank account found"

d1_local_ok "UPDATE merchant_bank_accounts SET verification_status = 'verified', status = 'active', for_settlement = 1 WHERE id = '$SUB_BA_ID'" \
  || fail "Failed to verify sub-merchant bank account in local D1"
pass "Bank account verified: ${SUB_BA_ID:0:16}..."

# ── Step 9: Guard: 404 on missing sub-merchant, auth checks ──────────────────
step 9 "Guard: 404 and auth on sub-merchant endpoints"

# 404 get missing sub-merchant
NOTFOUND_GET=$(http_get "$BROPAY/v1/merchant/sub-merchants/nonexistent-id" \
  -H "$OWNER" -H "$RESELLER_HEADER" -H "$ORIGIN")
NOTFOUND_GET_STATUS=$(echo "$NOTFOUND_GET" | status)
[ "$NOTFOUND_GET_STATUS" = "404" ] || fail "Expected 404 for missing sub-merchant, got $NOTFOUND_GET_STATUS"
pass "404 GET missing sub-merchant"

# 404 activate missing sub-merchant
NOTFOUND_ACT=$(http_post "$BROPAY/v1/merchant/sub-merchants/nonexistent-id/activate" \
  -H "$OWNER" -H "$RESELLER_HEADER" -H "$ORIGIN" -H "$CT" -d '{}')
NOTFOUND_ACT_STATUS=$(echo "$NOTFOUND_ACT" | status)
[ "$NOTFOUND_ACT_STATUS" = "404" ] || fail "Expected 404 activate missing, got $NOTFOUND_ACT_STATUS"
pass "404 activate missing sub-merchant"

# 401 without auth on sub-merchant list
NO_AUTH_LIST=$(http_get "$BROPAY/v1/merchant/sub-merchants" -H "$RESELLER_HEADER" -H "$ORIGIN")
NO_AUTH_LIST_STATUS=$(echo "$NO_AUTH_LIST" | status)
[ "$NO_AUTH_LIST_STATUS" = "401" ] || fail "Expected 401 without auth, got $NO_AUTH_LIST_STATUS"
pass "401 without auth on sub-merchant list"

# ── Step 10: Complete a payment on sub-merchant ──────────────────────────────
step 10 "Complete payment on sub-merchant"

# Get HMAC credentials
CREDS=$(curl -s "$BROPAY/v1/merchant/integrations/$SUB_INTEGRATION_ID/rotate-key" -X POST \
  -H "Authorization: Bearer $SUB_OWNER_TOKEN" -H "$SUB_OWNER_HEADER" -H "$ORIGIN" -H "$CT")
API_KEY=$(echo "$CREDS" | json "print(json.load(sys.stdin)['data']['api_key'])")
SECRET_KEY=$(echo "$CREDS" | json "print(json.load(sys.stdin)['data']['secret_key'])")

KBNK_TOKEN=$(curl -s "$KBNK/api/v1/auth/token" -H "$CT" \
  -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"$KBNK_CLIENT_ID\",\"client_secret\":\"$KBNK_CLIENT_SECRET\"}" \
  | json "print(json.load(sys.stdin).get('access_token',''))")

AMOUNT=$((5000 + RANDOM % 5000))
PI_BODY="{\"amount\":$AMOUNT,\"currency\":\"THB\",\"payment_method\":\"promptpay\",\"description\":\"Reseller hierarchy test\"}"
PI_TS=$(date +%s)
PI_SIG=$(hmac_sign "$SECRET_KEY" "$PI_TS" "$PI_BODY")

PI_RES=$(curl -s "$BROPAY/v1/api/payment-intents" -X POST -H "$CT" \
  -H "X-Api-Key: $API_KEY" -H "X-Signature: $PI_SIG" -H "X-Timestamp: $PI_TS" \
  -d "$PI_BODY")
PI_ID=$(echo "$PI_RES" | json "print(json.load(sys.stdin)['data']['id'])")
[ -n "$PI_ID" ] || fail "PI creation failed"

# Create KBNK deposit + complete (or fall back to direct DB update if KBNK unavailable)
KBNK_DEP_ID=""
if [ -n "$KBNK_TOKEN" ]; then
  KBNK_DEP=$(curl -s "$KBNK/api/v1/deposits" -H "Authorization: Bearer $KBNK_TOKEN" -H "$CT" \
    -d "{\"amount\":$AMOUNT.00,\"paymentMethod\":\"promptpay\",\"currency\":\"THB\",\"correlationId\":\"reseller-$PI_ID\",\"customer\":{\"bankCode\":\"KBANK\",\"accountNumber\":\"0123456789\",\"accountHolderName\":\"Test\"}}")
  KBNK_DEP_ID=$(echo "$KBNK_DEP" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
  # data.depositId (BRO-...) is what KBNK puts in webhook payloads
  KBNK_DEP_DISPLAY=$(echo "$KBNK_DEP" | json "print(json.load(sys.stdin).get('data',{}).get('depositId',''))")
  [ -n "$KBNK_DEP_DISPLAY" ] && pass "KBNK deposit: $KBNK_DEP_DISPLAY" || warn "KBNK deposit creation failed"
else
  warn "KBNK token unavailable. Using direct DB status update."
fi

if [ -n "$KBNK_DEP_ID" ]; then
  d1_local_ok "UPDATE payment_intents SET provider_deposit_id = '$KBNK_DEP_DISPLAY', status = 'processing', updated_at = datetime('now') WHERE id = '$PI_ID'" \
    || fail "Failed to link PI to KBNK deposit in local D1"
  curl -s "$KBNK/api/v1/deposits/$KBNK_DEP_ID/status" -X PATCH \
    -H "Authorization: Bearer $KBNK_TOKEN" -H "$CT" -d '{"status":"completed"}' > /dev/null
else
  d1_local_ok "UPDATE payment_intents SET status = 'processing', updated_at = datetime('now') WHERE id = '$PI_ID'" \
    || fail "Failed to set PI processing in local D1"
fi

d1_local_ok "INSERT INTO transactions (merchant_id, integration_id, reference_type, reference_id, amount, currency, direction, fee_amount, net_amount, status, description) VALUES ('$SUB_MERCHANT_ID', '$SUB_INTEGRATION_ID', 'payment', '$PI_ID', $AMOUNT, 'THB', 'credit', 0, $AMOUNT, 'completed', 'Reseller hierarchy test')" \
  || fail "Failed to insert transaction in local D1"
d1_local_ok "UPDATE payment_intents SET status = 'succeeded', succeeded_at = datetime('now'), updated_at = datetime('now') WHERE id = '$PI_ID'" \
  || fail "Failed to mark PI succeeded in local D1"

pass "Payment completed: $AMOUNT satang"

# ── Step 10b: Fund sub-merchant wallet (need balance to cover settlement fee) ─
step "10b" "Fund sub-merchant wallet (for fee coverage)"
SUB_WALLET_RES=$(curl -s "$BROPAY/v1/admin/wallets?merchant_id=$SUB_MERCHANT_ID&limit=1" \
  -H "$ADMIN" -H "$ORIGIN")
SUB_WALLET_ID=$(echo "$SUB_WALLET_RES" | json "
d=json.load(sys.stdin)
items=d.get('data',[])
print(items[0]['id'] if items else '')
")
[ -n "$SUB_WALLET_ID" ] || fail "No wallet found for sub-merchant"

d1_local_ok "UPDATE wallets SET available_balance = available_balance + 100000, updated_at = datetime('now') WHERE id = '$SUB_WALLET_ID'" \
  || fail "Failed to fund sub-merchant wallet in local D1"
d1_local_ok "INSERT INTO wallet_ledger_entries (wallet_id, entry_type, reference_type, reference_id, amount, currency, balance_before, balance_after, description) VALUES ('$SUB_WALLET_ID', 'credit', 'deposit', 'e2e-reseller-funding', 100000, 'THB', 0, 100000, 'E2E reseller hierarchy funding')" \
  || fail "Failed to insert sub-merchant funding ledger entry in local D1"
pass "Sub-merchant wallet funded: 100000 satang"

# ── Step 10c: Settlement preview on sub-merchant ─────────────────────────────
step "10c" "Settlement preview (sub-merchant)"
SUB_PREVIEW=$(http_get "$BROPAY/v1/merchant/settlements/preview?integration_id=$SUB_INTEGRATION_ID" \
  -H "Authorization: Bearer $SUB_OWNER_TOKEN" -H "$SUB_OWNER_HEADER" -H "$ORIGIN")
[ "$(echo "$SUB_PREVIEW" | status)" = "200" ] || warn "Sub-merchant preview HTTP $(echo "$SUB_PREVIEW" | status)"
PREVIEW_COUNT=$(echo "$SUB_PREVIEW" | body | json "print(json.load(sys.stdin).get('data',{}).get('eligible_transaction_count',0))")
[ "$PREVIEW_COUNT" -ge 1 ] && pass "Preview: $PREVIEW_COUNT eligible txn(s)" || warn "Preview eligible=$PREVIEW_COUNT"

# ── Step 11: Sub-owner creates settlement ────────────────────────────────────
step 11 "Create settlement on sub-merchant"
SETTLE_RES=$(curl -s "$BROPAY/v1/merchant/settlements" -X POST \
  -H "Authorization: Bearer $SUB_OWNER_TOKEN" -H "$SUB_OWNER_HEADER" -H "$ORIGIN" -H "$CT" \
  -d "{\"integration_id\":\"$SUB_INTEGRATION_ID\",\"bank_account_id\":\"$SUB_BA_ID\"}")

SETTLEMENT_ID=$(echo "$SETTLE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
SETTLEMENT_FEE=$(echo "$SETTLE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('fee_amount',0))")
[ -n "$SETTLEMENT_ID" ] || fail "Settlement creation failed"
pass "Settlement created: ${SETTLEMENT_ID:0:16}... (fee: $SETTLEMENT_FEE satang)"

# ── Step 12: Admin uploads slip + completes settlement (triggers commission) ─
step 12 "Admin slip upload + complete settlement"

# Windows/Git Bash: avoid mktemp under /tmp — use repo-local path + minimal JPEG (settlements.sh pattern).
SLIP_TMP="$REPO_ROOT/.e2e-reseller-slip-$$.jpg"
python3 -c "import sys; sys.stdout.buffer.write(bytes([0xff,0xd8,0xff,0xe0,0x00,0x10,0x4a,0x46,0x49,0x46,0x00,0x01,0x01,0x00,0x00,0x01,0x00,0x01,0x00,0x00,0xff,0xd9]))" > "$SLIP_TMP" 2>/dev/null \
  || printf '\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xff\xd9' > "$SLIP_TMP"
[ -s "$SLIP_TMP" ] || fail "Could not create slip JPEG at $SLIP_TMP"

UPLOAD_RES=$(curl -s "$BROPAY/v1/admin/settlements/$SETTLEMENT_ID/slip" -X POST \
  -H "$ADMIN" -H "$ORIGIN" \
  -F "file=@$SLIP_TMP;type=image/jpeg;filename=e2e-reseller-slip.jpg") || UPLOAD_RES=""
rm -f "$SLIP_TMP"
if [ "$(json_has_data "$UPLOAD_RES")" = "True" ]; then
  pass "Slip uploaded via API"
else
  warn "Slip upload via API failed (R2 may be unavailable locally), inserting settlement_slips row"
  SLIP_ID=$(python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null) || SLIP_ID=""
  SLIP_ID="${SLIP_ID//$'\r'/}"
  d1_local_ok "INSERT INTO settlement_slips (id, settlement_id, mime_type, original_filename, r2_key, file_size, uploaded_by) VALUES ('$SLIP_ID', '$SETTLEMENT_ID', 'image/jpeg', 'e2e-reseller-slip.jpg', 'e2e/$SETTLEMENT_ID.jpg', 12345, 'acct-super-admin-0000-000000000001')" \
    || fail "D1 settlement_slips insert failed (wrangler in apps/api?)"
  pass "Slip inserted (DB fallback)"
fi

COMPLETE_RES=$(curl -s "$BROPAY/v1/admin/settlements/$SETTLEMENT_ID/complete" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"notes":"E2E commission test","bank_reference":"E2E-REF-001"}')
COMPLETE_STATUS=$(echo "$COMPLETE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$COMPLETE_STATUS" = "completed" ] || fail "Expected status 'completed', got '$COMPLETE_STATUS' — $COMPLETE_RES"
pass "Settlement completed"

# ── Step 13: Verify commission in reseller wallet ────────────────────────────
step 13 "Verify commission in reseller wallet"

# Check reseller wallet ledger for commission entry
LEDGER_RES=$(curl -s "$BROPAY/v1/merchant/wallets/ledger" \
  -H "$OWNER" -H "$RESELLER_HEADER" -H "$ORIGIN")
COMMISSION_COUNT=$(echo "$LEDGER_RES" | json "
d=json.load(sys.stdin)
entries = d.get('data', [])
count = sum(1 for e in entries if e.get('reference_type') == 'commission' and e.get('reference_id') == '$SETTLEMENT_ID')
print(count)
")
[ "$COMMISSION_COUNT" -ge 1 ] || fail "No commission ledger entry found for settlement $SETTLEMENT_ID"
pass "Commission entries: $COMMISSION_COUNT"

# Check commissions endpoint
COMM_RES=$(curl -s "$BROPAY/v1/merchant/commissions" \
  -H "$OWNER" -H "$RESELLER_HEADER" -H "$ORIGIN")
COMM_TOTAL=$(echo "$COMM_RES" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
pass "Commissions via endpoint: $COMM_TOTAL"

# Verify commission summary
COMM_SUMMARY=$(curl -s "$BROPAY/v1/merchant/commissions/summary" \
  -H "$OWNER" -H "$RESELLER_HEADER" -H "$ORIGIN")
TOTAL_EARNED=$(echo "$COMM_SUMMARY" | json "print(json.load(sys.stdin).get('data',{}).get('total_earned',0))")
[ "$TOTAL_EARNED" -gt 0 ] || fail "Expected total_earned > 0, got $TOTAL_EARNED"
pass "Commission summary total_earned: $TOTAL_EARNED"

step "13b" "Commission detail + filters"
COMM_ENTRY_ID=$(echo "$COMM_RES" | json "
import json, sys
for e in json.load(sys.stdin).get('data', []):
    if e.get('reference_id') == '$SETTLEMENT_ID':
        print(e['id']); break
")
[ -n "$COMM_ENTRY_ID" ] || fail "No commission ledger entry id for settlement"
COMM_DETAIL=$(http_get "$BROPAY/v1/merchant/commissions/$COMM_ENTRY_ID" \
  -H "$OWNER" -H "$RESELLER_HEADER" -H "$ORIGIN")
[ "$(echo "$COMM_DETAIL" | status)" = "200" ] || fail "Commission detail failed"
HAS_CASCADE=$(echo "$COMM_DETAIL" | body | json "
d=json.load(sys.stdin).get('data',{})
fc=d.get('fee_cascade') or {}
print('yes' if fc.get('commissions') else 'no')
")
[ "$HAS_CASCADE" = "yes" ] && pass "Commission detail includes fee_cascade" || warn "fee_cascade missing in detail"

CREDITED=$(http_get "$BROPAY/v1/merchant/commissions?status=credited&limit=5" \
  -H "$OWNER" -H "$RESELLER_HEADER" -H "$ORIGIN")
CREDITED_FOUND=$(echo "$CREDITED" | body | json "
import json, sys
for e in json.load(sys.stdin).get('data', []):
    if e.get('id') == '$COMM_ENTRY_ID':
        print('found'); break
else:
    print('not_found')
")
[ "$CREDITED_FOUND" = "found" ] && pass "Commission in status=credited filter" || warn "Not in credited filter"

TS_RES=$(http_get "$BROPAY/v1/merchant/commissions/timeseries?date_from=2020-01-01&date_to=2099-12-31" \
  -H "$OWNER" -H "$RESELLER_HEADER" -H "$ORIGIN")
[ "$(echo "$TS_RES" | status)" = "200" ] && pass "Commission timeseries OK" || warn "Timeseries failed"

# ── Step 14: Verify hierarchy tree ───────────────────────────────────────────
step 14 "Verify hierarchy tree"
TREE_RES=$(curl -s "$BROPAY/v1/admin/merchants/$RESELLER_ID/tree" -H "$ADMIN" -H "$ORIGIN")
SUB_FOUND=$(echo "$TREE_RES" | json "
d=json.load(sys.stdin)
found = 'not_found'
for n in d.get('data', []):
    if n.get('descendant_id') == '$SUB_MERCHANT_ID':
        found = f\"depth={n['depth']} commission={n.get('commission_percentage', 0)}%\"
        break
print(found)
")
[ "$SUB_FOUND" != "not_found" ] || fail "Sub-merchant not found in hierarchy tree"
pass "Admin hierarchy: $SUB_FOUND"

step "14b" "Merchant downline tree + stats"
DOWNLINE_RES=$(curl -s "$BROPAY/v1/merchant/downline" -H "$OWNER" -H "$RESELLER_HEADER" -H "$ORIGIN")
DOWNLINE_FOUND=$(echo "$DOWNLINE_RES" | json "
import json, sys
for n in json.load(sys.stdin).get('data', []):
    if n.get('id') == '$SUB_MERCHANT_ID':
        print(f\"depth={n.get('depth')} status={n.get('status')}\")
        break
else:
    print('not_found')
")
[ "$DOWNLINE_FOUND" != "not_found" ] && pass "Downline tree: $DOWNLINE_FOUND" || fail "Sub-merchant not in merchant downline"

DOWNLINE_STATS=$(curl -s "$BROPAY/v1/merchant/downline/stats" -H "$OWNER" -H "$RESELLER_HEADER" -H "$ORIGIN")
DL_TOTAL=$(echo "$DOWNLINE_STATS" | json "print(json.load(sys.stdin).get('data',{}).get('total_sub_merchants',0))")
[ "$DL_TOTAL" -ge 1 ] && pass "Downline stats total_sub_merchants: $DL_TOTAL" || warn "downline stats total=$DL_TOTAL"

# ── Step 15: Verify sub-merchant list filters ────────────────────────────────
step 15 "Verify sub-merchant list filters"

# List all sub-merchants
SUB_LIST=$(curl -s "$BROPAY/v1/merchant/sub-merchants?limit=10" -H "$OWNER" -H "$RESELLER_HEADER" -H "$ORIGIN")
SUB_LIST_COUNT=$(echo "$SUB_LIST" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
[ "$SUB_LIST_COUNT" -ge 1 ] || fail "Expected sub-merchant list count >= 1, got $SUB_LIST_COUNT"
pass "Sub-merchant list count: $SUB_LIST_COUNT"

# Filter by status=active
ACTIVE_SUBS=$(curl -s "$BROPAY/v1/merchant/sub-merchants?status=active" -H "$OWNER" -H "$RESELLER_HEADER" -H "$ORIGIN")
ACTIVE_SUB_COUNT=$(echo "$ACTIVE_SUBS" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
[ "$ACTIVE_SUB_COUNT" -ge 1 ] || fail "Expected active sub-merchant count >= 1, got $ACTIVE_SUB_COUNT"
pass "Active sub-merchant filter count: $ACTIVE_SUB_COUNT"

# Filter by status=pending should not include our active sub-merchant
PENDING_SUBS=$(curl -s "$BROPAY/v1/merchant/sub-merchants?status=pending" -H "$OWNER" -H "$RESELLER_HEADER" -H "$ORIGIN")
PENDING_SUB_FOUND=$(echo "$PENDING_SUBS" | json "
d=json.load(sys.stdin)
for x in d.get('data', []):
    if x['id'] == '$SUB_MERCHANT_ID':
        print('found')
        break
else:
    print('not_found')
")
[ "$PENDING_SUB_FOUND" = "not_found" ] || fail "Active sub-merchant should not appear in pending filter"
pass "Not in pending filter"

# Search by name
Q_SUBS=$(curl -s "$BROPAY/v1/merchant/sub-merchants?q=E2E+Sub+Merchant" -H "$OWNER" -H "$RESELLER_HEADER" -H "$ORIGIN")
Q_SUB_FOUND=$(echo "$Q_SUBS" | json "
d=json.load(sys.stdin)
for x in d.get('data', []):
    if x['id'] == '$SUB_MERCHANT_ID':
        print('found')
        break
else:
    print('not_found')
")
[ "$Q_SUB_FOUND" = "found" ] || warn "Search by q did not find sub-merchant"
[ "$Q_SUB_FOUND" = "not_found" ] || pass "Search by q found sub-merchant"

step "15b" "PATCH sub-merchant"
PATCH_NAME="${SUB_NAME} (updated)"
PATCH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/sub-merchants/$SUB_MERCHANT_ID" -X PATCH \
  -H "$OWNER" -H "$RESELLER_HEADER" -H "$ORIGIN" -H "$CT" \
  -d "{\"name\":\"$PATCH_NAME\"}")
[ "$(echo "$PATCH_RES" | tail -n1)" = "200" ] && pass "PATCH sub-merchant name" || warn "PATCH failed: $(echo "$PATCH_RES" | tail -n1)"

# ── Step 16: Cleanup ─────────────────────────────────────────────────────────
step 16 "Cleanup created resources"

# Delete ledger entries tied to this settlement (commission, fee, platform_fee)
d1_local_quiet "DELETE FROM wallet_ledger_entries WHERE reference_id = '$SETTLEMENT_ID'"

# Delete settlement events, items, slip, then settlement
d1_local_quiet "DELETE FROM settlement_events WHERE settlement_id = '$SETTLEMENT_ID'"
d1_local_quiet "DELETE FROM settlement_items WHERE settlement_id = '$SETTLEMENT_ID'"
d1_local_quiet "DELETE FROM settlement_slips WHERE settlement_id = '$SETTLEMENT_ID'"
d1_local_quiet "DELETE FROM settlements WHERE id = '$SETTLEMENT_ID'"

# Delete transaction and payment intent
d1_local_quiet "DELETE FROM transactions WHERE reference_id = '$PI_ID'"
d1_local_quiet "DELETE FROM payment_intents WHERE id = '$PI_ID'"

# Delete integration API keys then integration
d1_local_quiet "DELETE FROM integration_api_keys WHERE integration_id = '$SUB_INTEGRATION_ID'"
d1_local_quiet "DELETE FROM integrations WHERE id = '$SUB_INTEGRATION_ID'"

# Delete bank account
d1_local_quiet "DELETE FROM merchant_bank_accounts WHERE id = '$SUB_BA_ID'"

# Delete sub-merchant wallet ledger entries and wallet
d1_local_quiet "DELETE FROM wallet_ledger_entries WHERE wallet_id = '$SUB_WALLET_ID'"
d1_local_quiet "DELETE FROM wallets WHERE id = '$SUB_WALLET_ID'"

# Delete hierarchy entries for sub-merchant
d1_local_quiet "DELETE FROM merchant_hierarchy WHERE descendant_id = '$SUB_MERCHANT_ID'"

# Delete memberships for sub-merchant
d1_local_quiet "DELETE FROM merchant_memberships WHERE merchant_id = '$SUB_MERCHANT_ID'"

# Delete fee configs for sub-merchant
d1_local_quiet "DELETE FROM fee_configurations WHERE merchant_id = '$SUB_MERCHANT_ID'"

# Delete sub-merchant
d1_local_quiet "DELETE FROM merchants WHERE id = '$SUB_MERCHANT_ID'"

# Delete plain merchant and its data
d1_local_quiet "DELETE FROM merchant_memberships WHERE merchant_id = '$PLAIN_MERCHANT_ID'"
d1_local_quiet "DELETE FROM wallets WHERE merchant_id = '$PLAIN_MERCHANT_ID'"
d1_local_quiet "DELETE FROM fee_configurations WHERE merchant_id = '$PLAIN_MERCHANT_ID'"
d1_local_quiet "DELETE FROM merchants WHERE id = '$PLAIN_MERCHANT_ID'"

# Delete registered accounts (sub-owner, plain owner)
d1_local_quiet "DELETE FROM accounts WHERE email IN ('$SUB_OWNER_EMAIL', '$PLAIN_EMAIL')"

# Restore owner account kind to 'merchant' so bootstrap works on next run
d1_local_quiet "UPDATE accounts SET kind = 'merchant' WHERE id = '$OWNER_ID'"
[ -n "$SLIP_FILE" ] && [ -f "$SLIP_FILE" ] && rm -f "$SLIP_FILE"
pass "Cleanup complete"

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}━━━ Reseller Hierarchy Flow Complete ━━━${NC}"
echo "Reseller:  ${RESELLER_ID:0:20}..."
echo "Sub:       ${SUB_MERCHANT_ID:0:20}..."
echo "Payment:   $AMOUNT satang → succeeded"
echo "Settlement:${SETTLEMENT_ID:0:20}... (fee: $SETTLEMENT_FEE satang)"
echo "Commission:$COMMISSION_COUNT entry(s) in reseller wallet"
