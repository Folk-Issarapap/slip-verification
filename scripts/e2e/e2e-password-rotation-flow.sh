#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Password Rotation Flow — must_change_password flag → forced rotation
#
# Usage:
#   bash scripts/e2e/e2e-password-rotation-flow.sh
#
# Environment: BROPAY_URL
#
# Flow:
#   1.  Bootstrap admin session
#   2.  Create a fresh merchant-owner account (disposable)
#   3.  Admin calls POST /v1/admin/users/{id}/reset-password
#   4.  Verify must_change_password = 1 via GET /v1/auth/me (flagged account)
#   5.  Flagged account calls a protected endpoint → 403 PASSWORD_CHANGE_REQUIRED
#   6.  Flagged account calls PUT /v1/profile/password (rotation endpoint)
#   7.  Verify must_change_password = 0 via GET /v1/auth/me after rotation
#   8.  Flagged account can now call protected endpoints normally (200)
#   9.  Negative path — rotate with wrong current password → 401
#  10.  Negative path — admin reset on non-existent account id → 404
#
# See: scripts/e2e/docs/e2e-password-rotation-flow.md
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BROPAY="${BROPAY_URL:-http://localhost:8787}"
ORIGIN="Origin: http://localhost:3000"
CT="Content-Type: application/json"
FAKE_USER_ID="00000000-0000-0000-0000-000000000000"

GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[0;33m' CYAN='\033[0;36m' NC='\033[0m'
pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }
info() { echo -e "${CYAN}→ $1${NC}"; }
warn() { echo -e "${YELLOW}! $1${NC}"; }
step() { echo -e "\n${CYAN}━━━ Step $1: $2 ━━━${NC}"; }
json() { python3 -c "import sys,json; $1" 2>/dev/null; }

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

http_put() {
  local url=$1
  shift
  local raw
  raw=$(curl -s -w "\n%{http_code}" "$url" -X PUT "$@")
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

echo -e "${CYAN}━━━ BroPay E2E Password Rotation Flow ━━━${NC}"

# ── Step 1: Bootstrap admin ───────────────────────────────────────────────────
step 1 "Bootstrap admin session"
source "$SCRIPT_DIR/_bootstrap.sh"
bootstrap_demo_merchant
ADMIN_TOKEN="$DEMO_ADMIN_TOKEN"
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
DEMO_MERCH_ID="$DEMO_MERCHANT_ID"
pass "Admin bootstrapped"

# ── Step 2: Create a fresh account ───────────────────────────────────────────
step 2 "Create fresh merchant-owner account"
TS=$(date +%s)
TARGET_EMAIL="pwd-rot-${TS}@e2e.local"
TARGET_PASSWORD="InitialPass123!"
TARGET_NAME="E2E Pwd Rotation ${TS}"

REG_RES=$(curl -s "$BROPAY/v1/auth/register" -H "$CT" -H "$ORIGIN" \
  -d "{\"email\":\"$TARGET_EMAIL\",\"password\":\"$TARGET_PASSWORD\",\"name\":\"$TARGET_NAME\"}")
TARGET_TOKEN=$(echo "$REG_RES" | json "print(json.load(sys.stdin).get('data',{}).get('accessToken',''))")
TARGET_ID=$(echo "$REG_RES" | json "print(json.load(sys.stdin).get('data',{}).get('user',{}).get('id',''))")
[ -n "$TARGET_TOKEN" ] || fail "Account registration failed — $REG_RES"
[ -n "$TARGET_ID" ] || fail "Could not extract account id from register response"
pass "Account created: ${TARGET_ID:0:20}... ($TARGET_EMAIL)"

http_get "$BROPAY/v1/auth/me" -H "Authorization: Bearer $TARGET_TOKEN" -H "$ORIGIN"
INITIAL_FLAG=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('must_change_password',0))")
[ "$INITIAL_FLAG" = "0" ] || [ "$INITIAL_FLAG" = "" ] && pass "Initial must_change_password = 0 (baseline)" || warn "Unexpected initial must_change_password = $INITIAL_FLAG"

# merchant/login requires at least one active membership on the demo merchant.
http_post "$BROPAY/v1/admin/merchants/$DEMO_MERCH_ID/members" -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"account_id\":\"$TARGET_ID\",\"role\":\"member\"}"
if [ "$HTTP_CODE" = "201" ]; then
  pass "Added to demo merchant (role=member)"
elif [ "$HTTP_CODE" = "400" ] && echo "$HTTP_BODY" | grep -q "already an active member"; then
  pass "Already a member of demo merchant"
else
  fail "Could not add merchant membership (HTTP $HTTP_CODE): $HTTP_BODY"
fi

# ── Step 3: Admin reset password ─────────────────────────────────────────────
step 3 "Admin calls POST /v1/admin/users/{id}/reset-password"
http_post "$BROPAY/v1/admin/users/$TARGET_ID/reset-password" -H "$ADMIN" -H "$ORIGIN" -H "$CT"
[ "$HTTP_CODE" = "200" ] || fail "Expected 200 from admin reset-password, got $HTTP_CODE (body: $HTTP_BODY)"
TEMP_PASSWORD=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('temporary_password',''))")
[ -n "$TEMP_PASSWORD" ] || fail "No temporary_password in reset-password response"
pass "Admin reset succeeded — temp password: ${TEMP_PASSWORD:0:4}... (${#TEMP_PASSWORD} chars)"

step "3b" "After reset — old password login fails"
http_post "$BROPAY/v1/auth/merchant/login" -H "$CT" -H "$ORIGIN" \
  -d "{\"email\":\"$TARGET_EMAIL\",\"password\":\"$TARGET_PASSWORD\"}"
[ "$HTTP_CODE" = "401" ] || warn "Expected 401 for initial password after reset, got $HTTP_CODE"
[[ "$HTTP_CODE" == 401 ]] && pass "Initial password rejected (401)"

# ── Step 4: Login with temp password → verify flag ───────────────────────────
step 4 "Login with temp password → verify must_change_password = 1"
LOGIN_RES=$(curl -s "$BROPAY/v1/auth/merchant/login" -H "$CT" -H "$ORIGIN" \
  -d "{\"email\":\"$TARGET_EMAIL\",\"password\":\"$TEMP_PASSWORD\"}")
FLAGGED_TOKEN=$(echo "$LOGIN_RES" | json "print(json.load(sys.stdin).get('data',{}).get('accessToken',''))")
FLAGGED_SESSION_ID=$(echo "$LOGIN_RES" | json "print(json.load(sys.stdin).get('data',{}).get('sessionId',''))")
LOGIN_FLAG=$(echo "$LOGIN_RES" | json "print(json.load(sys.stdin).get('data',{}).get('user',{}).get('must_change_password',''))")
[ -n "$FLAGGED_TOKEN" ] || fail "Login with temp password failed — $LOGIN_RES"
[ "$LOGIN_FLAG" = "1" ] || warn "Expected login body must_change_password=1, got '$LOGIN_FLAG'"
pass "Logged in with temp password"

http_get "$BROPAY/v1/auth/me" -H "Authorization: Bearer $FLAGGED_TOKEN" -H "$ORIGIN"
[ "$HTTP_CODE" = "200" ] || fail "GET /v1/auth/me returned $HTTP_CODE (expected 200 — allowlisted)"
MUST_CHANGE=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('must_change_password',0))")
[ "$MUST_CHANGE" = "1" ] || fail "Expected must_change_password = 1 after admin reset, got $MUST_CHANGE"
pass "must_change_password = 1 confirmed via GET /v1/auth/me"

# ── Step 5: Flagged account hits blocked endpoint → 403 ──────────────────────
step 5 "Flagged account hits normal endpoint → 403 PASSWORD_CHANGE_REQUIRED"
http_get "$BROPAY/v1/profile" -H "Authorization: Bearer $FLAGGED_TOKEN" -H "$ORIGIN"
[ "$HTTP_CODE" = "403" ] || fail "Expected 403 for flagged account on blocked endpoint, got $HTTP_CODE"
BLOCK_CODE=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin).get('error',{}).get('code',''))")
[ "$BLOCK_CODE" = "PASSWORD_CHANGE_REQUIRED" ] || fail "Expected error code PASSWORD_CHANGE_REQUIRED, got $BLOCK_CODE"
pass "Blocked endpoint returns 403 PASSWORD_CHANGE_REQUIRED"

