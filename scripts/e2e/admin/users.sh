#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Users Lifecycle
#
# Endpoints exercised:
#   GET  /v1/admin/users
#   GET  /v1/admin/users/{id}
#   POST /v1/admin/users
#   POST /v1/admin/users/{id}/suspend
#   POST /v1/admin/users/{id}/activate
#   POST /v1/admin/users/{id}/reset-password
#   POST /v1/admin/users/{id}/revoke-sessions
#
# Scenarios: list, filter, sort, paginate, CRUD, guards, lifecycle transitions
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

# ── Bootstrap demo merchant ───────────────────────────────────────────────────
step 0 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
pass "Admin token acquired (super_admin)"

# ── 1. List users ─────────────────────────────────────────────────────────────
step 1 "List users — verify meta and total"
LIST_RES=$(curl -s "$BROPAY/v1/admin/users" -H "$ADMIN" -H "$ORIGIN")
META_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin).get('meta',{}).get('total',-1))")
[ "$META_TOTAL" -ge 1 ] || fail "Expected total >= 1, got $META_TOTAL"
LIST_COUNT=$(echo "$LIST_RES" | json "print(len(json.load(sys.stdin).get('data',[])))" )
pass "Listed $LIST_COUNT user(s), meta.total=$META_TOTAL"

# ── 2. Filter by status=active ────────────────────────────────────────────────
step 2 "Filter by status=active"
ACTIVE_RES=$(curl -s "$BROPAY/v1/admin/users?status=active" -H "$ADMIN" -H "$ORIGIN")
ACTIVE_TOTAL=$(echo "$ACTIVE_RES" | json "print(json.load(sys.stdin).get('meta',{}).get('total',-1))")
[ "$ACTIVE_TOTAL" -ge 1 ] || fail "Expected >= 1 active user, got $ACTIVE_TOTAL"
pass "Active users: $ACTIVE_TOTAL"

# ── 3. Filter by multi-status (active,suspended) ──────────────────────────────
step 3 "Filter by multi-status (active,suspended)"
MULTI_RES=$(curl -s "$BROPAY/v1/admin/users?status=active,suspended" -H "$ADMIN" -H "$ORIGIN")
MULTI_TOTAL=$(echo "$MULTI_RES" | json "print(json.load(sys.stdin).get('meta',{}).get('total',-1))")
[ "$MULTI_TOTAL" -ge "$ACTIVE_TOTAL" ] || fail "Multi-status total should be >= active-only total"
pass "Multi-status (active,suspended): $MULTI_TOTAL"

# ── 4. Filter by kind=merchant,reseller (non-staff) ──────────────────────────
step 4 "Filter by kind=merchant,reseller"
NONSTAFF_RES=$(curl -s "$BROPAY/v1/admin/users?kind=merchant,reseller" -H "$ADMIN" -H "$ORIGIN")
NONSTAFF_TOTAL=$(echo "$NONSTAFF_RES" | json "print(json.load(sys.stdin).get('meta',{}).get('total',-1))")
[ "$NONSTAFF_TOTAL" -ge 1 ] || fail "Expected >= 1 non-staff user, got $NONSTAFF_TOTAL"
pass "Non-staff users: $NONSTAFF_TOTAL"

# ── 5. Filter by kind=staff ───────────────────────────────────────────────────
step 5 "Filter by kind=staff"
STAFF_RES=$(curl -s "$BROPAY/v1/admin/users?kind=staff" -H "$ADMIN" -H "$ORIGIN")
STAFF_TOTAL=$(echo "$STAFF_RES" | json "print(json.load(sys.stdin).get('meta',{}).get('total',-1))")
[ "$STAFF_TOTAL" -ge 1 ] || fail "Expected >= 1 staff user, got $STAFF_TOTAL"
pass "Staff users: $STAFF_TOTAL"

# ── 6. Search by q (email fragment 'demo') ────────────────────────────────────
step 6 "Search by q=demo (email fragment)"
Q_EMAIL_RES=$(curl -s "$BROPAY/v1/admin/users?q=demo" -H "$ADMIN" -H "$ORIGIN")
Q_EMAIL_TOTAL=$(echo "$Q_EMAIL_RES" | json "print(json.load(sys.stdin).get('meta',{}).get('total',-1))")
[ "$Q_EMAIL_TOTAL" -ge 1 ] || fail "Expected >= 1 result for q=demo, got $Q_EMAIL_TOTAL"
pass "q=demo: $Q_EMAIL_TOTAL result(s)"

