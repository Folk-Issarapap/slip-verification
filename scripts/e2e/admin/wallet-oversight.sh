#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Wallet Oversight (Realistic Lifecycle)
#
# Endpoints:
#   GET  /v1/admin/wallets
#   GET  /v1/admin/wallets/{id}
#   POST /v1/admin/wallets/{id}/adjust
#   POST /v1/admin/wallets/{id}/release-reserved
#   GET  /v1/admin/wallets/{id}/analytics
#   GET  /v1/admin/wallets/{id}/pending
#   GET  /v1/admin/wallets/{id}/ledger
#   PUT  /v1/admin/wallets/{id}
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
BROPAY="${BROPAY_URL:-http://localhost:8787}"
ORIGIN="Origin: http://localhost:3000"
CT="Content-Type: application/json"

GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[0;33m' CYAN='\033[0;36m' NC='\033[0m'
pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }
warn() { echo -e "${YELLOW}! $1${NC}"; }
step() { echo -e "\n${CYAN}━━━ Step $1: $2 ━━━${NC}"; }
json() { python3 -c "import sys,json; $1" 2>/dev/null; }

echo -e "${CYAN}━━━ Admin E2E — Wallet Oversight (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
pass "Admin token acquired (super_admin)"

WALLET_ID="$DEMO_WALLET_ID"
[ -n "$WALLET_ID" ] || fail "No wallet ID from bootstrap"

step 2 "List wallets for oversight (admin)"
LIST_RES=$(curl -s "$BROPAY/v1/admin/wallets" -H "$ADMIN" -H "$ORIGIN")
HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$HAS_META" = "True" ] || fail "Oversight list missing meta"
LIST_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_TOTAL" -ge 1 ] || fail "Expected at least 1 wallet"
pass "Listed $LIST_TOTAL wallet(s)"

step 3 "GET wallet detail with recent ledger entries (admin)"
DETAIL_RES=$(curl -s "$BROPAY/v1/admin/wallets/$WALLET_ID" -H "$ADMIN" -H "$ORIGIN")
DETAIL_ID=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$DETAIL_ID" = "$WALLET_ID" ] || fail "Detail mismatch"
BEFORE_BALANCE=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('available_balance',0))")
pass "Detail fetched (balance: $BEFORE_BALANCE)"

step 4 "GET wallet analytics (admin)"
ANALYTICS_RES=$(curl -s "$BROPAY/v1/admin/wallets/$WALLET_ID/analytics" \
  -H "$ADMIN" -H "$ORIGIN")
HAS_DATA=$(echo "$ANALYTICS_RES" | json "print('data' in json.load(sys.stdin))")
[ "$HAS_DATA" = "True" ] || fail "Analytics missing data"
pass "Analytics fetched"

step 5 "GET wallet pending items (admin)"
PENDING_RES=$(curl -s "$BROPAY/v1/admin/wallets/$WALLET_ID/pending" \
  -H "$ADMIN" -H "$ORIGIN")
HAS_DATA=$(echo "$PENDING_RES" | json "print('data' in json.load(sys.stdin))")
[ "$HAS_DATA" = "True" ] || fail "Pending missing data"
pass "Pending items fetched"

step 6 "Credit adjust wallet (admin)"
ADJUST_CREDIT_RES=$(curl -s "$BROPAY/v1/admin/wallets/$WALLET_ID/adjust" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"type":"credit","amount":250000,"reason":"e2e_test","description":"Credit adjustment for E2E testing"}')
ADJUST_CREDIT_OK=$(echo "$ADJUST_CREDIT_RES" | json "print('data' in json.load(sys.stdin))")
[ "$ADJUST_CREDIT_OK" = "True" ] || fail "Credit adjust failed"
CREDIT_BALANCE=$(echo "$ADJUST_CREDIT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('new_balance',0))")
pass "Credit adjust: new balance $CREDIT_BALANCE"

step 7 "Verify balance increased after credit"
[ "$CREDIT_BALANCE" -gt "$BEFORE_BALANCE" ] || fail "Expected balance to increase"
EXPECTED_AFTER_CREDIT=$((BEFORE_BALANCE + 250000))
[ "$CREDIT_BALANCE" -eq "$EXPECTED_AFTER_CREDIT" ] || fail "Expected $EXPECTED_AFTER_CREDIT, got $CREDIT_BALANCE"
pass "Balance correctly increased by 250000"

step 8 "Get wallet ledger filtered by manual_credit"
LEDGER_RES=$(curl -s "$BROPAY/v1/admin/wallets/$WALLET_ID/ledger?reference_type=manual_credit" \
  -H "$ADMIN" -H "$ORIGIN")
LEDGER_COUNT=$(echo "$LEDGER_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LEDGER_COUNT" -ge 1 ] || fail "Expected at least 1 manual_credit ledger entry"
pass "$LEDGER_COUNT manual_credit ledger entry(s)"

step 9 "Debit adjust wallet (admin)"
ADJUST_DEBIT_RES=$(curl -s "$BROPAY/v1/admin/wallets/$WALLET_ID/adjust" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"type":"debit","amount":100000,"reason":"e2e_test","description":"Debit adjustment for E2E testing"}')
ADJUST_DEBIT_OK=$(echo "$ADJUST_DEBIT_RES" | json "print('data' in json.load(sys.stdin))")
[ "$ADJUST_DEBIT_OK" = "True" ] || fail "Debit adjust failed"
DEBIT_BALANCE=$(echo "$ADJUST_DEBIT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('new_balance',0))")
pass "Debit adjust: new balance $DEBIT_BALANCE"

step 10 "Verify balance decreased after debit"
[ "$DEBIT_BALANCE" -lt "$CREDIT_BALANCE" ] || fail "Expected balance to decrease"
EXPECTED_AFTER_DEBIT=$((CREDIT_BALANCE - 100000))
[ "$DEBIT_BALANCE" -eq "$EXPECTED_AFTER_DEBIT" ] || fail "Expected $EXPECTED_AFTER_DEBIT, got $DEBIT_BALANCE"
pass "Balance correctly decreased by 100000"

step 11 "Guard: debit exceeds available balance → 422"
GUARD_DEBIT_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/wallets/$WALLET_ID/adjust" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"type\":\"debit\",\"amount\":9999999999,\"reason\":\"e2e_test\",\"description\":\"Should fail\"}")
GUARD_DEBIT_HTTP=$(echo "$GUARD_DEBIT_RES" | tail -n1)
[ "$GUARD_DEBIT_HTTP" = "422" ] || fail "Expected 422 for excessive debit, got $GUARD_DEBIT_HTTP"
pass "Correctly rejected excessive debit"

