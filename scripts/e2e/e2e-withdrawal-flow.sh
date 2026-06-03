#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# BroPay E2E — Wallet withdrawal happy path (โปรดักต์เดิม)
#
# KBNK withdrawal.completed / withdrawal.failed ใน kbnk.ts จับเฉพาะ payouts
# ไม่ใช่ wallet_withdrawals — flow นี้จบที่ admin slip + POST .../complete
#
# Prerequisites: pnpm db:seed, pnpm dev:api (apps/api), bash, curl, python3, wrangler+D1
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/_lib.sh"
source "$SCRIPT_DIR/_merchant-lib.sh"

REPO_ROOT="$_E2E_REPO_ROOT"
export REPO_ROOT

DEPOSIT_ID=""
BROPAY="${BROPAY_URL:-http://localhost:8787}"
ORIGIN="Origin: http://localhost:3000"
CT="Content-Type: application/json"

http_get() {
  local url=$1
  shift
  local raw
  raw=$(curl -s -w "\n%{http_code}" "$url" "$@")
  HTTP_CODE=$(echo "$raw" | tail -1)
  HTTP_BODY=$(echo "$raw" | sed '$d')
}

http_post() {
  local url=$1
  shift
  local raw
  raw=$(curl -s -w "\n%{http_code}" "$url" -X POST "$@")
  HTTP_CODE=$(echo "$raw" | tail -1)
  HTTP_BODY=$(echo "$raw" | sed '$d')
}

wallet_field() {
  local field=$1
  http_get "$BROPAY/v1/merchant/wallets" -H "$OWNER" -H "$MERCH" -H "$ORIGIN"
  echo "$HTTP_BODY" | python3 -c "
import json, sys
field = sys.argv[1]
data = json.load(sys.stdin).get('data', {})
wallet = data[0] if isinstance(data, list) and data else data
print(int(wallet.get(field, 0)))
" "$field"
}

ensure_verified_bank_account() {
  http_get "$BROPAY/v1/merchant/bank-accounts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN"
  local count
  count=$(echo "$HTTP_BODY" | json "print(len(json.load(sys.stdin).get('data', [])))")
  if [ "$count" = "0" ]; then
    http_post "$BROPAY/v1/merchant/bank-accounts" \
      -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
      -d '{"bank_id":"bank-kbank-0000-0000-000000000001","account_number":"9876543210","account_holder_name":"Demo Merchant","account_type":"savings"}'
    [ "$HTTP_CODE" = "201" ] || fail "Bank account create failed ($HTTP_CODE): $HTTP_BODY"
  fi

  http_get "$BROPAY/v1/merchant/bank-accounts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN"
  BA_ID=$(echo "$HTTP_BODY" | json "data=json.load(sys.stdin).get('data', []); print(data[0]['id'] if data else '')")
  [ -n "$BA_ID" ] || fail "No merchant bank account found"

  d1_local_ok "UPDATE merchant_bank_accounts SET verification_status = 'verified', status = 'active' WHERE id = '$BA_ID'" \
    || fail "Failed to verify bank account in local D1"
}

upload_withdrawal_slip() {
  local withdrawal_id=$1
  local slip_rel=".e2e-withdrawal-slip-$$.png"
  local saved_pwd=$PWD
  cd "$REPO_ROOT"
  printf 'fake-png-data' > "$slip_rel"

  local raw
  raw=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/wallet-withdrawals/$withdrawal_id/slip" \
    -X POST \
    -H "$ADMIN" -H "$ORIGIN" \
    -F "file=@$slip_rel;type=image/png;filename=test-slip.png") || raw=$'\n000'
  rm -f "$slip_rel"
  cd "$saved_pwd"

  HTTP_CODE=$(echo "$raw" | tail -1)
  HTTP_BODY=$(echo "$raw" | sed '$d')
}

echo -e "${CYAN}### BroPay E2E Withdrawal completion flow (admin path) ###${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/_bootstrap.sh"
bootstrap_demo_merchant
merchant_auth_headers
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
pass "Merchant: ${DEMO_MERCHANT_ID:0:16}... Wallet: ${DEMO_WALLET_ID:0:16}..."

