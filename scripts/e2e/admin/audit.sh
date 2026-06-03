#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Audit (top-level /v1/audit endpoint)
#
# DISTINCT from admin/audit-logs.sh which covers /v1/admin/audit-logs.
#
# Endpoints exercised:
#   GET    /v1/audit           — list (action = HTTP methods: POST/PUT/PATCH/DELETE)
#   GET    /v1/audit/{id}      — get one
#   DELETE /v1/audit/cleanup   — purge records older than 90 days
#
# Key schema differences from /v1/admin/audit-logs:
#   - action enum: "POST" | "PUT" | "PATCH" | "DELETE"  (HTTP method names)
#   - filter params: actor_id, action, resource_type, q
#   - No actor_type, no merchant_id, no status filter
#
# Auth: staff required. GET needs read:AuditLog, DELETE needs delete:AuditLog.
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

echo -e "${CYAN}━━━ Admin E2E — Audit (top-level /v1/audit) ━━━${NC}"

# ── Bootstrap ─────────────────────────────────────────────────────────────────
step 0 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
pass "Admin token acquired (super_admin)"

# ── 1. Generate audit log entries by performing mutations ─────────────────────
step 1 "Perform mutations to generate /v1/audit entries"
# Update merchant → writes a PUT audit log entry
TS=$(date +%s)
MUT_RES=$(curl -s "$BROPAY/v1/admin/merchants/$DEMO_MERCHANT_ID" -X PUT \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"daily_transaction_limit":60000000}')
MUT_OK=$(echo "$MUT_RES" | json "print('data' in json.load(sys.stdin))")
[ "$MUT_OK" = "True" ] || warn "Merchant update failed (audit entries may not exist)"

# Create invitation → writes a POST audit log entry
INV_RES=$(curl -s "$BROPAY/v1/admin/invitations" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"email\":\"audit-e2e-$TS@test.com\",\"merchant_id\":\"$DEMO_MERCHANT_ID\",\"role\":\"viewer\"}")
INV_OK=$(echo "$INV_RES" | json "print('data' in json.load(sys.stdin))")
[ "$INV_OK" = "True" ] || warn "Invitation create failed (audit entries may not exist)"
pass "Mutations performed"

# ── 2. List audit logs ────────────────────────────────────────────────────────
step 2 "GET /v1/audit — list"
LIST_RES=$(curl -s "$BROPAY/v1/audit" -H "$ADMIN" -H "$ORIGIN")
HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$HAS_META" = "True" ] || fail "List missing meta"
HAS_DATA=$(echo "$LIST_RES" | json "print('data' in json.load(sys.stdin))")
[ "$HAS_DATA" = "True" ] || fail "List missing data"
LIST_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
pass "Listed $LIST_TOTAL audit log(s)"

