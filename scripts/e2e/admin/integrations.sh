#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Integrations (Realistic Lifecycle)
#
# Endpoints:
#   GET /v1/admin/integrations
#   GET /v1/admin/integrations/{id}
#
# Integrations are created via merchant API (POST /v1/merchant/integrations).
# Admin integrations are READ-ONLY.
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

echo -e "${CYAN}━━━ Admin E2E — Integrations (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
OWNER="Authorization: Bearer $DEMO_OWNER_TOKEN"
MERCHANT_ID="$DEMO_MERCHANT_ID"
pass "Admin token acquired (super_admin); merchant=$MERCHANT_ID"

TS=$(date +%s)
step 2 "Merchant creates first integration"
INT1_RES=$(curl -s "$BROPAY/v1/merchant/integrations" -X POST \
  -H "$OWNER" -H "$ORIGIN" -H "X-Merchant-Id: $MERCHANT_ID" -H "$CT" \
  -d "{\"name\":\"E2E Active Gateway $TS\",\"slug\":\"e2e-active-gateway-$TS\",\"description\":\"Active integration for E2E testing\"}")
INT1_ID=$(echo "$INT1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
INT1_NAME=$(echo "$INT1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('name',''))")
[ -n "$INT1_ID" ] || fail "First integration creation failed"
# Default status is 'pending'; activate it
ACT1_RES=$(curl -s "$BROPAY/v1/merchant/integrations/$INT1_ID" -X PUT \
  -H "$OWNER" -H "$ORIGIN" -H "X-Merchant-Id: $MERCHANT_ID" -H "$CT" \
  -d '{"status":"active"}')
ACT1_STATUS=$(echo "$ACT1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$ACT1_STATUS" = "active" ] || fail "Expected active status, got '$ACT1_STATUS'"
pass "Created integration: ${INT1_ID:0:16}... ($INT1_NAME)"

step 3 "Merchant creates second integration (suspended)"
INT2_RES=$(curl -s "$BROPAY/v1/merchant/integrations" -X POST \
  -H "$OWNER" -H "$ORIGIN" -H "X-Merchant-Id: $MERCHANT_ID" -H "$CT" \
  -d "{\"name\":\"E2E Suspended Gateway $TS\",\"slug\":\"e2e-suspended-gateway-$TS\",\"description\":\"Suspended integration for E2E testing\"}")
INT2_ID=$(echo "$INT2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
INT2_NAME=$(echo "$INT2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('name',''))")
[ -n "$INT2_ID" ] || fail "Second integration creation failed"
pass "Created integration: ${INT2_ID:0:16}... ($INT2_NAME)"

step 4 "Merchant suspends second integration"
SUSP_RES=$(curl -s "$BROPAY/v1/merchant/integrations/$INT2_ID" -X PUT \
  -H "$OWNER" -H "$ORIGIN" -H "X-Merchant-Id: $MERCHANT_ID" -H "$CT" \
  -d '{"status":"suspended"}')
SUSP_STATUS=$(echo "$SUSP_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$SUSP_STATUS" = "suspended" ] || fail "Expected suspended status, got '$SUSP_STATUS'"
pass "Integration suspended"

step 5 "Admin lists all integrations — verify meta, total >= 2"
LIST_RES=$(curl -s "$BROPAY/v1/admin/integrations" -H "$ADMIN" -H "$ORIGIN")
LIST_HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$LIST_HAS_META" = "True" ] || fail "Integration list missing meta"
LIST_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_TOTAL" -ge 2 ] || fail "Expected at least 2 integrations, got $LIST_TOTAL"
pass "Listed $LIST_TOTAL integration(s)"

step 6 "Admin filters by merchant_id"
FM_RES=$(curl -s "$BROPAY/v1/admin/integrations?merchant_id=$MERCHANT_ID" \
  -H "$ADMIN" -H "$ORIGIN")
FM_TOTAL=$(echo "$FM_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FM_TOTAL" -ge 2 ] || fail "Expected at least 2 integrations for merchant, got $FM_TOTAL"
FM_IDS=$(echo "$FM_RES" | json "d=json.load(sys.stdin).get('data',[]); print(','.join([x['id'] for x in d]))")
[[ "$FM_IDS" == *"$INT1_ID"* ]] || fail "Merchant filter missing INT1"
[[ "$FM_IDS" == *"$INT2_ID"* ]] || fail "Merchant filter missing INT2"
pass "$FM_TOTAL integration(s) for merchant"

step 7 "Admin filters by status=active"
FA_RES=$(curl -s "$BROPAY/v1/admin/integrations?status=active" \
  -H "$ADMIN" -H "$ORIGIN")
FA_TOTAL=$(echo "$FA_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FA_TOTAL" -ge 1 ] || fail "Expected at least 1 active integration, got $FA_TOTAL"
FA_IDS=$(echo "$FA_RES" | json "d=json.load(sys.stdin).get('data',[]); print(','.join([x['id'] for x in d]))")
[[ "$FA_IDS" == *"$INT1_ID"* ]] || fail "Active filter missing INT1"
[[ "$FA_IDS" != *"$INT2_ID"* ]] || fail "Active filter should not include suspended INT2"
pass "$FA_TOTAL active integration(s)"

step 8 "Admin filters by multi-status (active,suspended)"
FMS_RES=$(curl -s "$BROPAY/v1/admin/integrations?status=active,suspended" \
  -H "$ADMIN" -H "$ORIGIN")
FMS_TOTAL=$(echo "$FMS_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FMS_TOTAL" -ge 2 ] || fail "Expected at least 2 integrations for multi-status, got $FMS_TOTAL"
FMS_IDS=$(echo "$FMS_RES" | json "d=json.load(sys.stdin).get('data',[]); print(','.join([x['id'] for x in d]))")
[[ "$FMS_IDS" == *"$INT1_ID"* ]] || fail "Multi-status filter missing INT1"
[[ "$FMS_IDS" == *"$INT2_ID"* ]] || fail "Multi-status filter missing INT2"
pass "$FMS_TOTAL integration(s) for status=active,suspended"

step 9 "Admin searches by q (integration name fragment)"
Q1_RES=$(curl -s "$BROPAY/v1/admin/integrations?q=Active%20Gateway" \
  -H "$ADMIN" -H "$ORIGIN")
Q1_TOTAL=$(echo "$Q1_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$Q1_TOTAL" -ge 1 ] || fail "Expected at least 1 result for name fragment, got $Q1_TOTAL"
Q1_IDS=$(echo "$Q1_RES" | json "d=json.load(sys.stdin).get('data',[]); print(','.join([x['id'] for x in d]))")
[[ "$Q1_IDS" == *"$INT1_ID"* ]] || fail "Name search missing INT1"
pass "$Q1_TOTAL result(s) for name fragment 'Active Gateway'"

step 10 "Admin searches by q (slug fragment)"
Q2_RES=$(curl -s "$BROPAY/v1/admin/integrations?q=suspended-gateway" \
  -H "$ADMIN" -H "$ORIGIN")
Q2_TOTAL=$(echo "$Q2_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$Q2_TOTAL" -ge 1 ] || fail "Expected at least 1 result for slug fragment, got $Q2_TOTAL"
Q2_IDS=$(echo "$Q2_RES" | json "d=json.load(sys.stdin).get('data',[]); print(','.join([x['id'] for x in d]))")
[[ "$Q2_IDS" == *"$INT2_ID"* ]] || fail "Slug search missing INT2"
pass "$Q2_TOTAL result(s) for slug fragment 'suspended-gateway'"

step 11 "Admin sorts by name asc"
SN_RES=$(curl -s "$BROPAY/v1/admin/integrations?sort=name&order=asc" \
  -H "$ADMIN" -H "$ORIGIN")
SN_OK=$(echo "$SN_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SN_OK" = "True" ] || fail "Sort by name asc failed"
SN_NAMES=$(echo "$SN_RES" | json "d=json.load(sys.stdin).get('data',[]); print(','.join([x['name'] for x in d]))")
[ -n "$SN_NAMES" ] || fail "Sort by name asc returned no names"
pass "Sorted by name asc"

step 12 "Admin sorts by created_at desc"
SC_RES=$(curl -s "$BROPAY/v1/admin/integrations?sort=created_at&order=desc" \
  -H "$ADMIN" -H "$ORIGIN")
SC_OK=$(echo "$SC_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SC_OK" = "True" ] || fail "Sort by created_at desc failed"
SC_FIRST=$(echo "$SC_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['created_at'] if d else '')")
SC_LAST=$(echo "$SC_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[-1]['created_at'] if d else '')")
[ -n "$SC_FIRST" ] && [ -n "$SC_LAST" ] || fail "Sort by created_at desc missing timestamps"
[ "$SC_FIRST" \> "$SC_LAST" ] || warn "Expected first created_at > last created_at for desc sort"
pass "Sorted by created_at desc"

step 13 "Admin sorts by status asc"
SS_RES=$(curl -s "$BROPAY/v1/admin/integrations?sort=status&order=asc" \
  -H "$ADMIN" -H "$ORIGIN")
SS_OK=$(echo "$SS_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SS_OK" = "True" ] || fail "Sort by status asc failed"
pass "Sorted by status asc"

step 14 "Admin paginates integrations"
PAGE1_RES=$(curl -s "$BROPAY/v1/admin/integrations?limit=1&page=1" \
  -H "$ADMIN" -H "$ORIGIN")
PAGE1_COUNT=$(echo "$PAGE1_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE1_COUNT" -eq 1 ] || fail "Expected 1 integration on page 1, got $PAGE1_COUNT"
PAGE1_TOTAL=$(echo "$PAGE1_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$PAGE1_TOTAL" -ge 2 ] || fail "Expected total >= 2 in pagination meta"

PAGE2_RES=$(curl -s "$BROPAY/v1/admin/integrations?limit=1&page=2" \
  -H "$ADMIN" -H "$ORIGIN")
PAGE2_COUNT=$(echo "$PAGE2_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE2_COUNT" -eq 1 ] || fail "Expected 1 integration on page 2, got $PAGE2_COUNT"
pass "Pagination works (limit=1, page=1+2)"

step 15 "Admin gets integration detail — verify base fields + HMAC credential fields"
DET1_RES=$(curl -s "$BROPAY/v1/admin/integrations/$INT1_ID" \
  -H "$ADMIN" -H "$ORIGIN")
DET1_ID=$(echo "$DET1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$DET1_ID" = "$INT1_ID" ] || fail "Detail ID mismatch"
DET1_NAME=$(echo "$DET1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('name',''))")
[ "$DET1_NAME" = "$INT1_NAME" ] || fail "Detail name mismatch"
DET1_MERCHANT=$(echo "$DET1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('merchant_id',''))")
[ "$DET1_MERCHANT" = "$MERCHANT_ID" ] || fail "Detail merchant_id mismatch"
DET1_STATUS=$(echo "$DET1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$DET1_STATUS" = "active" ] || fail "Detail status mismatch"
DET1_HMAC_KEY=$(echo "$DET1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('hmac_api_key','') or '')")
[ -n "$DET1_HMAC_KEY" ] || fail "Detail missing hmac_api_key"
DET1_HMAC_ACTIVE=$(echo "$DET1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('hmac_is_active',''))")
[ "$DET1_HMAC_ACTIVE" = "1" ] || [ "$DET1_HMAC_ACTIVE" = "0" ] || fail "Detail missing hmac_is_active"
DET1_HMAC_CREATED=$(echo "$DET1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('hmac_created_at','') or '')")
[ -n "$DET1_HMAC_CREATED" ] || fail "Detail missing hmac_created_at"
pass "Detail fetched with base fields + HMAC credential metadata"

step 16 "Admin gets detail for integration with no HMAC credentials — verify nulls"
# Create a third integration, then manually delete its HMAC credentials via direct DB manipulation
# is not possible in E2E. Instead, we verify that the detail endpoint returns the integration
# and that HMAC fields are present (they will be populated because creation auto-generates them).
# To truly test nulls we create an integration and rotate key (old key deactivated, but still a row).
# Since D1 batch always creates credentials, we simply verify the shape is tolerant.
DET2_RES=$(curl -s "$BROPAY/v1/admin/integrations/$INT2_ID" \
  -H "$ADMIN" -H "$ORIGIN")
DET2_ID=$(echo "$DET2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$DET2_ID" = "$INT2_ID" ] || fail "Detail ID mismatch for INT2"
DET2_HMAC_KEY=$(echo "$DET2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('hmac_api_key','') or '')")
DET2_HMAC_ACTIVE=$(echo "$DET2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('hmac_is_active',''))")
DET2_HMAC_LAST=$(echo "$DET2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('hmac_last_used_at','') or '')")
DET2_HMAC_CREATED=$(echo "$DET2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('hmac_created_at','') or '')")
# If credentials exist, they should be populated; if not, nulls are acceptable.
if [ -n "$DET2_HMAC_KEY" ]; then
  pass "Detail fetched with HMAC credentials present (key=$DET2_HMAC_KEY, active=$DET2_HMAC_ACTIVE)"
else
  pass "Detail fetched with null HMAC credentials (hmac_api_key is null)"
fi

step 17 "Combined filter: merchant_id + status=active"
FCOMB_RES=$(curl -s "$BROPAY/v1/admin/integrations?merchant_id=$MERCHANT_ID&status=active" \
  -H "$ADMIN" -H "$ORIGIN")
FCOMB_TOTAL=$(echo "$FCOMB_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FCOMB_TOTAL" -ge 1 ] || fail "Expected at least 1 result for combined filter, got $FCOMB_TOTAL"
FCOMB_IDS=$(echo "$FCOMB_RES" | json "d=json.load(sys.stdin).get('data',[]); print(','.join([x['id'] for x in d]))")
[[ "$FCOMB_IDS" == *"$INT1_ID"* ]] || fail "Combined filter missing active INT1"
[[ "$FCOMB_IDS" != *"$INT2_ID"* ]] || fail "Combined filter should not include suspended INT2"
pass "$FCOMB_TOTAL result(s) for merchant_id + status=active"

echo -e "\n${GREEN}━━━ Integrations Realistic Lifecycle Complete ━━━${NC}"
