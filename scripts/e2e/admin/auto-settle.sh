#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Auto-Settle (Cron Trigger)
#
# Endpoints exercised:
#   POST /v1/admin/cron/auto-settle
#
# Scenarios: trigger sweep, verify response shape, 401/403 guards
#
# Auth: requires staff + manage:Settlement permission (super_admin qualifies).
# Note: this is a safe idempotent trigger — running it on a fresh/demo DB
#       returns scheduled=0 which is expected (no auto-settlement-enabled
#       merchants or no eligible transactions). The shape test is what matters.
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

echo -e "${CYAN}━━━ Admin E2E — Auto-Settle Cron ━━━${NC}"

# ── Bootstrap ─────────────────────────────────────────────────────────────────
step 0 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
pass "Admin token acquired (super_admin)"

# ── 1. Trigger auto-settle sweep ─────────────────────────────────────────────
step 1 "POST /v1/admin/cron/auto-settle — trigger sweep"
SWEEP_RES=$(curl -s "$BROPAY/v1/admin/cron/auto-settle" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
HAS_DATA=$(echo "$SWEEP_RES" | json "print('data' in json.load(sys.stdin))")
[ "$HAS_DATA" = "True" ] || fail "Auto-settle response missing data: $SWEEP_RES"
pass "Auto-settle sweep triggered"

# ── 2. Verify response shape ──────────────────────────────────────────────────
step 2 "Verify AutoSettleResult response shape"
HAS_SCHEDULED=$(echo "$SWEEP_RES" | json "print('scheduled' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_SCHEDULED" = "True" ] || fail "Missing 'scheduled' in response"
HAS_SKIPPED_NOT_DUE=$(echo "$SWEEP_RES" | json "print('skipped_not_due' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_SKIPPED_NOT_DUE" = "True" ] || fail "Missing 'skipped_not_due' in response"
HAS_SKIPPED_NO_TXN=$(echo "$SWEEP_RES" | json "print('skipped_no_eligible_txns' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_SKIPPED_NO_TXN" = "True" ] || fail "Missing 'skipped_no_eligible_txns' in response"
HAS_SETTLEMENTS=$(echo "$SWEEP_RES" | json "print('settlements_created' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_SETTLEMENTS" = "True" ] || fail "Missing 'settlements_created' array in response"
SETTLEMENTS_IS_LIST=$(echo "$SWEEP_RES" | json "print(isinstance(json.load(sys.stdin).get('data',{}).get('settlements_created',[]), list))")
[ "$SETTLEMENTS_IS_LIST" = "True" ] || fail "'settlements_created' is not an array"
pass "Response shape valid: scheduled, skipped_not_due, skipped_no_eligible_txns, settlements_created[]"

# ── 3. Numeric types ──────────────────────────────────────────────────────────
step 3 "Verify count fields are non-negative integers"
SCHEDULED=$(echo "$SWEEP_RES" | json "print(json.load(sys.stdin)['data']['scheduled'])")
SKIPPED_NOT_DUE=$(echo "$SWEEP_RES" | json "print(json.load(sys.stdin)['data']['skipped_not_due'])")
SKIPPED_NO_TXN=$(echo "$SWEEP_RES" | json "print(json.load(sys.stdin)['data']['skipped_no_eligible_txns'])")
[ "$SCHEDULED" -ge 0 ] || fail "scheduled must be >= 0, got $SCHEDULED"
[ "$SKIPPED_NOT_DUE" -ge 0 ] || fail "skipped_not_due must be >= 0, got $SKIPPED_NOT_DUE"
[ "$SKIPPED_NO_TXN" -ge 0 ] || fail "skipped_no_eligible_txns must be >= 0, got $SKIPPED_NO_TXN"
pass "Counts: scheduled=$SCHEDULED skipped_not_due=$SKIPPED_NOT_DUE skipped_no_txn=$SKIPPED_NO_TXN"

# ── 4. Idempotent — second trigger is safe ────────────────────────────────────
step 4 "Idempotency — second trigger also succeeds"
SWEEP2_RES=$(curl -s "$BROPAY/v1/admin/cron/auto-settle" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
HAS_DATA2=$(echo "$SWEEP2_RES" | json "print('data' in json.load(sys.stdin))")
[ "$HAS_DATA2" = "True" ] || fail "Second auto-settle trigger failed: $SWEEP2_RES"
pass "Second trigger also returns data (idempotent)"

# ── 5. Guard: no auth → 401 ──────────────────────────────────────────────────
step 5 "Guard: request without auth → 401"
NO_AUTH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/cron/auto-settle" \
  -X POST -H "$ORIGIN" -H "$CT" -d '{}')
NO_AUTH_HTTP=$(echo "$NO_AUTH_RES" | tail -n1)
[ "$NO_AUTH_HTTP" = "401" ] || fail "Expected 401 with no auth, got $NO_AUTH_HTTP"
pass "No-auth guard: 401"

# ── 6. Guard: merchant token → 403 ───────────────────────────────────────────
step 6 "Guard: merchant owner token → 403 (staff-only endpoint)"
MERCH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/cron/auto-settle" \
  -X POST -H "Authorization: Bearer $DEMO_OWNER_TOKEN" -H "$ORIGIN" -H "$CT" -d '{}')
MERCH_HTTP=$(echo "$MERCH_RES" | tail -n1)
[ "$MERCH_HTTP" = "403" ] || fail "Expected 403 for merchant token, got $MERCH_HTTP"
pass "Merchant token correctly rejected (403)"

# ── 7. GET method → 405 ──────────────────────────────────────────────────────
step 7 "GET method → 404/405 (endpoint is POST-only)"
GET_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/cron/auto-settle" \
  -H "$ADMIN" -H "$ORIGIN")
GET_HTTP=$(echo "$GET_RES" | tail -n1)
[ "$GET_HTTP" = "404" ] || [ "$GET_HTTP" = "405" ] || \
  fail "Expected 404 or 405 for GET on POST-only endpoint, got $GET_HTTP"
pass "GET on POST-only endpoint returns $GET_HTTP"

echo -e "\n${GREEN}━━━ Auto-Settle Cron E2E Complete ━━━${NC}"
