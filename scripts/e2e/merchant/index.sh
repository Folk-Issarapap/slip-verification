#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Merchant — Profile (Index) (Realistic Lifecycle)
#
# Usage:
#   BROPAY_URL=http://localhost:8787 bash scripts/e2e/merchant/index.sh
#
# Environment: BROPAY_URL, BOOTSTRAP_MERCHANT_* (optional)
#
# Endpoints:
#   GET  /v1/merchant
#   PUT  /v1/merchant
#   PATCH /v1/merchant
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

echo -e "${CYAN}━━━ Merchant E2E — Profile (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
MERCHANT_ID="$DEMO_MERCHANT_ID"
OWNER_TOKEN="$DEMO_OWNER_TOKEN"
OWNER="Authorization: Bearer $OWNER_TOKEN"
MERCH="X-Merchant-Id: $MERCHANT_ID"
pass "Merchant: ${MERCHANT_ID:0:16}..."

step 2 "GET current merchant"
GET_RES=$(curl -s "$BROPAY/v1/merchant" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
GET_NAME=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('name',''))")
GET_ID=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
GET_STATUS=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ -n "$GET_NAME" ] || fail "Could not fetch merchant name"
[ "$GET_ID" = "$MERCHANT_ID" ] || fail "Merchant ID mismatch"
[ -n "$GET_STATUS" ] || fail "Merchant status missing"
pass "Merchant name: $GET_NAME, status: $GET_STATUS"

step 3 "Verify merchant has expected fields"
GET_TYPE=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('merchant_type',''))")
GET_CURRENCY=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('primary_currency',''))")
GET_RISK=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('risk_level',''))")
[ -n "$GET_TYPE" ] || fail "merchant_type missing"
[ -n "$GET_CURRENCY" ] || fail "primary_currency missing"
[ -n "$GET_RISK" ] || fail "risk_level missing"
pass "Fields: type=$GET_TYPE, currency=$GET_CURRENCY, risk=$GET_RISK"

step 4 "PUT full update"
TS=$(date +%s)
NEW_NAME="Updated Merchant $TS"
PUT_RES=$(curl -s "$BROPAY/v1/merchant" -X PUT \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"name\":\"$NEW_NAME\",\"merchant_description\":\"E2E updated description $TS\",\"contact\":\"{\\\"email\\\":\\\"contact-$TS@example.com\\\"}\",\"address\":\"{\\\"city\\\":\\\"Bangkok\\\"}\",\"settlement_frequency\":\"weekly\",\"auto_settlement_enabled\":1,\"allow_auto_customer_creation\":1}")
PUT_NAME=$(echo "$PUT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('name',''))")
PUT_DESC=$(echo "$PUT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('merchant_description',''))")
PUT_FREQ=$(echo "$PUT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('settlement_frequency',''))")
PUT_AUTO=$(echo "$PUT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('auto_settlement_enabled',''))")
[ "$PUT_NAME" = "$NEW_NAME" ] || fail "PUT did not update name"
[ "$PUT_DESC" = "E2E updated description $TS" ] || fail "PUT did not update description"
[ "$PUT_FREQ" = "weekly" ] || fail "PUT did not update settlement_frequency"
[ "$PUT_AUTO" = "1" ] || fail "PUT did not update auto_settlement_enabled"
pass "Name updated: $PUT_NAME, freq=$PUT_FREQ, auto=$PUT_AUTO"

step 5 "PATCH partial update"
PATCH_DESC="Patched via E2E $TS"
PATCH_RES=$(curl -s "$BROPAY/v1/merchant" -X PATCH \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"merchant_description\":\"$PATCH_DESC\",\"settlement_frequency\":\"daily\"}")
PATCH_DESC_RESULT=$(echo "$PATCH_RES" | json "print(json.load(sys.stdin).get('data',{}).get('merchant_description',''))")
PATCH_FREQ=$(echo "$PATCH_RES" | json "print(json.load(sys.stdin).get('data',{}).get('settlement_frequency',''))")
[ "$PATCH_DESC_RESULT" = "$PATCH_DESC" ] || fail "PATCH did not update description"
[ "$PATCH_FREQ" = "daily" ] || fail "PATCH did not update settlement_frequency"
pass "Description patched, settlement_frequency=daily"

step 6 "Verify GET reflects all updates"
GET2_RES=$(curl -s "$BROPAY/v1/merchant" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
GET2_NAME=$(echo "$GET2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('name',''))")
GET2_DESC=$(echo "$GET2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('merchant_description',''))")
GET2_FREQ=$(echo "$GET2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('settlement_frequency',''))")
GET2_AUTO=$(echo "$GET2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('auto_settlement_enabled',''))")
[ "$GET2_NAME" = "$NEW_NAME" ] || fail "GET name mismatch after updates"
[ "$GET2_DESC" = "$PATCH_DESC" ] || fail "GET description mismatch after patch"
[ "$GET2_FREQ" = "daily" ] || fail "GET settlement_frequency mismatch after patch"
[ "$GET2_AUTO" = "1" ] || fail "GET auto_settlement_enabled mismatch after PUT"
pass "GET reflects all updates correctly"

step 7 "Guard: PUT with no fields returns 400"
PUT_EMPTY_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant" -X PUT \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{}')
PUT_EMPTY_HTTP=$(echo "$PUT_EMPTY_RES" | tail -n1)
[ "$PUT_EMPTY_HTTP" = "400" ] || fail "Expected 400 for empty PUT, got $PUT_EMPTY_HTTP"
pass "Empty PUT rejected with 400"

step 8 "Guard: PATCH with no fields returns 400"
PATCH_EMPTY_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant" -X PATCH \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{}')
PATCH_EMPTY_HTTP=$(echo "$PATCH_EMPTY_RES" | tail -n1)
[ "$PATCH_EMPTY_HTTP" = "400" ] || fail "Expected 400 for empty PATCH, got $PATCH_EMPTY_HTTP"
pass "Empty PATCH rejected with 400"

step 9 "PATCH single field (settlement_method)"
PATCH2_RES=$(curl -s "$BROPAY/v1/merchant" -X PATCH \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{"settlement_method":"settlement_based"}')
PATCH2_METHOD=$(echo "$PATCH2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('settlement_method',''))")
[ "$PATCH2_METHOD" = "settlement_based" ] || fail "PATCH settlement_method failed"
pass "PATCH settlement_method='settlement_based'"

step 10 "Verify PATCH settlement_method persisted"
GET3_RES=$(curl -s "$BROPAY/v1/merchant" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
GET3_METHOD=$(echo "$GET3_RES" | json "print(json.load(sys.stdin).get('data',{}).get('settlement_method',''))")
[ "$GET3_METHOD" = "settlement_based" ] || fail "GET settlement_method mismatch"
pass "GET confirms settlement_method='settlement_based'"

echo -e "\n${GREEN}━━━ Profile Realistic Lifecycle Complete ━━━${NC}"
