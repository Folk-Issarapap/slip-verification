#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Merchant — Analytics (Realistic Lifecycle)
#
# Usage:
#   BROPAY_URL=http://localhost:8787 bash scripts/e2e/merchant/analytics.sh
#
# Environment: BROPAY_URL, BOOTSTRAP_MERCHANT_* (optional)
#
# Endpoints:
#   GET /v1/merchant/analytics/dashboard
#   GET /v1/merchant/analytics/report
#   GET /v1/merchant/analytics/money-flow
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROPAY="${BROPAY_URL:-http://localhost:8787}"
ORIGIN="Origin: http://localhost:3000"

GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[0;33m' CYAN='\033[0;36m' NC='\033[0m'
pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }
warn() { echo -e "${YELLOW}! $1${NC}"; }
step() { echo -e "\n${CYAN}━━━ Step $1: $2 ━━━${NC}"; }
json() { python3 -c "import sys,json; $1" 2>/dev/null; }

echo -e "${CYAN}━━━ Merchant E2E — Analytics (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
OWNER="Authorization: Bearer $DEMO_OWNER_TOKEN"
MERCH="X-Merchant-Id: $DEMO_MERCHANT_ID"
pass "Merchant: ${DEMO_MERCHANT_ID:0:16}..."

step 2 "GET analytics dashboard"
RES=$(curl -s "$BROPAY/v1/merchant/analytics/dashboard" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
HAS_DATA=$(echo "$RES" | json "print('data' in json.load(sys.stdin))")
[ "$HAS_DATA" = "True" ] || fail "Dashboard missing data key"
pass "Dashboard returned data"

step 3 "Verify wallet summary shape"
WALLET_STATUS=$(echo "$RES" | json "print(json.load(sys.stdin).get('data',{}).get('wallet',{}).get('status',''))")
[ -n "$WALLET_STATUS" ] || fail "Wallet status missing"
pass "Wallet status: $WALLET_STATUS"

step 4 "Verify payments summary shape"
PAYMENTS=$(echo "$RES" | json "print('payments' in json.load(sys.stdin).get('data',{}))")
[ "$PAYMENTS" = "True" ] || fail "Payments summary missing"
pass "Payments summary present"

step 5 "Verify payouts summary shape"
PAYOUTS=$(echo "$RES" | json "print('payouts' in json.load(sys.stdin).get('data',{}))")
[ "$PAYOUTS" = "True" ] || fail "Payouts summary missing"
pass "Payouts summary present"

step 6 "Verify settlements summary shape"
SETTLEMENTS=$(echo "$RES" | json "print('settlements' in json.load(sys.stdin).get('data',{}))")
[ "$SETTLEMENTS" = "True" ] || fail "Settlements summary missing"
pass "Settlements summary present"

step 7 "Verify recent activity is an array"
ACTIVITY=$(echo "$RES" | json "print(isinstance(json.load(sys.stdin).get('data',{}).get('recent_activity',[]), list))")
[ "$ACTIVITY" = "True" ] || fail "Recent activity is not a list"
pass "Recent activity is a list"

step 8 "Verify daily series is an array"
DAILY=$(echo "$RES" | json "print(isinstance(json.load(sys.stdin).get('data',{}).get('daily_series',[]), list))")
[ "$DAILY" = "True" ] || fail "Daily series is not a list"
pass "Daily series is a list"

step 9 "Verify daily payout series is an array"
DAILY_PAYOUT=$(echo "$RES" | json "print(isinstance(json.load(sys.stdin).get('data',{}).get('daily_payout_series',[]), list))")
[ "$DAILY_PAYOUT" = "True" ] || fail "Daily payout series is not a list"
pass "Daily payout series is a list"

step 10 "Verify daily wallet series is an array"
DAILY_WALLET=$(echo "$RES" | json "print(isinstance(json.load(sys.stdin).get('data',{}).get('daily_wallet_series',[]), list))")
[ "$DAILY_WALLET" = "True" ] || fail "Daily wallet series is not a list"
pass "Daily wallet series is a list"

step 11 "Guard: missing X-Merchant-Id returns 400"
NO_MERCH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/analytics/dashboard" \
  -H "$OWNER" -H "$ORIGIN")
NO_MERCH_HTTP=$(echo "$NO_MERCH_RES" | tail -n1)
[ "$NO_MERCH_HTTP" = "400" ] || fail "Expected 400 without X-Merchant-Id, got $NO_MERCH_HTTP"
pass "Missing X-Merchant-Id rejected with 400"

step 12 "Guard: invalid merchant id returns 404"
BAD_MERCH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/analytics/dashboard" \
  -H "$OWNER" -H "X-Merchant-Id: nonexistent-merchant-id" -H "$ORIGIN")
BAD_MERCH_HTTP=$(echo "$BAD_MERCH_RES" | tail -n1)
[ "$BAD_MERCH_HTTP" = "404" ] || fail "Expected 404 for invalid merchant, got $BAD_MERCH_HTTP"
pass "Invalid merchant rejected with 404"

step 13 "GET analytics report (range=30d)"
REPORT_RES=$(curl -s "$BROPAY/v1/merchant/analytics/report?range=30d" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
REPORT_HAS=$(echo "$REPORT_RES" | json "print('data' in json.load(sys.stdin))")
[ "$REPORT_HAS" = "True" ] || fail "Report missing data: $REPORT_RES"
pass "Report returned data"

step 14 "GET money-flow (range=30d)"
MF_RES=$(curl -s "$BROPAY/v1/merchant/analytics/money-flow?range=30d" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
MF_HAS=$(echo "$MF_RES" | json "print('data' in json.load(sys.stdin))")
[ "$MF_HAS" = "True" ] || fail "Money-flow missing data: $MF_RES"
MF_DAILY=$(echo "$MF_RES" | json "print(isinstance(json.load(sys.stdin).get('data',{}).get('daily',[]), list))")
[ "$MF_DAILY" = "True" ] || fail "Money-flow daily is not a list"
pass "Money-flow returned daily series"

echo -e "\n${GREEN}━━━ Analytics Realistic Lifecycle Complete ━━━${NC}"
