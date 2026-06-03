#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Merchant — Customer Analytics
#
# Prerequisites: API worker, python3, curl
#
# Usage:
#   BROPAY_URL=http://localhost:8787 bash scripts/e2e/merchant/customer-analytics.sh
#
# Environment:
#   BROPAY_URL              Base API URL (default: http://localhost:8787)
#   BOOTSTRAP_MERCHANT_ID   Override merchant (optional)
#   BOOTSTRAP_MERCHANT_SLUG Override slug (optional)
#
# External dependencies: None
#
# Endpoints:
#   GET /v1/merchant/customer-analytics/{id}?range=7d|30d|90d
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_merchant-lib.sh
source "$SCRIPT_DIR/../_merchant-lib.sh"

BROPAY="${BROPAY_URL:-http://localhost:8787}"
ORIGIN="Origin: http://localhost:3000"
CT="Content-Type: application/json"

echo -e "${CYAN}━━━ Merchant E2E — Customer Analytics ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
merchant_auth_headers
pass "Merchant: ${DEMO_MERCHANT_ID:0:16}..."

step 2 "Create customer for analytics"
TS=$(date +%s)
CUST_RES=$(curl -s "$BROPAY/v1/merchant/customers" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"first_name\":\"Ana\",\"last_name\":\"Stats\",\"email\":\"ana-stats-$TS@example.com\"}")
CUST_ID=$(echo "$CUST_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$CUST_ID" ] || fail "Customer create failed: $CUST_RES"
pass "Customer: ${CUST_ID:0:16}..."

step 3 "GET customer analytics range=30d"
R30_RES=$(curl -s "$BROPAY/v1/merchant/customer-analytics/$CUST_ID?range=30d" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
R30_RANGE=$(echo "$R30_RES" | json "print(json.load(sys.stdin).get('data',{}).get('range',''))")
[ "$R30_RANGE" = "30d" ] || fail "Expected range=30d, got '$R30_RANGE'"
R30_DAILY_LEN=$(echo "$R30_RES" | json "print(len(json.load(sys.stdin).get('data',{}).get('daily',[])))")
[ "$R30_DAILY_LEN" -eq 30 ] || fail "Expected 30 daily buckets, got $R30_DAILY_LEN"
pass "range=30d OK ($R30_DAILY_LEN buckets)"

step 4 "GET customer analytics range=7d"
R7_RES=$(curl -s "$BROPAY/v1/merchant/customer-analytics/$CUST_ID?range=7d" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
R7_DAILY_LEN=$(echo "$R7_RES" | json "print(len(json.load(sys.stdin).get('data',{}).get('daily',[])))")
[ "$R7_DAILY_LEN" -eq 7 ] || fail "Expected 7 daily buckets, got $R7_DAILY_LEN"
pass "range=7d OK"

step 5 "GET customer analytics range=90d"
R90_RES=$(curl -s "$BROPAY/v1/merchant/customer-analytics/$CUST_ID?range=90d" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
R90_DAILY_LEN=$(echo "$R90_RES" | json "print(len(json.load(sys.stdin).get('data',{}).get('daily',[])))")
[ "$R90_DAILY_LEN" -eq 90 ] || fail "Expected 90 daily buckets, got $R90_DAILY_LEN"
pass "range=90d OK"

step 6 "Guard: unknown customer returns 404"
BAD_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/customer-analytics/nonexistent-customer-id?range=30d" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
BAD_HTTP=$(echo "$BAD_RES" | tail -n1)
[ "$BAD_HTTP" = "404" ] || fail "Expected 404 for unknown customer, got $BAD_HTTP"
ERR_CODE=$(echo "$BAD_RES" | sed '$d' | json "print(json.load(sys.stdin).get('error',{}).get('code',''))")
[ -n "$ERR_CODE" ] || fail "404 response missing error.code"
pass "Unknown customer → 404 ($ERR_CODE)"

step 7 "Guard: missing X-Merchant-Id returns 400"
NO_MERCH_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/customer-analytics/$CUST_ID?range=30d" \
  -H "$OWNER" -H "$ORIGIN")
NO_MERCH_HTTP=$(echo "$NO_MERCH_RES" | tail -n1)
[ "$NO_MERCH_HTTP" = "400" ] || fail "Expected 400 without X-Merchant-Id, got $NO_MERCH_HTTP"
pass "Missing X-Merchant-Id → 400"

echo -e "\n${GREEN}━━━ Customer Analytics Complete ━━━${NC}"
