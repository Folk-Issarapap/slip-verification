#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Fee Configurations (Realistic Lifecycle)
#
# Endpoints:
#   GET    /v1/admin/fee-configurations
#   GET    /v1/admin/fee-configurations/{id}
#   POST   /v1/admin/fee-configurations
#   PUT    /v1/admin/fee-configurations/{id}
#   DELETE /v1/admin/fee-configurations/{id}
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

echo -e "${CYAN}━━━ Admin E2E — Fee Configurations (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
pass "Admin token acquired (super_admin)"

step 2 "List all fee configurations — verify meta"
LIST_RES=$(curl -s "$BROPAY/v1/admin/fee-configurations" -H "$ADMIN" -H "$ORIGIN")
LIST_HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$LIST_HAS_META" = "True" ] || fail "Fee config list missing meta"
LIST_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
pass "Listed $LIST_TOTAL fee config(s)"

step 3 "Filter by merchant_id (platform defaults may exist)"
FILTER_M_RES=$(curl -s "$BROPAY/v1/admin/fee-configurations?merchant_id=$DEMO_MERCHANT_ID" \
  -H "$ADMIN" -H "$ORIGIN")
FILTER_M_HAS_META=$(echo "$FILTER_M_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$FILTER_M_HAS_META" = "True" ] || fail "Filter by merchant_id missing meta"
pass "Filtered by merchant_id"

step 4 "Filter by stream_type=inbound"
FILTER_ST_RES=$(curl -s "$BROPAY/v1/admin/fee-configurations?stream_type=inbound" \
  -H "$ADMIN" -H "$ORIGIN")
FILTER_ST_HAS_META=$(echo "$FILTER_ST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$FILTER_ST_HAS_META" = "True" ] || fail "Filter by stream_type missing meta"
pass "Filtered by stream_type=inbound"

step 5 "Filter by payment_method=all"
FILTER_PM_RES=$(curl -s "$BROPAY/v1/admin/fee-configurations?payment_method=all" \
  -H "$ADMIN" -H "$ORIGIN")
FILTER_PM_HAS_META=$(echo "$FILTER_PM_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$FILTER_PM_HAS_META" = "True" ] || fail "Filter by payment_method missing meta"
pass "Filtered by payment_method=all"

step 6 "Filter by is_active=1"
FILTER_A_RES=$(curl -s "$BROPAY/v1/admin/fee-configurations?is_active=1" \
  -H "$ADMIN" -H "$ORIGIN")
FILTER_A_HAS_META=$(echo "$FILTER_A_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$FILTER_A_HAS_META" = "True" ] || fail "Filter by is_active missing meta"
pass "Filtered by is_active=1"

step 7 "Combined filter: stream_type=inbound + is_active=1"
FILTER_COMB_RES=$(curl -s "$BROPAY/v1/admin/fee-configurations?stream_type=inbound&is_active=1" \
  -H "$ADMIN" -H "$ORIGIN")
FILTER_COMB_HAS_META=$(echo "$FILTER_COMB_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$FILTER_COMB_HAS_META" = "True" ] || fail "Combined filter missing meta"
pass "Combined filter returned results"

step 8 "Search by q=\"inbound\""
SEARCH_RES=$(curl -s "$BROPAY/v1/admin/fee-configurations?q=inbound" \
  -H "$ADMIN" -H "$ORIGIN")
SEARCH_HAS_META=$(echo "$SEARCH_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SEARCH_HAS_META" = "True" ] || fail "Search by q missing meta"
pass "Search by q=\"inbound\" returned results"

step 9 "Sort by fee_percentage desc"
SORT_FP_RES=$(curl -s "$BROPAY/v1/admin/fee-configurations?sort=fee_percentage&order=desc" \
  -H "$ADMIN" -H "$ORIGIN")
SORT_FP_HAS_META=$(echo "$SORT_FP_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_FP_HAS_META" = "True" ] || fail "Sort by fee_percentage desc missing meta"
pass "Sorted by fee_percentage desc"

step 10 "Sort by effective_from asc"
SORT_EF_RES=$(curl -s "$BROPAY/v1/admin/fee-configurations?sort=effective_from&order=asc" \
  -H "$ADMIN" -H "$ORIGIN")
SORT_EF_HAS_META=$(echo "$SORT_EF_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_EF_HAS_META" = "True" ] || fail "Sort by effective_from asc missing meta"
pass "Sorted by effective_from asc"

step 11 "Paginate fee configs"
PAGE_RES=$(curl -s "$BROPAY/v1/admin/fee-configurations?page=1&limit=2" \
  -H "$ADMIN" -H "$ORIGIN")
PAGE_HAS_META=$(echo "$PAGE_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$PAGE_HAS_META" = "True" ] || fail "Pagination missing meta"
PAGE_LIMIT=$(echo "$PAGE_RES" | json "print(json.load(sys.stdin)['meta']['limit'])")
[ "$PAGE_LIMIT" = "2" ] || fail "Expected limit=2, got $PAGE_LIMIT"
pass "Paginated with limit=2"

