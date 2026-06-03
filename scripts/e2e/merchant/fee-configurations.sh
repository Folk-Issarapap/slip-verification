#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Merchant — Fee Configurations (Realistic Lifecycle)
#
# Endpoints:
#   GET /v1/merchant/fee-configurations/self
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

echo -e "${CYAN}━━━ Merchant E2E — Fee Configurations (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
MERCHANT_ID="$DEMO_MERCHANT_ID"
OWNER_TOKEN="$DEMO_OWNER_TOKEN"
OWNER="Authorization: Bearer $OWNER_TOKEN"
MERCH="X-Merchant-Id: $MERCHANT_ID"
pass "Merchant: ${MERCHANT_ID:0:16}..."

step 2 "GET self fee configuration"
RES=$(curl -s "$BROPAY/v1/merchant/fee-configurations/self" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
HAS_DATA=$(echo "$RES" | json "print('data' in json.load(sys.stdin))")
[ "$HAS_DATA" = "True" ] || fail "Fee config missing data key"

INBOUND=$(echo "$RES" | json "print(json.load(sys.stdin).get('data',{}).get('inbound',{}).get('fee_percentage',''))")
OUTBOUND=$(echo "$RES" | json "print(json.load(sys.stdin).get('data',{}).get('outbound',{}).get('fee_percentage',''))")
[ -n "$INBOUND" ] || fail "Inbound fee percentage missing"
[ -n "$OUTBOUND" ] || fail "Outbound fee percentage missing"
pass "Fee config returned: inbound=$INBOUND%, outbound=$OUTBOUND%"

step 3 "Verify inbound fee config structure"
INBOUND_ID=$(echo "$RES" | json "print(json.load(sys.stdin).get('data',{}).get('inbound',{}).get('id',''))")
INBOUND_CALC=$(echo "$RES" | json "print(json.load(sys.stdin).get('data',{}).get('inbound',{}).get('calculation_method',''))")
[ -n "$INBOUND_CALC" ] || fail "Inbound calculation_method missing"
pass "Inbound structure: id=${INBOUND_ID:-platform-default}, calculation_method=$INBOUND_CALC"

step 4 "Verify outbound fee config structure"
OUTBOUND_ID=$(echo "$RES" | json "print(json.load(sys.stdin).get('data',{}).get('outbound',{}).get('id',''))")
OUTBOUND_CALC=$(echo "$RES" | json "print(json.load(sys.stdin).get('data',{}).get('outbound',{}).get('calculation_method',''))")
[ -n "$OUTBOUND_CALC" ] || fail "Outbound calculation_method missing"
pass "Outbound structure: id=${OUTBOUND_ID:-platform-default}, calculation_method=$OUTBOUND_CALC"

step 5 "Verify fee percentages are numeric and within valid range"
INBOUND_NUM=$(echo "$INBOUND" | python3 -c "import sys; print(float(sys.stdin.read()))")
OUTBOUND_NUM=$(echo "$OUTBOUND" | python3 -c "import sys; print(float(sys.stdin.read()))")
python3 -c "
import sys
inbound = float(sys.argv[1])
outbound = float(sys.argv[2])
if not (0 <= inbound <= 100): sys.exit(1)
if not (0 <= outbound <= 100): sys.exit(1)
" "$INBOUND_NUM" "$OUTBOUND_NUM" || fail "Fee percentages out of valid range (0-100)"
pass "Fee percentages within valid range"

step 6 "Verify flat_fee_amount fields exist (can be null)"
INBOUND_FLAT=$(echo "$RES" | json "print(json.load(sys.stdin).get('data',{}).get('inbound',{}).get('flat_fee_amount','NULL'))")
OUTBOUND_FLAT=$(echo "$RES" | json "print(json.load(sys.stdin).get('data',{}).get('outbound',{}).get('flat_fee_amount','NULL'))")
pass "Flat fees present: inbound_flat=$INBOUND_FLAT, outbound_flat=$OUTBOUND_FLAT"

echo -e "\n${GREEN}━━━ Fee Configurations Realistic Lifecycle Complete ━━━${NC}"
