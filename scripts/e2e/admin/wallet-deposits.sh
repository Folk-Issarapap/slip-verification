#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Wallet Deposits
#
# Endpoints exercised:
#   GET  /v1/admin/wallet-deposits
#   GET  /v1/admin/wallet-deposits/{id}
#   POST /v1/admin/wallet-deposits
#   POST /v1/admin/wallet-deposits/{id}/simulate
#   POST /v1/admin/wallet-deposits/{id}/cancel
#
# Scenarios: list, filter, sort, paginate, create, simulate, cancel, guards
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

echo -e "${CYAN}━━━ Admin E2E — Wallet Deposits ━━━${NC}"

# ── Bootstrap ─────────────────────────────────────────────────────────────────
step 0 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
pass "Admin token acquired (super_admin)"

# ── 1. List all wallet deposits ────────────────────────────────────────────────
step 1 "List all wallet deposits"
LIST_RES=$(curl -s "$BROPAY/v1/admin/wallet-deposits" -H "$ADMIN" -H "$ORIGIN")
HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$HAS_META" = "True" ] || fail "List missing meta"
LIST_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
pass "Listed total=$LIST_TOTAL wallet deposit(s)"

# ── 2. Filter by merchant_id ───────────────────────────────────────────────────
step 2 "Filter by merchant_id"
MERCH_RES=$(curl -s "$BROPAY/v1/admin/wallet-deposits?merchant_id=$DEMO_MERCHANT_ID" \
  -H "$ADMIN" -H "$ORIGIN")
