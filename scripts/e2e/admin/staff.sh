#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Staff (Realistic Lifecycle)
#
# Endpoints:
#   GET  /v1/admin/staff
#   GET  /v1/admin/staff/{id}
#   POST /v1/admin/staff
#   PUT  /v1/admin/staff/{id}
#   POST /v1/admin/staff/{id}/suspend
#   POST /v1/admin/staff/{id}/activate
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROPAY="${BROPAY_URL:-http://localhost:8787}"
ORIGIN="Origin: http://localhost:3000"
CT="Content-Type: application/json"

GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[0;33m' CYAN='\033[0;36m' NC='\033[0m'
pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }
warn() { echo -e "${YELLOW}! $1${NC}"; }
step() { echo -e "\n${CYAN}━━━ Step $1: $2 ━━━${NC}"; }
json() { python3 -c "import sys,json; $1" 2>/dev/null; }

echo -e "${CYAN}━━━ Admin E2E — Staff (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
pass "Admin token acquired (super_admin)"

step 2 "Admin lists all staff"
LIST_RES=$(curl -s "$BROPAY/v1/admin/staff" -H "$ADMIN" -H "$ORIGIN")
LIST_HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$LIST_HAS_META" = "True" ] || fail "Staff list missing meta"
LIST_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_TOTAL" -ge 1 ] || fail "Expected at least 1 staff account"
pass "Listed $LIST_TOTAL staff account(s)"

step 3 "Admin filters by staff_role=super_admin"
ROLE_RES=$(curl -s "$BROPAY/v1/admin/staff?staff_role=super_admin" -H "$ADMIN" -H "$ORIGIN")
ROLE_TOTAL=$(echo "$ROLE_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$ROLE_TOTAL" -ge 1 ] || fail "Expected at least 1 super_admin"
pass "$ROLE_TOTAL super_admin account(s)"

step 4 "Admin filters by status=active"
STAT_RES=$(curl -s "$BROPAY/v1/admin/staff?status=active" -H "$ADMIN" -H "$ORIGIN")
STAT_TOTAL=$(echo "$STAT_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$STAT_TOTAL" -ge 1 ] || fail "Expected at least 1 active staff"
pass "$STAT_TOTAL active account(s)"

step 5 "Admin searches by q (email fragment)"
SEARCH_RES=$(curl -s "$BROPAY/v1/admin/staff?q=super" -H "$ADMIN" -H "$ORIGIN")
SEARCH_TOTAL=$(echo "$SEARCH_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$SEARCH_TOTAL" -ge 1 ] || fail "Expected at least 1 result for 'super'"
pass "$SEARCH_TOTAL result(s) for 'super'"

step 6 "Admin sorts by name asc"
SORT_RES=$(curl -s "$BROPAY/v1/admin/staff?sort=name&order=asc" -H "$ADMIN" -H "$ORIGIN")
SORT_HAS_META=$(echo "$SORT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_HAS_META" = "True" ] || fail "Sort by name failed"
pass "Sorted by name asc"

step 7 "Admin sorts by staff_role desc"
SORT_ROLE_RES=$(curl -s "$BROPAY/v1/admin/staff?sort=staff_role&order=desc" -H "$ADMIN" -H "$ORIGIN")
SORT_ROLE_HAS_META=$(echo "$SORT_ROLE_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_ROLE_HAS_META" = "True" ] || fail "Sort by staff_role failed"
pass "Sorted by staff_role desc"

step 8 "Admin creates a new staff account"
TS=$(date +%s)
STAFF_EMAIL="staff-e2e-$TS@bropay.local"
CREATE_RES=$(curl -s "$BROPAY/v1/admin/staff" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"email\":\"$STAFF_EMAIL\",\"password\":\"Password123!\",\"name\":\"E2E Staff $TS\",\"display_name\":\"E2E\",\"staff_role\":\"developer\"}")
CREATE_OK=$(echo "$CREATE_RES" | json "print('data' in json.load(sys.stdin))")
[ "$CREATE_OK" = "True" ] || fail "Staff creation failed"
STAFF_ID=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
STAFF_ROLE=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('staff_role',''))")
[ "$STAFF_ROLE" = "developer" ] || fail "Expected staff_role=developer, got '$STAFF_ROLE'"
pass "Created: ${STAFF_ID:0:16}... ($STAFF_ROLE)"

step 9 "Admin gets staff detail with memberships"
DETAIL_RES=$(curl -s "$BROPAY/v1/admin/staff/$STAFF_ID" -H "$ADMIN" -H "$ORIGIN")
DETAIL_ID=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$DETAIL_ID" = "$STAFF_ID" ] || fail "Detail ID mismatch"
DETAIL_HAS_MEMBERSHIPS=$(echo "$DETAIL_RES" | json "print('memberships' in json.load(sys.stdin).get('data',{}))")
[ "$DETAIL_HAS_MEMBERSHIPS" = "True" ] || fail "Detail missing memberships"
pass "Detail fetched with memberships"

step 10 "Admin updates staff role"
PUT_RES=$(curl -s "$BROPAY/v1/admin/staff/$STAFF_ID" -X PUT \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"name":"E2E Staff Updated","staff_role":"moderator"}')
PUT_ROLE=$(echo "$PUT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('staff_role',''))")
[ "$PUT_ROLE" = "moderator" ] || fail "Expected staff_role=moderator, got '$PUT_ROLE'"
PUT_NAME=$(echo "$PUT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('name',''))")
[ "$PUT_NAME" = "E2E Staff Updated" ] || fail "Name not updated"
pass "Role updated to moderator, name updated"

step 11 "Admin suspends staff account"
SUSP_RES=$(curl -s "$BROPAY/v1/admin/staff/$STAFF_ID/suspend" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
SUSP_STATUS=$(echo "$SUSP_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$SUSP_STATUS" = "suspended" ] || fail "Expected status=suspended, got '$SUSP_STATUS'"
pass "Staff suspended"

step 12 "Admin confirms suspended staff in list"
SUSP_LIST_RES=$(curl -s "$BROPAY/v1/admin/staff?status=suspended" -H "$ADMIN" -H "$ORIGIN")
SUSP_LIST_HAS=$(echo "$SUSP_LIST_RES" | json "d=json.load(sys.stdin).get('data',[]); print('True' if any(x.get('id')=='$STAFF_ID' for x in d) else 'False')")
[ "$SUSP_LIST_HAS" = "True" ] || fail "Suspended staff not found in suspended list"
pass "Confirmed in suspended list"

step 13 "Admin re-activates staff account"
ACT_RES=$(curl -s "$BROPAY/v1/admin/staff/$STAFF_ID/activate" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
ACT_STATUS=$(echo "$ACT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$ACT_STATUS" = "active" ] || fail "Expected status=active, got '$ACT_STATUS'"
pass "Staff re-activated"

step 14 "Admin filters by multiple staff roles"
MULTI_ROLE_RES=$(curl -s "$BROPAY/v1/admin/staff?staff_role=admin,developer,moderator" -H "$ADMIN" -H "$ORIGIN")
MULTI_ROLE_TOTAL=$(echo "$MULTI_ROLE_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$MULTI_ROLE_TOTAL" -ge 1 ] || fail "Expected at least 1 result for multi-role filter"
pass "$MULTI_ROLE_TOTAL result(s) for admin/developer/moderator"

step 15 "Guard: admin cannot suspend self → 400"
ME_RES=$(curl -s "$BROPAY/v1/auth/me" -H "$ADMIN" -H "$ORIGIN")
SELF_ID=$(echo "$ME_RES" | json "print(json.load(sys.stdin)['data']['id'])")
SELF_SUSP_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/staff/$SELF_ID/suspend" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
SELF_SUSP_HTTP=$(echo "$SELF_SUSP_RES" | tail -n1)
[ "$SELF_SUSP_HTTP" = "400" ] || fail "Expected 400 for self-suspend, got $SELF_SUSP_HTTP"
pass "Correctly rejected self-suspend"

step 16 "Admin paginates staff"
PAGE_RES=$(curl -s "$BROPAY/v1/admin/staff?limit=2&page=1" -H "$ADMIN" -H "$ORIGIN")
PAGE_LIMIT=$(echo "$PAGE_RES" | json "print(json.load(sys.stdin)['meta']['limit'])")
PAGE_COUNT=$(echo "$PAGE_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE_LIMIT" -eq 2 ] || fail "Expected limit=2"
[ "$PAGE_COUNT" -eq 2 ] || fail "Expected 2 items in page"
pass "Pagination limit=2 works"

# ── DELETE /v1/admin/staff/{id} ──────────────────────────────────────────────

step 17 "DELETE — create a fresh non-super-admin staff account to delete"
TS2=$(date +%s)
DEL_EMAIL="staff-del-e2e-$TS2@bropay.local"
DEL_CREATE_RES=$(curl -s "$BROPAY/v1/admin/staff" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"email\":\"$DEL_EMAIL\",\"password\":\"Password123!\",\"name\":\"E2E Delete Staff $TS2\",\"staff_role\":\"writer\"}")
DEL_STAFF_ID=$(echo "$DEL_CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$DEL_STAFF_ID" ] || fail "Staff creation for delete test failed: $DEL_CREATE_RES"
pass "Created staff to delete: ${DEL_STAFF_ID:0:16}..."

step 18 "DELETE — super_admin can delete a non-super-admin staff → 200 + id"
DELETE_RES=$(curl -s "$BROPAY/v1/admin/staff/$DEL_STAFF_ID" -X DELETE \
  -H "$ADMIN" -H "$ORIGIN")
DELETE_ID=$(echo "$DELETE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$DELETE_ID" = "$DEL_STAFF_ID" ] || fail "Delete did not return id=$DEL_STAFF_ID, got '$DELETE_ID'"
pass "Deleted: $DELETE_ID"

step 19 "DELETE — already-deleted staff → 404 (deleted_at IS NULL guard)"
REDELETE_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/staff/$DEL_STAFF_ID" \
  -X DELETE -H "$ADMIN" -H "$ORIGIN")
REDELETE_HTTP=$(echo "$REDELETE_RES" | tail -n1)
[ "$REDELETE_HTTP" = "404" ] || fail "Expected 404 for re-delete, got $REDELETE_HTTP"
pass "Re-delete correctly returns 404"

step 20 "DELETE — unknown id → 404"
UNKNOWN_DEL_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/staff/nonexistent-staff-id-xyz" \
  -X DELETE -H "$ADMIN" -H "$ORIGIN")
UNKNOWN_DEL_HTTP=$(echo "$UNKNOWN_DEL_RES" | tail -n1)
[ "$UNKNOWN_DEL_HTTP" = "404" ] || fail "Expected 404 for unknown id, got $UNKNOWN_DEL_HTTP"
pass "Unknown id correctly returns 404"

step 21 "DELETE — merchant account (kind!=staff) → 404 (staff-only guard)"
# The delete route filters AND kind='staff' — a merchant account id should 404
MERCH_DEL_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/staff/$DEMO_OWNER_ID" \
  -X DELETE -H "$ADMIN" -H "$ORIGIN")
MERCH_DEL_HTTP=$(echo "$MERCH_DEL_RES" | tail -n1)
[ "$MERCH_DEL_HTTP" = "404" ] || fail "Expected 404 for merchant-kind account, got $MERCH_DEL_HTTP"
pass "Merchant-kind account correctly rejected (404)"

step 22 "DELETE — last active super_admin → 409 LAST_SUPER_ADMIN"
# Resolve how many super_admins exist. If exactly 1 (the bootstrap admin),
# attempt delete. If more than 1 it is ambiguous — skip with warn.
SUPERS_RES=$(curl -s "$BROPAY/v1/admin/staff?staff_role=super_admin&status=active&limit=10" \
  -H "$ADMIN" -H "$ORIGIN")
SUPERS_COUNT=$(echo "$SUPERS_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
if [ "$SUPERS_COUNT" -eq 1 ]; then
  SOLE_SUPER_ID=$(echo "$SUPERS_RES" | json "print(json.load(sys.stdin)['data'][0]['id'])")
  LAST_SUPER_DEL_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/staff/$SOLE_SUPER_ID" \
    -X DELETE -H "$ADMIN" -H "$ORIGIN")
  LAST_SUPER_HTTP=$(echo "$LAST_SUPER_DEL_RES" | tail -n1)
  [ "$LAST_SUPER_HTTP" = "409" ] || fail "Expected 409 for last-super-admin delete, got $LAST_SUPER_HTTP"
  LAST_SUPER_BODY=$(echo "$LAST_SUPER_DEL_RES" | head -n1)
  LAST_SUPER_CODE=$(echo "$LAST_SUPER_BODY" | json "print(json.load(sys.stdin).get('error',{}).get('code',''))")
  [ "$LAST_SUPER_CODE" = "LAST_SUPER_ADMIN" ] || fail "Expected error code=LAST_SUPER_ADMIN, got '$LAST_SUPER_CODE'"
  pass "Last-super-admin guard: 409 LAST_SUPER_ADMIN"
else
  warn "Skipping last-super-admin guard test: found $SUPERS_COUNT active super_admins (need exactly 1)"
fi

step 23 "DELETE — merchant-scoped token (kind=merchant) → 401/403"
OWNER_DEL_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/staff/$DEMO_OWNER_ID" \
  -X DELETE -H "Authorization: Bearer $DEMO_OWNER_TOKEN" -H "$ORIGIN")
OWNER_DEL_HTTP=$(echo "$OWNER_DEL_RES" | tail -n1)
[ "$OWNER_DEL_HTTP" = "401" ] || [ "$OWNER_DEL_HTTP" = "403" ] || \
  fail "Expected 401 or 403 for merchant token on staff delete, got $OWNER_DEL_HTTP"
pass "Merchant token correctly rejected ($OWNER_DEL_HTTP)"

echo -e "\n${GREEN}━━━ Staff Realistic Lifecycle Complete ━━━${NC}"
