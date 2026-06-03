#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Merchants (Realistic Lifecycle)
#
# Endpoints:
#   GET  /v1/admin/merchants
#   GET  /v1/admin/merchants/{id}
#   POST /v1/admin/merchants
#   PUT  /v1/admin/merchants/{id}
#   POST /v1/admin/merchants/{id}/activate
#   POST /v1/admin/merchants/{id}/suspend
#   POST /v1/admin/merchants/{id}/block
#   POST /v1/admin/merchants/{id}/close
#   POST /v1/admin/merchants/{id}/assign-owner
#   GET  /v1/admin/merchants/{id}/tree
#   GET  /v1/admin/merchants/{id}/members
#   GET  /v1/admin/merchants/{id}/bank-accounts
#   GET  /v1/admin/fee-configurations
#   POST /v1/admin/fee-configurations
#   POST /v1/admin/merchants/{merchant_id}/members
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

echo -e "${CYAN}━━━ Admin E2E — Merchants (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
pass "Admin token acquired (super_admin)"

step 2 "List merchants (admin)"
LIST_RES=$(curl -s "$BROPAY/v1/admin/merchants" -H "$ADMIN" -H "$ORIGIN")
LIST_COUNT=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_COUNT" -ge 1 ] || fail "Expected at least 1 merchant"
pass "Listed $LIST_COUNT merchant(s)"

step 3 "Search merchants by q (admin)"
SEARCH_RES=$(curl -s "$BROPAY/v1/admin/merchants?q=demo" \
  -H "$ADMIN" -H "$ORIGIN")
SEARCH_OK=$(echo "$SEARCH_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SEARCH_OK" = "True" ] || fail "Merchant search failed"
pass "Search returned results"

step 4 "GET merchant detail (admin)"
GET_RES=$(curl -s "$BROPAY/v1/admin/merchants/$DEMO_MERCHANT_ID" \
  -H "$ADMIN" -H "$ORIGIN")
GET_ID=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$GET_ID" = "$DEMO_MERCHANT_ID" ] || fail "GET detail mismatch"
pass "Detail fetched"

step 5 "Register owner account for new merchant"
OWNER_EMAIL="adminmerchant-$(date +%s)@e2e.local"
REG_RES=$(curl -s "$BROPAY/v1/auth/register" -H "$CT" -H "$ORIGIN" \
  -d "{\"email\":\"$OWNER_EMAIL\",\"password\":\"Password123!\",\"name\":\"Admin Owner\"}")
OWNER_TOKEN=$(echo "$REG_RES" | json "print(json.load(sys.stdin).get('data',{}).get('accessToken',''))")
[ -n "$OWNER_TOKEN" ] || fail "Owner registration failed"

ME_RES=$(curl -s "$BROPAY/v1/auth/me" -H "Authorization: Bearer $OWNER_TOKEN" -H "$ORIGIN")
OWNER_ID=$(echo "$ME_RES" | json "print(json.load(sys.stdin)['data']['id'])")
pass "Owner account: ${OWNER_ID:0:16}..."

step 6 "Create merchant with settings (admin)"
TS=$(date +%s)
CREATE_BODY=$(cat <<EOF
{
  "name": "Admin E2E Merchant $TS",
  "slug": "admin-e2e-$TS",
  "merchant_type": "limited_company",
  "owner_account_id": "$OWNER_ID",
  "tax_id": "1234567890123",
  "daily_transaction_limit": 50000000,
  "max_deposit_amount": 10000000,
  "max_payment_amount": 5000000,
  "risk_level": "medium",
  "settlement_frequency": "daily"
}
EOF
)
CREATE_RES=$(curl -s "$BROPAY/v1/admin/merchants" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "$CREATE_BODY")
MERCH_ID=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$MERCH_ID" ] || fail "Merchant creation failed"
CREATED_LIMIT=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('daily_transaction_limit',''))")
[ "$CREATED_LIMIT" = "50000000" ] || fail "Limit not set on create"
pass "Created: ${MERCH_ID:0:16}... with limits"

step 7 "Filter merchants by merchant_type=limited_company"
FT_RES=$(curl -s "$BROPAY/v1/admin/merchants?merchant_type=limited_company" \
  -H "$ADMIN" -H "$ORIGIN")
FT_COUNT=$(echo "$FT_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FT_COUNT" -ge 1 ] || fail "Expected at least 1 limited_company merchant"
pass "$FT_COUNT merchant(s) with type limited_company"

step 8 "Filter merchants by risk_level=medium"
FR_RES=$(curl -s "$BROPAY/v1/admin/merchants?risk_level=medium" \
  -H "$ADMIN" -H "$ORIGIN")
