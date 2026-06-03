#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E — Run all top-level flow scripts
#
# Usage:
#   bash scripts/e2e/run-all.sh
#
# Runs:
#   e2e-merchant-onboarding.sh
#   e2e-staff-invitation-flow.sh
#   e2e-webhook-endpoint-flow.sh
#   e2e-payment-flow.sh
#   e2e-settlement-flow.sh
#   e2e-wallet-flow.sh
#   e2e-payout-cancel-flow.sh
#   e2e-payout-completion.sh
#   e2e-payout-failure-flow.sh
#   e2e-withdrawal-flow.sh
#   e2e-withdrawal-failure-flow.sh
#   e2e-kyc-verification-flow.sh
#   e2e-reseller-hierarchy.sh
#
# Skips:
#   kbnk-integration-test.sh (requires external KBNK staging)
# ──────────────────────────────────────────────────────────────────────────────

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROPAY="${BROPAY_URL:-http://localhost:8787}"

RED='\033[0;31m' GREEN='\033[0;32m' CYAN='\033[0;36m' NC='\033[0m'

FAILED=0
PASSED=0

SCRIPTS=(
  "e2e-merchant-onboarding.sh"
  "e2e-staff-invitation-flow.sh"
  "e2e-webhook-endpoint-flow.sh"
  "e2e-payment-flow.sh"
  "e2e-settlement-flow.sh"
  "e2e-wallet-flow.sh"
  "e2e-payout-cancel-flow.sh"
  "e2e-payout-completion.sh"
  "e2e-payout-failure-flow.sh"
  "e2e-reseller-hierarchy.sh"
  "e2e-hard-delete-flow.sh"
  "e2e-password-rotation-flow.sh"
  "e2e-withdrawal-flow.sh"
  "e2e-withdrawal-failure-flow.sh"
  "e2e-kyc-verification-flow.sh"
)

for name in "${SCRIPTS[@]}"; do
  f="$SCRIPT_DIR/$name"
  if [ ! -f "$f" ]; then
    echo -e "${RED}✗ $name not found${NC}"
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