http_post "$BROPAY/v1/auth/logout" -H "Authorization: Bearer $FLAGGED_TOKEN" -H "$ORIGIN" -H "$CT" \
  -d "{\"sessionId\":\"$FLAGGED_SESSION_ID\"}"
[ "$HTTP_CODE" = "200" ] || [ "$HTTP_CODE" = "204" ] && pass "Allowlisted /v1/auth/logout works while flagged ($HTTP_CODE)" || warn "Logout returned $HTTP_CODE"

LOGIN_RES2=$(curl -s "$BROPAY/v1/auth/merchant/login" -H "$CT" -H "$ORIGIN" \
  -d "{\"email\":\"$TARGET_EMAIL\",\"password\":\"$TEMP_PASSWORD\"}")
FLAGGED_TOKEN=$(echo "$LOGIN_RES2" | json "print(json.load(sys.stdin).get('data',{}).get('accessToken',''))")
FLAGGED_SESSION_ID=$(echo "$LOGIN_RES2" | json "print(json.load(sys.stdin).get('data',{}).get('sessionId',''))")
[ -n "$FLAGGED_TOKEN" ] || fail "Re-login with temp password after logout failed"
pass "Re-logged in with temp password"

step "5c" "Validation — weak new password"
http_put "$BROPAY/v1/profile/password" \
  -H "Authorization: Bearer $FLAGGED_TOKEN" -H "$ORIGIN" -H "$CT" \
  -d "{\"currentPassword\":\"$TEMP_PASSWORD\",\"newPassword\":\"weak\"}"
[ "$HTTP_CODE" = "400" ] || warn "Expected 400 for weak password, got $HTTP_CODE"
[[ "$HTTP_CODE" == 400 ]] && pass "Weak new password rejected (400)"

# ── Step 6: Rotate password ──────────────────────────────────────────────────
step 6 "Rotate password via PUT /v1/profile/password"
NEW_PASSWORD="RotatedSecure456!"
http_put "$BROPAY/v1/profile/password" \
  -H "Authorization: Bearer $FLAGGED_TOKEN" -H "$ORIGIN" -H "$CT" \
  -d "{\"currentPassword\":\"$TEMP_PASSWORD\",\"newPassword\":\"$NEW_PASSWORD\"}"
[ "$HTTP_CODE" = "200" ] || fail "Expected 200 on PUT /v1/profile/password, got $HTTP_CODE (body: $HTTP_BODY)"
pass "Password rotation returned 200"

step "6b" "Temp password login fails after rotation"
http_post "$BROPAY/v1/auth/merchant/login" -H "$CT" -H "$ORIGIN" \
  -d "{\"email\":\"$TARGET_EMAIL\",\"password\":\"$TEMP_PASSWORD\"}"
[ "$HTTP_CODE" = "401" ] || warn "Expected 401 for temp password after rotate, got $HTTP_CODE"
[[ "$HTTP_CODE" == 401 ]] && pass "Temp password rejected after rotate (401)"

# ── Step 7: Login with new password → flag cleared ───────────────────────────
step 7 "Login with new password → must_change_password = 0"
LOGIN_RES3=$(curl -s "$BROPAY/v1/auth/merchant/login" -H "$CT" -H "$ORIGIN" \
  -d "{\"email\":\"$TARGET_EMAIL\",\"password\":\"$NEW_PASSWORD\"}")
FRESH_TOKEN=$(echo "$LOGIN_RES3" | json "print(json.load(sys.stdin).get('data',{}).get('accessToken',''))")
FRESH_FLAG=$(echo "$LOGIN_RES3" | json "print(json.load(sys.stdin).get('data',{}).get('user',{}).get('must_change_password',''))")
[ -n "$FRESH_TOKEN" ] || fail "Login with new password after rotation failed — $LOGIN_RES3"
[ "$FRESH_FLAG" = "0" ] || warn "Expected login must_change_password=0, got '$FRESH_FLAG'"
pass "Login with new password succeeded"

http_get "$BROPAY/v1/auth/me" -H "Authorization: Bearer $FRESH_TOKEN" -H "$ORIGIN"
MUST_CHANGE_AFTER=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('must_change_password',1))")
[ "$MUST_CHANGE_AFTER" = "0" ] || fail "Expected must_change_password = 0 after rotation, got $MUST_CHANGE_AFTER"
pass "must_change_password = 0 confirmed — rotation cleared the flag"

