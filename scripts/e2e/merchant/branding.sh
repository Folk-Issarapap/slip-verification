#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Merchant — Branding (Realistic Lifecycle)
#
# Endpoints:
#   GET /v1/merchant/branding
#   PUT /v1/merchant/branding
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

echo -e "${CYAN}━━━ Merchant E2E — Branding (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
OWNER="Authorization: Bearer $DEMO_OWNER_TOKEN"
MERCH="X-Merchant-Id: $DEMO_MERCHANT_ID"
pass "Merchant: ${DEMO_MERCHANT_ID:0:16}..."

step 2 "Check account kind and GET branding"
ME_RES=$(curl -s "$BROPAY/v1/auth/me" -H "$OWNER" -H "$ORIGIN")
ACCOUNT_KIND=$(echo "$ME_RES" | json "print(json.load(sys.stdin).get('data',{}).get('kind',''))")
if [ "$ACCOUNT_KIND" != "reseller" ]; then
  warn "Account kind is '$ACCOUNT_KIND' — branding requires reseller; testing 403 guards"
  step 3 "Guard: GET branding returns 403 for non-reseller"
  GET_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/branding" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
  GET_HTTP=$(echo "$GET_RES" | tail -n1)
  [ "$GET_HTTP" = "403" ] || fail "Expected 403 for non-reseller branding GET, got $GET_HTTP"
  pass "Branding GET rejected with 403"

  step 4 "Guard: PUT branding returns 403 for non-reseller"
  PUT_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/branding" -X PUT \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
    -d '{"primary_color":"#FF5733"}')
  PUT_HTTP=$(echo "$PUT_RES" | tail -n1)
  [ "$PUT_HTTP" = "403" ] || fail "Expected 403 for non-reseller branding PUT, got $PUT_HTTP"
  pass "Branding PUT rejected with 403"

  step 5 "Guard: missing X-Merchant-Id returns 400"
  NO_MERCH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/branding" \
    -H "$OWNER" -H "$ORIGIN")
  NO_MERCH_HTTP=$(echo "$NO_MERCH_RES" | tail -n1)
  [ "$NO_MERCH_HTTP" = "400" ] || fail "Expected 400 without X-Merchant-Id, got $NO_MERCH_HTTP"
  pass "Missing X-Merchant-Id rejected with 400"

  step 6 "Guard: invalid merchant id returns 404"
  BAD_MERCH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/branding" \
    -H "$OWNER" -H "X-Merchant-Id: nonexistent-merchant-id" -H "$ORIGIN")
  BAD_MERCH_HTTP=$(echo "$BAD_MERCH_RES" | tail -n1)
  [ "$BAD_MERCH_HTTP" = "404" ] || fail "Expected 404 for invalid merchant, got $BAD_MERCH_HTTP"
  pass "Invalid merchant rejected with 404"

  echo -e "\n${GREEN}━━━ Branding Realistic Lifecycle Complete (non-reseller guards verified) ━━━${NC}"
  exit 0
fi

GET_RES=$(curl -s "$BROPAY/v1/merchant/branding" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
HAS_DATA=$(echo "$GET_RES" | json "print('data' in json.load(sys.stdin))")
[ "$HAS_DATA" = "True" ] || fail "Branding GET failed"
GET_MERCHANT_ID=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('merchant_id',''))")
[ "$GET_MERCHANT_ID" = "$DEMO_MERCHANT_ID" ] || fail "Branding merchant_id mismatch"
pass "Branding fetched for merchant"