step 12 "Reserve funds via DB for release-reserved test"
# Read current reserved balance before adding
BEFORE_RES_DETAIL=$(curl -s "$BROPAY/v1/admin/wallets/$WALLET_ID" -H "$ADMIN" -H "$ORIGIN")
ORIG_RESERVED=$(echo "$BEFORE_RES_DETAIL" | json "print(json.load(sys.stdin).get('data',{}).get('reserved_balance',0))")
pushd "$REPO_ROOT/apps/api" > /dev/null
wrangler d1 execute bropay-db --local --command \
  "UPDATE wallets SET reserved_balance = reserved_balance + 50000, available_balance = available_balance - 50000, updated_at = datetime('now') WHERE id = '$WALLET_ID'" 2>/dev/null > /dev/null
popd > /dev/null
pass "Reserved 50000 satang via DB (was $ORIG_RESERVED)"

step 13 "Release reserved funds (admin)"
RELEASE_RES=$(curl -s "$BROPAY/v1/admin/wallets/$WALLET_ID/release-reserved" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"amount":50000,"reason":"e2e_test","description":"Release stuck reserved funds"}')
RELEASE_OK=$(echo "$RELEASE_RES" | json "print('data' in json.load(sys.stdin))")
[ "$RELEASE_OK" = "True" ] || fail "Release reserved failed"
RELEASED_AMOUNT=$(echo "$RELEASE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('released_amount',0))")
NEW_RESERVED=$(echo "$RELEASE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('new_reserved',0))")
NEW_AVAILABLE=$(echo "$RELEASE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('new_available',0))")
[ "$RELEASED_AMOUNT" -eq 50000 ] || fail "Expected 50000 released, got $RELEASED_AMOUNT"
[ "$NEW_RESERVED" -eq "$ORIG_RESERVED" ] || fail "Expected reserved back to $ORIG_RESERVED, got $NEW_RESERVED"
pass "Released $RELEASED_AMOUNT (reserved now $NEW_RESERVED, available now $NEW_AVAILABLE)"