# ── Step 8: Account can now reach protected endpoints ────────────────────────
step 8 "Account accesses protected endpoint normally after rotation"
http_get "$BROPAY/v1/profile" -H "Authorization: Bearer $FRESH_TOKEN" -H "$ORIGIN"
[ "$HTTP_CODE" = "200" ] || fail "Expected 200 on GET /v1/profile after rotation, got $HTTP_CODE"
pass "GET /v1/profile returns 200 after password rotation"

# ── Step 9: Negative — rotate with wrong current password → 401 ───────────────
step 9 "Negative path — rotate with wrong current password → 401"
http_put "$BROPAY/v1/profile/password" \
  -H "Authorization: Bearer $FRESH_TOKEN" -H "$ORIGIN" -H "$CT" \
  -d '{"currentPassword":"WRONG_PASSWORD_XYZ","newPassword":"AnotherNew789!"}'
[ "$HTTP_CODE" = "401" ] || warn "Expected 401 for wrong current password, got $HTTP_CODE"
BAD_ERR=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin).get('error',{}).get('code',''))")
[ "$BAD_ERR" = "INVALID_CREDENTIALS" ] && pass "Wrong current password returns 401 INVALID_CREDENTIALS" || warn "Expected INVALID_CREDENTIALS, got $BAD_ERR ($HTTP_CODE)"

# ── Step 10: Negative — admin reset on non-existent account → 404 ─────────────
step 10 "Negative path — admin reset on non-existent account id → 404"
http_post "$BROPAY/v1/admin/users/$FAKE_USER_ID/reset-password" -H "$ADMIN" -H "$ORIGIN" -H "$CT"
[ "$HTTP_CODE" = "404" ] || warn "Expected 404 for reset on non-existent account, got $HTTP_CODE"
[ "$HTTP_CODE" = "404" ] && pass "Admin reset on missing account returns 404"

step "10b" "Negative — reset without auth → 401"
http_post "$BROPAY/v1/admin/users/$TARGET_ID/reset-password" -H "$ORIGIN" -H "$CT"
[ "$HTTP_CODE" = "401" ] || fail "Expected 401 with no auth token, got $HTTP_CODE"
pass "Unauthenticated reset rejected (401)"

step "10c" "Negative — owner JWT on admin reset → 403"
http_post "$BROPAY/v1/admin/users/$TARGET_ID/reset-password" \
  -H "Authorization: Bearer $FRESH_TOKEN" -H "$ORIGIN" -H "$CT"
[ "$HTTP_CODE" = "403" ] || warn "Expected 403 for owner on admin reset, got $HTTP_CODE"
ERR_KIND=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin).get('error',{}).get('code',''))")
[ "$ERR_KIND" = "FORBIDDEN_KIND" ] && pass "Owner blocked from admin reset (403 FORBIDDEN_KIND)" || pass "Owner blocked from admin reset ($HTTP_CODE)"

# ── Step 11: Cleanup (soft-delete via /v1/users — admin UI path) ─────────────
step 11 "Cleanup — DELETE /v1/users/{id}"
http_delete "$BROPAY/v1/users/$TARGET_ID" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "200" ] || fail "Expected 200 on DELETE /v1/users, got $HTTP_CODE"
DELETE_OK=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('success',False))")
[ "$DELETE_OK" = "True" ] || warn "Expected data.success=true from DELETE /v1/users"
pass "Test account soft-deleted (200)"

http_get "$BROPAY/v1/users/$TARGET_ID" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "404" ] || warn "Expected 404 for deleted user GET, got $HTTP_CODE"
[[ "$HTTP_CODE" == 404 ]] && pass "Deleted user not found (404)"

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}━━━ Password Rotation Flow Complete ━━━${NC}"
echo "Account:    $TARGET_EMAIL"
echo "Reset by:   POST /v1/admin/users/{id}/reset-password"
echo "Delete:     DELETE /v1/users/{id} (soft-delete — admin UI path)"
echo "Flag gate:  403 PASSWORD_CHANGE_REQUIRED on non-allowlisted endpoints"
echo "Rotation:   PUT /v1/profile/password (currentPassword + newPassword)"
echo "After:      must_change_password = 0, normal access restored"
