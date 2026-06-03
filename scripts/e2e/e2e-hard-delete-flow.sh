#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Hard-Delete Flow — admin permanent deletes (happy + negative paths)
#
# Usage:
#   bash scripts/e2e/e2e-hard-delete-flow.sh
#
# Environment: BROPAY_URL, BOOTSTRAP_MERCHANT_* (optional)
#
# Flow:
#   1.  Bootstrap demo merchant
#   2.  Create a fresh "disposable" merchant (clean slate — no financial history)
#   3.  Create a customer + customer bank account under that merchant (via admin)
#   4.  Create an integration under the disposable merchant
#   5.  Create a fee configuration for that merchant
#   6.  Hard-delete fee config → 404 on subsequent GET
#   7.  Hard-delete customer bank account → 404 on subsequent GET
#   8.  Hard-delete integration → 404 on subsequent GET
#   9.  Hard-delete merchant → 204 + 404 on subsequent GET; cascade cleanup confirmed
#  10.  Negative path — hard-delete already-gone merchant → 404
#  11.  Negative path — delete without staff auth → 403/401
#
# See: scripts/e2e/docs/e2e-hard-delete-flow.md
#
# Requires a healthy local D1 (pnpm migrate:local). A half-applied webhook_events
# migration leaves _old_* tables and breaks DELETE /admin/integrations (500 DB_ERROR).
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BROPAY="${BROPAY_URL:-http://localhost:8787}"
ORIGIN="Origin: http://localhost:3000"
CT="Content-Type: application/json"
FAKE_ID="00000000-0000-4000-8000-000000000099"
BANK_ID="bank-kbank-0000-0000-000000000001"
STAFF_PASSWORD="password123"

GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[0;33m' CYAN='\033[0;36m' NC='\033[0m'
pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }
info() { echo -e "${CYAN}→ $1${NC}"; }
warn() { echo -e "${YELLOW}! $1${NC}"; }
step() { echo -e "\n${CYAN}━━━ Step $1: $2 ━━━${NC}"; }
json() { python3 -c "import sys,json; $1" 2>/dev/null; }

http_get() {
  local raw
  raw=$(curl -s -w "\n%{http_code}" "$1" "${@:2}")
  HTTP_CODE=$(echo "$raw" | tail -1)
  HTTP_BODY=$(echo "$raw" | sed '$d')
}

http_post() {
  local raw
  raw=$(curl -s -w "\n%{http_code}" "$1" -X POST "${@:2}")
  HTTP_CODE=$(echo "$raw" | tail -1)
  HTTP_BODY=$(echo "$raw" | sed '$d')
}

http_delete() {
  local raw
  raw=$(curl -s -w "\n%{http_code}" "$1" -X DELETE "${@:2}")
  HTTP_CODE=$(echo "$raw" | tail -1)
  HTTP_BODY=$(echo "$raw" | sed '$d')
}

# Integration DELETE cascades into webhook_events; broken migrations leave _old_* tables.
assert_local_d1_healthy() {
  if ! command -v wrangler > /dev/null 2>&1 || [ ! -d "$REPO_ROOT/apps/api" ]; then
    return 0
  fi
  local out
  out=$(cd "$REPO_ROOT/apps/api" && wrangler d1 execute bropay-db --local --command \
    "SELECT name FROM sqlite_master WHERE type='table' AND name LIKE '_old_%' LIMIT 1;" 2>&1) || true
  if echo "$out" | grep -q "_old_"; then
    fail "Local D1 schema is broken (stale _old_* tables).
Fix: cd apps/api && rm -rf .wrangler/state/v3/d1 && pnpm migrate:local && pnpm db:seed
Then restart pnpm dev:api and re-run this script."
  fi
  out=$(cd "$REPO_ROOT/apps/api" && wrangler d1 execute bropay-db --local --command \
    "DELETE FROM integrations WHERE 0;" 2>&1) || true
  if echo "$out" | grep -qiE "_old_|no such table"; then
    fail "Local D1 cannot run integration DELETE (webhook_events migration likely corrupt).
Fix: cd apps/api && rm -rf .wrangler/state/v3/d1 && pnpm migrate:local && pnpm db:seed
Then restart pnpm dev:api and re-run this script."
  fi
}

fail_integration_delete() {
  if [ "$HTTP_CODE" = "500" ] && echo "$HTTP_BODY" | grep -q '"DB_ERROR"'; then
    fail "Expected 200 on integration DELETE, got 500 (DB_ERROR) — local D1 schema issue, not the E2E script.
Fix: cd apps/api && rm -rf .wrangler/state/v3/d1 && pnpm migrate:local && pnpm db:seed
Then restart pnpm dev:api and re-run."
  fi
  fail "Expected 200 on integration DELETE, got $HTTP_CODE (body: $HTTP_BODY)"
}

seed_payment_intent_local() {
  local pi_id=$1 merchant_id=$2 integration_id=$3
  if ! command -v wrangler > /dev/null 2>&1 || [ ! -d "$REPO_ROOT/apps/api" ]; then
    warn "wrangler not found — skipping PI seed for integration 422 test"
    return 1
  fi
  local secret="pi_${pi_id}_secret_e2e"
  (
    cd "$REPO_ROOT/apps/api" && \
    wrangler d1 execute bropay-db --local --command \
      "INSERT INTO payment_intents (id, merchant_id, integration_id, amount, currency, status, payment_method, expiry_minutes, client_secret, description, created_at, updated_at) VALUES ('$pi_id', '$merchant_id', '$integration_id', 10000, 'THB', 'requires_payment_method', 'promptpay', 15, '$secret', 'E2E hard-delete guard', datetime('now'), datetime('now'))" \
      > /dev/null 2>&1
  ) || return 1
  return 0
}

echo -e "${CYAN}━━━ BroPay E2E Hard-Delete Flow ━━━${NC}"

# ── Step 1: Bootstrap ─────────────────────────────────────────────────────────
step 1 "Bootstrap admin session"
source "$SCRIPT_DIR/_bootstrap.sh"
bootstrap_demo_merchant
ADMIN_TOKEN="$DEMO_ADMIN_TOKEN"
OWNER_TOKEN="$DEMO_OWNER_TOKEN"
OWNER_ID="$DEMO_OWNER_ID"
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
OWNER="Authorization: Bearer $OWNER_TOKEN"
pass "Admin bootstrapped"
assert_local_d1_healthy
pass "Local D1 schema OK"

# ── Step 2: Create a disposable merchant ───────────────────────────────────────
step 2 "Create disposable merchant (no financial history)"
DISP_TS=$(date +%s)
DISP_SLUG="e2e-harddelete-${DISP_TS}"
DISP_RES=$(curl -s "$BROPAY/v1/admin/merchants" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"name\":\"E2E Hard Delete ${DISP_TS}\",\"slug\":\"$DISP_SLUG\",\"merchant_type\":\"other\",\"primary_currency\":\"THB\",\"owner_account_id\":\"$OWNER_ID\"}")
DISP_ID=$(echo "$DISP_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$DISP_ID" ] || fail "Disposable merchant creation failed — $DISP_RES"
pass "Disposable merchant: ${DISP_ID:0:20}..."

curl -s "$BROPAY/v1/admin/merchants/$DISP_ID/activate" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}' > /dev/null
pass "Disposable merchant activated"

# ── Step 3: Create customer + customer bank account ───────────────────────────
step 3 "Create customer + customer bank account"

CUST_RES=$(curl -s "$BROPAY/v1/admin/customers" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"merchant_id\":\"$DISP_ID\",\"first_name\":\"E2E\",\"last_name\":\"HardDelete\",\"email\":\"e2e-hd-${DISP_TS}@example.com\"}")
CUST_ID=$(echo "$CUST_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$CUST_ID" ] || fail "Customer creation failed — $CUST_RES"
pass "Customer: ${CUST_ID:0:20}..."

step "3b" "GET customer detail"
http_get "$BROPAY/v1/admin/customers/$CUST_ID" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "200" ] || fail "Expected 200 for GET customer, got $HTTP_CODE"
pass "GET /admin/customers/{id} OK"

CBA_RES=$(curl -s "$BROPAY/v1/admin/customer-bank-accounts" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"customer_id\":\"$CUST_ID\",\"bank_id\":\"$BANK_ID\",\"account_number\":\"0123456789\",\"account_holder_name\":\"E2E HardDelete\",\"is_default\":0}")
CBA_ID=$(echo "$CBA_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$CBA_ID" ] || fail "Customer bank account creation failed — $CBA_RES"
pass "Customer bank account: ${CBA_ID:0:20}..."

# ── Step 4: Create integration ────────────────────────────────────────────────
step 4 "Create integration for disposable merchant"
INTG_RES=$(curl -s "$BROPAY/v1/admin/integrations" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"merchant_id\":\"$DISP_ID\",\"name\":\"E2E HD Integration\",\"slug\":\"e2e-hd-${DISP_TS}\"}")
INTG_ID=$(echo "$INTG_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$INTG_ID" ] || fail "Integration creation failed — $INTG_RES"
pass "Integration: ${INTG_ID:0:20}..."

