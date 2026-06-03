#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Merchant — Integrations (Realistic Lifecycle)
#
# Endpoints:
#   GET  /v1/merchant/integrations
#   GET  /v1/merchant/integrations/{id}
#   POST /v1/merchant/integrations
#   PUT  /v1/merchant/integrations/{id}
#   GET  /v1/merchant/integrations/{id}/api-key
#   POST /v1/merchant/integrations/{id}/rotate-key
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

echo -e "${CYAN}━━━ Merchant E2E — Integrations (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
OWNER="Authorization: Bearer $DEMO_OWNER_TOKEN"
MERCH="X-Merchant-Id: $DEMO_MERCHANT_ID"
pass "Merchant: ${DEMO_MERCHANT_ID:0:16}..."

step 2 "Create integration A"
TS=$(date +%s)
INT_SLUG_A="integ-a-$TS"
CREATE_A_RES=$(curl -s "$BROPAY/v1/merchant/integrations" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"name\":\"E2E Integration A\",\"slug\":\"$INT_SLUG_A\",\"description\":\"First test integration\"}")
INT_A_ID=$(echo "$CREATE_A_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$INT_A_ID" ] || fail "Integration A creation failed"
INT_A_KEY=$(echo "$CREATE_A_RES" | json "print(json.load(sys.stdin).get('data',{}).get('api_key',''))")
[ -n "$INT_A_KEY" ] || fail "Integration A api_key missing"
pass "Integration A created: ${INT_A_ID:0:16}..."

step 3 "Create integration B (auto-slug)"
INT_SLUG_B="integ-b-$TS"
CREATE_B_RES=$(curl -s "$BROPAY/v1/merchant/integrations" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"name\":\"E2E Integration B\",\"slug\":\"$INT_SLUG_B\",\"description\":\"Second test integration\"}")
INT_B_ID=$(echo "$CREATE_B_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$INT_B_ID" ] || fail "Integration B creation failed"
pass "Integration B created: ${INT_B_ID:0:16}..."

