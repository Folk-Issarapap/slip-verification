#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Reconcile Wallets (Cron Trigger)
#
# Endpoints exercised:
#   POST /v1/admin/cron/reconcile-wallets
#
# Scenarios: trigger sweep, verify ReconcileWalletsResult shape, guards
#
# Auth: staff + update:Wallet permission (super_admin qualifies).
# Detection-only — does NOT apply corrections. Safe to trigger repeatedly.
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

echo -e "${CYAN}━━━ Admin E2E — Reconcile Wallets Cron ━━━${NC}"

# ── Bootstrap ─────────────────────────────────────────────────────────────────
step 0 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
pass "Admin token acquired (super_admin)"

# ── 1. Trigger reconcile-wallets sweep ───────────────────────────────────────
step 1 "POST /v1/admin/cron/reconcile-wallets — trigger sweep"
SWEEP_RES=$(curl -s "$BROPAY/v1/admin/cron/reconcile-wallets" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
HAS_DATA=$(echo "$SWEEP_RES" | json "print('data' in json.load(sys.stdin))")
[ "$HAS_DATA" = "True" ] || fail "Reconcile-wallets response missing data: $SWEEP_RES"
pass "Reconcile-wallets sweep triggered"

# ── 2. Verify ReconcileWalletsResult shape ────────────────────────────────────
step 2 "Verify ReconcileWalletsResult response shape"
HAS_CHECKED=$(echo "$SWEEP_RES" | json "print('checked_count' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_CHECKED" = "True" ] || fail "Missing 'checked_count'"
HAS_MISMATCHED=$(echo "$SWEEP_RES" | json "print('mismatched_count' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_MISMATCHED" = "True" ] || fail "Missing 'mismatched_count'"
HAS_MISMATCHES=$(echo "$SWEEP_RES" | json "print('mismatches' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_MISMATCHES" = "True" ] || fail "Missing 'mismatches' array"
MISMATCHES_IS_LIST=$(echo "$SWEEP_RES" | json "print(isinstance(json.load(sys.stdin)['data']['mismatches'], list))")
[ "$MISMATCHES_IS_LIST" = "True" ] || fail "'mismatches' is not an array"
pass "Response shape valid: checked_count, mismatched_count, mismatches[]"

# ── 3. Verify numeric counts ──────────────────────────────────────────────────
step 3 "Verify count fields are non-negative integers"
CHECKED=$(echo "$SWEEP_RES" | json "print(json.load(sys.stdin)['data']['checked_count'])")
MISMATCHED=$(echo "$SWEEP_RES" | json "print(json.load(sys.stdin)['data']['mismatched_count'])")
[ "$CHECKED" -ge 0 ] || fail "checked_count must be >= 0, got $CHECKED"
[ "$MISMATCHED" -ge 0 ] || fail "mismatched_count must be >= 0, got $MISMATCHED"
pass "Counts: checked=$CHECKED mismatched=$MISMATCHED"

# ── 4. checked_count >= mismatched_count invariant ───────────────────────────
step 4 "Verify checked_count >= mismatched_count (subset invariant)"
INVARIANT_OK=$(echo "$SWEEP_RES" | json "d=json.load(sys.stdin)['data']; print(d['checked_count'] >= d['mismatched_count'])")
[ "$INVARIANT_OK" = "True" ] || fail "checked_count < mismatched_count — invariant violated"
pass "checked_count ($CHECKED) >= mismatched_count ($MISMATCHED)"

# ── 5. mismatches array shape (if any) ───────────────────────────────────────
step 5 "Verify mismatch item shape (if any mismatches found)"
MISMATCH_COUNT_FROM_ARRAY=$(echo "$SWEEP_RES" | json "print(len(json.load(sys.stdin)['data']['mismatches']))")
if [ "$MISMATCH_COUNT_FROM_ARRAY" -gt 0 ]; then
  FIRST_MISMATCH=$(echo "$SWEEP_RES" | json "print(json.dumps(json.load(sys.stdin)['data']['mismatches'][0]))")
  HAS_WALLET_ID=$(echo "$FIRST_MISMATCH" | json "print('wallet_id' in json.load(sys.stdin))")
  [ "$HAS_WALLET_ID" = "True" ] || fail "Mismatch item missing wallet_id"
  HAS_AVAILABLE=$(echo "$FIRST_MISMATCH" | json "print('available' in json.load(sys.stdin))")
  [ "$HAS_AVAILABLE" = "True" ] || fail "Mismatch item missing available"
  HAS_RESERVED=$(echo "$FIRST_MISMATCH" | json "print('reserved' in json.load(sys.stdin))")
  [ "$HAS_RESERVED" = "True" ] || fail "Mismatch item missing reserved"
  warn "Detected $MISMATCH_COUNT_FROM_ARRAY wallet mismatch(es) — first: $FIRST_MISMATCH"
else
  pass "No mismatches detected (healthy wallet ledger)"
fi

# ── 6. Idempotent — second trigger is safe ────────────────────────────────────
step 6 "Idempotency — second trigger returns 200"
SWEEP2_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/cron/reconcile-wallets" \
  -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
SWEEP2_HTTP=$(echo "$SWEEP2_RES" | tail -n1)
[ "$SWEEP2_HTTP" = "200" ] || fail "Second trigger returned $SWEEP2_HTTP (expected 200)"
pass "Second trigger returns 200 (idempotent)"

# ── 7. Guard: no auth → 401 ──────────────────────────────────────────────────
step 7 "Guard: request without auth → 401"
NO_AUTH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/cron/reconcile-wallets" \
  -X POST -H "$ORIGIN" -H "$CT" -d '{}')
NO_AUTH_HTTP=$(echo "$NO_AUTH_RES" | tail -n1)
[ "$NO_AUTH_HTTP" = "401" ] || fail "Expected 401 with no auth, got $NO_AUTH_HTTP"
pass "No-auth guard: 401"

# ── 8. Guard: merchant token → 403 ───────────────────────────────────────────
step 8 "Guard: merchant owner token → 403 (staff-only endpoint)"
MERCH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/cron/reconcile-wallets" \
  -X POST -H "Authorization: Bearer $DEMO_OWNER_TOKEN" -H "$ORIGIN" -H "$CT" -d '{}')
MERCH_HTTP=$(echo "$MERCH_RES" | tail -n1)
[ "$MERCH_HTTP" = "403" ] || fail "Expected 403 for merchant token, got $MERCH_HTTP"
pass "Merchant token correctly rejected (403)"

echo -e "\n${GREEN}━━━ Reconcile Wallets Cron E2E Complete ━━━${NC}"
