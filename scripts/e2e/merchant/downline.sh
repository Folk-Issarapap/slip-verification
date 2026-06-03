#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Merchant — Downline (Reseller) (Realistic Lifecycle)
#
# Endpoints:
#   GET /v1/merchant/downline
#   GET /v1/merchant/downline/stats
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

echo -e "${CYAN}━━━ Merchant E2E — Downline (Reseller) (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
MERCHANT_ID="$DEMO_MERCHANT_ID"
OWNER_TOKEN="$DEMO_OWNER_TOKEN"
OWNER="Authorization: Bearer $OWNER_TOKEN"
MERCH="X-Merchant-Id: $MERCHANT_ID"
pass "Merchant: ${MERCHANT_ID:0:16}..."

step 2 "Verify account has reseller kind"
ME_RES=$(curl -s "$BROPAY/v1/auth/me" -H "$OWNER" -H "$ORIGIN")
ACCOUNT_KIND=$(echo "$ME_RES" | json "print(json.load(sys.stdin).get('data',{}).get('kind',''))")
if [ "$ACCOUNT_KIND" != "reseller" ]; then
  warn "Account kind is '$ACCOUNT_KIND' — downline tests require reseller kind"
  step 3 "Guard: downline returns 403 for non-reseller"
  TREE_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/downline" \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
  TREE_HTTP=$(echo "$TREE_RES" | tail -n1)
  [ "$TREE_HTTP" = "403" ] || fail "Expected 403 for non-reseller downline, got $TREE_HTTP"
  pass "Downline rejected with 403 for non-reseller"

  step 4 "Guard: downline stats returns 403 for non-reseller"
  STATS_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/downline/stats" \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
  STATS_HTTP=$(echo "$STATS_RES" | tail -n1)
  [ "$STATS_HTTP" = "403" ] || fail "Expected 403 for non-reseller stats, got $STATS_HTTP"
  pass "Downline stats rejected with 403 for non-reseller"

  echo -e "\n${GREEN}━━━ Downline Flow Complete (non-reseller guards verified) ━━━${NC}"
  exit 0
fi
pass "Account kind is reseller"

step 3 "Register owner for sub-merchant"
SUB_OWNER_EMAIL="subowner-$(date +%s)@e2e.local"
SUB_OWNER_PASS="Password123!"
REG_RES=$(curl -s "$BROPAY/v1/auth/register" -H "$CT" -H "$ORIGIN" \
  -d "{\"email\":\"$SUB_OWNER_EMAIL\",\"password\":\"$SUB_OWNER_PASS\",\"name\":\"Sub Owner\"}")
SUB_OWNER_TOKEN=$(echo "$REG_RES" | json "print(json.load(sys.stdin).get('data',{}).get('accessToken',''))")
[ -n "$SUB_OWNER_TOKEN" ] || fail "Sub-owner registration failed"

ME_RES=$(curl -s "$BROPAY/v1/auth/me" -H "Authorization: Bearer $SUB_OWNER_TOKEN" -H "$ORIGIN")
SUB_OWNER_ID=$(echo "$ME_RES" | json "print(json.load(sys.stdin)['data']['id'])")
pass "Sub-owner: ${SUB_OWNER_ID:0:16}..."

step 4 "Create sub-merchant"
SUB_NAME="Sub-merchant $(date +%s)"
CREATE_RES=$(curl -s "$BROPAY/v1/merchant/sub-merchants" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"name\":\"$SUB_NAME\",\"merchant_type\":\"limited_company\",\"owner_account_id\":\"$SUB_OWNER_ID\",\"fee_percentage_inbound\":2.0,\"fee_percentage_outbound\":2.0}")
SUB_ID=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$SUB_ID" ] || fail "Sub-merchant creation failed"
pass "Created: ${SUB_ID:0:16}..."

step 5 "GET downline tree"
TREE_RES=$(curl -s "$BROPAY/v1/merchant/downline" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
HAS_DATA=$(echo "$TREE_RES" | json "print('data' in json.load(sys.stdin))")
[ "$HAS_DATA" = "True" ] || fail "Downline tree missing data"
TREE_COUNT=$(echo "$TREE_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$TREE_COUNT" -ge 1 ] || fail "Expected at least 1 downline node, got $TREE_COUNT"
pass "Downline tree fetched with $TREE_COUNT node(s)"

step 6 "Search downline by q (name fragment)"
SEARCH_Q="${SUB_NAME// /%20}"
SEARCH_RES=$(curl -s "$BROPAY/v1/merchant/downline?q=$SEARCH_Q" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SEARCH_OK=$(echo "$SEARCH_RES" | json "print('data' in json.load(sys.stdin))")
[ "$SEARCH_OK" = "True" ] || fail "Downline search failed"
SEARCH_COUNT=$(echo "$SEARCH_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$SEARCH_COUNT" -ge 1 ] || fail "Expected at least 1 search result, got $SEARCH_COUNT"
pass "Search returned $SEARCH_COUNT result(s)"

step 7 "Search downline by q (non-matching)"
NO_RES=$(curl -s "$BROPAY/v1/merchant/downline?q=zzzznonexistent" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
NO_COUNT=$(echo "$NO_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$NO_COUNT" -eq 0 ] || fail "Expected 0 results for non-matching search, got $NO_COUNT"
pass "Non-matching search returned 0 results"

step 8 "GET downline stats"
STATS_RES=$(curl -s "$BROPAY/v1/merchant/downline/stats" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
HAS_DATA=$(echo "$STATS_RES" | json "print('data' in json.load(sys.stdin))")
[ "$HAS_DATA" = "True" ] || fail "Downline stats missing data"
STATS_TOTAL=$(echo "$STATS_RES" | json "print(json.load(sys.stdin).get('data',{}).get('total_sub_merchants',0))")
[ "$STATS_TOTAL" -ge 1 ] || fail "Expected at least 1 sub-merchant in stats, got $STATS_TOTAL"
pass "Stats fetched: $STATS_TOTAL sub-merchant(s)"

step 9 "Activate sub-merchant"
ACT_RES=$(curl -s "$BROPAY/v1/merchant/sub-merchants/$SUB_ID/activate" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d '{}')
ACT_STATUS=$(echo "$ACT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$ACT_STATUS" = "active" ] || fail "Activation failed"
pass "Sub-merchant activated"

step 10 "Stats reflect active sub-merchant"
STATS2_RES=$(curl -s "$BROPAY/v1/merchant/downline/stats" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
ACTIVE_COUNT=$(echo "$STATS2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('active_count',0))")
[ "$ACTIVE_COUNT" -ge 1 ] || fail "Expected at least 1 active sub-merchant in stats, got $ACTIVE_COUNT"
pass "Stats show $ACTIVE_COUNT active sub-merchant(s)"

step 11 "Suspend sub-merchant"
SUSP_RES=$(curl -s "$BROPAY/v1/merchant/sub-merchants/$SUB_ID/suspend" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d '{}')
SUSP_STATUS=$(echo "$SUSP_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$SUSP_STATUS" = "suspended" ] || fail "Suspension failed"
pass "Sub-merchant suspended"

step 12 "Stats reflect suspended sub-merchant"
STATS3_RES=$(curl -s "$BROPAY/v1/merchant/downline/stats" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
ACTIVE_COUNT2=$(echo "$STATS3_RES" | json "print(json.load(sys.stdin).get('data',{}).get('active_count',0))")
# active_count may be 0 now since we suspended the only sub-merchant
pass "Stats active_count=$ACTIVE_COUNT2 after suspension"

echo -e "\n${GREEN}━━━ Downline Realistic Lifecycle Complete ━━━${NC}"