# ── 7. Search by q (name fragment) ────────────────────────────────────────────
step 7 "Search by q=Demo (name fragment)"
Q_NAME_RES=$(curl -s "$BROPAY/v1/admin/users?q=Demo" -H "$ADMIN" -H "$ORIGIN")
Q_NAME_TOTAL=$(echo "$Q_NAME_RES" | json "print(json.load(sys.stdin).get('meta',{}).get('total',-1))")
[ "$Q_NAME_TOTAL" -ge 1 ] || fail "Expected >= 1 result for q=Demo, got $Q_NAME_TOTAL"
pass "q=Demo: $Q_NAME_TOTAL result(s)"

# ── 8. Sort by name asc ───────────────────────────────────────────────────────
step 8 "Sort by name asc"
SORT_NAME_RES=$(curl -s "$BROPAY/v1/admin/users?sort=name&order=asc&limit=5" -H "$ADMIN" -H "$ORIGIN")
SORT_NAME_DATA=$(echo "$SORT_NAME_RES" | json "d=json.load(sys.stdin).get('data',[]); print(json.dumps([u.get('name') or '' for u in d]))")
[ -n "$SORT_NAME_DATA" ] || fail "No data returned for sort=name asc"
pass "Sort by name asc returned data"

# ── 9. Sort by kind desc ──────────────────────────────────────────────────────
# kind enum: staff|reseller|merchant — DESC alphabetical puts 'staff' first
step 9 "Sort by kind desc"
SORT_KIND_RES=$(curl -s "$BROPAY/v1/admin/users?sort=kind&order=desc&limit=5" -H "$ADMIN" -H "$ORIGIN")
SORT_KIND_FIRST=$(echo "$SORT_KIND_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['kind'] if d else '')")
[ "$SORT_KIND_FIRST" = "staff" ] || fail "Expected first item kind=staff for desc sort, got '$SORT_KIND_FIRST'"
pass "Sort by kind desc: first item kind=$SORT_KIND_FIRST"

# ── 10. Sort by created_at asc ─────────────────────────────────────────────────
step 10 "Sort by created_at asc"
SORT_CREATED_RES=$(curl -s "$BROPAY/v1/admin/users?sort=created_at&order=asc&limit=5" -H "$ADMIN" -H "$ORIGIN")
SORT_CREATED_DATA=$(echo "$SORT_CREATED_RES" | json "d=json.load(sys.stdin).get('data',[]); print(len(d))")
[ "$SORT_CREATED_DATA" -ge 1 ] || fail "Expected >= 1 result for sort=created_at asc"
pass "Sort by created_at asc: $SORT_CREATED_DATA item(s)"

# ── 11. Paginate users ────────────────────────────────────────────────────────
step 11 "Paginate users (limit=2, page=1 and page=2)"
PAGE1_RES=$(curl -s "$BROPAY/v1/admin/users?limit=2&page=1" -H "$ADMIN" -H "$ORIGIN")
PAGE1_COUNT=$(echo "$PAGE1_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE1_COUNT" -eq 2 ] || fail "Expected 2 items on page 1, got $PAGE1_COUNT"

PAGE2_RES=$(curl -s "$BROPAY/v1/admin/users?limit=2&page=2" -H "$ADMIN" -H "$ORIGIN")
PAGE2_COUNT=$(echo "$PAGE2_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE2_COUNT" -ge 1 ] || fail "Expected >= 1 item on page 2, got $PAGE2_COUNT"
pass "Pagination: page1=$PAGE1_COUNT, page2=$PAGE2_COUNT"

# ── 12. GET detail for DEMO_OWNER_ID ──────────────────────────────────────────
step 12 "GET detail for DEMO_OWNER_ID"
DETAIL_RES=$(curl -s "$BROPAY/v1/admin/users/$DEMO_OWNER_ID" -H "$ADMIN" -H "$ORIGIN")
DETAIL_ID=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$DETAIL_ID" = "$DEMO_OWNER_ID" ] || fail "Detail ID mismatch: expected $DEMO_OWNER_ID, got $DETAIL_ID"

HAS_MEMBERSHIPS=$(echo "$DETAIL_RES" | json "print('memberships' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_MEMBERSHIPS" = "True" ] || fail "Detail missing memberships array"
HAS_OAUTH=$(echo "$DETAIL_RES" | json "print('oauth_accounts' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_OAUTH" = "True" ] || fail "Detail missing oauth_accounts array"
pass "Detail fetched: memberships + oauth_accounts present"

# ── 13. Create new account ────────────────────────────────────────────────────
step 13 "Create new account (POST /v1/admin/users)"
NEW_EMAIL="e2e-$(date +%s)@test.com"
NEW_NAME="E2E Test User"
CREATE_BODY="{\"email\":\"$NEW_EMAIL\",\"name\":\"$NEW_NAME\",\"password\":\"TempPass123!\"}"
CREATE_RES=$(curl -s "$BROPAY/v1/admin/users" -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d "$CREATE_BODY")
CREATE_STATUS=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$CREATE_STATUS" ] || fail "Create account failed: $CREATE_RES"
NEW_USER_ID=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin)['data']['id'])")
pass "Created account: $NEW_USER_ID"

