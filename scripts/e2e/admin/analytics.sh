#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Analytics
#
# Endpoints:
#   GET /v1/admin/analytics/dashboard
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROPAY="${BROPAY_URL:-http://localhost:8787}"
ORIGIN="Origin: http://localhost:3000"

GREEN='\033[0;32m' RED='\033[0;31m' CYAN='\033[0;36m' NC='\033[0m'
pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }
step() { echo -e "\n${CYAN}━━━ Step $1: $2 ━━━${NC}"; }
json() { python3 -c "import sys,json; $1" 2>/dev/null; }

echo -e "${CYAN}━━━ Admin E2E — Analytics ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
pass "Admin token acquired (super_admin)"

step 2 "GET admin analytics dashboard"
RES=$(curl -s "$BROPAY/v1/admin/analytics/dashboard" -H "$ADMIN" -H "$ORIGIN")
HAS_DATA=$(echo "$RES" | json "print('data' in json.load(sys.stdin))")
[ "$HAS_DATA" = "True" ] || fail "Dashboard missing data"
pass "Dashboard returned data"

echo -e "\n${GREEN}━━━ Analytics Flow Complete ━━━${NC}"