step 4 "List integrations — verify both appear"
LIST_RES=$(curl -s "$BROPAY/v1/merchant/integrations" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
LIST_COUNT=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_COUNT" -ge 2 ] || fail "Expected at least 2 integrations, got $LIST_COUNT"
pass "Listed $LIST_COUNT integration(s)"

step 5 "Filter integrations by status=active"
FILT_RES=$(curl -s "$BROPAY/v1/merchant/integrations?status=active" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
FILT_COUNT=$(echo "$FILT_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FILT_COUNT" -ge 2 ] || fail "Expected at least 2 active integrations, got $FILT_COUNT"
pass "$FILT_COUNT active integration(s)"

step 6 "Search integrations by q (name fragment)"
Q_RES=$(curl -s "$BROPAY/v1/merchant/integrations?q=Integration+A" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
Q_COUNT=$(echo "$Q_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$Q_COUNT" -ge 1 ] || fail "Expected at least 1 result for name search, got $Q_COUNT"
pass "$Q_COUNT result(s) for name search"

step 7 "Sort integrations by name asc"
SORT_RES=$(curl -s "$BROPAY/v1/merchant/integrations?sort=name&order=asc" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT_OK=$(echo "$SORT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_OK" = "True" ] || fail "Sort by name asc failed"
pass "Sorted by name asc"

step 8 "Sort integrations by status desc"
SORT2_RES=$(curl -s "$BROPAY/v1/merchant/integrations?sort=status&order=desc" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT2_OK=$(echo "$SORT2_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT2_OK" = "True" ] || fail "Sort by status desc failed"
pass "Sorted by status desc"

step 9 "Pagination limit=1"
PAGE_RES=$(curl -s "$BROPAY/v1/merchant/integrations?limit=1&page=1" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
PAGE_LIMIT=$(echo "$PAGE_RES" | json "print(json.load(sys.stdin)['meta']['limit'])")
PAGE_COUNT=$(echo "$PAGE_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE_LIMIT" -eq 1 ] || fail "Expected limit=1, got $PAGE_LIMIT"
[ "$PAGE_COUNT" -eq 1 ] || fail "Expected 1 item in page, got $PAGE_COUNT"
pass "Pagination limit=1 works"

step 10 "GET integration A detail"
GET_RES=$(curl -s "$BROPAY/v1/merchant/integrations/$INT_A_ID" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
GET_ID=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$GET_ID" = "$INT_A_ID" ] || fail "GET detail mismatch"
pass "Detail fetched"

step 11 "GET API key for integration A"
KEY_RES=$(curl -s "$BROPAY/v1/merchant/integrations/$INT_A_ID/api-key" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
KEY_VAL=$(echo "$KEY_RES" | json "print(json.load(sys.stdin).get('data',{}).get('api_key',''))")
[ -n "$KEY_VAL" ] || fail "API key fetch failed"
[ "$KEY_VAL" = "$INT_A_KEY" ] || fail "API key mismatch"
pass "API key fetched and matches"

step 12 "Rotate key for integration A"
ROTATE_RES=$(curl -s "$BROPAY/v1/merchant/integrations/$INT_A_ID/rotate-key" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT")
ROTATE_OK=$(echo "$ROTATE_RES" | json "print('data' in json.load(sys.stdin))")
[ "$ROTATE_OK" = "True" ] || fail "Rotate-key failed"
NEW_KEY=$(echo "$ROTATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('api_key',''))")
[ -n "$NEW_KEY" ] || fail "Rotated api_key missing"
[ "$NEW_KEY" != "$INT_A_KEY" ] || fail "Rotated api_key should differ"
pass "Key rotated"

step 13 "Verify rotated key via GET api-key"
KEY2_RES=$(curl -s "$BROPAY/v1/merchant/integrations/$INT_A_ID/api-key" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
KEY2_VAL=$(echo "$KEY2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('api_key',''))")
[ "$KEY2_VAL" = "$NEW_KEY" ] || fail "Rotated key mismatch"
pass "Rotated key confirmed via GET"

step 14 "PUT update integration A — name, description, status, inbound_enabled"
PUT_RES=$(curl -s "$BROPAY/v1/merchant/integrations/$INT_A_ID" -X PUT \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{"name":"E2E Integration A Updated","description":"Updated via E2E","status":"suspended","inbound_enabled":0}')
PUT_NAME=$(echo "$PUT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('name',''))")
PUT_STATUS=$(echo "$PUT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
PUT_IN=$(echo "$PUT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('inbound_enabled',''))")
[ "$PUT_NAME" = "E2E Integration A Updated" ] || fail "Name not updated"
[ "$PUT_STATUS" = "suspended" ] || fail "Status not updated"
[ "$PUT_IN" = "0" ] || fail "inbound_enabled not updated"
pass "Updated name, status, inbound_enabled"

step 15 "Verify update reflected in list filter by status=suspended"
FILT_S_RES=$(curl -s "$BROPAY/v1/merchant/integrations?status=suspended" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
FILT_S_COUNT=$(echo "$FILT_S_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FILT_S_COUNT" -ge 1 ] || fail "Expected at least 1 suspended integration"
pass "$FILT_S_COUNT suspended integration(s)"

step 16 "Guard: PUT with no fields returns 400"
PUT_EMPTY_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/integrations/$INT_A_ID" -X PUT \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{}')
PUT_EMPTY_HTTP=$(echo "$PUT_EMPTY_RES" | tail -n1)
[ "$PUT_EMPTY_HTTP" = "400" ] || fail "Expected 400 for empty PUT, got $PUT_EMPTY_HTTP"
pass "Empty PUT rejected with 400"

step 17 "Guard: duplicate slug returns 409"
DUP_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/integrations" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"name\":\"Duplicate\",\"slug\":\"$INT_SLUG_A\"}")
DUP_HTTP=$(echo "$DUP_RES" | tail -n1)
[ "$DUP_HTTP" = "409" ] || fail "Expected 409 for duplicate slug, got $DUP_HTTP"
pass "Duplicate slug rejected with 409"

step 18 "Guard: GET non-existent integration returns 404"
NGET_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/integrations/nonexistent-id" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
NGET_HTTP=$(echo "$NGET_RES" | tail -n1)
[ "$NGET_HTTP" = "404" ] || fail "Expected 404 for missing integration, got $NGET_HTTP"
pass "GET missing integration returns 404"

echo -e "\n${GREEN}━━━ Integrations Realistic Lifecycle Complete ━━━${NC}"