step 12 "Create merchant-scoped fee config (inbound, 2.5%, flat 1000 satang) — assert 201"
# Pre-deactivate any existing active inbound fee configs for this merchant (auto-created on merchant creation)
EXISTING_ACTIVE=$(curl -s "$BROPAY/v1/admin/fee-configurations?merchant_id=$DEMO_MERCHANT_ID&stream_type=inbound&is_active=1" \
  -H "$ADMIN" -H "$ORIGIN")
STALE_FC_IDS=$(python3 -c "
import sys, json
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
for fc in d.get('data', []):
    print(fc.get('id', ''))
" "$EXISTING_ACTIVE" 2>/dev/null) || STALE_FC_IDS=""
while IFS= read -r fc_id; do
  fc_id="${fc_id//$'\r'/}"
  [ -z "$fc_id" ] && continue
  curl -s "$BROPAY/v1/admin/fee-configurations/$fc_id" -X PUT \
    -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{"is_active":0}' > /dev/null || true
done <<< "$STALE_FC_IDS"

CREATE_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/fee-configurations" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"merchant_id\":\"$DEMO_MERCHANT_ID\",\"stream_type\":\"inbound\",\"calculation_method\":\"transaction_based\",\"fee_percentage\":2.5,\"flat_fee_amount\":1000,\"is_active\":1}")
CREATE_HTTP=$(echo "$CREATE_RES" | tail -n1)
[ "$CREATE_HTTP" = "201" ] || fail "Expected 201 for create, got $CREATE_HTTP"
CREATE_BODY=$(echo "$CREATE_RES" | sed '$d')
FEE_ID=$(echo "$CREATE_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$FEE_ID" ] || fail "Fee config creation failed: no id"
FEE_PCT=$(echo "$CREATE_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('fee_percentage',''))")
FEE_FLAT=$(echo "$CREATE_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('flat_fee_amount',''))")
FEE_MERCH=$(echo "$CREATE_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('merchant_id',''))")
[ "$FEE_PCT" = "2.5" ] || fail "Expected fee_percentage=2.5, got $FEE_PCT"
[ "$FEE_FLAT" = "1000" ] || fail "Expected flat_fee_amount=1000, got $FEE_FLAT"
[ "$FEE_MERCH" = "$DEMO_MERCHANT_ID" ] || fail "Expected merchant_id=$DEMO_MERCHANT_ID, got $FEE_MERCH"
pass "Created: ${FEE_ID:0:16}... (fee_percentage=$FEE_PCT, flat_fee_amount=$FEE_FLAT)"

step 13 "GET detail — verify fields"
GET_RES=$(curl -s "$BROPAY/v1/admin/fee-configurations/$FEE_ID" \
  -H "$ADMIN" -H "$ORIGIN")
GET_ID=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
GET_STREAM=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('stream_type',''))")
GET_PCT=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('fee_percentage',''))")
GET_FLAT=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('flat_fee_amount',''))")
GET_ACTIVE=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('is_active',''))")
[ "$GET_ID" = "$FEE_ID" ] || fail "GET detail id mismatch"
[ "$GET_STREAM" = "inbound" ] || fail "GET detail stream_type mismatch"
[ "$GET_PCT" = "2.5" ] || fail "GET detail fee_percentage mismatch"
[ "$GET_FLAT" = "1000" ] || fail "GET detail flat_fee_amount mismatch"
[ "$GET_ACTIVE" = "1" ] || fail "GET detail is_active mismatch"
pass "Detail verified"

step 14 "Create a second fee config for same slot but is_active=0 (inactive) — no conflict"
CREATE2_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/fee-configurations" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"merchant_id\":\"$DEMO_MERCHANT_ID\",\"stream_type\":\"inbound\",\"calculation_method\":\"transaction_based\",\"fee_percentage\":3.0,\"flat_fee_amount\":2000,\"is_active\":0}")
CREATE2_HTTP=$(echo "$CREATE2_RES" | tail -n1)
[ "$CREATE2_HTTP" = "201" ] || fail "Expected 201 for inactive slot, got $CREATE2_HTTP"
CREATE2_BODY=$(echo "$CREATE2_RES" | sed '$d')
FEE2_ID=$(echo "$CREATE2_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$FEE2_ID" ] || fail "Inactive fee config creation failed: no id"
FEE2_ACTIVE=$(echo "$CREATE2_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('is_active',''))")
[ "$FEE2_ACTIVE" = "0" ] || fail "Expected is_active=0, got $FEE2_ACTIVE"
pass "Inactive slot created: ${FEE2_ID:0:16}..."