FR_COUNT=$(echo "$FR_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FR_COUNT" -ge 1 ] || fail "Expected at least 1 medium risk merchant"
pass "$FR_COUNT merchant(s) with risk_level medium"

step 9 "Sort merchants by name asc"
SN_RES=$(curl -s "$BROPAY/v1/admin/merchants?sort=name&order=asc" \
  -H "$ADMIN" -H "$ORIGIN")
SN_OK=$(echo "$SN_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SN_OK" = "True" ] || fail "Sort by name asc failed"
pass "Sorted by name asc"

step 10 "Sort merchants by status asc"
SS_RES=$(curl -s "$BROPAY/v1/admin/merchants?sort=status&order=asc" \
  -H "$ADMIN" -H "$ORIGIN")
SS_OK=$(echo "$SS_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SS_OK" = "True" ] || fail "Sort by status asc failed"
pass "Sorted by status asc"

step 11 "Sort merchants by risk_level desc"
SR_RES=$(curl -s "$BROPAY/v1/admin/merchants?sort=risk_level&order=desc" \
  -H "$ADMIN" -H "$ORIGIN")
SR_OK=$(echo "$SR_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SR_OK" = "True" ] || fail "Sort by risk_level desc failed"
pass "Sorted by risk_level desc"

step 12 "Search merchants by slug fragment"
SLUG_FRAG="${TS: -4}"
QS_RES=$(curl -s "$BROPAY/v1/admin/merchants?q=$SLUG_FRAG" \
  -H "$ADMIN" -H "$ORIGIN")
QS_COUNT=$(echo "$QS_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$QS_COUNT" -ge 1 ] || fail "Expected at least 1 result for slug fragment search"
pass "Slug fragment search returned $QS_COUNT result(s)"

step 13 "Pagination with order=asc"
PA_RES=$(curl -s "$BROPAY/v1/admin/merchants?sort=created_at&order=asc&limit=5" \
  -H "$ADMIN" -H "$ORIGIN")
PA_OK=$(echo "$PA_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$PA_OK" = "True" ] || fail "Pagination with order=asc failed"
pass "Pagination with order=asc returned results"

step 14 "GET merchant tree (admin)"
TREE_RES=$(curl -s "$BROPAY/v1/admin/merchants/$MERCH_ID/tree" \
  -H "$ADMIN" -H "$ORIGIN")
TREE_HAS_DATA=$(echo "$TREE_RES" | json "print('data' in json.load(sys.stdin))")
[ "$TREE_HAS_DATA" = "True" ] || fail "Tree missing data"
pass "Tree fetched"

step 15 "Create merchant-scoped fee config (admin)"
# Deactivate any existing active inbound fee config for this merchant first
EXISTING_FEE=$(curl -s "$BROPAY/v1/admin/fee-configurations?merchant_id=$MERCH_ID&stream_type=inbound&is_active=1" \
  -H "$ADMIN" -H "$ORIGIN")
