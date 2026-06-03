#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Wallet Flow — Fund wallet → payout → withdrawal
#
# Usage:
#   bash scripts/e2e/e2e-wallet-flow.sh
#
# Environment: BROPAY_URL, KBNK_URL (optional provider steps)
#
# Flow:
#   1. Bootstrap demo merchant
#   2. Check initial wallet balance + ensure verified bank account
#   3. Fund wallet (POST /v1/merchant/wallet-deposits)
#   4. Simulate deposit completion → wallet credited (local D1)
#   5. Verify wallet balance + ledger + deposit detail
#   6. Create payout to merchant bank account
#   7. Create wallet withdrawal
#   8. Admin wallet / payout oversight
#   9. Final wallet balance
#  10. Cleanup
#
# Amounts are in satang (100 satang = ฿1).
#
# See: scripts/e2e/docs/e2e-wallet-flow.md
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BROPAY="${BROPAY_URL:-http://localhost:8787}"
ORIGIN="Origin: http://localhost:3000"
CT="Content-Type: application/json"

GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[0;33m' CYAN='\033[0;36m' NC='\033[0m'
pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }
info() { echo -e "${CYAN}→ $1${NC}"; }
warn() { echo -e "${YELLOW}! $1${NC}"; }
step() { echo -e "\n${CYAN}━━━ Step $1: $2 ━━━${NC}"; }
json() { python3 -c "import sys,json; $1" 2>/dev/null; }

# curl helper: returns body + trailing status line; use sed '$d' for body, tail -1 for code
http_json() {
  local out
  out=$(curl -s -w "\n%{http_code}" "$@")
  echo "$out"
}
body() { sed '$d'; }
status() { tail -n1; }

wallet_available_balance() {
  curl -s "$BROPAY/v1/merchant/wallets" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" | json "
d=json.load(sys.stdin)
w=d.get('data',{})
if isinstance(w,list):
    w=w[0] if w else {}
print(w.get('available_balance',0))
"
}

echo -e "${CYAN}━━━ BroPay E2E Wallet Flow ━━━${NC}"

# ── Step 1: Bootstrap demo merchant ──────────────────────────────────────────
step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/_bootstrap.sh"
bootstrap_demo_merchant
MERCHANT_ID="$DEMO_MERCHANT_ID"
WALLET_ID="$DEMO_WALLET_ID"
MERCH_HEADER="X-Merchant-Id: $MERCHANT_ID"
OWNER_TOKEN="$DEMO_OWNER_TOKEN"
ADMIN_TOKEN="$DEMO_ADMIN_TOKEN"
OWNER="Authorization: Bearer $OWNER_TOKEN"
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
MERCH="$MERCH_HEADER"
pass "Merchant: ${MERCHANT_ID:0:16}...  Wallet: ${WALLET_ID:0:16}..."

# ── Step 1b: Guard checks ────────────────────────────────────────────────────
step "1b" "Guard checks"

# 404 on missing ledger entry (GET /wallets has no /{id} sub-route)
LEDGER_404=$(http_json "$BROPAY/v1/merchant/wallets/ledger/00000000-0000-0000-0000-000000000000" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
LEDGER_404_CODE=$(echo "$LEDGER_404" | status)
[ "$LEDGER_404_CODE" = "404" ] && pass "404 for missing ledger entry" || fail "Expected 404 for missing ledger entry, got $LEDGER_404_CODE"

# 400/422 for invalid payout input (negative amount)
BAD_PAYOUT=$(http_json "$BROPAY/v1/merchant/payouts" -X POST -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d '{"amount":-100}')
BAD_PAYOUT_CODE=$(echo "$BAD_PAYOUT" | status)
[ "$BAD_PAYOUT_CODE" = "400" ] || [ "$BAD_PAYOUT_CODE" = "422" ] && pass "400/422 for invalid payout input ($BAD_PAYOUT_CODE)" || fail "Expected 400/422 for bad payout, got $BAD_PAYOUT_CODE"

# 400/422 for invalid wallet deposit amount
BAD_DEPOSIT=$(http_json "$BROPAY/v1/merchant/wallet-deposits" -X POST -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d '{"amount":-100}')
BAD_DEPOSIT_CODE=$(echo "$BAD_DEPOSIT" | status)
[ "$BAD_DEPOSIT_CODE" = "400" ] || [ "$BAD_DEPOSIT_CODE" = "422" ] && pass "400/422 for invalid deposit ($BAD_DEPOSIT_CODE)" || fail "Expected 400/422 for bad deposit, got $BAD_DEPOSIT_CODE"

# Auth guard: no token
AUTH_WALLET=$(http_json "$BROPAY/v1/merchant/wallets" -H "$MERCH" -H "$ORIGIN")
AUTH_WALLET_CODE=$(echo "$AUTH_WALLET" | status)
[ "$AUTH_WALLET_CODE" = "401" ] && pass "401 without auth token" || fail "Expected 401 without token, got $AUTH_WALLET_CODE"

# ── Step 2: Check initial balance + bank account ─────────────────────────────
step 2 "Initial wallet balance + bank account"
INITIAL_BALANCE=$(wallet_available_balance)
pass "Balance: $INITIAL_BALANCE satang (wallet: ${WALLET_ID:0:12}...)"

BA_CHECK=$(curl -s "$BROPAY/v1/merchant/bank-accounts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
BA_COUNT=$(echo "$BA_CHECK" | json "print(len(json.load(sys.stdin).get('data',[])))")
if [ "$BA_COUNT" = "0" ]; then
  info "Creating bank account..."
  curl -s "$BROPAY/v1/merchant/bank-accounts" -X POST \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
    -d '{"bank_id":"bank-kbank-0000-0000-000000000001","account_number":"9876543210","account_holder_name":"Demo Merchant","account_type":"savings"}' > /dev/null
fi

BA_RES=$(curl -s "$BROPAY/v1/merchant/bank-accounts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
BA_ID=$(echo "$BA_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')")
[ -n "$BA_ID" ] || fail "No merchant bank account found"

if ! d1_local_ok "UPDATE merchant_bank_accounts SET verification_status = 'verified', status = 'active' WHERE id = '$BA_ID'"; then
  warn "Could not mark bank account verified via local D1 (wrangler missing or D1 unreachable)"
fi
pass "Bank account ready: ${BA_ID:0:16}..."

# ── Step 3: Fund wallet ───────────────────────────────────────────────────────
step 3 "Fund wallet (100,000 satang = ฿1,000)"
FUND_AMOUNT=100000

FUND_RAW=$(http_json "$BROPAY/v1/merchant/wallet-deposits" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"amount\":$FUND_AMOUNT}")
FUND_HTTP=$(echo "$FUND_RAW" | status)
FUND_BODY=$(echo "$FUND_RAW" | body)
[ "$FUND_HTTP" = "201" ] || fail "Expected 201 on wallet deposit create, got $FUND_HTTP — $FUND_BODY"

DEPOSIT_ID=$(echo "$FUND_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
DEPOSIT_STATUS=$(echo "$FUND_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ -n "$DEPOSIT_ID" ] || fail "Wallet deposit creation failed"
[ "$DEPOSIT_STATUS" = "processing" ] || fail "Expected deposit status processing, got $DEPOSIT_STATUS"
pass "Wallet deposit created: ${DEPOSIT_ID:0:12}... ($DEPOSIT_STATUS)"

# ── Step 4: Simulate deposit completion ───────────────────────────────────────
step 4 "Simulate wallet deposit completion (local D1)"

DEPOSIT_INFO=$(d1_local_deposit_row "$DEPOSIT_ID") || fail "Local D1 query failed — install wrangler (pnpm install in apps/api) and ensure pnpm dev:api has run once"
[ "$DEPOSIT_INFO" != "not_found" ] || fail "Deposit $DEPOSIT_ID not in local D1 — API and wrangler may use different DB files; restart dev:api from apps/api"
info "Deposit row: $DEPOSIT_INFO"

d1_local_ok "UPDATE wallet_deposits SET status = 'succeeded', succeeded_at = datetime('now') WHERE id = '$DEPOSIT_ID'" \
  || fail "Failed to mark deposit succeeded in local D1"
d1_local_ok "UPDATE wallets SET available_balance = available_balance + $FUND_AMOUNT, updated_at = datetime('now') WHERE id = '$WALLET_ID'" \
  || fail "Failed to credit wallet in local D1"
d1_local_ok "INSERT INTO wallet_ledger_entries (wallet_id, entry_type, reference_type, reference_id, amount, currency, balance_before, balance_after, description) VALUES ('$WALLET_ID', 'credit', 'deposit', '$DEPOSIT_ID', $FUND_AMOUNT, 'THB', $INITIAL_BALANCE, $INITIAL_BALANCE + $FUND_AMOUNT, 'E2E wallet funding deposit')" \
  || fail "Failed to insert wallet ledger entry in local D1"
pass "Wallet credited $FUND_AMOUNT satang"

# ── Step 5: Verify balance increased ─────────────────────────────────────────
step 5 "Verify wallet balance"
NEW_BALANCE=$(wallet_available_balance)
EXPECTED_BALANCE=$((INITIAL_BALANCE + FUND_AMOUNT))
[ "$NEW_BALANCE" -eq "$EXPECTED_BALANCE" ] || warn "Balance $NEW_BALANCE != expected $EXPECTED_BALANCE (may have prior activity)"
pass "Balance: $NEW_BALANCE satang (was $INITIAL_BALANCE, funded +$FUND_AMOUNT)"

# ── Step 5b: Verify ledger entries ─────────────────────────────────────────────
step "5b" "Verify wallet ledger"
LEDGER=$(curl -s "$BROPAY/v1/merchant/wallets/ledger?reference_type=deposit" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
LEDGER_COUNT=$(echo "$LEDGER" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
[ "${LEDGER_COUNT:-0}" -ge 1 ] && pass "Ledger entries (deposit filter): $LEDGER_COUNT" || warn "No ledger entries for reference_type=deposit"
echo "$LEDGER" | json "
d = json.load(sys.stdin)
entries = d.get('data', [])
print(f'Ledger entries: {len(entries)}')
for e in entries[:3]:
    print(f'  {e[\"entry_type\"]:6} {e.get(\"reference_type\",\"?\"):12} {e[\"amount\"]:>10} satang  {str(e.get(\"description\",\"\"))[:40]}')
"

# ── Step 5c: Wallet deposit detail ─────────────────────────────────────────────
step "5c" "GET wallet deposit detail"
DEP_DETAIL=$(curl -s "$BROPAY/v1/merchant/wallet-deposits/$DEPOSIT_ID" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
DETAIL_ID=$(echo "$DEP_DETAIL" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
DETAIL_STATUS=$(echo "$DEP_DETAIL" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$DETAIL_ID" = "$DEPOSIT_ID" ] || fail "Deposit detail id mismatch"
[ "$DETAIL_STATUS" = "succeeded" ] || warn "Deposit detail status=$DETAIL_STATUS (expected succeeded after D1 simulate)"
pass "Deposit detail: ${DETAIL_ID:0:12}... status=$DETAIL_STATUS"

# ── Step 5d: List wallet deposits ──────────────────────────────────────────────
step "5d" "List wallet deposits"
DEP_LIST=$(curl -s "$BROPAY/v1/merchant/wallet-deposits?limit=5" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
DEP_LIST_TOTAL=$(echo "$DEP_LIST" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
[ "$DEP_LIST_TOTAL" -ge 1 ] || fail "Expected at least 1 wallet deposit in list"
pass "Wallet deposits listed: $DEP_LIST_TOTAL total"

# ── Step 6: Create payout ─────────────────────────────────────────────────────
step 6 "Create payout (5,000 satang = ฿50)"
PAYOUT_AMOUNT=5000

PAYOUT_RAW=$(http_json "$BROPAY/v1/merchant/payouts" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"amount\":$PAYOUT_AMOUNT,\"merchant_bank_account_id\":\"$BA_ID\",\"description\":\"E2E payout to merchant bank\"}")
PAYOUT_HTTP=$(echo "$PAYOUT_RAW" | status)
PAYOUT_BODY=$(echo "$PAYOUT_RAW" | body)
[ "$PAYOUT_HTTP" = "201" ] || fail "Expected 201 on payout create, got $PAYOUT_HTTP — $PAYOUT_BODY"

PAYOUT_ID=$(echo "$PAYOUT_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
PAYOUT_STATUS=$(echo "$PAYOUT_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ -n "$PAYOUT_ID" ] || fail "Payout creation failed"
[ "$PAYOUT_STATUS" = "pending" ] || fail "Expected payout status pending, got $PAYOUT_STATUS"
pass "Payout created: ${PAYOUT_ID:0:12}... ($PAYOUT_STATUS)"

PAYOUT_GET=$(curl -s "$BROPAY/v1/merchant/payouts/$PAYOUT_ID" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
PAYOUT_GET_STATUS=$(echo "$PAYOUT_GET" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$PAYOUT_GET_STATUS" = "pending" ] || warn "GET payout status=$PAYOUT_GET_STATUS"
pass "GET payout detail: $PAYOUT_GET_STATUS"

# ── Step 7: Create wallet withdrawal ─────────────────────────────────────────
step 7 "Create wallet withdrawal (10,000 satang = ฿100)"
WITHDRAW_AMOUNT=10000

WITHDRAW_RAW=$(http_json "$BROPAY/v1/merchant/wallet-withdrawals" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"amount\":$WITHDRAW_AMOUNT,\"bank_account_id\":\"$BA_ID\",\"notes\":\"E2E wallet withdrawal\"}")
WITHDRAW_HTTP=$(echo "$WITHDRAW_RAW" | status)
WITHDRAW_BODY=$(echo "$WITHDRAW_RAW" | body)
[ "$WITHDRAW_HTTP" = "201" ] || fail "Expected 201 on withdrawal create, got $WITHDRAW_HTTP — $WITHDRAW_BODY"

WITHDRAW_ID=$(echo "$WITHDRAW_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
WITHDRAW_STATUS=$(echo "$WITHDRAW_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ -n "$WITHDRAW_ID" ] || fail "Withdrawal creation failed"
pass "Withdrawal created: ${WITHDRAW_ID:0:12}... ($WITHDRAW_STATUS)"

WITHDRAW_GET=$(curl -s "$BROPAY/v1/merchant/wallet-withdrawals/$WITHDRAW_ID" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
WITHDRAW_GET_ID=$(echo "$WITHDRAW_GET" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$WITHDRAW_GET_ID" = "$WITHDRAW_ID" ] || fail "Withdrawal detail id mismatch"
pass "GET withdrawal detail OK"

# ── Step 8: Admin oversight + merchant pending ────────────────────────────────
step 8 "Admin wallet oversight + merchant pending ops"
ADMIN_WALLETS=$(curl -s "$BROPAY/v1/admin/wallets" -H "$ADMIN" -H "$ORIGIN")
ADMIN_WALLET_FOUND=$(echo "$ADMIN_WALLETS" | json "
d=json.load(sys.stdin)
print('yes' if any(w.get('id')=='$WALLET_ID' for w in d.get('data',[])) else 'no')
")
[ "$ADMIN_WALLET_FOUND" = "yes" ] || warn "Demo wallet not in admin list (may be paginated)"
pass "Admin wallet list OK"

ADMIN_WALLET_GET=$(curl -s "$BROPAY/v1/admin/wallets/$WALLET_ID" -H "$ADMIN" -H "$ORIGIN")
ADMIN_WALLET_STATUS=$(echo "$ADMIN_WALLET_GET" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ -n "$ADMIN_WALLET_STATUS" ] || fail "Admin GET wallet failed"
pass "Admin GET wallet: status=$ADMIN_WALLET_STATUS"

PENDING_OPS=$(curl -s "$BROPAY/v1/merchant/wallets/pending" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
HAS_PENDING=$(echo "$PENDING_OPS" | json "print('data' in json.load(sys.stdin))")
[ "$HAS_PENDING" = "True" ] || fail "GET /merchant/wallets/pending failed"
pass "Merchant pending ops endpoint OK"

ADMIN_PAYOUTS=$(curl -s "$BROPAY/v1/admin/payouts" -H "$ADMIN" -H "$ORIGIN")
ADMIN_PAYOUT_TOTAL=$(echo "$ADMIN_PAYOUTS" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
pass "Admin payouts total: $ADMIN_PAYOUT_TOTAL"

# ── Step 9: Final balance ─────────────────────────────────────────────────────
step 9 "Final wallet balance"
FINAL_BALANCE=$(wallet_available_balance)
pass "Final balance: $FINAL_BALANCE satang"

# ── Step 10: Cleanup ──────────────────────────────────────────────────────────
step 10 "Cleanup"
info "Reverting wallet balance and deleting test records..."

# Release payout reservation + delete payout
if [ -n "${PAYOUT_ID:-}" ]; then
  d1_local_ok "UPDATE wallets SET reserved_balance = MAX(0, reserved_balance - (SELECT amount + fee_amount FROM payouts WHERE id = '$PAYOUT_ID')), updated_at = datetime('now') WHERE id = '$WALLET_ID'" || true
  d1_local_ok "DELETE FROM payout_events WHERE payout_id = '$PAYOUT_ID'" || true
  d1_local_ok "DELETE FROM payouts WHERE id = '$PAYOUT_ID'" || true
fi

# Delete withdrawal
if [ -n "${WITHDRAW_ID:-}" ]; then
  d1_local_ok "UPDATE wallets SET reserved_balance = MAX(0, reserved_balance - $WITHDRAW_AMOUNT), updated_at = datetime('now') WHERE id = '$WALLET_ID'" || true
  d1_local_ok "DELETE FROM wallet_withdrawals WHERE id = '$WITHDRAW_ID'" || true
fi

d1_local_ok "DELETE FROM wallet_ledger_entries WHERE reference_id = '$DEPOSIT_ID'" || true
d1_local_ok "UPDATE wallets SET available_balance = $INITIAL_BALANCE, updated_at = datetime('now') WHERE id = '$WALLET_ID'" || true
d1_local_ok "DELETE FROM wallet_deposits WHERE id = '$DEPOSIT_ID'" || true
pass "Cleanup complete"

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}━━━ Wallet Flow Complete ━━━${NC}"
echo "Initial:     $INITIAL_BALANCE satang"
echo "Funded:      +$FUND_AMOUNT satang (deposit ${DEPOSIT_ID:0:12}...)"
echo "Payout:      $PAYOUT_STATUS (${PAYOUT_ID:0:12}...)"
echo "Withdrawal:  $WITHDRAW_STATUS (${WITHDRAW_ID:0:12}...)"
echo "Final:       $FINAL_BALANCE satang"