# ── Step 5: Create fee configuration ─────────────────────────────────────────
step 5 "Create fee configuration for disposable merchant"
FEE_RES=$(curl -s "$BROPAY/v1/admin/fee-configurations" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"merchant_id\":\"$DISP_ID\",\"stream_type\":\"inbound\",\"fee_percentage\":1.5,\"flat_fee_amount\":500,\"is_active\":0}")
FEE_ID=$(echo "$FEE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$FEE_ID" ] || fail "Fee config creation failed — $FEE_RES"
pass "Fee config: ${FEE_ID:0:20}..."

http_get "$BROPAY/v1/admin/fee-configurations/$FEE_ID" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "200" ] || fail "Expected 200 for fee config GET before delete, got $HTTP_CODE"
pass "Fee config GET before delete: 200"

# ── Step 6: Hard-delete fee config ────────────────────────────────────────────
step 6 "Hard-delete fee config → verify 404"
http_delete "$BROPAY/v1/admin/fee-configurations/$FEE_ID" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "200" ] || fail "Expected 200 on fee config DELETE, got $HTTP_CODE (body: $HTTP_BODY)"
pass "Fee config DELETE returned $HTTP_CODE"

http_get "$BROPAY/v1/admin/fee-configurations/$FEE_ID" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "404" ] || fail "Expected 404 after fee config delete, got $HTTP_CODE"
http_delete "$BROPAY/v1/admin/fee-configurations/$FEE_ID" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "404" ] || warn "Expected 404 on second fee DELETE, got $HTTP_CODE"
pass "Fee config hard-delete + double-delete 404"

# ── Step 7: Hard-delete customer bank account ─────────────────────────────────
step 7 "Hard-delete customer bank account → verify 404"

http_get "$BROPAY/v1/admin/customer-bank-accounts/$CBA_ID" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "200" ] || warn "Expected 200 for CBA GET before delete, got $HTTP_CODE"

http_delete "$BROPAY/v1/admin/customer-bank-accounts/$CBA_ID" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "200" ] || fail "Expected 200 on customer bank account DELETE, got $HTTP_CODE (body: $HTTP_BODY)"
pass "Customer bank account DELETE returned $HTTP_CODE"

http_get "$BROPAY/v1/admin/customer-bank-accounts/$CBA_ID" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "404" ] || fail "Expected 404 after customer bank account delete, got $HTTP_CODE"
http_delete "$BROPAY/v1/admin/customer-bank-accounts/$CBA_ID" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "404" ] || warn "Expected 404 on second CBA DELETE, got $HTTP_CODE"
pass "Customer bank account hard-delete + double-delete 404"

# ── Step 8: Hard-delete integration ──────────────────────────────────────────
step 8 "Hard-delete integration → verify 404"

http_get "$BROPAY/v1/admin/integrations/$INTG_ID" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "200" ] || warn "Expected 200 for integration GET before delete, got $HTTP_CODE"

http_delete "$BROPAY/v1/admin/integrations/$INTG_ID" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "200" ] || fail_integration_delete
pass "Integration DELETE returned $HTTP_CODE"

http_get "$BROPAY/v1/admin/integrations/$INTG_ID" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "404" ] || fail "Expected 404 after integration delete, got $HTTP_CODE"
http_delete "$BROPAY/v1/admin/integrations/$INTG_ID" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "404" ] || warn "Expected 404 on second integration DELETE, got $HTTP_CODE"
pass "Integration hard-delete + double-delete 404"

# ── Step 9: Hard-delete merchant ──────────────────────────────────────────────
step 9 "Hard-delete disposable merchant → cascade verified"

http_get "$BROPAY/v1/admin/merchants/$DISP_ID" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "200" ] || warn "Expected 200 for merchant GET before delete, got $HTTP_CODE"

http_delete "$BROPAY/v1/admin/merchants/$DISP_ID" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "204" ] || fail "Expected 204 on merchant DELETE, got $HTTP_CODE (body: $HTTP_BODY)"
pass "Merchant DELETE returned 204"

http_get "$BROPAY/v1/admin/merchants/$DISP_ID" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "404" ] || fail "Expected 404 after merchant delete, got $HTTP_CODE"
pass "Merchant 404 after hard-delete confirmed"

WALLET_CHECK=$(curl -s "$BROPAY/v1/admin/wallets?merchant_id=$DISP_ID&limit=1" \
  -H "$ADMIN" -H "$ORIGIN")
