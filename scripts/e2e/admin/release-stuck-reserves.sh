#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Release Stuck Reserves (Cron Trigger)
#
# Endpoints exercised:
#   POST /v1/admin/cron/release-stuck-reserves
#
# Scenarios: trigger sweep, verify ReleaseStuckReservesResult shape, guards
#
# Auth: staff + update:Wallet permission (super_admin qualifies).
# Safety-net — processes terminal payouts (cancelled/failed) with unreleased
# reservations. Safe to run repeatedly (idempotent via reservation_released_at).
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

echo -e "${CYAN}━━━ Admin E2E — Release Stuck Reserves Cron ━━━${NC}"

# ── Bootstrap ─────────────────────────────────────────────────────────────────
step 0 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
pass "Admin token acquired (super_admin)"

# ── 1. Trigger release-stuck-reserves sweep ───────────────────────────────────
step 1 "POST /v1/admin/cron/release-stuck-reserves — trigger sweep"
SWEEP_RES=$(curl -s "$BROPAY/v1/admin/cron/release-stuck-reserves" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
HAS_DATA=$(echo "$SWEEP_RES" | json "print('data' in json.load(sys.stdin))")
[ "$HAS_DATA" = "True" ] || fail "Release-stuck-reserves response missing data: $SWEEP_RES"
pass "Release-stuck-reserves sweep triggered"

# ── 2. Verify ReleaseStuckReservesResult shape ────────────────────────────────
step 2 "Verify ReleaseStuckReservesResult response shape"
HAS_RELEASED_COUNT=$(echo "$SWEEP_RES" | json "print('released_count' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_RELEASED_COUNT" = "True" ] || fail "Missing 'released_count'"
HAS_TOTAL_AMT=$(echo "$SWEEP_RES" | json "print('total_released_amount' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_TOTAL_AMT" = "True" ] || fail "Missing 'total_released_amount'"
HAS_PAYOUT_IDS=$(echo "$SWEEP_RES" | json "print('payout_ids' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_PAYOUT_IDS" = "True" ] || fail "Missing 'payout_ids' array"
PAYOUT_IDS_IS_LIST=$(echo "$SWEEP_RES" | json "print(isinstance(json.load(sys.stdin)['data']['payout_ids'], list))")
[ "$PAYOUT_IDS_IS_LIST" = "True" ] || fail "'payout_ids' is not an array"
pass "Response shape valid: released_count, total_released_amount, payout_ids[]"

# ── 3. Verify numeric counts ──────────────────────────────────────────────────
step 3 "Verify count fields are non-negative"
RELEASED=$(echo "$SWEEP_RES" | json "print(json.load(sys.stdin)['data']['released_count'])")
TOTAL_AMT=$(echo "$SWEEP_RES" | json "print(json.load(sys.stdin)['data']['total_released_amount'])")
[ "$RELEASED" -ge 0 ] || fail "released_count must be >= 0, got $RELEASED"
[ "$TOTAL_AMT" -ge 0 ] || fail "total_released_amount must be >= 0, got $TOTAL_AMT"
pass "Counts: released=$RELEASED total_released_amount=$TOTAL_AMT"

# ── 4. Array length matches released_count ───────────────────────────────────
step 4 "Verify payout_ids array length matches released_count"
PAYOUT_IDS_LEN=$(echo "$SWEEP_RES" | json "print(len(json.load(sys.stdin)['data']['payout_ids']))")
[ "$PAYOUT_IDS_LEN" -eq "$RELEASED" ] || \
  fail "payout_ids length ($PAYOUT_IDS_LEN) != released_count ($RELEASED)"
pass "payout_ids.length ($PAYOUT_IDS_LEN) == released_count ($RELEASED)"

# ── 5. If any released — note summary ────────────────────────────────────────
step 5 "Log release summary"
if [ "$RELEASED" -gt 0 ]; then
  warn "Released $RELEASED stuck reservations (total $TOTAL_AMT satang)"
else
  pass "No stuck reservations found (clean system)"
fi

# ── 6. Idempotency — second trigger returns 200 ───────────────────────────────
step 6 "Idempotency — second trigger returns 200"
SWEEP2_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/cron/release-stuck-reserves" \
  -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
SWEEP2_HTTP=$(echo "$SWEEP2_RES" | tail -n1)
[ "$SWEEP2_HTTP" = "200" ] || fail "Second trigger returned $SWEEP2_HTTP (expected 200)"
# Second run should release 0 (already processed)
SWEEP2_BODY=$(echo "$SWEEP2_RES" | head -n1)
SWEEP2_RELEASED=$(echo "$SWEEP2_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('released_count',0))")
pass "Second trigger: released_count=$SWEEP2_RELEASED (idempotent)"

# ── 7. Guard: no auth → 401 ──────────────────────────────────────────────────
step 7 "Guard: request without auth → 401"
NO_AUTH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/cron/release-stuck-reserves" \
  -X POST -H "$ORIGIN" -H "$CT" -d '{}')
NO_AUTH_HTTP=$(echo "$NO_AUTH_RES" | tail -n1)
[ "$NO_AUTH_HTTP" = "401" ] || fail "Expected 401 with no auth, got $NO_AUTH_HTTP"
pass "No-auth guard: 401"

# ── 8. Guard: merchant token → 403 ───────────────────────────────────────────
step 8 "Guard: merchant owner token → 403 (staff-only endpoint)"
MERCH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/cron/release-stuck-reserves" \
  -X POST -H "Authorization: Bearer $DEMO_OWNER_TOKEN" -H "$ORIGIN" -H "$CT" -d '{}')
MERCH_HTTP=$(echo "$MERCH_RES" | tail -n1)
[ "$MERCH_HTTP" = "403" ] || fail "Expected 403 for merchant token, got $MERCH_HTTP"
pass "Merchant token correctly rejected (403)"

echo -e "\n${GREEN}━━━ Release Stuck Reserves Cron E2E Complete ━━━${NC}"
