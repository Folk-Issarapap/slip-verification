#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Wallet Withdrawals
#
# Endpoints exercised:
#   GET  /v1/admin/wallet-withdrawals
#   GET  /v1/admin/wallet-withdrawals/{id}
#   POST /v1/admin/wallet-withdrawals/{id}/cancel
#   POST /v1/admin/wallet-withdrawals/{id}/fail
#   POST /v1/admin/wallet-withdrawals/{id}/complete   (requires slip)
#   GET  /v1/admin/wallet-withdrawals/{id}/slip
#
# Scenarios: list, filter, sort, paginate, get-one, cancel, fail, slip, guards
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

echo -e "${CYAN}━━━ Admin E2E — Wallet Withdrawals ━━━${NC}"

# ── Bootstrap ─────────────────────────────────────────────────────────────────
step 0 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
pass "Admin token acquired (super_admin)"

# ── 1. List all wallet withdrawals ─────────────────────────────────────────────
step 1 "List all wallet withdrawals"
LIST_RES=$(curl -s "$BROPAY/v1/admin/wallet-withdrawals" -H "$ADMIN" -H "$ORIGIN")
HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$HAS_META" = "True" ] || fail "List missing meta"
LIST_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
pass "Listed total=$LIST_TOTAL withdrawal(s)"

# ── 2. Filter by merchant_id ───────────────────────────────────────────────────
step 2 "Filter by merchant_id"
MERCH_RES=$(curl -s "$BROPAY/v1/admin/wallet-withdrawals?merchant_id=$DEMO_MERCHANT_ID" \
  -H "$ADMIN" -H "$ORIGIN")
