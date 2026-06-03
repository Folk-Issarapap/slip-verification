#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Payout failure — KBNK withdrawal.failed → payout failed + reversal
#
# Provider withdrawal.failed resolves payouts via provider_transfer_id.
# No admin POST /complete for payouts — guard uses withdrawal.completed after failed.
#
# Usage:
#   bash scripts/e2e/e2e-payout-failure-flow.sh
#
# Prerequisites: pnpm db:seed, pnpm dev:api, apps/api/.dev.vars with ENCRYPTION_KEY
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
# shellcheck source=_merchant-lib.sh
source "$SCRIPT_DIR/_merchant-lib.sh"
# shellcheck source=_withdrawal-lib.sh
source "$SCRIPT_DIR/_withdrawal-lib.sh"

REPO_ROOT="$_E2E_REPO_ROOT"
BROPAY="${BROPAY_URL:-http://localhost:8787}"
ORIGIN="Origin: http://localhost:3000"
CT="Content-Type: application/json"

echo -e "${CYAN}━━━ BroPay E2E Payout failure (KBNK withdrawal.failed) ━━━${NC}"

step 1 "Bootstrap demo merchant"
# shellcheck source=_bootstrap.sh
source "$SCRIPT_DIR/_bootstrap.sh"
bootstrap_demo_merchant
merchant_auth_headers
pass "Merchant: ${DEMO_MERCHANT_ID:0:16}..."

step 1b "Preflight: cancel stale reservations + seed KBNK credentials"
preflight_withdrawal_wallet
# seed.sql omits token_endpoint; webhook handler needs valid HTTPS URLs (matches integration seedKbnkProvider).
e2e_d1_local_sql \
  "UPDATE providers SET status = 'active', api_endpoint = 'https://api.kbnk.test', token_endpoint = 'https://api.kbnk.test/auth/token' WHERE slug = 'kbnk'"
pass "Wallet preflight OK (reserved baseline=$RESERVED_BASELINE)"

step 2 "Create and verify bank account"
ensure_verified_bank_account
pass "Bank account verified"

step 3 "Fund wallet"
FUND_AMOUNT=5000000
INITIAL_BALANCE=$(merchant_wallet_field available_balance)
e2e_d1_local_sql \
  "UPDATE wallets SET available_balance = available_balance + $FUND_AMOUNT, updated_at = datetime('now') WHERE id = '$DEMO_WALLET_ID'"
FUNDED_BALANCE=$((INITIAL_BALANCE + FUND_AMOUNT))
PRE_PAYOUT_AVAIL=$FUNDED_BALANCE
pass "Funded to $FUNDED_BALANCE satang"

step 4 "Create payout"
PAYOUT_AMOUNT=100000
http_post "$BROPAY/v1/merchant/payouts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"amount\":$PAYOUT_AMOUNT,\"merchant_bank_account_id\":\"$BA_ID\",\"description\":\"E2E payout failure\"}"
[ "$HTTP_CODE" = "201" ] || fail "Payout create failed ($HTTP_CODE): $HTTP_BODY"
PAYOUT_ID=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin)['data']['id'])")
FEE_AMOUNT=$(echo "$HTTP_BODY" | json "print(int(json.load(sys.stdin)['data']['fee_amount']))")
TOTAL_DEBIT=$((PAYOUT_AMOUNT + FEE_AMOUNT))
pass "Payout pending (total_debit=$TOTAL_DEBIT)"

step 4b "Verify wallet reservation"
EXPECTED_AVAIL_AFTER=$((PRE_PAYOUT_AVAIL - TOTAL_DEBIT))
assert_wallet_reservation_delta "$TOTAL_DEBIT" "$EXPECTED_AVAIL_AFTER"
pass "Wallet reserved for payout"

step 5 "Set provider_transfer_id"
PROVIDER_TRANSFER_ID="kbnk-transfer-$(python3 -c 'import uuid; print(uuid.uuid4())')"
set_payout_provider_transfer_id "$PAYOUT_ID" "$PROVIDER_TRANSFER_ID"
pass "provider_transfer_id set"

step 6 "POST withdrawal.failed"
post_kbnk_webhook_expect_payout "withdrawal.failed" "$PROVIDER_TRANSFER_ID" "$PAYOUT_AMOUNT" "$PAYOUT_ID" "failed"
pass "withdrawal.failed → payout failed"

step 7 "Verify wallet restored"
FINAL_AVAIL=$(merchant_wallet_field available_balance)
FINAL_RESERVED=$(merchant_wallet_field reserved_balance)
[ "$FINAL_AVAIL" -eq "$PRE_PAYOUT_AVAIL" ] || fail "available: expected $PRE_PAYOUT_AVAIL, got $FINAL_AVAIL"
[ "$FINAL_RESERVED" -eq "$RESERVED_BASELINE" ] || fail "reserved: expected $RESERVED_BASELINE, got $FINAL_RESERVED"
pass "Wallet restored: available=$FINAL_AVAIL reserved=$FINAL_RESERVED"

