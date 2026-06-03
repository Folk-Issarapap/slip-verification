#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Email Outbox (Ops Diagnostics)
#
# Endpoints exercised:
#   GET /v1/admin/email-outbox
#   GET /v1/admin/email-outbox/{id}
#
# Scenarios: list, filter by status, search, sort, paginate, get-one, guards
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

echo -e "${CYAN}━━━ Admin E2E — Email Outbox ━━━${NC}"

# ── Bootstrap ─────────────────────────────────────────────────────────────────
step 0 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
OWNER="Authorization: Bearer $DEMO_OWNER_TOKEN"
pass "Admin token acquired (super_admin)"

# ── 1. List email outbox ───────────────────────────────────────────────────────
step 1 "List email outbox — verify meta and data array"
LIST_RES=$(curl -s "$BROPAY/v1/admin/email-outbox" -H "$ADMIN" -H "$ORIGIN")
HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$HAS_META" = "True" ] || fail "List missing meta"
HAS_DATA=$(echo "$LIST_RES" | json "print('data' in json.load(sys.stdin))")
[ "$HAS_DATA" = "True" ] || fail "List missing data array"
LIST_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
pass "Email outbox list OK (total=$LIST_TOTAL)"

# ── 2. Filter by status=sent ──────────────────────────────────────────────────
step 2 "Filter by status=sent"
SENT_RES=$(curl -s "$BROPAY/v1/admin/email-outbox?status=sent" -H "$ADMIN" -H "$ORIGIN")
SENT_HAS_META=$(echo "$SENT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SENT_HAS_META" = "True" ] || fail "status=sent filter missing meta"
SENT_TOTAL=$(echo "$SENT_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
pass "status=sent: $SENT_TOTAL result(s)"

# ── 3. Filter by status=failed ────────────────────────────────────────────────
step 3 "Filter by status=failed"
FAIL_RES=$(curl -s "$BROPAY/v1/admin/email-outbox?status=failed" -H "$ADMIN" -H "$ORIGIN")
FAIL_HAS_META=$(echo "$FAIL_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$FAIL_HAS_META" = "True" ] || fail "status=failed filter missing meta"
FAIL_TOTAL=$(echo "$FAIL_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
pass "status=failed: $FAIL_TOTAL result(s)"

# ── 4. Filter by status=pending ───────────────────────────────────────────────
step 4 "Filter by status=pending"
PEND_RES=$(curl -s "$BROPAY/v1/admin/email-outbox?status=pending" -H "$ADMIN" -H "$ORIGIN")
PEND_HAS_META=$(echo "$PEND_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$PEND_HAS_META" = "True" ] || fail "status=pending filter missing meta"
PEND_TOTAL=$(echo "$PEND_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
pass "status=pending: $PEND_TOTAL result(s)"

# ── 5. Filter by status=dead ──────────────────────────────────────────────────
step 5 "Filter by status=dead"
DEAD_RES=$(curl -s "$BROPAY/v1/admin/email-outbox?status=dead" -H "$ADMIN" -H "$ORIGIN")
DEAD_HAS_META=$(echo "$DEAD_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$DEAD_HAS_META" = "True" ] || fail "status=dead filter missing meta"
DEAD_TOTAL=$(echo "$DEAD_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
pass "status=dead: $DEAD_TOTAL result(s)"

# ── 6. Invalid status → 400 ───────────────────────────────────────────────────
step 6 "Invalid status value → 400"
BAD_STATUS_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/email-outbox?status=bogus" -H "$ADMIN" -H "$ORIGIN")
BAD_STATUS_HTTP=$(echo "$BAD_STATUS_RES" | tail -n1)
[ "$BAD_STATUS_HTTP" = "400" ] || fail "Expected 400 for invalid status, got $BAD_STATUS_HTTP"
pass "Invalid status correctly rejected (400)"

# ── 7. Search by q (to_address fragment) ─────────────────────────────────────
step 7 "Search by q= (email recipient fragment)"
Q_RES=$(curl -s "$BROPAY/v1/admin/email-outbox?q=bropay" -H "$ADMIN" -H "$ORIGIN")
Q_HAS_META=$(echo "$Q_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$Q_HAS_META" = "True" ] || fail "Search q=bropay missing meta"
Q_TOTAL=$(echo "$Q_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
pass "q=bropay: $Q_TOTAL result(s)"

# ── 8. Sort by attempt_count desc ────────────────────────────────────────────
step 8 "Sort by attempt_count desc"
SORT_ATTEMPT_RES=$(curl -s "$BROPAY/v1/admin/email-outbox?sort=attempt_count&order=desc&limit=5" -H "$ADMIN" -H "$ORIGIN")
SORT_ATTEMPT_OK=$(echo "$SORT_ATTEMPT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_ATTEMPT_OK" = "True" ] || fail "Sort by attempt_count failed"
pass "Sort by attempt_count desc OK"

# ── 9. Sort by next_retry_at asc ─────────────────────────────────────────────
step 9 "Sort by next_retry_at asc"
SORT_RETRY_RES=$(curl -s "$BROPAY/v1/admin/email-outbox?sort=next_retry_at&order=asc&limit=5" -H "$ADMIN" -H "$ORIGIN")
SORT_RETRY_OK=$(echo "$SORT_RETRY_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_RETRY_OK" = "True" ] || fail "Sort by next_retry_at failed"
pass "Sort by next_retry_at asc OK"

# ── 10. Sort by created_at asc ───────────────────────────────────────────────
step 10 "Sort by created_at asc"
SORT_CREATED_RES=$(curl -s "$BROPAY/v1/admin/email-outbox?sort=created_at&order=asc&limit=5" -H "$ADMIN" -H "$ORIGIN")
SORT_CREATED_OK=$(echo "$SORT_CREATED_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_CREATED_OK" = "True" ] || fail "Sort by created_at failed"
pass "Sort by created_at asc OK"

# ── 11. Paginate ──────────────────────────────────────────────────────────────
step 11 "Paginate (limit=1, page=1)"
PAGE_RES=$(curl -s "$BROPAY/v1/admin/email-outbox?limit=1&page=1" -H "$ADMIN" -H "$ORIGIN")
PAGE_LIMIT=$(echo "$PAGE_RES" | json "print(json.load(sys.stdin).get('meta',{}).get('limit',-1))")
[ "$PAGE_LIMIT" -eq 1 ] || fail "Expected limit=1 in meta, got $PAGE_LIMIT"
pass "Pagination limit=1 honoured"

# ── 12. Get one — by ID from list ────────────────────────────────────────────
step 12 "GET /v1/admin/email-outbox/{id} — fetch first from list (if any)"
FIRST_ID=$(echo "$LIST_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')")
if [ -z "$FIRST_ID" ]; then
  warn "No email outbox rows exist yet — skipping get-one test (table is empty on a fresh install)"
else
  DETAIL_RES=$(curl -s "$BROPAY/v1/admin/email-outbox/$FIRST_ID" -H "$ADMIN" -H "$ORIGIN")
  DETAIL_ID=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
  [ "$DETAIL_ID" = "$FIRST_ID" ] || fail "Detail ID mismatch: expected $FIRST_ID, got $DETAIL_ID"
  DETAIL_HAS_STATUS=$(echo "$DETAIL_RES" | json "print('status' in json.load(sys.stdin).get('data',{}))")
  [ "$DETAIL_HAS_STATUS" = "True" ] || fail "Detail missing status field"
  pass "Detail fetched: id=$DETAIL_ID"
fi

# ── 13. GET unknown ID → 404 ─────────────────────────────────────────────────
step 13 "GET /v1/admin/email-outbox/{id} with unknown id → 404"
UNKNOWN_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/email-outbox/nonexistent-id-xyz" \
  -H "$ADMIN" -H "$ORIGIN")
UNKNOWN_HTTP=$(echo "$UNKNOWN_RES" | tail -n1)
[ "$UNKNOWN_HTTP" = "404" ] || fail "Expected 404 for unknown id, got $UNKNOWN_HTTP"
pass "Unknown id correctly returns 404"

# ── 14. Guard: no auth → 401 ─────────────────────────────────────────────────
step 14 "Guard: list without auth → 401"
NO_AUTH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/email-outbox" -H "$ORIGIN")
NO_AUTH_HTTP=$(echo "$NO_AUTH_RES" | tail -n1)
[ "$NO_AUTH_HTTP" = "401" ] || fail "Expected 401 with no auth, got $NO_AUTH_HTTP"
pass "No-auth guard: 401"

# ── 15. Guard: merchant token → 403 ──────────────────────────────────────────
step 15 "Guard: merchant owner token → 403 (staff-only endpoint)"
MERCH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/email-outbox" \
  -H "Authorization: Bearer $DEMO_OWNER_TOKEN" -H "$ORIGIN")
MERCH_HTTP=$(echo "$MERCH_RES" | tail -n1)
[ "$MERCH_HTTP" = "403" ] || fail "Expected 403 for merchant token, got $MERCH_HTTP"
pass "Merchant token correctly rejected (403)"

echo -e "\n${GREEN}━━━ Email Outbox E2E Complete ━━━${NC}"