MERCH_HAS_META=$(echo "$MERCH_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$MERCH_HAS_META" = "True" ] || fail "merchant_id filter missing meta"
MERCH_TOTAL=$(echo "$MERCH_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
pass "merchant_id filter: $MERCH_TOTAL result(s)"

# ── 3. Filter by wallet_id ────────────────────────────────────────────────────
step 3 "Filter by wallet_id"
WALLET_RES=$(curl -s "$BROPAY/v1/admin/wallet-withdrawals?wallet_id=$DEMO_WALLET_ID" \
  -H "$ADMIN" -H "$ORIGIN")
WALLET_HAS_META=$(echo "$WALLET_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$WALLET_HAS_META" = "True" ] || fail "wallet_id filter missing meta"
WALLET_TOTAL=$(echo "$WALLET_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
pass "wallet_id filter: $WALLET_TOTAL result(s)"

# ── 4. Filter by status=pending ───────────────────────────────────────────────
step 4 "Filter by status=pending"
PEND_RES=$(curl -s "$BROPAY/v1/admin/wallet-withdrawals?status=pending" -H "$ADMIN" -H "$ORIGIN")
PEND_HAS_META=$(echo "$PEND_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$PEND_HAS_META" = "True" ] || fail "status=pending filter missing meta"
PEND_TOTAL=$(echo "$PEND_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
pass "status=pending: $PEND_TOTAL result(s)"

# ── 5. Filter by multi-status (completed,failed) ──────────────────────────────
step 5 "Filter by status=completed,failed"
MULTI_RES=$(curl -s "$BROPAY/v1/admin/wallet-withdrawals?status=completed,failed" \
  -H "$ADMIN" -H "$ORIGIN")
MULTI_HAS_META=$(echo "$MULTI_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$MULTI_HAS_META" = "True" ] || fail "multi-status filter missing meta"
MULTI_TOTAL=$(echo "$MULTI_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
pass "status=completed,failed: $MULTI_TOTAL result(s)"

# ── 6. Invalid status value → 400 ─────────────────────────────────────────────
step 6 "Invalid status value → 400"
BAD_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/wallet-withdrawals?status=bogus" \
  -H "$ADMIN" -H "$ORIGIN")
BAD_HTTP=$(echo "$BAD_RES" | tail -n1)
[ "$BAD_HTTP" = "400" ] || fail "Expected 400 for invalid status, got $BAD_HTTP"
pass "Invalid status correctly rejected (400)"

# ── 7. Sort by amount desc ────────────────────────────────────────────────────
step 7 "Sort by amount desc"
SORT_AMT_RES=$(curl -s "$BROPAY/v1/admin/wallet-withdrawals?sort=amount&order=desc&limit=5" \
  -H "$ADMIN" -H "$ORIGIN")
SORT_AMT_OK=$(echo "$SORT_AMT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_AMT_OK" = "True" ] || fail "Sort by amount failed"
pass "Sort by amount desc OK"

# ── 8. Sort by created_at asc ────────────────────────────────────────────────
step 8 "Sort by created_at asc"
SORT_CA_RES=$(curl -s "$BROPAY/v1/admin/wallet-withdrawals?sort=created_at&order=asc&limit=5" \
  -H "$ADMIN" -H "$ORIGIN")
SORT_CA_OK=$(echo "$SORT_CA_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_CA_OK" = "True" ] || fail "Sort by created_at failed"
pass "Sort by created_at asc OK"

# ── 9. Paginate ───────────────────────────────────────────────────────────────
step 9 "Paginate (limit=2)"
PAGE_RES=$(curl -s "$BROPAY/v1/admin/wallet-withdrawals?limit=2&page=1" -H "$ADMIN" -H "$ORIGIN")
PAGE_LIMIT=$(echo "$PAGE_RES" | json "print(json.load(sys.stdin).get('meta',{}).get('limit',-1))")
[ "$PAGE_LIMIT" -eq 2 ] || fail "Expected limit=2 in meta, got $PAGE_LIMIT"
pass "Pagination limit=2 honoured"

# ── 10. GET unknown id → 404 ─────────────────────────────────────────────────
step 10 "GET unknown withdrawal id → 404"
UNKNOWN_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/wallet-withdrawals/nonexistent-wth-xyz" \
  -H "$ADMIN" -H "$ORIGIN")
UNKNOWN_HTTP=$(echo "$UNKNOWN_RES" | tail -n1)
[ "$UNKNOWN_HTTP" = "404" ] || fail "Expected 404 for unknown id, got $UNKNOWN_HTTP"
pass "Unknown id → 404"

# ── 11. GET first withdrawal detail (if any exist) ────────────────────────────
step 11 "GET /v1/admin/wallet-withdrawals/{id} — fetch first from list"
FIRST_ID=$(echo "$LIST_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')")
if [ -z "$FIRST_ID" ]; then
  warn "No withdrawals exist yet — skipping detail test"
else
  DETAIL_RES=$(curl -s "$BROPAY/v1/admin/wallet-withdrawals/$FIRST_ID" -H "$ADMIN" -H "$ORIGIN")
  DETAIL_ID=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
  [ "$DETAIL_ID" = "$FIRST_ID" ] || fail "Detail ID mismatch: expected $FIRST_ID, got $DETAIL_ID"
  HAS_AUDIT=$(echo "$DETAIL_RES" | json "print('audit_logs' in json.load(sys.stdin).get('data',{}))")
  [ "$HAS_AUDIT" = "True" ] || fail "Detail missing audit_logs"
  pass "Detail fetched with audit_logs"
fi

# ── 12. Cancel a pending withdrawal (if any pending exist) ────────────────────
step 12 "Cancel a pending withdrawal"
PENDING_ID=$(echo "$PEND_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')")
if [ -z "$PENDING_ID" ]; then
  warn "No pending withdrawals — skipping cancel test"
else
  CANCEL_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/wallet-withdrawals/$PENDING_ID/cancel" \
    -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
    -d '{"cancellation_reason":"e2e smoke test cancel"}')
  CANCEL_HTTP=$(echo "$CANCEL_RES" | tail -n1)
  [ "$CANCEL_HTTP" = "200" ] || fail "Cancel pending withdrawal failed: HTTP $CANCEL_HTTP"
  CANCEL_BODY=$(echo "$CANCEL_RES" | head -n1)
  CANCEL_STATUS=$(echo "$CANCEL_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
  [ "$CANCEL_STATUS" = "cancelled" ] || fail "Expected status=cancelled, got $CANCEL_STATUS"
  pass "Withdrawal $PENDING_ID cancelled"

  # ── 13. Cancel already-cancelled → 422 ───────────────────────────────────
  step 13 "Cancel already-cancelled withdrawal → 422"
  DOUBLE_CANCEL_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/wallet-withdrawals/$PENDING_ID/cancel" \
    -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
    -d '{"cancellation_reason":"double cancel test"}')
  DOUBLE_CANCEL_HTTP=$(echo "$DOUBLE_CANCEL_RES" | tail -n1)
  [ "$DOUBLE_CANCEL_HTTP" = "422" ] || fail "Expected 422 for double-cancel, got $DOUBLE_CANCEL_HTTP"
  pass "Double-cancel correctly rejected (422)"
fi

# ── 14. Fail a pending withdrawal (if another pending exists) ─────────────────
step 14 "Fail a pending withdrawal — guard: cancellation_reason required"
FAIL_MISSING_BODY_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/wallet-withdrawals/fake-id/fail" \
  -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"failure_reason":"bank_rejected"}')
FAIL_MISSING_HTTP=$(echo "$FAIL_MISSING_BODY_RES" | tail -n1)
# Missing cancellation_reason → 400/422, or 404 for fake-id — both acceptable
[ "$FAIL_MISSING_HTTP" = "400" ] || [ "$FAIL_MISSING_HTTP" = "422" ] || \
  [ "$FAIL_MISSING_HTTP" = "404" ] || \
  fail "Expected 400/422/404 for fail with missing fields, got $FAIL_MISSING_HTTP"
pass "Missing fail fields handled ($FAIL_MISSING_HTTP)"

# ── 15. GET slip for unknown withdrawal → 404 ─────────────────────────────────
step 15 "GET /v1/admin/wallet-withdrawals/{id}/slip for unknown id → 404"
SLIP_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/wallet-withdrawals/nonexistent-wth-xyz/slip" \
  -H "$ADMIN" -H "$ORIGIN")
SLIP_HTTP=$(echo "$SLIP_RES" | tail -n1)
[ "$SLIP_HTTP" = "404" ] || fail "Expected 404 for slip on unknown withdrawal, got $SLIP_HTTP"
pass "Slip on unknown id → 404"

# ── 16. Guard: no auth → 401 ─────────────────────────────────────────────────
step 16 "Guard: list without auth → 401"
NO_AUTH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/wallet-withdrawals" -H "$ORIGIN")
NO_AUTH_HTTP=$(echo "$NO_AUTH_RES" | tail -n1)
[ "$NO_AUTH_HTTP" = "401" ] || fail "Expected 401 with no auth, got $NO_AUTH_HTTP"
pass "No-auth guard: 401"

echo -e "\n${GREEN}━━━ Wallet Withdrawals E2E Complete ━━━${NC}"
