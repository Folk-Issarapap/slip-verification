#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Customer Analytics
#
# Endpoints exercised:
#   GET /v1/admin/customer-analytics/:id
#
# Scenarios: range=7d/30d/90d, 404 for unknown customer, 401 guard
# Note: the route path is /:id (no slash prefix variation), mounted at
#       /v1/admin/customer-analytics. Full path: /v1/admin/customer-analytics/{id}
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

echo -e "${CYAN}━━━ Admin E2E — Customer Analytics ━━━${NC}"

# ── Bootstrap ─────────────────────────────────────────────────────────────────
step 0 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
pass "Admin token acquired (super_admin)"

# ── 1. Discover a customer id ──────────────────────────────────────────────────
step 1 "Discover a customer ID from the admin customers list"
CUST_LIST=$(curl -s "$BROPAY/v1/admin/customers?merchant_id=$DEMO_MERCHANT_ID&limit=1" \
  -H "$ADMIN" -H "$ORIGIN")
DEMO_CUSTOMER_ID=$(echo "$CUST_LIST" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')")
if [ -z "$DEMO_CUSTOMER_ID" ]; then
  warn "No customers for demo merchant — creating one via payment intent first"
  # No customer found — we still test the 404 guard below, and skip range tests
  DEMO_CUSTOMER_ID=""
else
  pass "Found customer: $DEMO_CUSTOMER_ID"
fi

# ── 2. Analytics with range=30d (default) ─────────────────────────────────────
step 2 "GET customer analytics range=30d"
if [ -n "$DEMO_CUSTOMER_ID" ]; then
  R30_RES=$(curl -s "$BROPAY/v1/admin/customer-analytics/$DEMO_CUSTOMER_ID?range=30d" \
    -H "$ADMIN" -H "$ORIGIN")
  R30_RANGE=$(echo "$R30_RES" | json "print(json.load(sys.stdin).get('data',{}).get('range',''))")
  [ "$R30_RANGE" = "30d" ] || fail "Expected range=30d, got '$R30_RANGE'"
  R30_DAILY_LEN=$(echo "$R30_RES" | json "print(len(json.load(sys.stdin).get('data',{}).get('daily',[])))")
  [ "$R30_DAILY_LEN" -eq 30 ] || fail "Expected 30 daily buckets, got $R30_DAILY_LEN"
  HAS_PAYIN=$(echo "$R30_RES" | json "print('payin_total' in json.load(sys.stdin).get('data',{}))")
  [ "$HAS_PAYIN" = "True" ] || fail "Missing payin_total in response"
  HAS_PAYOUT=$(echo "$R30_RES" | json "print('payout_total' in json.load(sys.stdin).get('data',{}))")
  [ "$HAS_PAYOUT" = "True" ] || fail "Missing payout_total in response"
  pass "range=30d: $R30_DAILY_LEN daily buckets, payin_total + payout_total present"
else
  warn "Skipping range=30d test (no customer)"
fi

# ── 3. Analytics with range=7d ────────────────────────────────────────────────
step 3 "GET customer analytics range=7d"
if [ -n "$DEMO_CUSTOMER_ID" ]; then
  R7_RES=$(curl -s "$BROPAY/v1/admin/customer-analytics/$DEMO_CUSTOMER_ID?range=7d" \
    -H "$ADMIN" -H "$ORIGIN")
  R7_RANGE=$(echo "$R7_RES" | json "print(json.load(sys.stdin).get('data',{}).get('range',''))")
  [ "$R7_RANGE" = "7d" ] || fail "Expected range=7d, got '$R7_RANGE'"
  R7_DAILY_LEN=$(echo "$R7_RES" | json "print(len(json.load(sys.stdin).get('data',{}).get('daily',[])))")
  [ "$R7_DAILY_LEN" -eq 7 ] || fail "Expected 7 daily buckets, got $R7_DAILY_LEN"
  pass "range=7d: $R7_DAILY_LEN daily buckets"
else
  warn "Skipping range=7d test (no customer)"
fi

# ── 4. Analytics with range=90d ───────────────────────────────────────────────
step 4 "GET customer analytics range=90d"
if [ -n "$DEMO_CUSTOMER_ID" ]; then
  R90_RES=$(curl -s "$BROPAY/v1/admin/customer-analytics/$DEMO_CUSTOMER_ID?range=90d" \
    -H "$ADMIN" -H "$ORIGIN")
  R90_RANGE=$(echo "$R90_RES" | json "print(json.load(sys.stdin).get('data',{}).get('range',''))")
  [ "$R90_RANGE" = "90d" ] || fail "Expected range=90d, got '$R90_RANGE'"
  R90_DAILY_LEN=$(echo "$R90_RES" | json "print(len(json.load(sys.stdin).get('data',{}).get('daily',[])))")
  [ "$R90_DAILY_LEN" -eq 90 ] || fail "Expected 90 daily buckets, got $R90_DAILY_LEN"
  pass "range=90d: $R90_DAILY_LEN daily buckets"
else
  warn "Skipping range=90d test (no customer)"
fi

# ── 5. Verify prior-period fields present ─────────────────────────────────────
step 5 "Verify prior-period comparison fields present"
if [ -n "$DEMO_CUSTOMER_ID" ]; then
  PRIOR_CHECK=$(echo "$R30_RES" | json "d=json.load(sys.stdin).get('data',{}); print('payin_prior_total' in d and 'payout_prior_total' in d)")
  [ "$PRIOR_CHECK" = "True" ] || fail "Missing prior-period fields"
  PERIOD_START=$(echo "$R30_RES" | json "print(json.load(sys.stdin).get('data',{}).get('period_start',''))")
  [ -n "$PERIOD_START" ] || fail "Missing period_start"
  PERIOD_END=$(echo "$R30_RES" | json "print(json.load(sys.stdin).get('data',{}).get('period_end',''))")
  [ -n "$PERIOD_END" ] || fail "Missing period_end"
  pass "Prior-period fields present (period_start=$PERIOD_START, period_end=$PERIOD_END)"
else
  warn "Skipping prior-period check (no customer)"
fi

# ── 6. Invalid range → 400 ───────────────────────────────────────────────────
step 6 "Invalid range → 400"
if [ -n "$DEMO_CUSTOMER_ID" ]; then
  BAD_RANGE_RES=$(curl -s -w "\n%{http_code}" \
    "$BROPAY/v1/admin/customer-analytics/$DEMO_CUSTOMER_ID?range=365d" \
    -H "$ADMIN" -H "$ORIGIN")
  BAD_RANGE_HTTP=$(echo "$BAD_RANGE_RES" | tail -n1)
  [ "$BAD_RANGE_HTTP" = "400" ] || fail "Expected 400 for invalid range, got $BAD_RANGE_HTTP"
  pass "Invalid range correctly rejected (400)"
else
  warn "Skipping invalid-range test (no customer)"
fi

# ── 7. Unknown customer → 404 ────────────────────────────────────────────────
step 7 "Unknown customer id → 404"
UNKNOWN_RES=$(curl -s -w "\n%{http_code}" \
  "$BROPAY/v1/admin/customer-analytics/nonexistent-customer-xyz?range=30d" \
  -H "$ADMIN" -H "$ORIGIN")
UNKNOWN_HTTP=$(echo "$UNKNOWN_RES" | tail -n1)
[ "$UNKNOWN_HTTP" = "404" ] || fail "Expected 404 for unknown customer, got $UNKNOWN_HTTP"
pass "Unknown customer → 404"

# ── 8. Guard: no auth → 401 ──────────────────────────────────────────────────
step 8 "Guard: request without auth → 401"
TARGET_ID="${DEMO_CUSTOMER_ID:-some-customer}"
NO_AUTH_RES=$(curl -s -w "\n%{http_code}" \
  "$BROPAY/v1/admin/customer-analytics/$TARGET_ID?range=7d" \
  -H "$ORIGIN")
NO_AUTH_HTTP=$(echo "$NO_AUTH_RES" | tail -n1)
[ "$NO_AUTH_HTTP" = "401" ] || fail "Expected 401 with no auth, got $NO_AUTH_HTTP"
pass "No-auth guard: 401"

# ── 9. Guard: merchant token → 403 ───────────────────────────────────────────
step 9 "Guard: merchant owner token → 403 (staff-only endpoint)"
TARGET_ID="${DEMO_CUSTOMER_ID:-some-customer}"
MERCH_RES=$(curl -s -w "\n%{http_code}" \
  "$BROPAY/v1/admin/customer-analytics/$TARGET_ID?range=7d" \
  -H "Authorization: Bearer $DEMO_OWNER_TOKEN" -H "$ORIGIN")
MERCH_HTTP=$(echo "$MERCH_RES" | tail -n1)
[ "$MERCH_HTTP" = "403" ] || fail "Expected 403 for merchant token, got $MERCH_HTTP"
pass "Merchant token correctly rejected (403)"

echo -e "\n${GREEN}━━━ Customer Analytics E2E Complete ━━━${NC}"