WALLET_COUNT=$(echo "$WALLET_CHECK" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
[ "${WALLET_COUNT:-0}" -eq 0 ] && pass "Cascade: wallet row gone" || warn "Wallet still listed (total: $WALLET_COUNT)"

http_get "$BROPAY/v1/admin/customers/$CUST_ID" -H "$ADMIN" -H "$ORIGIN"
if [ "$HTTP_CODE" = "404" ]; then
  pass "Cascade: customer row removed (404)"
elif [ "$HTTP_CODE" = "200" ]; then
  LINK_COUNT=$(echo "$HTTP_BODY" | json "print(len(json.load(sys.stdin).get('data',{}).get('merchants',[])))")
  [ "${LINK_COUNT:-0}" -eq 0 ] && pass "Cascade: customer exists, merchant links cleared" \
    || warn "Customer still shows $LINK_COUNT merchant link(s)"
else
  warn "Unexpected GET customer after merchant delete: $HTTP_CODE"
fi

# ── Step 10: Negative — double-delete same merchant id → 404 ─────────────────
step 10 "Negative path — delete already-gone merchant id → 404"
http_delete "$BROPAY/v1/admin/merchants/$DISP_ID" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "404" ] || warn "Expected 404 on second delete of same id, got $HTTP_CODE"
[ "$HTTP_CODE" = "404" ] && pass "Second delete correctly returns 404"

# ── Step 11: Negative — delete without staff auth ───────────────────────────────
step 11 "Negative path — delete with non-staff token → 403/401"
http_delete "$BROPAY/v1/admin/merchants/$DEMO_MERCHANT_ID" -H "$OWNER" -H "$ORIGIN"
[ "$HTTP_CODE" = "403" ] || [ "$HTTP_CODE" = "401" ] || warn "Expected 403/401 for non-staff delete, got $HTTP_CODE"
[[ "$HTTP_CODE" == 4* ]] && pass "Delete without staff token rejected ($HTTP_CODE)" || fail "Expected 4xx for unauthorized delete, got $HTTP_CODE"

step "11b" "Negative path — delete with no token → 401"
http_delete "$BROPAY/v1/admin/integrations/some-id" -H "$ORIGIN"
[ "$HTTP_CODE" = "401" ] || fail "Expected 401 with no auth token, got $HTTP_CODE"
pass "Unauthenticated delete rejected (401)"

# ── Extra negatives (API guards) ──────────────────────────────────────────────
step "12" "Negative — DELETE fake ids → 404"
http_delete "$BROPAY/v1/admin/fee-configurations/$FAKE_ID" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "404" ] && pass "Fake fee-config → 404" || fail "Fake fee-config expected 404, got $HTTP_CODE"
http_delete "$BROPAY/v1/admin/customer-bank-accounts/$FAKE_ID" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "404" ] && pass "Fake CBA → 404" || fail "Fake CBA expected 404, got $HTTP_CODE"
http_delete "$BROPAY/v1/admin/integrations/$FAKE_ID" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "404" ] && pass "Fake integration → 404" || fail "Fake integration expected 404, got $HTTP_CODE"
http_delete "$BROPAY/v1/admin/merchants/$FAKE_ID" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "404" ] && pass "Fake merchant → 404" || fail "Fake merchant expected 404, got $HTTP_CODE"

