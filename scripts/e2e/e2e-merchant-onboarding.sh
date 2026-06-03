#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Merchant Onboarding Flow
#
# Usage:
#   bash scripts/e2e/e2e-merchant-onboarding.sh
#
# Environment: BROPAY_URL (default http://localhost:8787)
#
# Flow:
#   1. Admin login
#   2. Register a new owner account
#   3. Admin creates merchant with owner
#   4. Admin activates merchant
#   5. Verify auto-created wallet exists
#   6. Verify auto-created fee configs exist (inbound + outbound)
#   7. Verify owner membership exists
#   8. Owner can access merchant dashboard
#   9. Guards: 404 missing, 400 invalid, 401 unauthenticated
#  10. Filters: status filter on merchant list
#  11. Cleanup: delete merchant
#
# See: scripts/e2e/docs/e2e-merchant-onboarding.md
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
BROPAY="${BROPAY_URL:-http://localhost:8787}"
ORIGIN="Origin: http://localhost:3000"
CT="Content-Type: application/json"
FAKE_OWNER_ID="00000000-0000-4000-8000-000000000099"
FAKE_MERCHANT_ID="00000000-0000-0000-0000-000000000000"

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

http_delete() {
  local url=$1
  shift
  local raw
  raw=$(curl -s -w "\n%{http_code}" "$url" -X DELETE "$@")
  HTTP_CODE=$(echo "$raw" | tail -1)
  HTTP_BODY=$(echo "$raw" | sed '$d')
}

echo -e "${CYAN}━━━ BroPay E2E Merchant Onboarding ━━━${NC}"

# ── Step 1: Admin login ──────────────────────────────────────────────────────
step 1 "Admin login"
ADMIN_RES=$(curl -s "$BROPAY/v1/auth/staff/login" -H "$CT" -H "$ORIGIN" \
  -d '{"email":"super@bropay.com","password":"password123"}')
ADMIN_TOKEN=$(echo "$ADMIN_RES" | json "print(json.load(sys.stdin)['data']['accessToken'])")
[ -n "$ADMIN_TOKEN" ] || fail "Admin login failed"
pass "Admin authenticated"
ADMIN="Authorization: Bearer $ADMIN_TOKEN"

# ── Step 1b: Auth guard ──────────────────────────────────────────────────────
step "1b" "Auth guard — no token"
http_get "$BROPAY/v1/admin/merchants" -H "$ORIGIN"
[ "$HTTP_CODE" = "401" ] || fail "Expected 401 without token, got $HTTP_CODE"
pass "Unauthenticated request rejected (401)"

# ── Step 2: Register new owner ───────────────────────────────────────────────
step 2 "Register new owner"
OWNER_EMAIL="onboard-$(date +%s)@e2e.local"
OWNER_PASSWORD="Password123!"
OWNER_NAME="E2E Onboard Owner"

REG_RES=$(curl -s "$BROPAY/v1/auth/register" -H "$CT" -H "$ORIGIN" \
  -d "{\"email\":\"$OWNER_EMAIL\",\"password\":\"$OWNER_PASSWORD\",\"name\":\"$OWNER_NAME\"}")
OWNER_TOKEN=$(echo "$REG_RES" | json "print(json.load(sys.stdin)['data']['accessToken'])")
[ -n "$OWNER_TOKEN" ] || fail "Owner registration failed"

ME_RES=$(curl -s "$BROPAY/v1/auth/me" -H "Authorization: Bearer $OWNER_TOKEN" -H "$ORIGIN")
OWNER_ID=$(echo "$ME_RES" | json "print(json.load(sys.stdin)['data']['id'])")
[ -n "$OWNER_ID" ] || fail "Could not get owner ID"
pass "Owner registered: ${OWNER_ID:0:16}... ($OWNER_EMAIL)"

# ── Step 2b: Invalid input guard ─────────────────────────────────────────────
step "2b" "Invalid input guard — empty name"
BASELINE_RES=$(curl -s "$BROPAY/v1/admin/merchants?limit=1" -H "$ADMIN" -H "$ORIGIN")
BASELINE_COUNT=$(echo "$BASELINE_RES" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")

http_post "$BROPAY/v1/admin/merchants" -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"name":""}'
[ "$HTTP_CODE" = "400" ] || [ "$HTTP_CODE" = "422" ] || warn "Expected 400/422 for invalid input, got $HTTP_CODE"
[[ "$HTTP_CODE" == 4* ]] && pass "Invalid input rejected ($HTTP_CODE)" || fail "Expected 4xx for invalid input, got $HTTP_CODE"

