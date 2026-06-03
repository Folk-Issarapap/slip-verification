#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Merchant — Payouts (Realistic Lifecycle)
#
# Endpoints:
#   GET  /v1/merchant/payouts
#   GET  /v1/merchant/payouts/{id}
#   POST /v1/merchant/payouts
#   POST /v1/merchant/payouts/{id}/cancel
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BROPAY="${BROPAY_URL:-http://localhost:8787}"
ORIGIN="Origin: http://localhost:3000"
CT="Content-Type: application/json"

GREEN='\033[0;32m' RED='\033[0;31m' YELLOW='\033[0;33m' CYAN='\033[0;36m' NC='\033[0m'
pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
step() { echo -e "\n${CYAN}━━━ Step $1: $2 ━━━${NC}"; }
json() { python3 -c "import sys,json; $1" 2>/dev/null; }

echo -e "${CYAN}━━━ Merchant E2E — Payouts (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
OWNER="Authorization: Bearer $DEMO_OWNER_TOKEN"
MERCH="X-Merchant-Id: $DEMO_MERCHANT_ID"
pass "Merchant: ${DEMO_MERCHANT_ID:0:16}..."

step 2 "Fetch a valid bank_id"
BANKS=$(curl -s "$BROPAY/v1/banks" -H "$ORIGIN")
BANK_ID=$(echo "$BANKS" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')")
BANK_ID="${BANK_ID:-bkk_bank}"
pass "Bank ID: $BANK_ID"

step 3 "Create bank account + verify via admin API (same DB as Worker)"
BA_RES=$(curl -s "$BROPAY/v1/merchant/bank-accounts" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"bank_id\":\"$BANK_ID\",\"account_number\":\"1111111111\",\"account_holder_name\":\"Payout Test\",\"account_type\":\"savings\"}")
BA_ID=$(echo "$BA_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$BA_ID" ] || fail "Bank account creation failed"

ADMIN_AUTH="Authorization: Bearer $DEMO_ADMIN_TOKEN"
BAV_RES=$(curl -s "$BROPAY/v1/admin/bank-account-verifications?merchant_bank_account_id=$BA_ID&limit=1" \
  -H "$ADMIN_AUTH" -H "$ORIGIN")
BAV_ID=$(echo "$BAV_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['id'] if d else '')")
[ -n "$BAV_ID" ] || fail "No verification row for bank account $BA_ID — $BAV_RES"
OV_RAW=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/bank-account-verifications/$BAV_ID/override" -X POST \
  -H "$ADMIN_AUTH" -H "$ORIGIN" -H "$CT" \
  -d '{"status":"verified","override_reason":"e2e merchant payouts shell"}')
OV_HTTP=$(echo "$OV_RAW" | tail -n1)
OV_BODY=$(echo "$OV_RAW" | sed '$d')
[ "$OV_HTTP" = "200" ] || fail "Verification override failed HTTP $OV_HTTP — $OV_BODY"
pass "Bank account verified via admin override: ${BA_ID:0:16}..."

step "3b" "Fund wallet for payout coverage (amount + fees, same DB as Worker)"
WALLET_DETAIL=$(curl -s "$BROPAY/v1/merchant/wallets" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
WALLET_BAL=$(echo "$WALLET_DETAIL" | json "print(json.load(sys.stdin).get('data',{}).get('available_balance',0))")
NEED_FUND=$(python3 -c "b=float('$WALLET_BAL' or 0); print('1' if b < 500000 else '0')")
# Two payouts (10k + 20k) + outbound fees — credit via admin API (no wrangler / D1 CLI)
if [ "$NEED_FUND" = "1" ]; then
  FUND_RAW=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/wallets/$DEMO_WALLET_ID/adjust" -X POST \
    -H "$ADMIN_AUTH" -H "$ORIGIN" -H "$CT" \
    -d '{"type":"credit","amount":5000000,"reason":"e2e_merchant_payouts","description":"Shell E2E — fund wallet for payout reservations"}')
  FUND_HTTP=$(echo "$FUND_RAW" | tail -n1)
  FUND_BODY=$(echo "$FUND_RAW" | sed '$d')
  [ "$FUND_HTTP" = "200" ] || fail "Wallet adjust failed HTTP $FUND_HTTP — $FUND_BODY"
  pass "Wallet credited for E2E payouts (+5000000 satang)"
else
  pass "Wallet already funded ($WALLET_BAL satang)"
fi

step 4 "Create payout A"
TS=$(date +%s)
PO_A_RES=$(curl -s "$BROPAY/v1/merchant/payouts" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"amount\":10000,\"merchant_bank_account_id\":\"$BA_ID\",\"description\":\"E2E payout A\",\"idempotency_key\":\"e2e-payout-a-$TS\"}")
PO_A_ID=$(echo "$PO_A_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$PO_A_ID" ] || fail "Payout A creation failed"
PO_A_STATUS=$(echo "$PO_A_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$PO_A_STATUS" = "pending" ] || warn "Payout A status is $PO_A_STATUS (expected pending)"
pass "Payout A created: ${PO_A_ID:0:16}..."

step 5 "Create payout B"
PO_B_RES=$(curl -s "$BROPAY/v1/merchant/payouts" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"amount\":20000,\"merchant_bank_account_id\":\"$BA_ID\",\"description\":\"E2E payout B\",\"idempotency_key\":\"e2e-payout-b-$TS\"}")
PO_B_ID=$(echo "$PO_B_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$PO_B_ID" ] || fail "Payout B creation failed"
pass "Payout B created: ${PO_B_ID:0:16}..."

step 6 "List payouts — verify both appear"
LIST_RES=$(curl -s "$BROPAY/v1/merchant/payouts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
LIST_COUNT=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_COUNT" -ge 2 ] || fail "Expected at least 2 payouts, got $LIST_COUNT"
pass "Listed $LIST_COUNT payout(s)"

step 7 "Filter payouts by status=pending"
FILT_RES=$(curl -s "$BROPAY/v1/merchant/payouts?status=pending" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
FILT_COUNT=$(echo "$FILT_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FILT_COUNT" -ge 2 ] || fail "Expected at least 2 pending payouts, got $FILT_COUNT"
pass "$FILT_COUNT pending payout(s)"

step 8 "Search payouts by q (id fragment)"
Q_RES=$(curl -s "$BROPAY/v1/merchant/payouts?q=${PO_A_ID: -8}" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
Q_COUNT=$(echo "$Q_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$Q_COUNT" -ge 1 ] || fail "Expected at least 1 result for id search, got $Q_COUNT"
pass "$Q_COUNT result(s) for id search"

step 9 "Sort payouts by amount desc"
SORT_RES=$(curl -s "$BROPAY/v1/merchant/payouts?sort=amount&order=desc" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT_OK=$(echo "$SORT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_OK" = "True" ] || fail "Sort by amount desc failed"
pass "Sorted by amount desc"

step 10 "Sort payouts by status asc"
SORT2_RES=$(curl -s "$BROPAY/v1/merchant/payouts?sort=status&order=asc" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT2_OK=$(echo "$SORT2_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT2_OK" = "True" ] || fail "Sort by status asc failed"
pass "Sorted by status asc"

step 11 "Pagination limit=1"
PAGE_RES=$(curl -s "$BROPAY/v1/merchant/payouts?limit=1&page=1" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
PAGE_LIMIT=$(echo "$PAGE_RES" | json "print(json.load(sys.stdin)['meta']['limit'])")
PAGE_COUNT=$(echo "$PAGE_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE_LIMIT" -eq 1 ] || fail "Expected limit=1, got $PAGE_LIMIT"
[ "$PAGE_COUNT" -eq 1 ] || fail "Expected 1 item in page, got $PAGE_COUNT"
pass "Pagination limit=1 works"

step 12 "GET payout A detail with events"
GET_RES=$(curl -s "$BROPAY/v1/merchant/payouts/$PO_A_ID" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
GET_ID=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$GET_ID" = "$PO_A_ID" ] || fail "GET detail mismatch"
GET_HAS_EVENTS=$(echo "$GET_RES" | json "print('events' in json.load(sys.stdin).get('data',{}))")
[ "$GET_HAS_EVENTS" = "True" ] || fail "Detail missing events array"
pass "Detail fetched with events"

step 13 "Cancel payout A"
CANCEL_RES=$(curl -s "$BROPAY/v1/merchant/payouts/$PO_A_ID/cancel" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{"cancellation_reason":"E2E test cancellation"}')
CANCEL_STATUS=$(echo "$CANCEL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$CANCEL_STATUS" = "cancelled" ] || fail "Cancel failed, status=$CANCEL_STATUS"
pass "Payout A cancelled"

step 14 "Verify cancelled payout no longer in pending filter"
FILT2_RES=$(curl -s "$BROPAY/v1/merchant/payouts?status=pending" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
FILT2_IDS=$(echo "$FILT2_RES" | json "print(json.dumps([d['id'] for d in json.load(sys.stdin).get('data',[])]))")
if echo "$FILT2_IDS" | grep -q "$PO_A_ID"; then
  fail "Cancelled payout still in pending filter"
fi
pass "Cancelled payout no longer in pending filter"

step 15 "Guard: cancel already-cancelled payout returns 400"
CANCEL2_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/payouts/$PO_A_ID/cancel" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d '{}')
CANCEL2_HTTP=$(echo "$CANCEL2_RES" | tail -n1)
[ "$CANCEL2_HTTP" = "400" ] || fail "Expected 400 for double cancel, got $CANCEL2_HTTP"
pass "Double cancel rejected with 400"

step 16 "Guard: idempotency — duplicate payout with same key returns same payout"
IDEM_RES=$(curl -s "$BROPAY/v1/merchant/payouts" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"amount\":99999,\"merchant_bank_account_id\":\"$BA_ID\",\"description\":\"Should not create new\",\"idempotency_key\":\"e2e-payout-a-$TS\"}")
IDEM_ID=$(echo "$IDEM_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$IDEM_ID" = "$PO_A_ID" ] || fail "Idempotency mismatch: expected $PO_A_ID, got $IDEM_ID"
pass "Idempotency returns same payout"

step 17 "Guard: GET non-existent payout returns 404"
NGET_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/payouts/nonexistent-id" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
NGET_HTTP=$(echo "$NGET_RES" | tail -n1)
[ "$NGET_HTTP" = "404" ] || fail "Expected 404 for missing payout, got $NGET_HTTP"
pass "GET missing payout returns 404"

echo -e "\n${GREEN}━━━ Payouts Realistic Lifecycle Complete ━━━${NC}"
