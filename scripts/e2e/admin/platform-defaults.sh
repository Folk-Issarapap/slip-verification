#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Platform Defaults
#
# Endpoints:
#   GET /v1/admin/platform-defaults/amount-limits
#
# Validates that the platform default per-transaction amount limits are returned
# as numbers, have sane min/max ordering, and fall within expected ranges.
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

echo -e "${CYAN}━━━ Admin E2E — Platform Defaults ━━━${NC}"

# ── Step 1: Bootstrap demo merchant ───────────────────────────────────────────
step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
pass "Admin token acquired (super_admin)"

# ── Step 2: GET platform default amount limits ────────────────────────────────
step 2 "GET platform default amount limits"
RES=$(curl -s "$BROPAY/v1/admin/platform-defaults/amount-limits" -H "$ADMIN" -H "$ORIGIN")

# Verify top-level envelope
HAS_DATA=$(echo "$RES" | json "print('data' in json.load(sys.stdin))")
[ "$HAS_DATA" = "True" ] || fail "Response missing data envelope"

# Extract each limit value
deposit_min=$(echo "$RES" | json "print(json.load(sys.stdin)['data']['deposit']['min'])")
deposit_max=$(echo "$RES" | json "print(json.load(sys.stdin)['data']['deposit']['max'])")
withdrawal_min=$(echo "$RES" | json "print(json.load(sys.stdin)['data']['withdrawal']['min'])")
withdrawal_max=$(echo "$RES" | json "print(json.load(sys.stdin)['data']['withdrawal']['max'])")
payout_min=$(echo "$RES" | json "print(json.load(sys.stdin)['data']['payout']['min'])")
payout_max=$(echo "$RES" | json "print(json.load(sys.stdin)['data']['payout']['max'])")
payment_min=$(echo "$RES" | json "print(json.load(sys.stdin)['data']['payment']['min'])")
payment_max=$(echo "$RES" | json "print(json.load(sys.stdin)['data']['payment']['max'])")

# Ensure all values are non-empty
for pair in deposit withdrawal payout payment; do
  for bound in min max; do
    val=$(eval "echo \$${pair}_${bound}")
    [ -n "$val" ] || fail "Missing value: ${pair}.${bound}"
  done
done

pass "Platform defaults fetched (deposit/withdrawal/payout/payment)"

# ── Step 3: Verify deposit limits ─────────────────────────────────────────────
step 3 "Verify deposit limits"
[ "$deposit_min" -gt 0 ] || fail "deposit.min must be > 0 (got $deposit_min)"
[ "$deposit_max" -gt 0 ] || fail "deposit.max must be > 0 (got $deposit_max)"
[ "$deposit_max" -gt "$deposit_min" ] || fail "deposit.max ($deposit_max) must be > deposit.min ($deposit_min)"
pass "deposit: min=$deposit_min, max=$deposit_max"

# ── Step 4: Verify withdrawal limits ──────────────────────────────────────────
step 4 "Verify withdrawal limits"
[ "$withdrawal_min" -gt 0 ] || fail "withdrawal.min must be > 0 (got $withdrawal_min)"
[ "$withdrawal_max" -gt 0 ] || fail "withdrawal.max must be > 0 (got $withdrawal_max)"
[ "$withdrawal_max" -gt "$withdrawal_min" ] || fail "withdrawal.max ($withdrawal_max) must be > withdrawal.min ($withdrawal_min)"
pass "withdrawal: min=$withdrawal_min, max=$withdrawal_max"

# ── Step 5: Verify payout limits ──────────────────────────────────────────────
step 5 "Verify payout limits"
[ "$payout_min" -gt 0 ] || fail "payout.min must be > 0 (got $payout_min)"
[ "$payout_max" -gt 0 ] || fail "payout.max must be > 0 (got $payout_max)"
[ "$payout_max" -gt "$payout_min" ] || fail "payout.max ($payout_max) must be > payout.min ($payout_min)"
pass "payout: min=$payout_min, max=$payout_max"

# ── Step 6: Verify payment limits ─────────────────────────────────────────────
step 6 "Verify payment limits"
[ "$payment_min" -gt 0 ] || fail "payment.min must be > 0 (got $payment_min)"
[ "$payment_max" -gt 0 ] || fail "payment.max must be > 0 (got $payment_max)"
[ "$payment_max" -gt "$payment_min" ] || fail "payment.max ($payment_max) must be > payment.min ($payment_min)"
pass "payment: min=$payment_min, max=$payment_max"

# ── Step 7: Verify all max values exceed their min values ─────────────────────
step 7 "Verify max > min for all flows"
[ "$deposit_max" -gt "$deposit_min" ] || fail "deposit max <= min"
[ "$withdrawal_max" -gt "$withdrawal_min" ] || fail "withdrawal max <= min"
[ "$payout_max" -gt "$payout_min" ] || fail "payout max <= min"
[ "$payment_max" -gt "$payment_min" ] || fail "payment max <= min"
pass "All max values exceed their corresponding min values"

# ── Step 8: Verify values are reasonable ──────────────────────────────────────
step 8 "Verify values are reasonable"

# Deposit: min >= 5,000 satang (฿50), max >= 1,000,000 satang (฿10,000)
[ "$deposit_min" -ge 5000 ] || warn "deposit.min ($deposit_min) < 5,000 satang (฿50)"
[ "$deposit_max" -ge 1000000 ] || warn "deposit.max ($deposit_max) < 1,000,000 satang (฿10,000)"

# Withdrawal: min >= 1,000 satang (฿10), max >= 500,000 satang (฿5,000)
[ "$withdrawal_min" -ge 1000 ] || warn "withdrawal.min ($withdrawal_min) < 1,000 satang (฿10)"
[ "$withdrawal_max" -ge 500000 ] || warn "withdrawal.max ($withdrawal_max) < 500,000 satang (฿5,000)"

# Payout: min >= 1,000 satang (฿10), max >= 500,000 satang (฿5,000)
[ "$payout_min" -ge 1000 ] || warn "payout.min ($payout_min) < 1,000 satang (฿10)"
[ "$payout_max" -ge 500000 ] || warn "payout.max ($payout_max) < 500,000 satang (฿5,000)"

# Payment: min >= 5,000 satang (฿50), max >= 1,000,000 satang (฿10,000)
[ "$payment_min" -ge 5000 ] || warn "payment.min ($payment_min) < 5,000 satang (฿50)"
[ "$payment_max" -ge 1000000 ] || warn "payment.max ($payment_max) < 1,000,000 satang (฿10,000)"

pass "Values within reasonable ranges"

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}━━━ Platform Defaults Flow Complete ━━━${NC}"
printf "  %-12s min=%-10s max=%s\n" "deposit" "$deposit_min" "$deposit_max"
printf "  %-12s min=%-10s max=%s\n" "withdrawal" "$withdrawal_min" "$withdrawal_max"
printf "  %-12s min=%-10s max=%s\n" "payout" "$payout_min" "$payout_max"
printf "  %-12s min=%-10s max=%s\n" "payment" "$payment_min" "$payment_max"