step "2c" "Validation guard — owner_account_id not found"
http_post "$BROPAY/v1/admin/merchants" -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"name\":\"Ghost Owner Merchant\",\"slug\":\"ghost-$(date +%s)\",\"merchant_type\":\"limited_company\",\"owner_account_id\":\"$FAKE_OWNER_ID\"}"
[ "$HTTP_CODE" = "422" ] || fail "Expected 422 for missing owner, got $HTTP_CODE"
ERR_CODE=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin).get('error',{}).get('code',''))")
[ "$ERR_CODE" = "OWNER_NOT_FOUND" ] || warn "Expected OWNER_NOT_FOUND, got '$ERR_CODE'"
pass "Missing owner rejected (422)"

# ── Step 3: Admin creates merchant ───────────────────────────────────────────
step 3 "Create merchant"
MERCHANT_SLUG="onboard-$(date +%s)"
MERCHANT_NAME="E2E Onboard Merchant $(date +%s)"
CREATE_RES=$(curl -s "$BROPAY/v1/admin/merchants" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"name\":\"$MERCHANT_NAME\",\"slug\":\"$MERCHANT_SLUG\",\"merchant_type\":\"limited_company\",\"primary_currency\":\"THB\",\"can_resell\":0,\"owner_account_id\":\"$OWNER_ID\"}")

MERCHANT_ID=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$MERCHANT_ID" ] || fail "Merchant creation failed"
INIT_STATUS=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin)['data']['status'])")
[ "$INIT_STATUS" = "pending" ] || fail "Expected status 'pending', got '$INIT_STATUS'"
pass "Merchant created: ${MERCHANT_ID:0:16}... (pending)"

step "3a" "GET merchant detail — owner + wallet_summary"
DETAIL_RES=$(curl -s "$BROPAY/v1/admin/merchants/$MERCHANT_ID" -H "$ADMIN" -H "$ORIGIN")
DETAIL_OWNER=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('owner_account_id',''))")
[ "$DETAIL_OWNER" = "$OWNER_ID" ] || fail "Detail owner_account_id mismatch"
HAS_WALLET=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('wallet_summary') is not None)")
[ "$HAS_WALLET" = "True" ] || fail "Expected wallet_summary on merchant detail"
pass "GET /admin/merchants/{id} OK"

# ── Step 3b: Verify list count increased ─────────────────────────────────────
step "3b" "Verify merchant list count increased"
LIST_AFTER=$(curl -s "$BROPAY/v1/admin/merchants?limit=1" -H "$ADMIN" -H "$ORIGIN")
COUNT_AFTER=$(echo "$LIST_AFTER" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
[ "$COUNT_AFTER" -gt "$BASELINE_COUNT" ] || fail "Expected merchant count to increase ($BASELINE_COUNT → >$BASELINE_COUNT), got $COUNT_AFTER"
pass "Merchant count increased: $BASELINE_COUNT → $COUNT_AFTER"

# ── Step 3c: 404 guard ───────────────────────────────────────────────────────
step "3c" "404 guard — missing merchant"
http_get "$BROPAY/v1/admin/merchants/$FAKE_MERCHANT_ID" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "404" ] || fail "Expected 404 for missing merchant, got $HTTP_CODE"
pass "Missing merchant returns 404"

step "3d" "Merchant inactive guard — pending merchant"
http_get "$BROPAY/v1/merchant" \
  -H "Authorization: Bearer $OWNER_TOKEN" \
  -H "X-Merchant-Id: $MERCHANT_ID" \
  -H "$ORIGIN"
[ "$HTTP_CODE" = "403" ] || fail "Expected 403 for pending merchant portal, got $HTTP_CODE"
pass "Owner blocked until activation (403)"

step "3e" "Conflict guard — duplicate slug"
http_post "$BROPAY/v1/admin/merchants" -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"name\":\"Duplicate Slug Merchant\",\"slug\":\"$MERCHANT_SLUG\",\"merchant_type\":\"limited_company\",\"owner_account_id\":\"$OWNER_ID\"}"
[ "$HTTP_CODE" = "409" ] || fail "Expected 409 for duplicate slug, got $HTTP_CODE"
pass "Duplicate slug rejected (409)"

