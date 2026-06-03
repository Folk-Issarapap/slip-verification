#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Run all admin API test scripts
# ──────────────────────────────────────────────────────────────────────────────

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROPAY="${BROPAY_URL:-http://localhost:8787}"

RED='\033[0;31m' GREEN='\033[0;32m' CYAN='\033[0;36m' NC='\033[0m'

FAILED=0
PASSED=0

for f in "$SCRIPT_DIR"/*.sh; do
  name=$(basename "$f")
  [ "$name" = "run-all.sh" ] && continue

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