step 3 "PUT branding update (all fields)"
TS=$(date +%s)
PUT_RES=$(curl -s "$BROPAY/v1/merchant/branding" -X PUT \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"name\":\"E2E Brand $TS\",\"logo_url\":\"https://example.com/logo-$TS.png\",\"primary_color\":\"#FF5733\",\"secondary_color\":\"#33FF57\"}")
PUT_COLOR=$(echo "$PUT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('branding',{}).get('primary_color',''))")
[ "$PUT_COLOR" = "#FF5733" ] || fail "Branding PUT did not update primary_color"
PUT_NAME=$(echo "$PUT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('branding',{}).get('name',''))")
[ "$PUT_NAME" = "E2E Brand $TS" ] || fail "Branding PUT did not update name"
PUT_LOGO=$(echo "$PUT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('branding',{}).get('logo_url',''))")
[ "$PUT_LOGO" = "https://example.com/logo-$TS.png" ] || fail "Branding PUT did not update logo_url"
PUT_SECONDARY=$(echo "$PUT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('branding',{}).get('secondary_color',''))")
[ "$PUT_SECONDARY" = "#33FF57" ] || fail "Branding PUT did not update secondary_color"
pass "Branding updated (all fields)"

step 4 "GET branding after update"
GET2_RES=$(curl -s "$BROPAY/v1/merchant/branding" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
GET2_COLOR=$(echo "$GET2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('branding',{}).get('primary_color',''))")
[ "$GET2_COLOR" = "#FF5733" ] || fail "GET after PUT did not reflect primary_color"
GET2_NAME=$(echo "$GET2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('branding',{}).get('name',''))")
[ "$GET2_NAME" = "E2E Brand $TS" ] || fail "GET after PUT did not reflect name"
pass "GET branding reflects update"

step 5 "PUT partial update (only primary_color)"
PUT3_RES=$(curl -s "$BROPAY/v1/merchant/branding" -X PUT \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{"primary_color":"#112233"}')
PUT3_COLOR=$(echo "$PUT3_RES" | json "print(json.load(sys.stdin).get('data',{}).get('branding',{}).get('primary_color',''))")
[ "$PUT3_COLOR" = "#112233" ] || fail "Partial PUT did not update primary_color"
PUT3_NAME=$(echo "$PUT3_RES" | json "print(json.load(sys.stdin).get('data',{}).get('branding',{}).get('name',''))")
[ "$PUT3_NAME" = "E2E Brand $TS" ] || fail "Partial PUT unexpectedly changed name"
pass "Partial update works (primary_color changed, name preserved)"

step 6 "Guard: PUT invalid color format returns 400"
BAD_COLOR_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/branding" -X PUT \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{"primary_color":"invalid-color"}')
BAD_COLOR_HTTP=$(echo "$BAD_COLOR_RES" | tail -n1)
[ "$BAD_COLOR_HTTP" = "400" ] || fail "Expected 400 for invalid color, got $BAD_COLOR_HTTP"
pass "Invalid color rejected with 400"

step 7 "Guard: PUT invalid logo_url returns 400"
BAD_LOGO_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/branding" -X PUT \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{"logo_url":"not-a-url"}')
BAD_LOGO_HTTP=$(echo "$BAD_LOGO_RES" | tail -n1)
[ "$BAD_LOGO_HTTP" = "400" ] || fail "Expected 400 for invalid logo_url, got $BAD_LOGO_HTTP"
pass "Invalid logo_url rejected with 400"

step 8 "Guard: missing X-Merchant-Id returns 400"
NO_MERCH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/branding" \
  -H "$OWNER" -H "$ORIGIN")
NO_MERCH_HTTP=$(echo "$NO_MERCH_RES" | tail -n1)
[ "$NO_MERCH_HTTP" = "400" ] || fail "Expected 400 without X-Merchant-Id, got $NO_MERCH_HTTP"
pass "Missing X-Merchant-Id rejected with 400"

step 9 "Guard: invalid merchant id returns 404"
BAD_MERCH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/branding" \
  -H "$OWNER" -H "X-Merchant-Id: nonexistent-merchant-id" -H "$ORIGIN")
BAD_MERCH_HTTP=$(echo "$BAD_MERCH_RES" | tail -n1)
[ "$BAD_MERCH_HTTP" = "404" ] || fail "Expected 404 for invalid merchant, got $BAD_MERCH_HTTP"
pass "Invalid merchant rejected with 404"

echo -e "\n${GREEN}━━━ Branding Realistic Lifecycle Complete ━━━${NC}"