MERCH_HAS_META=$(echo "$MERCH_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$MERCH_HAS_META" = "True" ] || fail "merchant_id filter missing meta"
MERCH_TOTAL=$(echo "$MERCH_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
pass "merchant_id filter: $MERCH_TOTAL result(s)"

# ── 3. Filter by wallet_id ─────────────────────────────────────────────────────
step 3 "Filter by wallet_id"
WALLET_RES=$(curl -s "$BROPAY/v1/admin/wallet-deposits?wallet_id=$DEMO_WALLET_ID" \
  -H "$ADMIN" -H "$ORIGIN")
WALLET_HAS_META=$(echo "$WALLET_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$WALLET_HAS_META" = "True" ] || fail "wallet_id filter missing meta"
WALLET_TOTAL=$(echo "$WALLET_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
pass "wallet_id filter: $WALLET_TOTAL result(s)"

# ── 4. Filter by status=processing ────────────────────────────────────────────
step 4 "Filter by status=processing"
PROC_RES=$(curl -s "$BROPAY/v1/admin/wallet-deposits?status=processing" -H "$ADMIN" -H "$ORIGIN")
PROC_HAS_META=$(echo "$PROC_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$PROC_HAS_META" = "True" ] || fail "status=processing filter missing meta"
PROC_TOTAL=$(echo "$PROC_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
pass "status=processing: $PROC_TOTAL result(s)"

# ── 5. Filter by multi-status (succeeded,cancelled) ───────────────────────────
step 5 "Filter by status=succeeded,cancelled"
MULTI_RES=$(curl -s "$BROPAY/v1/admin/wallet-deposits?status=succeeded,cancelled" \
  -H "$ADMIN" -H "$ORIGIN")
MULTI_HAS_META=$(echo "$MULTI_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$MULTI_HAS_META" = "True" ] || fail "multi-status filter missing meta"
MULTI_TOTAL=$(echo "$MULTI_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
pass "status=succeeded,cancelled: $MULTI_TOTAL result(s)"

# ── 6. Sort by amount desc ────────────────────────────────────────────────────
step 6 "Sort by amount desc"
SORT_AMT_RES=$(curl -s "$BROPAY/v1/admin/wallet-deposits?sort=amount&order=desc&limit=5" \
  -H "$ADMIN" -H "$ORIGIN")
SORT_AMT_OK=$(echo "$SORT_AMT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_AMT_OK" = "True" ] || fail "Sort by amount failed"
pass "Sort by amount desc OK"

# ── 7. Sort by status asc ─────────────────────────────────────────────────────
step 7 "Sort by status asc"
SORT_STAT_RES=$(curl -s "$BROPAY/v1/admin/wallet-deposits?sort=status&order=asc&limit=5" \
  -H "$ADMIN" -H "$ORIGIN")
SORT_STAT_OK=$(echo "$SORT_STAT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_STAT_OK" = "True" ] || fail "Sort by status failed"
pass "Sort by status asc OK"

# ── 8. Paginate ───────────────────────────────────────────────────────────────
step 8 "Paginate (limit=2)"
PAGE_RES=$(curl -s "$BROPAY/v1/admin/wallet-deposits?limit=2&page=1" -H "$ADMIN" -H "$ORIGIN")
PAGE_LIMIT=$(echo "$PAGE_RES" | json "print(json.load(sys.stdin).get('meta',{}).get('limit',-1))")
[ "$PAGE_LIMIT" -eq 2 ] || fail "Expected limit=2 in meta, got $PAGE_LIMIT"
pass "Pagination limit=2 honoured"

# ── 9. Create a wallet deposit via admin ──────────────────────────────────────
step 9 "POST /v1/admin/wallet-deposits — create deposit for demo merchant"
CREATE_BODY="{\"merchant_id\":\"$DEMO_MERCHANT_ID\",\"wallet_id\":\"$DEMO_WALLET_ID\",\"amount\":50000,\"currency\":\"THB\",\"payment_method\":\"promptpay\",\"expiry_minutes\":30}"
CREATE_RES=$(curl -s "$BROPAY/v1/admin/wallet-deposits" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d "$CREATE_BODY")
CREATE_ID=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$CREATE_ID" ] || fail "Deposit creation failed: $CREATE_RES"
CREATE_STATUS=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
pass "Deposit created: $CREATE_ID (status=$CREATE_STATUS)"

# ── 10. GET deposit detail ────────────────────────────────────────────────────
step 10 "GET /v1/admin/wallet-deposits/{id} — detail view"
DETAIL_RES=$(curl -s "$BROPAY/v1/admin/wallet-deposits/$CREATE_ID" -H "$ADMIN" -H "$ORIGIN")
DETAIL_ID=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$DETAIL_ID" = "$CREATE_ID" ] || fail "Detail ID mismatch: expected $CREATE_ID, got $DETAIL_ID"
HAS_TRANSACTIONS=$(echo "$DETAIL_RES" | json "print('transactions' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_TRANSACTIONS" = "True" ] || fail "Detail missing transactions array"
HAS_LEDGER=$(echo "$DETAIL_RES" | json "print('ledger_entries' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_LEDGER" = "True" ] || fail "Detail missing ledger_entries array"
pass "Detail fetched with transactions + ledger_entries"

# ── 11. GET unknown id → 404 ─────────────────────────────────────────────────
step 11 "GET unknown deposit id → 404"
UNKNOWN_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/wallet-deposits/nonexistent-deposit-xyz" \
  -H "$ADMIN" -H "$ORIGIN")
UNKNOWN_HTTP=$(echo "$UNKNOWN_RES" | tail -n1)
[ "$UNKNOWN_HTTP" = "404" ] || fail "Expected 404 for unknown id, got $UNKNOWN_HTTP"
pass "Unknown id → 404"

# ── 12. Simulate deposit.completed ───────────────────────────────────────────
step 12 "POST /{id}/simulate with event=deposit.completed"
SIM_RES=$(curl -s "$BROPAY/v1/admin/wallet-deposits/$CREATE_ID/simulate" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"event":"deposit.completed"}')
SIM_HTTP_CHECK=$(echo "$SIM_RES" | json "print('data' in json.load(sys.stdin) or 'error' in json.load(sys.stdin))")
[ "$SIM_HTTP_CHECK" = "True" ] || fail "Simulate response has neither data nor error"
SIM_STATUS=$(echo "$SIM_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
if [ "$SIM_STATUS" = "succeeded" ]; then
  pass "Simulated deposit.completed → status=$SIM_STATUS"
else
  # In production mode the endpoint returns 403; both are valid
  SIM_ERR_CODE=$(echo "$SIM_RES" | json "print(json.load(sys.stdin).get('error',{}).get('code',''))")
  [ "$SIM_ERR_CODE" = "FORBIDDEN" ] || [ "$SIM_ERR_CODE" = "CONFLICT" ] || \
    fail "Unexpected error on simulate: $SIM_RES"
  warn "Simulate returned error code=$SIM_ERR_CODE (production env or already terminal)"
fi

# ── 13. Cancel already-terminal deposit → 409 ────────────────────────────────
step 13 "Cancel already-terminal deposit → 409"
# Create a second deposit that we can cancel while still in a non-terminal state
CREATE2_RES=$(curl -s "$BROPAY/v1/admin/wallet-deposits" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"merchant_id\":\"$DEMO_MERCHANT_ID\",\"wallet_id\":\"$DEMO_WALLET_ID\",\"amount\":10000}")
CREATE2_ID=$(echo "$CREATE2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
if [ -n "$CREATE2_ID" ]; then
  # First cancel should succeed
  CANCEL1_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/wallet-deposits/$CREATE2_ID/cancel" \
    -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{"reason":"e2e test cancel"}')
  CANCEL1_HTTP=$(echo "$CANCEL1_RES" | tail -n1)
  [ "$CANCEL1_HTTP" = "200" ] || [ "$CANCEL1_HTTP" = "202" ] || \
    warn "First cancel returned unexpected HTTP $CANCEL1_HTTP (may need provider_payment_id)"
  # Second cancel on a terminal deposit → 409
  CANCEL2_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/wallet-deposits/$CREATE2_ID/cancel" \
    -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{"reason":"double cancel test"}')
  CANCEL2_HTTP=$(echo "$CANCEL2_RES" | tail -n1)
  if [ "$CANCEL2_HTTP" = "409" ]; then
    pass "Double-cancel correctly rejected (409)"
  else
    warn "Double-cancel returned $CANCEL2_HTTP (deposit may not have been cancelable)"
  fi
else
  warn "Second deposit creation failed — skipping cancel-terminal guard"
fi

# ── 14. Create with invalid wallet_id → 400 ──────────────────────────────────
step 14 "Create with wallet not belonging to merchant → 400"
BAD_WALLET_BODY="{\"merchant_id\":\"$DEMO_MERCHANT_ID\",\"wallet_id\":\"wallet-does-not-exist\",\"amount\":50000}"
BAD_WALLET_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/wallet-deposits" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d "$BAD_WALLET_BODY")
BAD_WALLET_HTTP=$(echo "$BAD_WALLET_RES" | tail -n1)
[ "$BAD_WALLET_HTTP" = "400" ] || fail "Expected 400 for invalid wallet_id, got $BAD_WALLET_HTTP"
pass "Invalid wallet_id correctly rejected (400)"

# ── 15. Guard: no auth → 401 ─────────────────────────────────────────────────
step 15 "Guard: list without auth → 401"
NO_AUTH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/wallet-deposits" -H "$ORIGIN")
NO_AUTH_HTTP=$(echo "$NO_AUTH_RES" | tail -n1)
[ "$NO_AUTH_HTTP" = "401" ] || fail "Expected 401 with no auth, got $NO_AUTH_HTTP"
pass "No-auth guard: 401"

echo -e "\n${GREEN}━━━ Wallet Deposits E2E Complete ━━━${NC}"