step 14 "Guard: release-reserved amount exceeds reserved → 422"
GUARD_RELEASE_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/wallets/$WALLET_ID/release-reserved" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"amount":9999999999,"reason":"e2e_test","description":"Should fail"}')
GUARD_RELEASE_HTTP=$(echo "$GUARD_RELEASE_RES" | tail -n1)
[ "$GUARD_RELEASE_HTTP" = "422" ] || fail "Expected 422 for excessive release, got $GUARD_RELEASE_HTTP"
pass "Correctly rejected release exceeding reserved balance"

step 15 "Update wallet limits (admin)"
UPDATE_RES=$(curl -s "$BROPAY/v1/admin/wallets/$WALLET_ID" -X PUT \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"low_balance_threshold":500000,"alert_enabled":1,"daily_deposit_limit":10000000,"max_deposit_amount":5000000}')
UPDATE_OK=$(echo "$UPDATE_RES" | json "print('data' in json.load(sys.stdin))")
[ "$UPDATE_OK" = "True" ] || fail "Wallet update failed"
UPDATED_THRESHOLD=$(echo "$UPDATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('low_balance_threshold',''))")
[ "$UPDATED_THRESHOLD" = "500000" ] || fail "Threshold not updated"
UPDATED_ALERT=$(echo "$UPDATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('alert_enabled',''))")
[ "$UPDATED_ALERT" = "1" ] || fail "Alert not enabled"
pass "Wallet limits updated"

step 16 "Search wallets by q (admin)"
SEARCH_RES=$(curl -s "$BROPAY/v1/admin/wallets?q=Merchant" -H "$ADMIN" -H "$ORIGIN")
SEARCH_HAS_META=$(echo "$SEARCH_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SEARCH_HAS_META" = "True" ] || fail "Search missing meta"
SEARCH_TOTAL=$(echo "$SEARCH_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$SEARCH_TOTAL" -ge 1 ] || fail "Expected at least 1 search result"
pass "$SEARCH_TOTAL wallet(s) matching 'Merchant'"

step 17 "Filter wallets by merchant_id (admin)"
FILTER_RES=$(curl -s "$BROPAY/v1/admin/wallets?merchant_id=$DEMO_MERCHANT_ID" -H "$ADMIN" -H "$ORIGIN")
FILTER_HAS_META=$(echo "$FILTER_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$FILTER_HAS_META" = "True" ] || fail "Filter missing meta"
FILTER_TOTAL=$(echo "$FILTER_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FILTER_TOTAL" -ge 1 ] || fail "Expected at least 1 wallet for merchant"
pass "$FILTER_TOTAL wallet(s) for merchant"

step 18 "Get wallet ledger (admin)"
LEDGER_ALL_RES=$(curl -s "$BROPAY/v1/admin/wallets/$WALLET_ID/ledger" -H "$ADMIN" -H "$ORIGIN")
LEDGER_ALL_COUNT=$(echo "$LEDGER_ALL_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LEDGER_ALL_COUNT" -ge 2 ] || fail "Expected at least 2 ledger entries"
pass "$LEDGER_ALL_COUNT ledger entry(s)"

echo -e "\n${GREEN}━━━ Wallet Oversight Realistic Lifecycle Complete ━━━${NC}"