# ── Step 4: Admin activates merchant ─────────────────────────────────────────
step 4 "Activate merchant"
ACTIVATE_RES=$(curl -s "$BROPAY/v1/admin/merchants/$MERCHANT_ID/activate" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
ACTIVE_STATUS=$(echo "$ACTIVATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$ACTIVE_STATUS" = "active" ] || fail "Expected status 'active', got '$ACTIVE_STATUS'"
pass "Merchant activated"

# ── Step 4b: Status filter works ─────────────────────────────────────────────
step "4b" "Status filter on merchant list"
ACTIVE_LIST=$(curl -s "$BROPAY/v1/admin/merchants?status=active&limit=1" -H "$ADMIN" -H "$ORIGIN")
ACTIVE_COUNT=$(echo "$ACTIVE_LIST" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
[ "$ACTIVE_COUNT" -ge 1 ] || warn "Active filter returned 0 results"
[ "$ACTIVE_COUNT" -ge 1 ] && pass "Active filter works: $ACTIVE_COUNT result(s)"

http_get "$BROPAY/v1/admin/merchants?status=pending&q=$MERCHANT_SLUG" -H "$ADMIN" -H "$ORIGIN"
PENDING_MATCH=$(echo "$HTTP_BODY" | json "mid='$MERCHANT_ID'; d=json.load(sys.stdin).get('data',[]); print(any(x.get('id')==mid for x in d))")
[ "$PENDING_MATCH" = "False" ] || fail "Activated merchant still in pending filter"
pass "Merchant no longer in pending filter"

step "4c" "Merchant login"
LOGIN_RES=$(curl -s "$BROPAY/v1/auth/merchant/login" -H "$CT" -H "$ORIGIN" \
  -d "{\"email\":\"$OWNER_EMAIL\",\"password\":\"$OWNER_PASSWORD\"}")
OWNER_LOGIN_TOKEN=$(echo "$LOGIN_RES" | json "print(json.load(sys.stdin).get('data',{}).get('accessToken',''))")
[ -n "$OWNER_LOGIN_TOKEN" ] || fail "Merchant login failed"
pass "Merchant login succeeded"

# ── Step 5: Verify auto-created wallet ───────────────────────────────────────
step 5 "Verify auto-created wallet"
WALLET_RES=$(curl -s "$BROPAY/v1/admin/wallets?merchant_id=$MERCHANT_ID&limit=1" \
  -H "$ADMIN" -H "$ORIGIN")
WALLET_COUNT=$(echo "$WALLET_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$WALLET_COUNT" -eq 1 ] || fail "Expected 1 wallet, found $WALLET_COUNT"

WALLET_ID=$(echo "$WALLET_RES" | json "d=json.load(sys.stdin)['data']; print(d[0]['id'] if d else '')")
WALLET_CURRENCY=$(echo "$WALLET_RES" | json "d=json.load(sys.stdin)['data']; print(d[0]['currency'] if d else '')")
WALLET_STATUS=$(echo "$WALLET_RES" | json "d=json.load(sys.stdin)['data']; print(d[0]['status'] if d else '')")
[ "$WALLET_CURRENCY" = "THB" ] || fail "Expected wallet currency THB, got '$WALLET_CURRENCY'"
[ "$WALLET_STATUS" = "active" ] || fail "Expected wallet status active, got '$WALLET_STATUS'"
pass "Wallet auto-created: ${WALLET_ID:0:16}... ($WALLET_CURRENCY, $WALLET_STATUS)"

# ── Step 6: Verify auto-created fee configs ──────────────────────────────────
step 6 "Verify auto-created fee configs"
FEE_RES=$(curl -s "$BROPAY/v1/admin/fee-configurations?merchant_id=$MERCHANT_ID&limit=10" \
  -H "$ADMIN" -H "$ORIGIN")
FEE_COUNT=$(echo "$FEE_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FEE_COUNT" -ge 2 ] || fail "Expected at least 2 fee configs, found $FEE_COUNT"

INBOUND_COUNT=$(echo "$FEE_RES" | json "d=json.load(sys.stdin)['data']; print(sum(1 for x in d if x.get('stream_type')=='inbound'))")
OUTBOUND_COUNT=$(echo "$FEE_RES" | json "d=json.load(sys.stdin)['data']; print(sum(1 for x in d if x.get('stream_type')=='outbound'))")
[ "$INBOUND_COUNT" -ge 1 ] || fail "Expected at least 1 inbound fee config"
[ "$OUTBOUND_COUNT" -ge 1 ] || fail "Expected at least 1 outbound fee config"
pass "Fee configs auto-created: $INBOUND_COUNT inbound, $OUTBOUND_COUNT outbound"

# ── Step 7: Verify owner membership ──────────────────────────────────────────
step 7 "Verify owner membership"
MEMBER_RES=$(curl -s "$BROPAY/v1/admin/merchants/$MERCHANT_ID/members" \
  -H "$ADMIN" -H "$ORIGIN")
OWNER_COUNT=$(echo "$MEMBER_RES" | json "d=json.load(sys.stdin)['data']; print(sum(1 for x in d if x.get('role')=='owner'))")
[ "$OWNER_COUNT" -eq 1 ] || fail "Expected 1 owner membership, found $OWNER_COUNT"
pass "Owner membership verified"

# ── Step 8: Owner can access merchant ────────────────────────────────────────
step 8 "Owner accesses merchant dashboard"
OWNER_MERCH=$(curl -s "$BROPAY/v1/merchant" \
  -H "Authorization: Bearer $OWNER_LOGIN_TOKEN" \
  -H "X-Merchant-Id: $MERCHANT_ID" \
  -H "$ORIGIN")
OWNER_MERCH_NAME=$(echo "$OWNER_MERCH" | json "print(json.load(sys.stdin).get('data',{}).get('name',''))")
[ "$OWNER_MERCH_NAME" = "$MERCHANT_NAME" ] || fail "Owner cannot access merchant"
pass "Owner dashboard access confirmed"

# ── Step 8b: Owner cannot access admin endpoints ─────────────────────────────
step "8b" "RBAC guard — owner cannot access admin endpoints"
http_get "$BROPAY/v1/admin/merchants" -H "Authorization: Bearer $OWNER_LOGIN_TOKEN" -H "$ORIGIN"
[ "$HTTP_CODE" = "403" ] || [ "$HTTP_CODE" = "401" ] || warn "Expected 403/401 for owner accessing admin, got $HTTP_CODE"
[[ "$HTTP_CODE" == 403 ]] || [[ "$HTTP_CODE" == 401 ]] && pass "Owner blocked from admin endpoints ($HTTP_CODE)"

# ── Step 9: Cleanup ──────────────────────────────────────────────────────────
step 9 "Cleanup created resources"

http_delete "$BROPAY/v1/admin/merchants/$MERCHANT_ID" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "204" ] || fail "Expected 204 on merchant DELETE, got $HTTP_CODE"
pass "Merchant deleted (204)"

http_get "$BROPAY/v1/admin/merchants/$MERCHANT_ID" -H "$ADMIN" -H "$ORIGIN"
[ "$HTTP_CODE" = "404" ] || fail "Merchant still reachable after delete ($HTTP_CODE)"
pass "Merchant no longer accessible (404)"

POST_WALLET=$(curl -s "$BROPAY/v1/admin/wallets?merchant_id=$MERCHANT_ID&limit=1" -H "$ADMIN" -H "$ORIGIN")
POST_WALLET_COUNT=$(echo "$POST_WALLET" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
[ "${POST_WALLET_COUNT:-0}" -eq 0 ] && pass "Wallet cascade: meta.total=0" || warn "Wallets still listed (total: $POST_WALLET_COUNT)"

POST_FEE=$(curl -s "$BROPAY/v1/admin/fee-configurations?merchant_id=$MERCHANT_ID&limit=10" -H "$ADMIN" -H "$ORIGIN")
POST_FEE_COUNT=$(echo "$POST_FEE" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
[ "${POST_FEE_COUNT:-0}" -eq 0 ] && pass "Fee config cascade: meta.total=0" || warn "Fees still listed (total: $POST_FEE_COUNT)"

info "Owner account $OWNER_EMAIL left in DB (no admin DELETE /accounts route)"

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}━━━ Merchant Onboarding Flow Complete ━━━${NC}"
echo "Owner:     $OWNER_EMAIL (${OWNER_ID:0:20}...)"
echo "Merchant:  $MERCHANT_SLUG (${MERCHANT_ID:0:20}...)"
echo "Wallet:    ${WALLET_ID:0:20}..."
echo "Fees:      $INBOUND_COUNT inbound + $OUTBOUND_COUNT outbound"