step 15 "Replace active config: deactivate previous, create new active"
# API does not auto-deactivate — deactivate the old config first via PUT, then create new.
DEACT_RES=$(curl -s "$BROPAY/v1/admin/fee-configurations/$FEE_ID" -X PUT \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"is_active":0}')
DEACT_ACTIVE=$(echo "$DEACT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('is_active',''))")
[ "$DEACT_ACTIVE" = "0" ] || fail "Expected old config is_active=0 after PUT, got $DEACT_ACTIVE"
NEW_FEE_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/fee-configurations" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"merchant_id\":\"$DEMO_MERCHANT_ID\",\"stream_type\":\"inbound\",\"calculation_method\":\"transaction_based\",\"fee_percentage\":4.0,\"flat_fee_amount\":3000,\"is_active\":1}")
NEW_FEE_HTTP=$(echo "$NEW_FEE_RES" | tail -n1)
[ "$NEW_FEE_HTTP" = "201" ] || fail "Expected 201 for new active config, got $NEW_FEE_HTTP"
NEW_FEE_BODY=$(echo "$NEW_FEE_RES" | sed '$d')
NEW_FEE_ID=$(echo "$NEW_FEE_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
NEW_FEE_ACTIVE=$(echo "$NEW_FEE_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('is_active',''))")
[ "$NEW_FEE_ACTIVE" = "1" ] || fail "Expected new config is_active=1, got $NEW_FEE_ACTIVE"
# Verify old config is now inactive
OLD_ACTIVE=$(curl -s "$BROPAY/v1/admin/fee-configurations/$FEE_ID" -H "$ADMIN" -H "$ORIGIN" | json "print(json.load(sys.stdin).get('data',{}).get('is_active',''))")
[ "$OLD_ACTIVE" = "0" ] || fail "Expected old config is_active=0, got $OLD_ACTIVE"
pass "Old config deactivated, new active config created"
# Use the new active config for remaining mutation tests
FEE_ID="$NEW_FEE_ID"

step 16 "Try to create with fee_percentage below floor — expect 422 (env-dependent)"
# First deactivate current active config so the conflict guard doesn't trigger
curl -s "$BROPAY/v1/admin/fee-configurations/$FEE_ID" -X PUT \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{"is_active":0}' > /dev/null
FLOOR_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/fee-configurations" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"merchant_id\":\"$DEMO_MERCHANT_ID\",\"stream_type\":\"inbound\",\"calculation_method\":\"transaction_based\",\"fee_percentage\":0.01,\"flat_fee_amount\":500,\"is_active\":1}")
FLOOR_HTTP=$(echo "$FLOOR_RES" | tail -n1)
if [ "$FLOOR_HTTP" = "422" ]; then
  pass "Fee floor violation rejected with 422"
else
  warn "Fee floor guard returned $FLOOR_HTTP (PLATFORM_MIN_FEE_INBOUND_PCT may be 0 in this env)"
fi

step 17 "PUT update flat_fee_amount → 2000"
PUT_RES=$(curl -s "$BROPAY/v1/admin/fee-configurations/$FEE_ID" -X PUT \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"flat_fee_amount":2000}')
PUT_FLAT=$(echo "$PUT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('flat_fee_amount',''))")
[ "$PUT_FLAT" = "2000" ] || fail "PUT update flat_fee_amount failed: expected 2000, got $PUT_FLAT"
pass "Updated flat_fee_amount to 2000"

step 18 "PUT with no fields — expect 400"
PUT_EMPTY_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/fee-configurations/$FEE_ID" -X PUT \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{}')
PUT_EMPTY_HTTP=$(echo "$PUT_EMPTY_RES" | tail -n1)
[ "$PUT_EMPTY_HTTP" = "400" ] || fail "Expected 400 for empty PUT, got $PUT_EMPTY_HTTP"
pass "Empty PUT rejected with 400"

step 19 "DELETE the fee config"
DEL_RES=$(curl -s "$BROPAY/v1/admin/fee-configurations/$FEE_ID" -X DELETE \
  -H "$ADMIN" -H "$ORIGIN")
DEL_OK=$(echo "$DEL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('success',False))")
[ "$DEL_OK" = "True" ] || fail "DELETE did not return success"
pass "Deleted fee config"

step 20 "Verify deleted config is gone (GET → 404)"
GET_DEL_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/fee-configurations/$FEE_ID" \
  -H "$ADMIN" -H "$ORIGIN")
GET_DEL_HTTP=$(echo "$GET_DEL_RES" | tail -n1)
[ "$GET_DEL_HTTP" = "404" ] || fail "Expected 404 for deleted config, got $GET_DEL_HTTP"
pass "Deleted config returns 404"

# Cleanup inactive config
step 21 "Cleanup inactive fee config"
DEL2_RES=$(curl -s "$BROPAY/v1/admin/fee-configurations/$FEE2_ID" -X DELETE \
  -H "$ADMIN" -H "$ORIGIN")
DEL2_OK=$(echo "$DEL2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('success',False))")
[ "$DEL2_OK" = "True" ] || warn "Cleanup of inactive config may have failed"
pass "Cleanup complete"

echo -e "\n${GREEN}━━━ Fee Configurations Realistic Lifecycle Complete ━━━${NC}"