step 8 "Verify reversal ledger (no completion release)"
http_get "$BROPAY/v1/merchant/wallets/ledger?q=$PAYOUT_ID&limit=50" -H "$OWNER" -H "$MERCH" -H "$ORIGIN"
LEDGER_SUMMARY=$(echo "$HTTP_BODY" | json "
import json, sys
d=json.load(sys.stdin)
pairs=set((e['entry_type'], e['reference_type']) for e in d.get('data',[]))
print('|'.join(sorted(f'{a}/{b}' for a,b in pairs)))
")
echo "$LEDGER_SUMMARY" | tr '|' '\n' | grep -Fx 'credit/payout_reversal' >/dev/null \
  || fail "Missing credit/payout_reversal"
echo "$LEDGER_SUMMARY" | tr '|' '\n' | grep -Fx 'release/payout_reversal' >/dev/null \
  || fail "Missing release/payout_reversal"
echo "$LEDGER_SUMMARY" | tr '|' '\n' | grep -Fx 'release/payout' >/dev/null \
  && fail "Unexpected release/payout (completion path)" || true
pass "Ledger reversals: $LEDGER_SUMMARY"

step 9 "Guard: duplicate withdrawal.failed is idempotent"
BEFORE_LEDGER_COUNT=$(e2e_d1_local_scalar \
  "SELECT COUNT(*) as c FROM wallet_ledger_entries WHERE reference_id = '$PAYOUT_ID'")
post_kbnk_webhook "withdrawal.failed" "$PROVIDER_TRANSFER_ID" "$PAYOUT_AMOUNT"
[ "$HTTP_CODE" = "200" ] || fail "Duplicate webhook should return 200"
DUP_AVAIL=$(merchant_wallet_field available_balance)
DUP_RESERVED=$(merchant_wallet_field reserved_balance)
[ "$DUP_AVAIL" -eq "$FINAL_AVAIL" ] || fail "Duplicate webhook changed available_balance"
[ "$DUP_RESERVED" -eq "$FINAL_RESERVED" ] || fail "Duplicate webhook changed reserved_balance"
AFTER_LEDGER_COUNT=$(e2e_d1_local_scalar \
  "SELECT COUNT(*) as c FROM wallet_ledger_entries WHERE reference_id = '$PAYOUT_ID'")
[ "$AFTER_LEDGER_COUNT" -eq "$BEFORE_LEDGER_COUNT" ] || fail "Duplicate webhook added ledger rows ($BEFORE_LEDGER_COUNT → $AFTER_LEDGER_COUNT)"
pass "Duplicate withdrawal.failed idempotent (ledger count=$AFTER_LEDGER_COUNT)"

step 10 "Guard: cancel failed payout returns 400"
http_post "$BROPAY/v1/merchant/payouts/$PAYOUT_ID/cancel" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d '{}'
[ "$HTTP_CODE" = "400" ] || fail "Expected 400 cancelling failed payout, got $HTTP_CODE"
pass "400 on cancel failed payout"

step 11 "Guard: withdrawal.completed after failed does not complete payout"
post_kbnk_webhook "withdrawal.completed" "$PROVIDER_TRANSFER_ID" "$PAYOUT_AMOUNT"
[ "$HTTP_CODE" = "200" ] || fail "withdrawal.completed after failed should return 200"
http_get "$BROPAY/v1/merchant/payouts/$PAYOUT_ID" -H "$OWNER" -H "$MERCH" -H "$ORIGIN"
STILL_FAILED=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin)['data']['status'])")
[ "$STILL_FAILED" = "failed" ] || fail "Expected payout still failed, got $STILL_FAILED"
POST_COMPLETE_AVAIL=$(merchant_wallet_field available_balance)
POST_COMPLETE_RESERVED=$(merchant_wallet_field reserved_balance)
[ "$POST_COMPLETE_AVAIL" -eq "$FINAL_AVAIL" ] || fail "completed-after-failed changed available_balance"
[ "$POST_COMPLETE_RESERVED" -eq "$FINAL_RESERVED" ] || fail "completed-after-failed changed reserved_balance"
pass "withdrawal.completed after failed left payout failed and wallet unchanged"

step 12 "Cleanup"
d1_local_quiet "DELETE FROM payout_events WHERE payout_id = '$PAYOUT_ID'"
d1_local_quiet "DELETE FROM wallet_ledger_entries WHERE reference_id = '$PAYOUT_ID'"
d1_local_quiet "DELETE FROM payouts WHERE id = '$PAYOUT_ID'"
d1_local_quiet \
  "UPDATE wallets SET available_balance = $INITIAL_BALANCE, reserved_balance = $RESERVED_BASELINE WHERE id = '$DEMO_WALLET_ID'"
pass "Cleanup complete"

echo -e "\n${GREEN}━━━ Payout failure E2E passed ━━━${NC}"
