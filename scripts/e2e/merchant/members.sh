#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Merchant — Members (Realistic Lifecycle)
#
# Endpoints:
#   GET    /v1/merchant/members
#   GET    /v1/merchant/members/{id}
#   PUT    /v1/merchant/members/{id}/role
#   DELETE /v1/merchant/members/{id}
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROPAY="${BROPAY_URL:-http://localhost:8787}"
ORIGIN="Origin: http://localhost:3000"
CT="Content-Type: application/json"

GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[0;33m' CYAN='\033[0;36m' NC='\033[0m'
pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
step() { echo -e "\n${CYAN}━━━ Step $1: $2 ━━━${NC}"; }
json() { python3 -c "import sys,json; $1" 2>/dev/null; }

echo -e "${CYAN}━━━ Merchant E2E — Members (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
OWNER="Authorization: Bearer $DEMO_OWNER_TOKEN"
MERCH="X-Merchant-Id: $DEMO_MERCHANT_ID"
pass "Merchant: ${DEMO_MERCHANT_ID:0:16}..."

step 2 "Register staff member A"
TS=$(date +%s)
STAFF_A_EMAIL="staff-a-$TS@e2e.local"
REG_A_RES=$(curl -s "$BROPAY/v1/auth/register" -H "$CT" -H "$ORIGIN" \
  -d "{\"email\":\"$STAFF_A_EMAIL\",\"password\":\"Password123!\",\"name\":\"E2E Staff A\"}")
STAFF_A_TOKEN=$(echo "$REG_A_RES" | json "print(json.load(sys.stdin).get('data',{}).get('accessToken',''))")
[ -n "$STAFF_A_TOKEN" ] || fail "Staff A registration failed"

ME_A_RES=$(curl -s "$BROPAY/v1/auth/me" -H "Authorization: Bearer $STAFF_A_TOKEN" -H "$ORIGIN")
STAFF_A_ID=$(echo "$ME_A_RES" | json "print(json.load(sys.stdin)['data']['id'])")
pass "Staff A registered: ${STAFF_A_ID:0:16}..."

step 3 "Register staff member B"
STAFF_B_EMAIL="staff-b-$TS@e2e.local"
REG_B_RES=$(curl -s "$BROPAY/v1/auth/register" -H "$CT" -H "$ORIGIN" \
  -d "{\"email\":\"$STAFF_B_EMAIL\",\"password\":\"Password123!\",\"name\":\"E2E Staff B\"}")
STAFF_B_TOKEN=$(echo "$REG_B_RES" | json "print(json.load(sys.stdin).get('data',{}).get('accessToken',''))")
[ -n "$STAFF_B_TOKEN" ] || fail "Staff B registration failed"

ME_B_RES=$(curl -s "$BROPAY/v1/auth/me" -H "Authorization: Bearer $STAFF_B_TOKEN" -H "$ORIGIN")
STAFF_B_ID=$(echo "$ME_B_RES" | json "print(json.load(sys.stdin)['data']['id'])")
pass "Staff B registered: ${STAFF_B_ID:0:16}..."

step 4 "Invite staff A to merchant"
INV_A_RES=$(curl -s "$BROPAY/v1/merchant/invitations" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"email\":\"$STAFF_A_EMAIL\",\"role\":\"manager\"}")
INV_A_TOKEN=$(echo "$INV_A_RES" | json "print(json.load(sys.stdin).get('data',{}).get('token',''))")
[ -n "$INV_A_TOKEN" ] || fail "Invitation A creation failed"
pass "Invitation A created"

step 5 "Invite staff B to merchant"
INV_B_RES=$(curl -s "$BROPAY/v1/merchant/invitations" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"email\":\"$STAFF_B_EMAIL\",\"role\":\"member\"}")
INV_B_TOKEN=$(echo "$INV_B_RES" | json "print(json.load(sys.stdin).get('data',{}).get('token',''))")
[ -n "$INV_B_TOKEN" ] || fail "Invitation B creation failed"
pass "Invitation B created"

step 6 "Staff A accepts invitation"
ACCEPT_A_RES=$(curl -s "$BROPAY/v1/invitations/accept" -X POST \
  -H "Authorization: Bearer $STAFF_A_TOKEN" -H "$CT" -H "$ORIGIN" \
  -d "{\"token\":\"$INV_A_TOKEN\"}")
ACCEPT_A_MERCHANT=$(echo "$ACCEPT_A_RES" | json "print(json.load(sys.stdin).get('data',{}).get('merchant_id',''))")
[ "$ACCEPT_A_MERCHANT" = "$DEMO_MERCHANT_ID" ] || fail "Invitation A accepted for wrong merchant"
pass "Invitation A accepted"

step 7 "Staff B accepts invitation"
ACCEPT_B_RES=$(curl -s "$BROPAY/v1/invitations/accept" -X POST \
  -H "Authorization: Bearer $STAFF_B_TOKEN" -H "$CT" -H "$ORIGIN" \
  -d "{\"token\":\"$INV_B_TOKEN\"}")
ACCEPT_B_MERCHANT=$(echo "$ACCEPT_B_RES" | json "print(json.load(sys.stdin).get('data',{}).get('merchant_id',''))")
[ "$ACCEPT_B_MERCHANT" = "$DEMO_MERCHANT_ID" ] || fail "Invitation B accepted for wrong merchant"
pass "Invitation B accepted"

step 8 "List members — verify all 3 appear (owner + A + B)"
LIST_RES=$(curl -s "$BROPAY/v1/merchant/members" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
LIST_COUNT=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_COUNT" -ge 3 ] || fail "Expected at least 3 members, got $LIST_COUNT"
pass "Members listed: $LIST_COUNT"

step 9 "Filter members by role=manager"
FILT_RES=$(curl -s "$BROPAY/v1/merchant/members?role=manager" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
FILT_COUNT=$(echo "$FILT_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FILT_COUNT" -ge 1 ] || fail "Expected at least 1 manager, got $FILT_COUNT"
pass "$FILT_COUNT manager(s)"

step 10 "Filter members by status=active"
FILT_S_RES=$(curl -s "$BROPAY/v1/merchant/members?status=active" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
FILT_S_COUNT=$(echo "$FILT_S_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FILT_S_COUNT" -ge 3 ] || fail "Expected at least 3 active members, got $FILT_S_COUNT"
pass "$FILT_S_COUNT active member(s)"

step 11 "Search members by name fragment"
Q_RES=$(curl -s "$BROPAY/v1/merchant/members?q=Staff+A" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
Q_COUNT=$(echo "$Q_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$Q_COUNT" -ge 1 ] || fail "Expected at least 1 result for name search, got $Q_COUNT"
pass "$Q_COUNT result(s) for name search"

step 12 "Sort members by joined_at desc"
SORT_RES=$(curl -s "$BROPAY/v1/merchant/members?sort=joined_at&order=desc" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT_OK=$(echo "$SORT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_OK" = "True" ] || fail "Sort by joined_at desc failed"
pass "Sorted by joined_at desc"

step 13 "Sort members by role asc"
SORT2_RES=$(curl -s "$BROPAY/v1/merchant/members?sort=role&order=asc" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT2_OK=$(echo "$SORT2_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT2_OK" = "True" ] || fail "Sort by role asc failed"
pass "Sorted by role asc"

step 14 "Pagination limit=2"
PAGE_RES=$(curl -s "$BROPAY/v1/merchant/members?limit=2&page=1" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
PAGE_LIMIT=$(echo "$PAGE_RES" | json "print(json.load(sys.stdin)['meta']['limit'])")
PAGE_COUNT=$(echo "$PAGE_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE_LIMIT" -eq 2 ] || fail "Expected limit=2, got $PAGE_LIMIT"
[ "$PAGE_COUNT" -eq 2 ] || fail "Expected 2 items in page, got $PAGE_COUNT"
pass "Pagination limit=2 works"

step 15 "Find staff A membership ID"
MEMBER_A_ID=$(echo "$LIST_RES" | json "
d=json.load(sys.stdin)['data']
for m in d:
    if m.get('email') == '$STAFF_A_EMAIL':
        print(m['id'])
        break
")
[ -n "$MEMBER_A_ID" ] || fail "Staff A membership not found"
pass "Membership A ID: ${MEMBER_A_ID:0:16}..."

step 16 "GET member detail for staff A"
GET_RES=$(curl -s "$BROPAY/v1/merchant/members/$MEMBER_A_ID" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
GET_ID=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$GET_ID" = "$MEMBER_A_ID" ] || fail "GET detail mismatch"
GET_ROLE=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('role',''))")
[ "$GET_ROLE" = "manager" ] || fail "Expected role manager, got $GET_ROLE"
pass "Detail fetched: role=$GET_ROLE"

step 17 "Change staff A role to admin"
ROLE_RES=$(curl -s "$BROPAY/v1/merchant/members/$MEMBER_A_ID/role" -X PUT \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{"role":"admin"}')
ROLE_RESULT=$(echo "$ROLE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('role',''))")
[ "$ROLE_RESULT" = "admin" ] || fail "Role change failed"
pass "Role changed to admin"

step 18 "Verify role change in list filter by role=admin"
FILT_A_RES=$(curl -s "$BROPAY/v1/merchant/members?role=admin" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
FILT_A_COUNT=$(echo "$FILT_A_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FILT_A_COUNT" -ge 1 ] || fail "Expected at least 1 admin after role change, got $FILT_A_COUNT"
pass "$FILT_A_COUNT admin(s)"

step 19 "Find staff B membership ID"
MEMBER_B_ID=$(echo "$LIST_RES" | json "
d=json.load(sys.stdin)['data']
for m in d:
    if m.get('email') == '$STAFF_B_EMAIL':
        print(m['id'])
        break
")
[ -n "$MEMBER_B_ID" ] || fail "Staff B membership not found"
pass "Membership B ID: ${MEMBER_B_ID:0:16}..."

step 20 "Remove staff B"
DEL_RES=$(curl -s "$BROPAY/v1/merchant/members/$MEMBER_B_ID" -X DELETE \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
DEL_OK=$(echo "$DEL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('success',False))")
[ "$DEL_OK" = "True" ] || fail "Member removal failed"
pass "Member B removed"

step 21 "Verify removal — staff B no longer in active filter"
LIST2_RES=$(curl -s "$BROPAY/v1/merchant/members?status=active" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
LIST2_COUNT=$(echo "$LIST2_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST2_COUNT" -ge 2 ] || fail "Expected at least 2 active members after removal, got $LIST2_COUNT"
# Ensure staff B is gone
B_GONE=$(echo "$LIST2_RES" | json "
d=json.load(sys.stdin)['data']
print('True' if not any(m.get('email') == '$STAFF_B_EMAIL' for m in d) else 'False')
")
[ "$B_GONE" = "True" ] || fail "Staff B still appears in active list"
pass "Staff B no longer in active members"

step 22 "Guard: GET non-existent member returns 404"
NGET_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/members/nonexistent-id" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
NGET_HTTP=$(echo "$NGET_RES" | tail -n1)
[ "$NGET_HTTP" = "404" ] || fail "Expected 404 for missing member, got $NGET_HTTP"
pass "GET missing member returns 404"

echo -e "\n${GREEN}━━━ Members Realistic Lifecycle Complete ━━━${NC}"