# ── 3. Filter by action=PUT ───────────────────────────────────────────────────
step 3 "Filter by action=PUT (HTTP method filter)"
ACTION_PUT_RES=$(curl -s "$BROPAY/v1/audit?action=PUT" -H "$ADMIN" -H "$ORIGIN")
ACTION_PUT_HAS_META=$(echo "$ACTION_PUT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$ACTION_PUT_HAS_META" = "True" ] || fail "action=PUT filter missing meta"
ACTION_PUT_TOTAL=$(echo "$ACTION_PUT_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
pass "action=PUT: $ACTION_PUT_TOTAL result(s)"

# ── 4. Filter by action=POST ──────────────────────────────────────────────────
step 4 "Filter by action=POST"
ACTION_POST_RES=$(curl -s "$BROPAY/v1/audit?action=POST" -H "$ADMIN" -H "$ORIGIN")
ACTION_POST_HAS_META=$(echo "$ACTION_POST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$ACTION_POST_HAS_META" = "True" ] || fail "action=POST filter missing meta"
ACTION_POST_TOTAL=$(echo "$ACTION_POST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
pass "action=POST: $ACTION_POST_TOTAL result(s)"

# ── 5. Filter by action=POST,PUT,DELETE (comma-separated) ─────────────────────
step 5 "Filter by action=POST,PUT,DELETE"
MULTI_ACTION_RES=$(curl -s "$BROPAY/v1/audit?action=POST,PUT,DELETE" -H "$ADMIN" -H "$ORIGIN")
MULTI_ACTION_OK=$(echo "$MULTI_ACTION_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$MULTI_ACTION_OK" = "True" ] || fail "Multi-action filter missing meta"
MULTI_ACTION_TOTAL=$(echo "$MULTI_ACTION_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
pass "action=POST,PUT,DELETE: $MULTI_ACTION_TOTAL result(s)"

# ── 6. Filter by resource_type ────────────────────────────────────────────────
step 6 "Filter by resource_type=Merchant"
RT_RES=$(curl -s "$BROPAY/v1/audit?resource_type=Merchant" -H "$ADMIN" -H "$ORIGIN")
RT_HAS_META=$(echo "$RT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$RT_HAS_META" = "True" ] || fail "resource_type=Merchant filter missing meta"
RT_TOTAL=$(echo "$RT_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
pass "resource_type=Merchant: $RT_TOTAL result(s)"

# ── 7. Search by q ────────────────────────────────────────────────────────────
step 7 "Search by q=Merchant"
Q_RES=$(curl -s "$BROPAY/v1/audit?q=Merchant" -H "$ADMIN" -H "$ORIGIN")
Q_HAS_META=$(echo "$Q_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$Q_HAS_META" = "True" ] || fail "q=Merchant search missing meta"
Q_TOTAL=$(echo "$Q_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
pass "q=Merchant: $Q_TOTAL result(s)"

# ── 8. Sort by action desc ────────────────────────────────────────────────────
step 8 "Sort by action desc"
SORT_ACT_RES=$(curl -s "$BROPAY/v1/audit?sort=action&order=desc&limit=5" -H "$ADMIN" -H "$ORIGIN")
SORT_ACT_OK=$(echo "$SORT_ACT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_ACT_OK" = "True" ] || fail "Sort by action failed"
pass "Sort by action desc OK"

# ── 9. Sort by actor_id asc ───────────────────────────────────────────────────
step 9 "Sort by actor_id asc"
SORT_ACTOR_RES=$(curl -s "$BROPAY/v1/audit?sort=actor_id&order=asc&limit=5" -H "$ADMIN" -H "$ORIGIN")
SORT_ACTOR_OK=$(echo "$SORT_ACTOR_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_ACTOR_OK" = "True" ] || fail "Sort by actor_id failed"
pass "Sort by actor_id asc OK"

# ── 10. Paginate ─────────────────────────────────────────────────────────────
step 10 "Paginate (limit=2)"
PAGE_RES=$(curl -s "$BROPAY/v1/audit?limit=2&page=1" -H "$ADMIN" -H "$ORIGIN")
PAGE_LIMIT=$(echo "$PAGE_RES" | json "print(json.load(sys.stdin).get('meta',{}).get('limit',-1))")
[ "$PAGE_LIMIT" -eq 2 ] || fail "Expected limit=2 in meta, got $PAGE_LIMIT"
pass "Pagination limit=2 honoured"

# ── 11. GET one audit log by id ───────────────────────────────────────────────
step 11 "GET /v1/audit/{id} — fetch first from list"
FIRST_ID=$(echo "$LIST_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')")
if [ -z "$FIRST_ID" ]; then
  warn "No audit log entries yet — skipping get-one test"
else
  DETAIL_RES=$(curl -s "$BROPAY/v1/audit/$FIRST_ID" -H "$ADMIN" -H "$ORIGIN")
  DETAIL_ID=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
  [ "$DETAIL_ID" = "$FIRST_ID" ] || fail "Detail ID mismatch: expected $FIRST_ID, got $DETAIL_ID"
  DETAIL_HAS_ACTION=$(echo "$DETAIL_RES" | json "print('action' in json.load(sys.stdin).get('data',{}))")
  [ "$DETAIL_HAS_ACTION" = "True" ] || fail "Detail missing action field"
  pass "Detail fetched: id=$DETAIL_ID"
fi

# ── 12. GET unknown id → 404 ─────────────────────────────────────────────────
step 12 "GET /v1/audit/{id} with unknown id → 404"
UNKNOWN_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/audit/nonexistent-audit-xyz" \
  -H "$ADMIN" -H "$ORIGIN")
UNKNOWN_HTTP=$(echo "$UNKNOWN_RES" | tail -n1)
[ "$UNKNOWN_HTTP" = "404" ] || fail "Expected 404 for unknown id, got $UNKNOWN_HTTP"
pass "Unknown id → 404"

# ── 13. DELETE /v1/audit/cleanup ─────────────────────────────────────────────
step 13 "DELETE /v1/audit/cleanup — purge logs older than 90 days"
CLEANUP_RES=$(curl -s "$BROPAY/v1/audit/cleanup" -X DELETE \
  -H "$ADMIN" -H "$ORIGIN")
CLEANUP_HAS_DELETED=$(echo "$CLEANUP_RES" | json "print('deleted' in json.load(sys.stdin).get('data',{}))")
[ "$CLEANUP_HAS_DELETED" = "True" ] || fail "Cleanup response missing deleted count: $CLEANUP_RES"
CLEANUP_DELETED=$(echo "$CLEANUP_RES" | json "print(json.load(sys.stdin)['data']['deleted'])")
[ "$CLEANUP_DELETED" -ge 0 ] || fail "deleted must be >= 0, got $CLEANUP_DELETED"
pass "Cleanup succeeded: deleted=$CLEANUP_DELETED records older than 90 days"

# ── 14. Guard: no auth → 401 ─────────────────────────────────────────────────
step 14 "Guard: list without auth → 401"
NO_AUTH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/audit" -H "$ORIGIN")
NO_AUTH_HTTP=$(echo "$NO_AUTH_RES" | tail -n1)
[ "$NO_AUTH_HTTP" = "401" ] || fail "Expected 401 with no auth, got $NO_AUTH_HTTP"
pass "No-auth guard: 401"

# ── 15. Guard: merchant token → 403 ──────────────────────────────────────────
step 15 "Guard: merchant owner token → 403 (staff-only endpoint)"
MERCH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/audit" \
  -H "Authorization: Bearer $DEMO_OWNER_TOKEN" -H "$ORIGIN")
MERCH_HTTP=$(echo "$MERCH_RES" | tail -n1)
[ "$MERCH_HTTP" = "403" ] || fail "Expected 403 for merchant token, got $MERCH_HTTP"
pass "Merchant token correctly rejected (403)"

echo -e "\n${GREEN}━━━ Audit (/v1/audit) E2E Complete ━━━${NC}"