EXISTING_FEE_ID=$(echo "$EXISTING_FEE" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')")
if [ -n "$EXISTING_FEE_ID" ]; then
  curl -s "$BROPAY/v1/admin/fee-configurations/$EXISTING_FEE_ID" -X PUT \
    -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{"is_active":0}' > /dev/null
fi
FEE_RES=$(curl -s "$BROPAY/v1/admin/fee-configurations" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"merchant_id\":\"$MERCH_ID\",\"stream_type\":\"inbound\",\"fee_percentage\":2.5,\"flat_fee_amount\":1500,\"is_active\":1}")
FEE_ID=$(echo "$FEE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$FEE_ID" ] || fail "Fee config creation failed"
pass "Fee config created: ${FEE_ID:0:16}..."

step 16 "List fee configs filtered by merchant (admin)"
FEE_LIST_RES=$(curl -s "$BROPAY/v1/admin/fee-configurations?merchant_id=$MERCH_ID" \
  -H "$ADMIN" -H "$ORIGIN")
FEE_LIST_COUNT=$(echo "$FEE_LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FEE_LIST_COUNT" -ge 1 ] || fail "Expected at least 1 fee config for merchant"
pass "$FEE_LIST_COUNT fee config(s) for merchant"

step 17 "PUT update merchant with additional fields"
PUT2_RES=$(curl -s "$BROPAY/v1/admin/merchants/$MERCH_ID" -X PUT \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"merchant_type":"public_company","industry_code":"5411","merchant_description":"E2E test merchant","auto_settlement_enabled":1,"monthly_transaction_limit":200000000,"can_resell":1}')
PUT2_TYPE=$(echo "$PUT2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('merchant_type',''))")
PUT2_CODE=$(echo "$PUT2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('industry_code',''))")
PUT2_DESC=$(echo "$PUT2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('merchant_description',''))")
PUT2_AUTO=$(echo "$PUT2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('auto_settlement_enabled',''))")
PUT2_MONTHLY=$(echo "$PUT2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('monthly_transaction_limit',''))")
PUT2_RESELL=$(echo "$PUT2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('can_resell',''))")
[ "$PUT2_TYPE" = "public_company" ] || fail "merchant_type not updated"
[ "$PUT2_CODE" = "5411" ] || fail "industry_code not updated"
[ "$PUT2_DESC" = "E2E test merchant" ] || fail "merchant_description not updated"
[ "$PUT2_AUTO" = "1" ] || fail "auto_settlement_enabled not updated"
[ "$PUT2_MONTHLY" = "200000000" ] || fail "monthly_transaction_limit not updated"
[ "$PUT2_RESELL" = "1" ] || fail "can_resell not updated"
pass "Additional fields updated"

step 18 "Guard: PUT with no fields returns 400"
PUT_EMPTY_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/merchants/$MERCH_ID" -X PUT \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{}')
PUT_EMPTY_HTTP=$(echo "$PUT_EMPTY_RES" | tail -n1)
[ "$PUT_EMPTY_HTTP" = "400" ] || fail "Expected 400 for empty PUT, got $PUT_EMPTY_HTTP"
pass "Empty PUT rejected with 400"

step 19 "PUT update merchant limits (admin)"
PUT_RES=$(curl -s "$BROPAY/v1/admin/merchants/$MERCH_ID" -X PUT \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"daily_transaction_limit":75000000,"max_deposit_amount":15000000}')
PUT_LIMIT=$(echo "$PUT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('daily_transaction_limit',''))")
[ "$PUT_LIMIT" = "75000000" ] || fail "Limit update failed"
pass "Limits updated"

step 20 "Filter merchants by can_resell=1"
FC_RES=$(curl -s "$BROPAY/v1/admin/merchants?can_resell=1" \
  -H "$ADMIN" -H "$ORIGIN")
FC_COUNT=$(echo "$FC_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FC_COUNT" -ge 1 ] || fail "Expected at least 1 merchant with can_resell=1"
pass "$FC_COUNT merchant(s) with can_resell=1"

step 21 "Register account to add as member"
MEM_EMAIL="member-$(date +%s)@e2e.local"
MEM_REG_RES=$(curl -s "$BROPAY/v1/auth/register" -H "$CT" -H "$ORIGIN" \
  -d "{\"email\":\"$MEM_EMAIL\",\"password\":\"Password123!\",\"name\":\"Member User\"}")
MEM_TOKEN=$(echo "$MEM_REG_RES" | json "print(json.load(sys.stdin).get('data',{}).get('accessToken',''))")
[ -n "$MEM_TOKEN" ] || fail "Member registration failed"

MEM_ME_RES=$(curl -s "$BROPAY/v1/auth/me" -H "Authorization: Bearer $MEM_TOKEN" -H "$ORIGIN")
MEM_ID=$(echo "$MEM_ME_RES" | json "print(json.load(sys.stdin)['data']['id'])")
pass "Member account: ${MEM_ID:0:16}..."

step 22 "Add member to merchant (admin)"
ADD_RES=$(curl -s "$BROPAY/v1/admin/merchants/$MERCH_ID/members" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"account_id\":\"$MEM_ID\",\"role\":\"manager\"}")
ADD_OK=$(echo "$ADD_RES" | json "print('data' in json.load(sys.stdin))")
[ "$ADD_OK" = "True" ] || fail "Add member failed"
pass "Member added"

step 23 "List merchant members (admin)"
MEM_LIST_RES=$(curl -s "$BROPAY/v1/admin/merchants/$MERCH_ID/members" \
  -H "$ADMIN" -H "$ORIGIN")
MEM_LIST_HAS_DATA=$(echo "$MEM_LIST_RES" | json "print('data' in json.load(sys.stdin))")
[ "$MEM_LIST_HAS_DATA" = "True" ] || fail "Member list missing data"
pass "Members listed"

step 24 "GET merchant bank accounts (admin)"
BA_RES=$(curl -s "$BROPAY/v1/admin/merchants/$MERCH_ID/bank-accounts" \
  -H "$ADMIN" -H "$ORIGIN")
BA_HAS_DATA=$(echo "$BA_RES" | json "print('data' in json.load(sys.stdin))")
[ "$BA_HAS_DATA" = "True" ] || fail "Bank accounts missing data"
pass "Bank accounts fetched"

step 25 "Activate merchant (admin)"
ACT_RES=$(curl -s "$BROPAY/v1/admin/merchants/$MERCH_ID/activate" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
ACT_STATUS=$(echo "$ACT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$ACT_STATUS" = "active" ] || fail "Activation failed"
pass "Activated"

step 26 "Filter merchants by status=active"
FSA_RES=$(curl -s "$BROPAY/v1/admin/merchants?status=active" \
  -H "$ADMIN" -H "$ORIGIN")
FSA_COUNT=$(echo "$FSA_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FSA_COUNT" -ge 1 ] || fail "Expected at least 1 active merchant"
pass "$FSA_COUNT active merchant(s)"

step 27 "Combined filter: status=active&risk_level=medium"
FCOMB_RES=$(curl -s "$BROPAY/v1/admin/merchants?status=active&risk_level=medium" \
  -H "$ADMIN" -H "$ORIGIN")
FCOMB_COUNT=$(echo "$FCOMB_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FCOMB_COUNT" -ge 1 ] || fail "Expected at least 1 active medium-risk merchant"
pass "$FCOMB_COUNT merchant(s) with status=active and risk_level=medium"

step 28 "Suspend merchant (admin)"
SUSP_RES=$(curl -s "$BROPAY/v1/admin/merchants/$MERCH_ID/suspend" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
SUSP_STATUS=$(echo "$SUSP_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$SUSP_STATUS" = "suspended" ] || fail "Suspension failed"
pass "Suspended"

step 29 "Re-activate merchant (admin)"
ACT2_RES=$(curl -s "$BROPAY/v1/admin/merchants/$MERCH_ID/activate" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
ACT2_STATUS=$(echo "$ACT2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$ACT2_STATUS" = "active" ] || fail "Re-activation failed"
pass "Re-activated"

step 30 "Block merchant (admin)"
BLOCK_RES=$(curl -s "$BROPAY/v1/admin/merchants/$MERCH_ID/block" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
BLOCK_STATUS=$(echo "$BLOCK_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$BLOCK_STATUS" = "blocked" ] || fail "Block failed"
pass "Blocked"

step 31 "Guard: block already-blocked merchant returns 409"
BLOCK2_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/merchants/$MERCH_ID/block" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
BLOCK2_HTTP=$(echo "$BLOCK2_RES" | tail -n1)
[ "$BLOCK2_HTTP" = "409" ] || fail "Expected 409 for double block, got $BLOCK2_HTTP"
pass "Double block rejected with 409"

step 32 "Register new owner for reassignment"
NEW_OWNER_EMAIL="newowner-$(date +%s)@e2e.local"
NEW_REG_RES=$(curl -s "$BROPAY/v1/auth/register" -H "$CT" -H "$ORIGIN" \
  -d "{\"email\":\"$NEW_OWNER_EMAIL\",\"password\":\"Password123!\",\"name\":\"New Owner\"}")
NEW_OWNER_TOKEN=$(echo "$NEW_REG_RES" | json "print(json.load(sys.stdin).get('data',{}).get('accessToken',''))")
[ -n "$NEW_OWNER_TOKEN" ] || fail "New owner registration failed"

NEW_ME_RES=$(curl -s "$BROPAY/v1/auth/me" -H "Authorization: Bearer $NEW_OWNER_TOKEN" -H "$ORIGIN")
NEW_OWNER_ID=$(echo "$NEW_ME_RES" | json "print(json.load(sys.stdin)['data']['id'])")
pass "New owner account: ${NEW_OWNER_ID:0:16}..."

step 33 "Assign new owner (admin)"
ASSIGN_RES=$(curl -s "$BROPAY/v1/admin/merchants/$MERCH_ID/assign-owner" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"account_id\":\"$NEW_OWNER_ID\"}")
ASSIGN_OK=$(echo "$ASSIGN_RES" | json "print(json.load(sys.stdin).get('data',{}).get('success',False))")
[ "$ASSIGN_OK" = "True" ] || fail "Assign owner failed"
pass "Owner reassigned"

step 34 "Close merchant (admin)"
CLOSE_RES=$(curl -s "$BROPAY/v1/admin/merchants/$MERCH_ID/close" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
CLOSE_STATUS=$(echo "$CLOSE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$CLOSE_STATUS" = "closed" ] || fail "Close failed"
pass "Closed"

step 35 "Guard: close already-closed merchant returns 409"
CLOSE2_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/merchants/$MERCH_ID/close" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
CLOSE2_HTTP=$(echo "$CLOSE2_RES" | tail -n1)
[ "$CLOSE2_HTTP" = "409" ] || fail "Expected 409 for double close, got $CLOSE2_HTTP"
pass "Double close rejected with 409"

echo -e "\n${GREEN}━━━ Merchants Realistic Lifecycle Complete ━━━${NC}"
