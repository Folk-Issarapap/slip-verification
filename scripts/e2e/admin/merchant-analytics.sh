#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Merchant Analytics
#
# Endpoints exercised:
#   GET /v1/admin/merchant-analytics/:id
#
# Scenarios: range=7d/30d/90d, custom from+to dates, 404 unknown merchant,
#            422 invalid date range, 401/403 guards
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROPAY="${BROPAY_URL:-http://localhost:8787}"
ORIGIN="Origin: http://localhost:3000"
CT="Content-Type: application/json"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }
warn() { echo -e "${YELLOW}! $1${NC}"; }
step() { echo -e "\n${CYAN}━━━ Step $1: $2 ━━━${NC}"; }
json() { python3 -c "import sys,json; $1" 2>/dev/null; }

echo -e "${CYAN}━━━ Admin E2E — Merchant Analytics ━━━${NC}"

# ── Bootstrap ─────────────────────────────────────────────────────────────────
step 0 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
pass "Admin token acquired (super_admin); merchant=$DEMO_MERCHANT_ID"

# ── 1. range=30d (default) ────────────────────────────────────────────────────
step 1 "GET merchant analytics range=30d"
R30_RES=$(curl -s "$BROPAY/v1/admin/merchant-analytics/$DEMO_MERCHANT_ID?range=30d" \
  -H "$ADMIN" -H "$ORIGIN")
R30_OK=$(echo "$R30_RES" | json "print('data' in json.load(sys.stdin))")
[ "$R30_OK" = "True" ] || fail "range=30d missing data: $R30_RES"
R30_RANGE=$(echo "$R30_RES" | json "print(json.load(sys.stdin).get('data',{}).get('range',''))")
[ "$R30_RANGE" = "30d" ] || fail "Expected range=30d, got '$R30_RANGE'"
R30_DAILY=$(echo "$R30_RES" | json "print(len(json.load(sys.stdin).get('data',{}).get('daily',[])))")
[ "$R30_DAILY" -eq 30 ] || fail "Expected 30 daily buckets, got $R30_DAILY"
pass "range=30d: $R30_DAILY daily buckets"

# ── 2. Verify KPI fields ──────────────────────────────────────────────────────
step 2 "Verify KPI fields present in response"
HAS_PAYIN=$(echo "$R30_RES" | json "print('payin_total' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_PAYIN" = "True" ] || fail "Missing payin_total"
HAS_PAYOUT=$(echo "$R30_RES" | json "print('payout_total' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_PAYOUT" = "True" ] || fail "Missing payout_total"
HAS_FEE=$(echo "$R30_RES" | json "print('fee_total' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_FEE" = "True" ] || fail "Missing fee_total"
HAS_PRIOR_PAYIN=$(echo "$R30_RES" | json "print('payin_prior_total' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_PRIOR_PAYIN" = "True" ] || fail "Missing payin_prior_total"
pass "KPI fields present: payin_total, payout_total, fee_total, payin_prior_total"

# ── 3. range=7d ───────────────────────────────────────────────────────────────
step 3 "GET merchant analytics range=7d"
R7_RES=$(curl -s "$BROPAY/v1/admin/merchant-analytics/$DEMO_MERCHANT_ID?range=7d" \
  -H "$ADMIN" -H "$ORIGIN")
R7_RANGE=$(echo "$R7_RES" | json "print(json.load(sys.stdin).get('data',{}).get('range',''))")
[ "$R7_RANGE" = "7d" ] || fail "Expected range=7d, got '$R7_RANGE'"
R7_DAILY=$(echo "$R7_RES" | json "print(len(json.load(sys.stdin).get('data',{}).get('daily',[])))")
[ "$R7_DAILY" -eq 7 ] || fail "Expected 7 daily buckets, got $R7_DAILY"
pass "range=7d: $R7_DAILY daily buckets"

# ── 4. range=90d ──────────────────────────────────────────────────────────────
step 4 "GET merchant analytics range=90d"
R90_RES=$(curl -s "$BROPAY/v1/admin/merchant-analytics/$DEMO_MERCHANT_ID?range=90d" \
  -H "$ADMIN" -H "$ORIGIN")
R90_RANGE=$(echo "$R90_RES" | json "print(json.load(sys.stdin).get('data',{}).get('range',''))")
[ "$R90_RANGE" = "90d" ] || fail "Expected range=90d, got '$R90_RANGE'"
R90_DAILY=$(echo "$R90_RES" | json "print(len(json.load(sys.stdin).get('data',{}).get('daily',[])))")
[ "$R90_DAILY" -eq 90 ] || fail "Expected 90 daily buckets, got $R90_DAILY"
pass "range=90d: $R90_DAILY daily buckets"