step 2 "Create and verify bank account"
ensure_verified_bank_account
pass "Bank account ready: ${BA_ID:0:16}..."

step 3 "Fund wallet (wallet-deposit + local D1 complete)"
FUND_AMOUNT=5000000
INITIAL_AVAILABLE=$(wallet_field available_balance)
INITIAL_RESERVED=$(wallet_field reserved_balance)
e2e_fund_wallet_via_deposit "$FUND_AMOUNT" "E2E withdrawal completion fund"
FUNDED_AVAILABLE=$((INITIAL_AVAILABLE + FUND_AMOUNT))
pass "Wallet funded to $FUNDED_AVAILABLE satang (deposit ${DEPOSIT_ID:0:12}...)"

step 4 "Create wallet withdrawal"
WITHDRAWAL_AMOUNT=100000
http_post "$BROPAY/v1/merchant/wallet-withdrawals" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"amount\":$WITHDRAWAL_AMOUNT,\"bank_account_id\":\"$BA_ID\",\"notes\":\"E2E withdrawal completion\"}"
[ "$HTTP_CODE" = "201" ] || fail "Withdrawal create failed ($HTTP_CODE): $HTTP_BODY"

WITHDRAWAL_ID=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin)['data']['id'])")
WITHDRAWAL_STATUS=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin)['data']['status'])")
[ "$WITHDRAWAL_STATUS" = "pending" ] || fail "Expected pending withdrawal, got $WITHDRAWAL_STATUS"
pass "Withdrawal created: ${WITHDRAWAL_ID:0:16}..."

step 5 "Verify reservation after create"
AFTER_CREATE_AVAILABLE=$(wallet_field available_balance)
AFTER_CREATE_RESERVED=$(wallet_field reserved_balance)
EXPECTED_AVAILABLE_AFTER_CREATE=$((FUNDED_AVAILABLE - WITHDRAWAL_AMOUNT))
EXPECTED_RESERVED_AFTER_CREATE=$((INITIAL_RESERVED + WITHDRAWAL_AMOUNT))
[ "$AFTER_CREATE_AVAILABLE" -eq "$EXPECTED_AVAILABLE_AFTER_CREATE" ] \
  || fail "available_balance mismatch after create: expected $EXPECTED_AVAILABLE_AFTER_CREATE, got $AFTER_CREATE_AVAILABLE"
[ "$AFTER_CREATE_RESERVED" -eq "$EXPECTED_RESERVED_AFTER_CREATE" ] \
  || fail "reserved_balance mismatch after create: expected $EXPECTED_RESERVED_AFTER_CREATE, got $AFTER_CREATE_RESERVED"
pass "Reservation OK: available=$AFTER_CREATE_AVAILABLE reserved=$AFTER_CREATE_RESERVED"

step 6 "Upload admin slip"
upload_withdrawal_slip "$WITHDRAWAL_ID"
[ "$HTTP_CODE" = "200" ] || fail "Slip upload failed ($HTTP_CODE): $HTTP_BODY"
pass "Slip uploaded"

step 7 "Admin complete withdrawal"
http_post "$BROPAY/v1/admin/wallet-withdrawals/$WITHDRAWAL_ID/complete" \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"bank_reference":"E2E-WIRE-001","notes":"E2E completed withdrawal"}'
[ "$HTTP_CODE" = "200" ] || fail "Admin complete failed ($HTTP_CODE): $HTTP_BODY"
COMPLETED_STATUS=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin)['data']['status'])")
[ "$COMPLETED_STATUS" = "completed" ] || fail "Expected completed status, got $COMPLETED_STATUS"
pass "Withdrawal completed"

step 8 "Verify final wallet state"
FINAL_AVAILABLE=$(wallet_field available_balance)
FINAL_RESERVED=$(wallet_field reserved_balance)
[ "$FINAL_AVAILABLE" -eq "$EXPECTED_AVAILABLE_AFTER_CREATE" ] \
  || fail "Final available_balance mismatch: expected $EXPECTED_AVAILABLE_AFTER_CREATE, got $FINAL_AVAILABLE"