# ── 14. GET detail for new account ────────────────────────────────────────────
step 14 "GET detail for new account"
NEW_DETAIL_RES=$(curl -s "$BROPAY/v1/admin/users/$NEW_USER_ID" -H "$ADMIN" -H "$ORIGIN")
NEW_DETAIL_ID=$(echo "$NEW_DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$NEW_DETAIL_ID" = "$NEW_USER_ID" ] || fail "New account detail ID mismatch"

NEW_MEMBERSHIPS_LEN=$(echo "$NEW_DETAIL_RES" | json "print(len(json.load(sys.stdin).get('data',{}).get('memberships',[])))")
NEW_OAUTH_LEN=$(echo "$NEW_DETAIL_RES" | json "print(len(json.load(sys.stdin).get('data',{}).get('oauth_accounts',[])))")
[ "$NEW_MEMBERSHIPS_LEN" -eq 0 ] || fail "Expected empty memberships for new account, got $NEW_MEMBERSHIPS_LEN"
[ "$NEW_OAUTH_LEN" -eq 0 ] || fail "Expected empty oauth_accounts for new account, got $NEW_OAUTH_LEN"
pass "New account detail: empty memberships + oauth_accounts"

# ── 15. Suspend new account ───────────────────────────────────────────────────
step 15 "Suspend new account"
SUSPEND_RES=$(curl -s "$BROPAY/v1/admin/users/$NEW_USER_ID/suspend" -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
SUSPEND_STATUS=$(echo "$SUSPEND_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$SUSPEND_STATUS" = "suspended" ] || fail "Expected status=suspended, got '$SUSPEND_STATUS'"
pass "Account suspended"

# ── 16. Activate new account ──────────────────────────────────────────────────
step 16 "Activate new account"
ACTIVATE_RES=$(curl -s "$BROPAY/v1/admin/users/$NEW_USER_ID/activate" -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
ACTIVATE_STATUS=$(echo "$ACTIVATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$ACTIVATE_STATUS" = "active" ] || fail "Expected status=active, got '$ACTIVATE_STATUS'"
pass "Account activated"

# ── 17. Self-suspend guard ────────────────────────────────────────────────────
step 17 "Self-suspend guard (admin suspending self → 400)"
# Need admin's own user id. Extract from the admin login response in bootstrap.
# bootstrap_demo_merchant does not export it, so we fetch /v1/auth/me with admin token.
ADMIN_ME=$(curl -s "$BROPAY/v1/auth/me" -H "$ADMIN" -H "$ORIGIN")
ADMIN_ID=$(echo "$ADMIN_ME" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$ADMIN_ID" ] || fail "Could not resolve admin user id"

SELF_SUSPEND_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/users/$ADMIN_ID/suspend" -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
SELF_SUSPEND_HTTP=$(echo "$SELF_SUSPEND_RES" | tail -n1)
[ "$SELF_SUSPEND_HTTP" = "400" ] || fail "Expected 400 for self-suspend, got $SELF_SUSPEND_HTTP"
pass "Self-suspend correctly rejected (400)"

# ── 18. Reset password for new account ────────────────────────────────────────
step 18 "Reset password for new account"
RESET_RES=$(curl -s "$BROPAY/v1/admin/users/$NEW_USER_ID/reset-password" -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
TEMP_PASSWORD=$(echo "$RESET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('temporary_password',''))")
[ -n "$TEMP_PASSWORD" ] || fail "Expected temp_password in response, got none"
[ "${#TEMP_PASSWORD}" -ge 8 ] || fail "Expected temp_password length >= 8, got ${#TEMP_PASSWORD}"
pass "Temp password returned (${#TEMP_PASSWORD} chars)"

# ── 19. Revoke sessions for new account ───────────────────────────────────────
step 19 "Revoke sessions for new account"
REVOKE_RES=$(curl -s "$BROPAY/v1/admin/users/$NEW_USER_ID/revoke-sessions" -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
REVOKE_COUNT=$(echo "$REVOKE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('revoked_count',-1))")
[ "$REVOKE_COUNT" -ge 0 ] || fail "Expected revoked_count >= 0, got $REVOKE_COUNT"
pass "Sessions revoked: $REVOKE_COUNT"

# ── 20. Guard: duplicate email → 409 ──────────────────────────────────────────
step 20 "Guard: create account with duplicate email → 409"
DUP_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/users" -X POST -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d "$CREATE_BODY")
DUP_HTTP=$(echo "$DUP_RES" | tail -n1)
[ "$DUP_HTTP" = "409" ] || fail "Expected 409 for duplicate email, got $DUP_HTTP"
pass "Duplicate email correctly rejected (409)"

echo -e "\n${GREEN}━━━ Users Lifecycle E2E Complete ━━━${NC}"
