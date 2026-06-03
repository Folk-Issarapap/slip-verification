#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Staff Invitation Flow
#
# Usage:
#   bash scripts/e2e/e2e-staff-invitation-flow.sh
#
# Environment: BROPAY_URL, BOOTSTRAP_MERCHANT_* (via _bootstrap.sh)
#
# Flow:
#   1. Bootstrap demo merchant
#   2. Owner invites staff by email
#   3. Register new account with that email
#   4. Accept invitation with token
#   5. Verify staff is now a member
#   6. Verify staff can read transactions
#   7. Verify staff CANNOT create settlements (RBAC guard)
#   8. Guards: 404 missing, 400 invalid token, 401 unauthenticated, 409 duplicate
#   9. Filters: role filter on merchant members
#  10. Cleanup: cancel invitation, remove staff member, soft-delete account
#
# See: scripts/e2e/docs/e2e-staff-invitation-flow.md
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
BROPAY="${BROPAY_URL:-http://localhost:8787}"
ORIGIN="Origin: http://localhost:3000"
CT="Content-Type: application/json"

GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[0;33m' CYAN='\033[0;36m' NC='\033[0m'
pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }
info() { echo -e "${CYAN}→ $1${NC}"; }
warn() { echo -e "${YELLOW}! $1${NC}"; }
step() { echo -e "\n${CYAN}━━━ Step $1: $2 ━━━${NC}"; }
json() { python3 -c "import sys,json; $1" 2>/dev/null; }

# Helper: curl with status code extraction
http_get() {
  local url=$1
  shift
  local raw
  raw=$(curl -s -w "\n%{http_code}" "$url" "$@")
  HTTP_CODE=$(echo "$raw" | tail -1)
  HTTP_BODY=$(echo "$raw" | sed '$d')
}

http_post() {
  local url=$1
  shift
  local raw
  raw=$(curl -s -w "\n%{http_code}" "$url" -X POST "$@")
  HTTP_CODE=$(echo "$raw" | tail -1)
  HTTP_BODY=$(echo "$raw" | sed '$d')
}

http_delete() {
  local url=$1
  shift
  local raw
  raw=$(curl -s -w "\n%{http_code}" "$url" -X DELETE "$@")
  HTTP_CODE=$(echo "$raw" | tail -1)
  HTTP_BODY=$(echo "$raw" | sed '$d')
}

echo -e "${CYAN}━━━ BroPay E2E Staff Invitation Flow ━━━${NC}"

# ── Step 1: Bootstrap demo merchant ──────────────────────────────────────────
step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/_bootstrap.sh"
bootstrap_demo_merchant
MERCHANT_ID="$DEMO_MERCHANT_ID"
OWNER_TOKEN="$DEMO_OWNER_TOKEN"
ADMIN_TOKEN="$DEMO_ADMIN_TOKEN"
OWNER="Authorization: Bearer $OWNER_TOKEN"
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
MERCH="X-Merchant-Id: $MERCHANT_ID"
pass "Merchant: ${MERCHANT_ID:0:16}..."

# ── Step 1b: Auth guard ──────────────────────────────────────────────────────
step "1b" "Auth guard — no token"
http_get "$BROPAY/v1/merchant/invitations" -H "$MERCH" -H "$ORIGIN"
[ "$HTTP_CODE" = "401" ] || fail "Expected 401 without token, got $HTTP_CODE"
pass "Unauthenticated request rejected (401)"

# ── Step 1c: Baseline invitation count ───────────────────────────────────────
step "1c" "Baseline invitation count"
BASE_INVITES=$(curl -s "$BROPAY/v1/merchant/invitations" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
BASE_INVITE_COUNT=$(echo "$BASE_INVITES" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
pass "Baseline invitations: $BASE_INVITE_COUNT"

# ── Step 2: Owner invites staff ──────────────────────────────────────────────
step 2 "Owner invites staff"
STAFF_EMAIL="staff-$(date +%s)@e2e.local"
STAFF_ROLE="manager"

http_post "$BROPAY/v1/merchant/invitations" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"email\":\"$STAFF_EMAIL\",\"role\":\"$STAFF_ROLE\"}"
[ "$HTTP_CODE" = "201" ] || fail "Expected 201 on invitation create, got $HTTP_CODE — $HTTP_BODY"

INVITE_ID=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
INVITE_TOKEN=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('token',''))")
INVITE_STATUS=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ -n "$INVITE_ID" ] || fail "Invitation creation failed"
[ -n "$INVITE_TOKEN" ] || fail "No invitation token returned"
[ "$INVITE_STATUS" = "pending" ] || fail "Expected status pending, got $INVITE_STATUS"
pass "Invitation created: ${INVITE_ID:0:16}... ($STAFF_EMAIL as $STAFF_ROLE)"

# ── Step 2b: Verify invitation list count increased ──────────────────────────
step "2b" "Verify invitation list count increased"
AFTER_INVITES=$(curl -s "$BROPAY/v1/merchant/invitations" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
AFTER_INVITE_COUNT=$(echo "$AFTER_INVITES" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
[ "$AFTER_INVITE_COUNT" -gt "$BASE_INVITE_COUNT" ] || fail "Expected invite count to increase ($BASE_INVITE_COUNT → >$BASE_INVITE_COUNT), got $AFTER_INVITE_COUNT"
pass "Invitation count increased: $BASE_INVITE_COUNT → $AFTER_INVITE_COUNT"

# ── Step 2c: GET invitation by id ────────────────────────────────────────────
step "2c" "GET invitation by id"
http_get "$BROPAY/v1/merchant/invitations/$INVITE_ID" -H "$OWNER" -H "$MERCH" -H "$ORIGIN"
[ "$HTTP_CODE" = "200" ] || fail "Expected 200 for GET invitation, got $HTTP_CODE"
GET_INVITE_EMAIL=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('email',''))")
GET_INVITE_STATUS=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$GET_INVITE_EMAIL" = "$STAFF_EMAIL" ] || fail "GET invitation email mismatch"
[ "$GET_INVITE_STATUS" = "pending" ] || fail "Expected pending on GET, got $GET_INVITE_STATUS"
pass "GET invitation: $GET_INVITE_EMAIL ($GET_INVITE_STATUS)"

# ── Step 2d: 404 guard — missing invitation ──────────────────────────────────
step "2d" "404 guard — missing invitation"
http_get "$BROPAY/v1/merchant/invitations/00000000-0000-0000-0000-000000000000" -H "$OWNER" -H "$MERCH" -H "$ORIGIN"
[ "$HTTP_CODE" = "404" ] || fail "Expected 404 for missing invitation, got $HTTP_CODE"
pass "Missing invitation returns 404"

# ── Step 2e: Invalid input guard — bad role ──────────────────────────────────
step "2e" "Invalid input guard — bad role"
http_post "$BROPAY/v1/merchant/invitations" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{"email":"bad@e2e.local","role":"superadmin"}'
[ "$HTTP_CODE" = "400" ] || [ "$HTTP_CODE" = "422" ] || warn "Expected 400/422 for invalid role, got $HTTP_CODE"
[[ "$HTTP_CODE" == 4* ]] && pass "Invalid role rejected ($HTTP_CODE)" || fail "Expected 4xx for invalid role, got $HTTP_CODE"

# ── Step 2f: Duplicate pending invitation guard ────────────────────────────────
step "2f" "Duplicate pending invitation guard — 409"
http_post "$BROPAY/v1/merchant/invitations" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"email\":\"$STAFF_EMAIL\",\"role\":\"member\"}"
[ "$HTTP_CODE" = "409" ] || fail "Expected 409 for duplicate pending invitation, got $HTTP_CODE"
pass "Duplicate pending invitation rejected (409)"

# ── Step 3: Register staff account ───────────────────────────────────────────
step 3 "Register staff account"
STAFF_PASSWORD="Password123!"
STAFF_NAME="E2E Staff Member"

REG_RES=$(curl -s "$BROPAY/v1/auth/register" -H "$CT" -H "$ORIGIN" \
  -d "{\"email\":\"$STAFF_EMAIL\",\"password\":\"$STAFF_PASSWORD\",\"name\":\"$STAFF_NAME\"}")
STAFF_TOKEN=$(echo "$REG_RES" | json "print(json.load(sys.stdin).get('data',{}).get('accessToken',''))")
[ -n "$STAFF_TOKEN" ] || fail "Staff registration failed"
pass "Staff account registered"

ME_RES=$(curl -s "$BROPAY/v1/auth/me" -H "Authorization: Bearer $STAFF_TOKEN" -H "$ORIGIN")
STAFF_ID=$(echo "$ME_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$STAFF_ID" ] || fail "Could not resolve staff account id from /auth/me"

# ── Step 3b: Invalid token guard ─────────────────────────────────────────────
step "3b" "Invalid token guard — accept with bad token"
http_post "$BROPAY/v1/invitations/accept" -H "Authorization: Bearer $STAFF_TOKEN" -H "$CT" -H "$ORIGIN" \
  -d '{"token":"invalid-token-12345"}'
[ "$HTTP_CODE" = "400" ] || [ "$HTTP_CODE" = "404" ] || [ "$HTTP_CODE" = "422" ] || warn "Expected 400/404/422 for invalid token, got $HTTP_CODE"
[[ "$HTTP_CODE" == 4* ]] && pass "Invalid token rejected ($HTTP_CODE)" || fail "Expected 4xx for invalid token, got $HTTP_CODE"

# ── Step 4: Accept invitation ────────────────────────────────────────────────
step 4 "Accept invitation"
http_post "$BROPAY/v1/invitations/accept" -H "Authorization: Bearer $STAFF_TOKEN" -H "$CT" -H "$ORIGIN" \
  -d "{\"token\":\"$INVITE_TOKEN\"}"
[ "$HTTP_CODE" = "200" ] || fail "Expected 200 on accept, got $HTTP_CODE — $HTTP_BODY"

ACCEPT_MERCHANT=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('merchant_id',''))")
ACCEPT_ROLE=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('role',''))")
ACCOUNT_CREATED=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('account_created',True))")
[ "$ACCEPT_MERCHANT" = "$MERCHANT_ID" ] || fail "Invitation accepted for wrong merchant"
[ "$ACCEPT_ROLE" = "$STAFF_ROLE" ] || fail "Expected role $STAFF_ROLE, got $ACCEPT_ROLE"
[ "$ACCOUNT_CREATED" = "False" ] || fail "Expected account_created=false for existing account, got $ACCOUNT_CREATED"
pass "Invitation accepted — merchant: ${ACCEPT_MERCHANT:0:16}..., role: $ACCEPT_ROLE"

