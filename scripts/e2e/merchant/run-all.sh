#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Merchant — Run all merchant API test scripts
#
# Usage:
#   BROPAY_URL=http://localhost:8787 bash scripts/e2e/merchant/run-all.sh
#
# Environment:
#   BROPAY_URL  Base API URL (default: http://localhost:8787)
#
# Notes:
#   - Explicit script order (not filesystem glob) for stable dependencies.
#   - index.sh covers GET/PUT/PATCH /v1/merchant (profile); run early.
# ──────────────────────────────────────────────────────────────────────────────

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROPAY="${BROPAY_URL:-http://localhost:8787}"

RED='\033[0;31m' GREEN='\033[0;32m' CYAN='\033[0;36m' NC='\033[0m'

# Profile and read-heavy smokes first; mutations and integrations later.
MERCHANT_SCRIPTS=(
  index.sh
  analytics.sh
  audit-logs.sh
  bank-accounts.sh
  branding.sh
  commissions.sh
  customer-analytics.sh
  customer-bank-accounts.sh
  customers.sh
  downline.sh
  fee-configurations.sh
  integrations.sh
  invitations.sh
  members.sh
  payment-intents.sh
  payouts.sh
  settlements.sh
  sub-merchants.sh
  transactions.sh
  wallet-deposits.sh
  wallets.sh
  webhook-deliveries.sh
  webhook-endpoints.sh
)

FAILED=0
PASSED=0

for name in "${MERCHANT_SCRIPTS[@]}"; do
  f="$SCRIPT_DIR/$name"
  if [ ! -f "$f" ]; then
    echo -e "${RED}✗ missing script: $name${NC}" >&2
    ((FAILED++))
    continue
  fi

  echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${CYAN}  ▶ $name${NC}"
  echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

  if BROPAY_URL="$BROPAY" bash "$f"; then
    ((PASSED++))
  else
    echo -e "${RED}✗ $name FAILED${NC}"
    ((FAILED++))
  fi
done

echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}Passed: $PASSED${NC}  ${RED}Failed: $FAILED${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

[ "$FAILED" -eq 0 ] || exit 1
