#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Expire Stale (Cron Trigger)
#
# Endpoints exercised:
#   POST /v1/admin/cron/expire-stale
#
# Scenarios: trigger sweep, verify ExpireStaleResult shape, guards
#
# Auth: staff + manage:PaymentIntent permission (super_admin qualifies).
# Safe to run repeatedly — UPDATE only touches records where expires_at < now
# AND status is non-terminal.
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROPAY="${BROPAY_URL:-http://localhost:8787}"
ORIGIN="Origin: http://localhost:3000"
CT="Content-Type: application/json"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }
warn() { echo -e "${YELLOW}! $1${NC}"; }
step() { echo -e "\n${CYAN}━━━ Step $1: $2 ━━━${NC}"; }
json() { python3 -c "import sys,json; $1" 2>/dev/null; }

echo -e "${CYAN}━━━ Admin E2E — Expire Stale Cron ━━━${NC}"

# ── Bootstrap ─────────────────────────────────────────────────────────────────
step 0 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
pass "Admin token acquired (super_admin)"

# ── 1. Trigger expire-stale sweep ────────────────────────────────────────────
step 1 "POST /v1/admin/cron/expire-stale — trigger sweep"
SWEEP_RES=$(curl -s "$BROPAY/v1/admin/cron/expire-stale" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
HAS_DATA=$(echo "$SWEEP_RES" | json "print('data' in json.load(sys.stdin))")
[ "$HAS_DATA" = "True" ] || fail "Expire-stale response missing data: $SWEEP_RES"
pass "Expire-stale sweep triggered"

# ── 2. Verify ExpireStaleResult shape ─────────────────────────────────────────
step 2 "Verify ExpireStaleResult response shape"
HAS_PI_COUNT=$(echo "$SWEEP_RES" | json "print('payment_intents_expired' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_PI_COUNT" = "True" ] || fail "Missing 'payment_intents_expired'"
HAS_WD_COUNT=$(echo "$SWEEP_RES" | json "print('wallet_deposits_expired' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_WD_COUNT" = "True" ] || fail "Missing 'wallet_deposits_expired'"
HAS_PI_IDS=$(echo "$SWEEP_RES" | json "print('payment_intent_ids' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_PI_IDS" = "True" ] || fail "Missing 'payment_intent_ids'"
HAS_WD_IDS=$(echo "$SWEEP_RES" | json "print('wallet_deposit_ids' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_WD_IDS" = "True" ] || fail "Missing 'wallet_deposit_ids'"
pass "Response shape valid: all four ExpireStaleResult fields present"

# ── 3. Verify numeric types ───────────────────────────────────────────────────
step 3 "Verify count fields are non-negative integers"
PI_EXPIRED=$(echo "$SWEEP_RES" | json "print(json.load(sys.stdin)['data']['payment_intents_expired'])")
WD_EXPIRED=$(echo "$SWEEP_RES" | json "print(json.load(sys.stdin)['data']['wallet_deposits_expired'])")
[ "$PI_EXPIRED" -ge 0 ] || fail "payment_intents_expired must be >= 0, got $PI_EXPIRED"
[ "$WD_EXPIRED" -ge 0 ] || fail "wallet_deposits_expired must be >= 0, got $WD_EXPIRED"
pass "Counts: payment_intents_expired=$PI_EXPIRED wallet_deposits_expired=$WD_EXPIRED"

# ── 4. Verify ID arrays are arrays ───────────────────────────────────────────
step 4 "Verify ID arrays are proper arrays"
PI_IDS_IS_LIST=$(echo "$SWEEP_RES" | json "print(isinstance(json.load(sys.stdin)['data']['payment_intent_ids'], list))")
[ "$PI_IDS_IS_LIST" = "True" ] || fail "'payment_intent_ids' is not an array"
WD_IDS_IS_LIST=$(echo "$SWEEP_RES" | json "print(isinstance(json.load(sys.stdin)['data']['wallet_deposit_ids'], list))")
[ "$WD_IDS_IS_LIST" = "True" ] || fail "'wallet_deposit_ids' is not an array"
pass "Both ID arrays are proper arrays"

# ── 5. Idempotent — second trigger is safe ────────────────────────────────────
step 5 "Idempotency — second trigger returns 200"
SWEEP2_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/cron/expire-stale" \
  -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
SWEEP2_HTTP=$(echo "$SWEEP2_RES" | tail -n1)
[ "$SWEEP2_HTTP" = "200" ] || fail "Second trigger returned $SWEEP2_HTTP (expected 200)"
pass "Second trigger returns 200 (idempotent)"

# ── 6. Guard: no auth → 401 ──────────────────────────────────────────────────
step 6 "Guard: request without auth → 401"
NO_AUTH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/cron/expire-stale" \
  -X POST -H "$ORIGIN" -H "$CT" -d '{}')
NO_AUTH_HTTP=$(echo "$NO_AUTH_RES" | tail -n1)
[ "$NO_AUTH_HTTP" = "401" ] || fail "Expected 401 with no auth, got $NO_AUTH_HTTP"
pass "No-auth guard: 401"

# ── 7. Guard: merchant token → 403 ───────────────────────────────────────────
step 7 "Guard: merchant owner token → 403 (staff-only endpoint)"
MERCH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/cron/expire-stale" \
  -X POST -H "Authorization: Bearer $DEMO_OWNER_TOKEN" -H "$ORIGIN" -H "$CT" -d '{}')
MERCH_HTTP=$(echo "$MERCH_RES" | tail -n1)
[ "$MERCH_HTTP" = "403" ] || fail "Expected 403 for merchant token, got $MERCH_HTTP"
pass "Merchant token correctly rejected (403)"

# ── 8. GET method → 404/405 ──────────────────────────────────────────────────
step 8 "GET method → 404/405 (endpoint is POST-only)"
GET_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/cron/expire-stale" \
  -H "$ADMIN" -H "$ORIGIN")
GET_HTTP=$(echo "$GET_RES" | tail -n1)
[ "$GET_HTTP" = "404" ] || [ "$GET_HTTP" = "405" ] || \
  fail "Expected 404 or 405 for GET, got $GET_HTTP"
pass "GET on POST-only endpoint returns $GET_HTTP"

echo -e "\n${GREEN}━━━ Expire Stale Cron E2E Complete ━━━${NC}"