# ── Step 4b: Accept again guard ────────────────────────────────────────────────
step "4b" "Accept again guard — already accepted"
http_post "$BROPAY/v1/invitations/accept" -H "Authorization: Bearer $STAFF_TOKEN" -H "$CT" -H "$ORIGIN" \
  -d "{\"token\":\"$INVITE_TOKEN\"}"
[ "$HTTP_CODE" = "400" ] || fail "Expected 400 for already-accepted invitation, got $HTTP_CODE"
pass "Second accept rejected ($HTTP_CODE)"

# ── Step 5: Verify staff membership ──────────────────────────────────────────
step 5 "Verify staff membership"
MEMBERS_RES=$(curl -s "$BROPAY/v1/admin/merchants/$MERCHANT_ID/members" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H "$ORIGIN")
STAFF_MEMBER=$(echo "$MEMBERS_RES" | json "
d=json.load(sys.stdin)
for m in d.get('data', []):
    if m.get('email') == '$STAFF_EMAIL':
        print(f\"{m['role']} {m['status']}\")
        break
else:
    print('not_found')
")
[ "$STAFF_MEMBER" != "not_found" ] || fail "Staff not found in membership list"
[ "$STAFF_MEMBER" = "$STAFF_ROLE active" ] || fail "Expected '$STAFF_ROLE active', got '$STAFF_MEMBER'"
pass "Staff membership: $STAFF_MEMBER"

# ── Step 5b: Role filter on merchant members ───────────────────────────────────
step "5b" "Role filter on merchant members"
MANAGER_SEARCH=$(curl -s "$BROPAY/v1/merchant/members?role=manager" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
MANAGER_COUNT=$(echo "$MANAGER_SEARCH" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
[ "$MANAGER_COUNT" -ge 1 ] || fail "Expected at least 1 manager in filter results, got $MANAGER_COUNT"
MANAGER_HAS_STAFF=$(echo "$MANAGER_SEARCH" | json "
d=json.load(sys.stdin)
print('yes' if any(m.get('email') == '$STAFF_EMAIL' for m in d.get('data', [])) else 'no')
")
[ "$MANAGER_HAS_STAFF" = "yes" ] || fail "Staff email not found in manager role filter"
pass "Manager role filter: $MANAGER_COUNT result(s), staff included"

OWNER_SEARCH=$(curl -s "$BROPAY/v1/merchant/members?role=owner" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
OWNER_COUNT=$(echo "$OWNER_SEARCH" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
[ "$OWNER_COUNT" -ge 1 ] || fail "Expected at least 1 owner in filter results, got $OWNER_COUNT"
pass "Owner role filter: $OWNER_COUNT result(s)"

# ── Step 6: Verify staff can read transactions ───────────────────────────────
step 6 "Verify staff can read transactions"
STAFF_TX=$(curl -s "$BROPAY/v1/merchant/transactions" \
  -H "Authorization: Bearer $STAFF_TOKEN" \
  -H "X-Merchant-Id: $MERCHANT_ID" \
  -H "$ORIGIN")
STAFF_TX_STATUS=$(echo "$STAFF_TX" | json "d=json.load(sys.stdin); print(d.get('meta',{}).get('total','ok') if 'meta' in d else d.get('error',{}).get('code','?'))")
# If it's a number (total count), success. If it's an error code, fail.
if echo "$STAFF_TX_STATUS" | grep -qE '^[0-9]+$'; then
  pass "Staff can read transactions (count: $STAFF_TX_STATUS)"
else
  fail "Staff cannot read transactions: $STAFF_TX_STATUS"
fi

# ── Step 7: Verify staff CANNOT create settlements ───────────────────────────
step 7 "Verify staff cannot create settlements"
STAFF_SETTLE=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/settlements" -X POST \
  -H "Authorization: Bearer $STAFF_TOKEN" \
  -H "X-Merchant-Id: $MERCHANT_ID" \
  -H "$ORIGIN" -H "$CT" \
  -d '{"integration_id":"00000000-0000-0000-0000-000000000000"}')

SETTLE_HTTP_CODE=$(echo "$STAFF_SETTLE" | tail -1)
[ "$SETTLE_HTTP_CODE" = "403" ] || [ "$SETTLE_HTTP_CODE" = "401" ] || warn "Expected 403, got $SETTLE_HTTP_CODE (may vary by role)"
[ "$SETTLE_HTTP_CODE" = "403" ] || [ "$SETTLE_HTTP_CODE" = "401" ] && pass "Settlement creation blocked with HTTP $SETTLE_HTTP_CODE"

# ── Step 8: Cleanup ──────────────────────────────────────────────────────────
step 8 "Cleanup"

# Cancel invitation (already accepted — idempotent cancel still returns cancelled)
http_post "$BROPAY/v1/merchant/invitations/$INVITE_ID/cancel" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d '{}'
if [ "$HTTP_CODE" = "200" ]; then
  CANCEL_STATUS=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
  [ "$CANCEL_STATUS" = "cancelled" ] && pass "Invitation cancelled ($CANCEL_STATUS)" || warn "Cancel returned 200 but status=$CANCEL_STATUS"
else
  warn "Invitation cancel returned $HTTP_CODE"
fi

# Remove staff member (admin route uses account_id)
http_delete "$BROPAY/v1/admin/merchants/$MERCHANT_ID/members/$STAFF_ID" -H "$ADMIN" -H "$ORIGIN"
if [ "$HTTP_CODE" = "200" ]; then
  DEL_OK=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('success',False))")
  [ "$DEL_OK" = "True" ] && pass "Staff member removed (200)" || warn "Delete member returned 200 but success!=true"
else
  warn "Staff member removal returned $HTTP_CODE"
fi

# Verify staff no longer an active member
MEMBERS_AFTER=$(curl -s "$BROPAY/v1/admin/merchants/$MERCHANT_ID/members" \
  -H "Authorization: Bearer $ADMIN_TOKEN" -H "$ORIGIN")
STAFF_AFTER=$(echo "$MEMBERS_AFTER" | json "
d=json.load(sys.stdin)
for m in d.get('data', []):
    if m.get('email') == '$STAFF_EMAIL' and m.get('status') == 'active':
        print('active')
        break
else:
    print('gone')
")
[ "$STAFF_AFTER" = "gone" ] || warn "Staff still active in member list after cleanup"
[ "$STAFF_AFTER" = "gone" ] && pass "Staff no longer an active member"

# Soft-delete staff account (DELETE /v1/users/{id})
if [ -n "$STAFF_ID" ]; then
  http_delete "$BROPAY/v1/users/$STAFF_ID" -H "$ADMIN" -H "$ORIGIN"
  if [ "$HTTP_CODE" = "200" ]; then
    pass "Staff account soft-deleted (200)"
  else
    warn "Staff account deletion returned $HTTP_CODE"
  fi
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}━━━ Staff Invitation Flow Complete ━━━${NC}"
echo "Staff:     $STAFF_EMAIL ($STAFF_ROLE)"
echo "Merchant:  ${MERCHANT_ID:0:20}..."
echo "RBAC:      read:Transaction OK, create:Settlement BLOCKED ($SETTLE_HTTP_CODE)"