# ── 5. Custom from+to date range ─────────────────────────────────────────────
step 5 "GET merchant analytics with custom from+to dates"
# Cross-platform date helper
if date -d "30 days ago" +%Y-%m-%d >/dev/null 2>&1; then
  FROM_DATE=$(date -d "30 days ago" +%Y-%m-%d)
  TO_DATE=$(date +%Y-%m-%d)
else
  FROM_DATE=$(date -v-30d +%Y-%m-%d)
  TO_DATE=$(date +%Y-%m-%d)
fi
CUSTOM_RES=$(curl -s "$BROPAY/v1/admin/merchant-analytics/$DEMO_MERCHANT_ID?from=$FROM_DATE&to=$TO_DATE" \
  -H "$ADMIN" -H "$ORIGIN")
CUSTOM_OK=$(echo "$CUSTOM_RES" | json "print('data' in json.load(sys.stdin))")
[ "$CUSTOM_OK" = "True" ] || fail "Custom date range missing data: $CUSTOM_RES"
CUSTOM_NULL_RANGE=$(echo "$CUSTOM_RES" | json "print(json.load(sys.stdin).get('data',{}).get('range'))")
# When from+to are provided, range should be null (per MerchantMoneyFlowResponseSchema)
pass "Custom date range from=$FROM_DATE to=$TO_DATE accepted"

# ── 6. Verify integrations array ─────────────────────────────────────────────
step 6 "Verify integrations breakdown present"
HAS_INTEGRATIONS=$(echo "$R30_RES" | json "print('integrations' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_INTEGRATIONS" = "True" ] || fail "Missing integrations breakdown"
pass "Integrations breakdown field present"

# ── 7. Invalid range value → 400 ─────────────────────────────────────────────
step 7 "Invalid range value → 400"
BAD_RANGE_RES=$(curl -s -w "\n%{http_code}" \
  "$BROPAY/v1/admin/merchant-analytics/$DEMO_MERCHANT_ID?range=365d" \
  -H "$ADMIN" -H "$ORIGIN")
BAD_RANGE_HTTP=$(echo "$BAD_RANGE_RES" | tail -n1)
[ "$BAD_RANGE_HTTP" = "400" ] || fail "Expected 400 for invalid range, got $BAD_RANGE_HTTP"
pass "Invalid range correctly rejected (400)"

# ── 8. from > to → 422 ───────────────────────────────────────────────────────
step 8 "from > to → 422 (invalid date range)"
INVALID_DATE_RES=$(curl -s -w "\n%{http_code}" \
  "$BROPAY/v1/admin/merchant-analytics/$DEMO_MERCHANT_ID?from=2026-12-31&to=2026-01-01" \
  -H "$ADMIN" -H "$ORIGIN")
INVALID_DATE_HTTP=$(echo "$INVALID_DATE_RES" | tail -n1)
[ "$INVALID_DATE_HTTP" = "422" ] || fail "Expected 422 for from > to, got $INVALID_DATE_HTTP"
pass "from > to correctly rejected (422)"

# ── 9. Unknown merchant → 404 ────────────────────────────────────────────────
step 9 "Unknown merchant id → 404"
UNKNOWN_RES=$(curl -s -w "\n%{http_code}" \
  "$BROPAY/v1/admin/merchant-analytics/nonexistent-merchant-xyz?range=30d" \
  -H "$ADMIN" -H "$ORIGIN")
UNKNOWN_HTTP=$(echo "$UNKNOWN_RES" | tail -n1)
[ "$UNKNOWN_HTTP" = "404" ] || fail "Expected 404 for unknown merchant, got $UNKNOWN_HTTP"
pass "Unknown merchant → 404"

# ── 10. Guard: no auth → 401 ─────────────────────────────────────────────────
step 10 "Guard: request without auth → 401"
NO_AUTH_RES=$(curl -s -w "\n%{http_code}" \
  "$BROPAY/v1/admin/merchant-analytics/$DEMO_MERCHANT_ID?range=7d" \
  -H "$ORIGIN")
NO_AUTH_HTTP=$(echo "$NO_AUTH_RES" | tail -n1)
[ "$NO_AUTH_HTTP" = "401" ] || fail "Expected 401 with no auth, got $NO_AUTH_HTTP"
pass "No-auth guard: 401"

# ── 11. Guard: merchant owner token → 403 ────────────────────────────────────
step 11 "Guard: merchant owner token → 403 (staff-only endpoint)"
MERCH_RES=$(curl -s -w "\n%{http_code}" \
  "$BROPAY/v1/admin/merchant-analytics/$DEMO_MERCHANT_ID?range=7d" \
  -H "Authorization: Bearer $DEMO_OWNER_TOKEN" -H "$ORIGIN")
MERCH_HTTP=$(echo "$MERCH_RES" | tail -n1)
[ "$MERCH_HTTP" = "403" ] || fail "Expected 403 for merchant token, got $MERCH_HTTP"
pass "Merchant token correctly rejected (403)"

echo -e "\n${GREEN}━━━ Merchant Analytics E2E Complete ━━━${NC}"