[ "$FINAL_RESERVED" -eq "$INITIAL_RESERVED" ] \
  || fail "Final reserved_balance mismatch: expected $INITIAL_RESERVED, got $FINAL_RESERVED"
pass "Final wallet: available=$FINAL_AVAILABLE reserved=$FINAL_RESERVED"

step 9 "Verify withdrawal ledger"
http_get "$BROPAY/v1/merchant/wallets/ledger?q=$WITHDRAWAL_ID&limit=20" -H "$OWNER" -H "$MERCH" -H "$ORIGIN"
LEDGER_PAIRS=$(echo "$HTTP_BODY" | json "
import json, sys
data = json.load(sys.stdin).get('data', [])
print('|'.join(sorted(f\"{row['entry_type']}/{row['reference_type']}\" for row in data)))
")
echo "$LEDGER_PAIRS" | tr '|' '\n' | grep -Fx 'reserve/withdrawal' >/dev/null \
  || fail "Missing reserve/withdrawal ledger entry"
echo "$LEDGER_PAIRS" | tr '|' '\n' | grep -Fx 'release/withdrawal' >/dev/null \
  || fail "Missing release/withdrawal ledger entry"
echo "$LEDGER_PAIRS" | tr '|' '\n' | grep -Fx 'debit/withdrawal' >/dev/null \
  || fail "Missing debit/withdrawal ledger entry"
pass "Ledger entries OK: $LEDGER_PAIRS"

step 10 "Verify conservation and guard"
LEDGER_SUM=$(echo "$HTTP_BODY" | json "
import json, sys
total = 0
for row in json.load(sys.stdin).get('data', []):
    sign = 0
    if row['entry_type'] in ('credit', 'release'):
        sign = 1
    elif row['entry_type'] in ('debit', 'reserve'):
        sign = -1
    total += sign * int(row['amount'])
print(total)
")
[ "$LEDGER_SUM" -eq $((-1 * WITHDRAWAL_AMOUNT)) ] \
  || fail "Ledger signed sum mismatch: expected $((-1 * WITHDRAWAL_AMOUNT)), got $LEDGER_SUM"

http_post "$BROPAY/v1/merchant/wallet-withdrawals/$WITHDRAWAL_ID/cancel" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{"cancellation_reason":"should fail"}'
[ "$HTTP_CODE" = "422" ] || fail "Expected 422 cancelling completed withdrawal, got $HTTP_CODE"
pass "Completed withdrawal cannot be cancelled"

step 11 "Cleanup"
d1_local_quiet "DELETE FROM wallet_withdrawal_slips WHERE withdrawal_id = '$WITHDRAWAL_ID'"
d1_local_quiet "DELETE FROM audit_logs WHERE resource_type = 'wallet_withdrawal' AND resource_id = '$WITHDRAWAL_ID'"
d1_local_quiet "DELETE FROM wallet_ledger_entries WHERE reference_id = '$WITHDRAWAL_ID' AND reference_type = 'withdrawal'"
d1_local_quiet "DELETE FROM wallet_withdrawals WHERE id = '$WITHDRAWAL_ID'"
[ -n "${DEPOSIT_ID:-}" ] && d1_local_quiet "DELETE FROM wallet_ledger_entries WHERE reference_id = '$DEPOSIT_ID' AND reference_type = 'deposit'"
[ -n "${DEPOSIT_ID:-}" ] && d1_local_quiet "DELETE FROM wallet_deposits WHERE id = '$DEPOSIT_ID'"
d1_local_quiet "UPDATE wallets SET available_balance = $INITIAL_AVAILABLE, reserved_balance = $INITIAL_RESERVED, updated_at = datetime('now') WHERE id = '$DEMO_WALLET_ID'"
pass "Cleanup complete"

echo -e "\n${GREEN}### Withdrawal completion E2E passed ###${NC}"