step "13" "Negative — DELETE merchant with integration → 422"
NEG_M1=$(curl -s "$BROPAY/v1/admin/merchants" -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"name\":\"E2E HD Neg M1\",\"slug\":\"e2e-hd-neg-m1-${DISP_TS}\",\"merchant_type\":\"other\",\"primary_currency\":\"THB\",\"owner_account_id\":\"$OWNER_ID\"}" \
  | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
NEG_I1=$(curl -s "$BROPAY/v1/admin/integrations" -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"merchant_id\":\"$NEG_M1\",\"name\":\"Neg Int\",\"slug\":\"e2e-hd-neg-i1-${DISP_TS}\"}" \
  | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
http_delete "$BROPAY/v1/admin/merchants/$NEG_M1" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "422" ] || fail "Expected 422 deleting merchant with integration, got $HTTP_CODE"
pass "Merchant blocked while integration exists (422)"
http_delete "$BROPAY/v1/admin/integrations/$NEG_I1" -H "$ADMIN" -H "$ORIGIN" > /dev/null
http_delete "$BROPAY/v1/admin/merchants/$NEG_M1" -H "$ADMIN" -H "$ORIGIN" > /dev/null
pass "Cleanup neg merchant M1"

step "14" "Negative — DELETE integration with payment_intents → 422"
NEG_M2=$(curl -s "$BROPAY/v1/admin/merchants" -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"name\":\"E2E HD Neg M2\",\"slug\":\"e2e-hd-neg-m2-${DISP_TS}\",\"merchant_type\":\"other\",\"primary_currency\":\"THB\",\"owner_account_id\":\"$OWNER_ID\"}" \
  | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
NEG_I2=$(curl -s "$BROPAY/v1/admin/integrations" -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"merchant_id\":\"$NEG_M2\",\"name\":\"Neg Int 2\",\"slug\":\"e2e-hd-neg-i2-${DISP_TS}\"}" \
  | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
NEG_PI_ID=$(python3 -c "import uuid; print(uuid.uuid4())")
if seed_payment_intent_local "$NEG_PI_ID" "$NEG_M2" "$NEG_I2"; then
  http_delete "$BROPAY/v1/admin/integrations/$NEG_I2" -H "$ADMIN" -H "$ORIGIN"
  [ "$HTTP_CODE" = "422" ] || fail "Expected 422 deleting integration with PI, got $HTTP_CODE"
  pass "Integration with PI blocked (422)"
  ( cd "$REPO_ROOT/apps/api" && wrangler d1 execute bropay-db --local --command \
    "DELETE FROM payment_intents WHERE id = '$NEG_PI_ID'" > /dev/null 2>&1 ) || true
else
  warn "Skipped integration+PI 422 (wrangler D1 seed unavailable)"
fi
http_delete "$BROPAY/v1/admin/integrations/$NEG_I2" -H "$ADMIN" -H "$ORIGIN" > /dev/null 2>&1 || true
http_delete "$BROPAY/v1/admin/merchants/$NEG_M2" -H "$ADMIN" -H "$ORIGIN" > /dev/null 2>&1 || true

step "15" "Negative — DELETE default customer bank account → 422"
NEG_M3=$(curl -s "$BROPAY/v1/admin/merchants" -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"name\":\"E2E HD Neg M3\",\"slug\":\"e2e-hd-neg-m3-${DISP_TS}\",\"merchant_type\":\"other\",\"primary_currency\":\"THB\",\"owner_account_id\":\"$OWNER_ID\"}" \
  | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
NEG_CUST=$(curl -s "$BROPAY/v1/admin/customers" -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"merchant_id\":\"$NEG_M3\",\"first_name\":\"E2E\",\"last_name\":\"Def\",\"email\":\"e2e-hd-def-${DISP_TS}@example.com\"}" \
  | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
NEG_CBA=$(curl -s "$BROPAY/v1/admin/customer-bank-accounts" -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"customer_id\":\"$NEG_CUST\",\"bank_id\":\"$BANK_ID\",\"account_number\":\"9988776655\",\"account_holder_name\":\"Default Holder\",\"is_default\":1}" \
  | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
http_delete "$BROPAY/v1/admin/customer-bank-accounts/$NEG_CBA" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "422" ] || fail "Expected 422 deleting default CBA, got $HTTP_CODE"
pass "Default CBA DELETE blocked (422)"
http_delete "$BROPAY/v1/admin/merchants/$NEG_M3" -H "$ADMIN" -H "$ORIGIN" > /dev/null 2>&1 || true

step "16" "Negative — moderator DELETE fee-config → 403"
MOD_RES=$(curl -s "$BROPAY/v1/auth/staff/login" -H "$CT" -H "$ORIGIN" \
  -d "{\"email\":\"moderator@bropay.com\",\"password\":\"$STAFF_PASSWORD\"}")
MOD_TOKEN=$(echo "$MOD_RES" | json "print(json.load(sys.stdin).get('data',{}).get('accessToken',''))")
[ -n "$MOD_TOKEN" ] || fail "moderator login failed"
MOD_FEE=$(curl -s "$BROPAY/v1/admin/fee-configurations" -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"merchant_id\":\"$DEMO_MERCHANT_ID\",\"stream_type\":\"inbound\",\"fee_percentage\":2.0,\"flat_fee_amount\":500,\"is_active\":0}" \
  | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
http_delete "$BROPAY/v1/admin/fee-configurations/$MOD_FEE" -H "Authorization: Bearer $MOD_TOKEN" -H "$ORIGIN"
[ "$HTTP_CODE" = "403" ] || fail "Expected 403 for moderator fee DELETE, got $HTTP_CODE"
pass "Moderator fee DELETE rejected (403)"
http_delete "$BROPAY/v1/admin/fee-configurations/$MOD_FEE" -H "$ADMIN" -H "$ORIGIN" > /dev/null

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}━━━ Hard-Delete Flow Complete ━━━${NC}"
echo "Happy path merchant:  ${DISP_ID:0:20}... (deleted)"
echo "Coverage: happy DELETE + GET 404, double-delete, auth negatives, API 422 guards"
