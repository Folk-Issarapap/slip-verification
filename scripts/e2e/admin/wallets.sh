#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Wallets (Realistic Lifecycle)
#
# Endpoints:
#   GET  /v1/admin/wallets
#   GET  /v1/admin/wallets/{id}
#   GET  /v1/admin/wallets/{id}/ledger
#   PUT  /v1/admin/wallets/{id}
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROPAY="${BROPAY_URL:-http://localhost:8787}"
ORIGIN="Origin: http://localhost:3000"
CT="Content-Type: application/json"

GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[0;33m' CYAN='\033[0;36m' NC='\033[0m'
pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }
warn() { echo -e "${YELLOW}! $1${NC}"; }
step() { echo -e "\n${CYAN}━━━ Step $1: $2 ━━━${NC}"; }
json() { python3 -c "import sys,json; $1" 2>/dev/null; }

echo -e "${CYAN}━━━ Admin E2E — Wallets (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
pass "Admin token acquired (super_admin)"

WALLET_ID="$DEMO_WALLET_ID"
[ -n "$WALLET_ID" ] || fail "No wallet ID from bootstrap"

step 2 "List wallets — verify meta, total >= 1"
LIST_RES=$(curl -s "$BROPAY/v1/admin/wallets" -H "$ADMIN" -H "$ORIGIN")
HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$HAS_META" = "True" ] || fail "Wallet list missing meta"
LIST_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_TOTAL" -ge 1 ] || fail "Expected at least 1 wallet, got $LIST_TOTAL"
pass "Listed $LIST_TOTAL wallet(s)"

step 3 "Filter by status=active"
F1_RES=$(curl -s "$BROPAY/v1/admin/wallets?status=active" -H "$ADMIN" -H "$ORIGIN")
F1_TOTAL=$(echo "$F1_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$F1_TOTAL" -ge 1 ] || fail "Expected at least 1 active wallet, got $F1_TOTAL"
pass "$F1_TOTAL active wallet(s)"

step 4 "Filter by multi-status (active,frozen)"
F2_RES=$(curl -s "$BROPAY/v1/admin/wallets?status=active,frozen" -H "$ADMIN" -H "$ORIGIN")
F2_TOTAL=$(echo "$F2_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$F2_TOTAL" -ge 1 ] || fail "Expected at least 1 wallet for multi-status, got $F2_TOTAL"
pass "$F2_TOTAL wallet(s) for status=active,frozen"

step 5 "Filter by currency=THB"
F3_RES=$(curl -s "$BROPAY/v1/admin/wallets?currency=THB" -H "$ADMIN" -H "$ORIGIN")
F3_TOTAL=$(echo "$F3_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$F3_TOTAL" -ge 1 ] || fail "Expected at least 1 THB wallet, got $F3_TOTAL"
pass "$F3_TOTAL THB wallet(s)"

step 6 "Filter by merchant_id"
F4_RES=$(curl -s "$BROPAY/v1/admin/wallets?merchant_id=$DEMO_MERCHANT_ID" -H "$ADMIN" -H "$ORIGIN")
F4_TOTAL=$(echo "$F4_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$F4_TOTAL" -ge 1 ] || fail "Expected at least 1 wallet for merchant, got $F4_TOTAL"
F4_ID=$(echo "$F4_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')")
[ "$F4_ID" = "$WALLET_ID" ] || fail "Merchant filter returned wrong wallet"
pass "$F4_TOTAL wallet(s) for merchant $DEMO_MERCHANT_ID"

step 7 "Search by q (merchant name fragment 'Merchant')"
Q_RES=$(curl -s "$BROPAY/v1/admin/wallets?q=Merchant" -H "$ADMIN" -H "$ORIGIN")
Q_TOTAL=$(echo "$Q_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$Q_TOTAL" -ge 1 ] || fail "Expected at least 1 result for q=Merchant, got $Q_TOTAL"
pass "$Q_TOTAL wallet(s) matching 'Merchant'"

step 8 "Combined filter: status=active + currency=THB"
COMB_RES=$(curl -s "$BROPAY/v1/admin/wallets?status=active&currency=THB" -H "$ADMIN" -H "$ORIGIN")
COMB_TOTAL=$(echo "$COMB_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$COMB_TOTAL" -ge 1 ] || fail "Expected at least 1 active THB wallet, got $COMB_TOTAL"
COMB_FIRST_STATUS=$(echo "$COMB_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['status'] if d else '')")
COMB_FIRST_CURRENCY=$(echo "$COMB_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['currency'] if d else '')")
[ "$COMB_FIRST_STATUS" = "active" ] || fail "Expected status=active in combined filter"
[ "$COMB_FIRST_CURRENCY" = "THB" ] || fail "Expected currency=THB in combined filter"
pass "$COMB_TOTAL active THB wallet(s)"

step 9 "Sort by available_balance desc"
S1_RES=$(curl -s "$BROPAY/v1/admin/wallets?sort=available_balance&order=desc" -H "$ADMIN" -H "$ORIGIN")
S1_OK=$(echo "$S1_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$S1_OK" = "True" ] || fail "Sort desc response missing meta"
pass "Sorted by available_balance desc"

step 10 "Sort by created_at asc"
S2_RES=$(curl -s "$BROPAY/v1/admin/wallets?sort=created_at&order=asc" -H "$ADMIN" -H "$ORIGIN")
S2_OK=$(echo "$S2_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$S2_OK" = "True" ] || fail "Sort asc response missing meta"
S2_FIRST=$(echo "$S2_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['created_at'] if d else '')")
S2_LAST=$(echo "$S2_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[-1]['created_at'] if d else '')")
[ "$S2_FIRST" \< "$S2_LAST" ] || fail "Expected first created_at < last created_at when sorting asc"
pass "Sorted by created_at asc, oldest first"

step 11 "Paginate wallets"
PAGE1_RES=$(curl -s "$BROPAY/v1/admin/wallets?limit=1&page=1" -H "$ADMIN" -H "$ORIGIN")
PAGE1_COUNT=$(echo "$PAGE1_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE1_COUNT" -eq 1 ] || fail "Expected 1 wallet on page 1"
PAGE2_RES=$(curl -s "$BROPAY/v1/admin/wallets?limit=1&page=2" -H "$ADMIN" -H "$ORIGIN")
PAGE2_COUNT=$(echo "$PAGE2_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE2_COUNT" -eq 1 ] || fail "Expected 1 wallet on page 2"
pass "Pagination works (limit=1, page=1+2)"

step 12 "GET wallet detail — verify recent_entries and all balance fields"
DETAIL_RES=$(curl -s "$BROPAY/v1/admin/wallets/$WALLET_ID" -H "$ADMIN" -H "$ORIGIN")
DETAIL_ID=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$DETAIL_ID" = "$WALLET_ID" ] || fail "Detail ID mismatch"
HAS_ENTRIES=$(echo "$DETAIL_RES" | json "print('recent_entries' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_ENTRIES" = "True" ] || fail "Detail missing recent_entries"
HAS_AVAIL=$(echo "$DETAIL_RES" | json "print('available_balance' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_AVAIL" = "True" ] || fail "Detail missing available_balance"
HAS_RESV=$(echo "$DETAIL_RES" | json "print('reserved_balance' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_RESV" = "True" ] || fail "Detail missing reserved_balance"
HAS_ALLOC=$(echo "$DETAIL_RES" | json "print('allocated_balance' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_ALLOC" = "True" ] || fail "Detail missing allocated_balance"
HAS_UNALLOC=$(echo "$DETAIL_RES" | json "print('unallocated_balance' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_UNALLOC" = "True" ] || fail "Detail missing unallocated_balance"
pass "Detail fetched with recent_entries and all balance fields"

step 13 "GET wallet ledger — verify meta"
LEDGER_RES=$(curl -s "$BROPAY/v1/admin/wallets/$WALLET_ID/ledger" -H "$ADMIN" -H "$ORIGIN")
LEDGER_HAS_META=$(echo "$LEDGER_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$LEDGER_HAS_META" = "True" ] || fail "Ledger missing meta"
pass "Ledger listed with meta"

step 14 "Filter ledger by entry_type"
L1_RES=$(curl -s "$BROPAY/v1/admin/wallets/$WALLET_ID/ledger?entry_type=credit" -H "$ADMIN" -H "$ORIGIN")
L1_HAS_META=$(echo "$L1_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$L1_HAS_META" = "True" ] || fail "Ledger entry_type filter missing meta"
pass "Ledger filtered by entry_type=credit"

step 15 "Filter ledger by multi-reference_type"
L2_RES=$(curl -s "$BROPAY/v1/admin/wallets/$WALLET_ID/ledger?reference_type=manual_credit,manual_debit" -H "$ADMIN" -H "$ORIGIN")
L2_HAS_META=$(echo "$L2_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$L2_HAS_META" = "True" ] || fail "Ledger multi-reference_type filter missing meta"
pass "Ledger filtered by multi-reference_type"

step 16 "Sort ledger by created_at asc"
L3_RES=$(curl -s "$BROPAY/v1/admin/wallets/$WALLET_ID/ledger?order=asc" -H "$ADMIN" -H "$ORIGIN")
L3_HAS_META=$(echo "$L3_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$L3_HAS_META" = "True" ] || fail "Ledger asc sort missing meta"
L3_FIRST=$(echo "$L3_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['created_at'] if d else '')")
L3_LAST=$(echo "$L3_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[-1]['created_at'] if d else '')")
[ "$L3_FIRST" \< "$L3_LAST" ] || fail "Expected first created_at < last created_at in asc ledger sort"
pass "Ledger sorted by created_at asc, oldest first"

step 17 "Paginate ledger"
LP1_RES=$(curl -s "$BROPAY/v1/admin/wallets/$WALLET_ID/ledger?limit=2&page=1" -H "$ADMIN" -H "$ORIGIN")
LP1_COUNT=$(echo "$LP1_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$LP1_COUNT" -le 2 ] || fail "Expected at most 2 ledger entries on page 1"
LP1_LIMIT=$(echo "$LP1_RES" | json "print(json.load(sys.stdin)['meta']['limit'])")
[ "$LP1_LIMIT" -eq 2 ] || fail "Expected limit=2 in ledger pagination"
pass "Ledger pagination works (limit=2)"

step 18 "PUT update low_balance_threshold"
PUT1_RES=$(curl -s "$BROPAY/v1/admin/wallets/$WALLET_ID" -X PUT \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"low_balance_threshold":500000}')
PUT1_THRESHOLD=$(echo "$PUT1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('low_balance_threshold',''))")
[ "$PUT1_THRESHOLD" = "500000" ] || fail "Expected low_balance_threshold=500000, got $PUT1_THRESHOLD"
pass "low_balance_threshold updated to 500000"

step 19 "PUT update alert_enabled"
PUT2_RES=$(curl -s "$BROPAY/v1/admin/wallets/$WALLET_ID" -X PUT \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"alert_enabled":1}')
PUT2_ALERT=$(echo "$PUT2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('alert_enabled',''))")
[ "$PUT2_ALERT" = "1" ] || fail "Expected alert_enabled=1, got $PUT2_ALERT"
pass "alert_enabled updated to 1"

step 20 "PUT update daily_deposit_limit"
PUT3_RES=$(curl -s "$BROPAY/v1/admin/wallets/$WALLET_ID" -X PUT \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"daily_deposit_limit":10000000}')
PUT3_LIMIT=$(echo "$PUT3_RES" | json "print(json.load(sys.stdin).get('data',{}).get('daily_deposit_limit',''))")
[ "$PUT3_LIMIT" = "10000000" ] || fail "Expected daily_deposit_limit=10000000, got $PUT3_LIMIT"
pass "daily_deposit_limit updated to 10000000"

step 21 "Guard: try to close wallet (status=closed) → expect 422"
CLOSE_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/wallets/$WALLET_ID" -X PUT \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"status":"closed"}')
CLOSE_HTTP=$(echo "$CLOSE_RES" | tail -n1)
[ "$CLOSE_HTTP" = "422" ] || fail "Expected 422 for close with non-zero balances or active merchant, got $CLOSE_HTTP"
pass "Close wallet rejected with 422"

step 22 "Verify wallet still active after failed close"
VERIFY_RES=$(curl -s "$BROPAY/v1/admin/wallets/$WALLET_ID" -H "$ADMIN" -H "$ORIGIN")
VERIFY_STATUS=$(echo "$VERIFY_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$VERIFY_STATUS" = "active" ] || fail "Expected wallet to remain active, got '$VERIFY_STATUS'"
pass "Wallet still active after failed close attempt"

echo -e "\n${GREEN}━━━ Wallets Realistic Lifecycle Complete ━━━${NC}"
