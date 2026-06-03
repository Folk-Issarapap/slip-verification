#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Payout Cancel Flow
#
# Usage:
#   bash scripts/e2e/e2e-payout-cancel-flow.sh
#
# Environment: BROPAY_URL, BOOTSTRAP_MERCHANT_* (optional)
#
# Flow:
#   1. Bootstrap demo merchant
#   2. Create + verify bank account
#   3. Fund wallet
#   4. Guard: 404 on missing payout, 401 without auth
#   5. Create payout
#   6. Verify payout = pending and wallet reserved
#   7. Verify list filters (status, pagination)
#   8. Guard: cancel non-pending payout returns 400
#   9. Cancel payout
#  10. Verify payout = cancelled
#  11. Verify wallet balance restored
#  12. Verify ledger entry for cancellation
#  13. Cleanup: delete payout + bank account (DB only)
#
# See: scripts/e2e/docs/e2e-payout-cancel-flow.md
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

# Helper: curl with status code extraction
# Usage: http_get <url> [extra curl args...]
http_get() {
  local url="$1"; shift
  curl -s -w "\n%{http_code}" "$url" "$@"
}
http_post() {
  local url="$1"; shift
  curl -s -w "\n%{http_code}" "$url" -X POST "$@"
}

# Extract body (all but last line) and status (last line)
body() { sed '$d'; }
status() { tail -n1; }

echo -e "${CYAN}━━━ BroPay E2E Payout Cancel Flow ━━━${NC}"

# ── Step 1: Bootstrap demo merchant ──────────────────────────────────────────
step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/_bootstrap.sh"
bootstrap_demo_merchant
MERCHANT_ID="$DEMO_MERCHANT_ID"
WALLET_ID="$DEMO_WALLET_ID"
OWNER_TOKEN="$DEMO_OWNER_TOKEN"
OWNER="Authorization: Bearer $OWNER_TOKEN"
MERCH="X-Merchant-Id: $MERCHANT_ID"
pass "Merchant: ${MERCHANT_ID:0:16}...  Wallet: ${WALLET_ID:0:16}..."

# ── Step 2: Create + verify bank account ─────────────────────────────────────
step 2 "Create and verify bank account"
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
[ -n "$BA_ID" ] || fail "No bank account found"

d1_local_ok "UPDATE merchant_bank_accounts SET verification_status = 'verified', status = 'active' WHERE id = '$BA_ID'" \
  || fail "Failed to verify bank account in local D1"
pass "Bank account verified: ${BA_ID:0:16}..."

# ── Step 3: Fund wallet ──────────────────────────────────────────────────────
step 3 "Fund wallet (100,000 satang)"
FUND_AMOUNT=100000

INITIAL_BALANCE=$(curl -s "$BROPAY/v1/merchant/wallets" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" | json "
d=json.load(sys.stdin)
w=d.get('data',{})
if isinstance(w,list):
    w=w[0] if w else {}
print(w.get('available_balance',0))
")

d1_local_ok "UPDATE wallets SET available_balance = available_balance + $FUND_AMOUNT, updated_at = datetime('now') WHERE id = '$WALLET_ID'" \
  || fail "Failed to fund wallet in local D1"
d1_local_ok "INSERT INTO wallet_ledger_entries (wallet_id, entry_type, reference_type, reference_id, amount, currency, balance_before, balance_after, description) VALUES ('$WALLET_ID', 'credit', 'deposit', 'e2e-cancel-funding', $FUND_AMOUNT, 'THB', $INITIAL_BALANCE, $INITIAL_BALANCE + $FUND_AMOUNT, 'E2E cancel flow funding')" \
  || fail "Failed to insert funding ledger entry in local D1"

FUNDED_BALANCE=$((INITIAL_BALANCE + FUND_AMOUNT))
pass "Wallet funded: $FUNDED_BALANCE THB"

# ── Step 4: Auth + 404 guards ────────────────────────────────────────────────
step 4 "Guard: auth and 404 errors"

# 401 without auth
NO_AUTH_RES=$(http_post "$BROPAY/v1/merchant/payouts" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d '{"amount":1000}')
NO_AUTH_STATUS=$(echo "$NO_AUTH_RES" | status)
[ "$NO_AUTH_STATUS" = "401" ] || fail "Expected 401 without auth, got $NO_AUTH_STATUS"
pass "401 without auth"

# 404 on missing payout
NOTFOUND_RES=$(http_post "$BROPAY/v1/merchant/payouts/nonexistent-id/cancel" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d '{}')
NOTFOUND_STATUS=$(echo "$NOTFOUND_RES" | status)
[ "$NOTFOUND_STATUS" = "404" ] || fail "Expected 404 for missing payout, got $NOTFOUND_STATUS"
pass "404 for missing payout"

# 422 on amount below minimum (platform min payout default is 1,000 satang = 10 THB)
BELOW_MIN_RES=$(http_post "$BROPAY/v1/merchant/payouts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d '{"amount":1,"merchant_bank_account_id":"'$BA_ID'"}')
BELOW_MIN_STATUS=$(echo "$BELOW_MIN_RES" | status)
[ "$BELOW_MIN_STATUS" = "422" ] || fail "Expected 422 for amount below min, got $BELOW_MIN_STATUS"
pass "422 for amount below minimum"

# 404 on missing bank account
BAD_BA_RES=$(http_post "$BROPAY/v1/merchant/payouts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d '{"amount":5000,"merchant_bank_account_id":"bank-does-not-exist"}')
BAD_BA_STATUS=$(echo "$BAD_BA_RES" | status)
[ "$BAD_BA_STATUS" = "404" ] || fail "Expected 404 for missing bank account, got $BAD_BA_STATUS"
pass "404 for missing bank account"

# 400 when neither destination bank account is provided
NO_DEST_RES=$(http_post "$BROPAY/v1/merchant/payouts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d '{"amount":5000}')
NO_DEST_STATUS=$(echo "$NO_DEST_RES" | status)
[ "$NO_DEST_STATUS" = "400" ] || [ "$NO_DEST_STATUS" = "422" ] || fail "Expected 400/422 without bank account, got $NO_DEST_STATUS"
pass "400/422 without destination bank account ($NO_DEST_STATUS)"

# 400/422 for negative amount
NEG_RES=$(http_post "$BROPAY/v1/merchant/payouts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"amount\":-100,\"merchant_bank_account_id\":\"$BA_ID\"}")
NEG_STATUS=$(echo "$NEG_RES" | status)
[ "$NEG_STATUS" = "400" ] || [ "$NEG_STATUS" = "422" ] && pass "400/422 for negative amount ($NEG_STATUS)" || warn "Expected 400/422 for negative amount, got $NEG_STATUS"

# 401 on GET list without auth
NO_AUTH_LIST=$(http_get "$BROPAY/v1/merchant/payouts" -H "$MERCH" -H "$ORIGIN")
NO_AUTH_LIST_STATUS=$(echo "$NO_AUTH_LIST" | status)
[ "$NO_AUTH_LIST_STATUS" = "401" ] && pass "401 on GET payouts without token" || warn "Expected 401 on GET list, got $NO_AUTH_LIST_STATUS"

# 404 on GET missing payout detail
DETAIL_404=$(http_get "$BROPAY/v1/merchant/payouts/nonexistent-payout-id" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
DETAIL_404_STATUS=$(echo "$DETAIL_404" | status)
[ "$DETAIL_404_STATUS" = "404" ] && pass "404 for missing payout detail" || warn "Expected 404 for missing payout detail, got $DETAIL_404_STATUS"

# 400 when bank account exists but is not verified
UNVERIFIED_CREATE=$(curl -s "$BROPAY/v1/merchant/bank-accounts" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{"bank_id":"bank-kbank-0000-0000-000000000001","account_number":"1111222233","account_holder_name":"Unverified BA","account_type":"savings"}')
UNVERIFIED_BA=$(echo "$UNVERIFIED_CREATE" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
if [ -n "$UNVERIFIED_BA" ]; then
  UNVERIFIED_PAYOUT=$(http_post "$BROPAY/v1/merchant/payouts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
    -d "{\"amount\":5000,\"merchant_bank_account_id\":\"$UNVERIFIED_BA\"}")
  UNVERIFIED_PAYOUT_STATUS=$(echo "$UNVERIFIED_PAYOUT" | status)
  [ "$UNVERIFIED_PAYOUT_STATUS" = "400" ] && pass "400 for unverified bank account" || warn "Expected 400 for unverified BA, got $UNVERIFIED_PAYOUT_STATUS"
fi

# ── Step 5: Create payout ────────────────────────────────────────────────────
step 5 "Create payout (500 THB)"
PAYOUT_AMOUNT=5000
E2E_IDEM_KEY="e2e-payout-cancel-$(date +%s)"
PAYOUT_RAW=$(http_post "$BROPAY/v1/merchant/payouts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"amount\":$PAYOUT_AMOUNT,\"merchant_bank_account_id\":\"$BA_ID\",\"description\":\"E2E cancel test\",\"idempotency_key\":\"$E2E_IDEM_KEY\"}")
PAYOUT_HTTP=$(echo "$PAYOUT_RAW" | status)
PAYOUT_RES=$(echo "$PAYOUT_RAW" | body)
[ "$PAYOUT_HTTP" = "201" ] || fail "Expected 201 on payout create, got $PAYOUT_HTTP — $PAYOUT_RES"

PAYOUT_ID=$(echo "$PAYOUT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
PAYOUT_STATUS=$(echo "$PAYOUT_RES" | json "d=json.load(sys.stdin); print(d.get('data',{}).get('status', d.get('error',{}).get('code','?')))" )
[ -n "$PAYOUT_ID" ] || fail "Payout creation failed: $PAYOUT_STATUS"
[ "$PAYOUT_STATUS" = "pending" ] || fail "Expected payout status 'pending', got '$PAYOUT_STATUS'"

FEE_AMOUNT=$(echo "$PAYOUT_RES" | json "print(json.load(sys.stdin)['data']['fee_amount'])")
PAYOUT_REF=$(echo "$PAYOUT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('reference_number',''))")
TOTAL_DEBIT=$((PAYOUT_AMOUNT + FEE_AMOUNT))
[ -n "$PAYOUT_REF" ] && pass "Payout created: ${PAYOUT_ID:0:16}... ref=$PAYOUT_REF ($PAYOUT_STATUS, debit $TOTAL_DEBIT)" || pass "Payout created: ${PAYOUT_ID:0:16}... ($PAYOUT_STATUS, debit $TOTAL_DEBIT)"

step "5b" "Idempotency key replay"
IDEM_RAW=$(http_post "$BROPAY/v1/merchant/payouts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"amount\":$PAYOUT_AMOUNT,\"merchant_bank_account_id\":\"$BA_ID\",\"description\":\"E2E cancel test\",\"idempotency_key\":\"$E2E_IDEM_KEY\"}")
IDEM_HTTP=$(echo "$IDEM_RAW" | status)
IDEM_ID=$(echo "$IDEM_RAW" | body | json "print(json.load(sys.stdin).get('data',{}).get('id',''))" 2>/dev/null)
if [ "$IDEM_HTTP" = "201" ] && [ "$IDEM_ID" = "$PAYOUT_ID" ]; then
  pass "Idempotent replay returned same payout (201)"
else
  warn "Idempotency replay: HTTP $IDEM_HTTP id=$IDEM_ID (expected 201 + $PAYOUT_ID)"
fi

step "5c" "GET payout detail (before cancel)"
PRE_DETAIL=$(curl -s "$BROPAY/v1/merchant/payouts/$PAYOUT_ID" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
PRE_STATUS=$(echo "$PRE_DETAIL" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
DEST_KIND=$(echo "$PRE_DETAIL" | json "print(json.load(sys.stdin).get('data',{}).get('destination_bank_account',{}).get('kind',''))")
[ "$PRE_STATUS" = "pending" ] && pass "Detail before cancel: pending" || warn "Detail before cancel: $PRE_STATUS"
[ "$DEST_KIND" = "merchant" ] && pass "destination_bank_account.kind=merchant" || warn "destination_bank_account missing or wrong kind ($DEST_KIND)"

step "5d" "Payout stats + wallet pending"
STATS_RES=$(curl -s "$BROPAY/v1/merchant/payouts/stats" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
STATS_PENDING=$(echo "$STATS_RES" | json "print(json.load(sys.stdin).get('data',{}).get('pending_count',0))")
[ "${STATS_PENDING:-0}" -ge 1 ] && pass "Stats pending_count: $STATS_PENDING" || warn "Stats pending_count unexpected: $STATS_PENDING"

PENDING_OPS=$(curl -s "$BROPAY/v1/merchant/wallets/pending" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
PENDING_PAYOUT_RESERVED=$(echo "$PENDING_OPS" | json "print(json.load(sys.stdin).get('data',{}).get('pending_payouts',{}).get('total_reserved',0))")
[ "${PENDING_PAYOUT_RESERVED:-0}" -ge "$TOTAL_DEBIT" ] && pass "Wallet pending_payouts total_reserved: $PENDING_PAYOUT_RESERVED" || warn "Wallet pending_payouts total_reserved: $PENDING_PAYOUT_RESERVED (expected >= $TOTAL_DEBIT)"

BA_DETAIL=$(http_get "$BROPAY/v1/merchant/bank-accounts/$BA_ID" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
BA_DETAIL_CODE=$(echo "$BA_DETAIL" | status)
[ "$BA_DETAIL_CODE" = "200" ] && pass "GET bank account detail → 200" || warn "GET bank account detail: HTTP $BA_DETAIL_CODE"

# ── Step 6: Verify list + filters ────────────────────────────────────────────
step 6 "Verify payout list and filters"

# List should contain at least 1 payout
LIST_RES=$(curl -s "$BROPAY/v1/merchant/payouts?limit=10" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
LIST_COUNT=$(echo "$LIST_RES" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
[ "$LIST_COUNT" -ge 1 ] || fail "Expected list count >= 1, got $LIST_COUNT"
pass "List count: $LIST_COUNT"

# Filter by status=pending should include our payout
PENDING_LIST=$(curl -s "$BROPAY/v1/merchant/payouts?status=pending" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
PENDING_COUNT=$(echo "$PENDING_LIST" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
[ "$PENDING_COUNT" -ge 1 ] || fail "Expected pending count >= 1, got $PENDING_COUNT"
pass "Pending filter count: $PENDING_COUNT"

# Filter by status=completed should not include our payout
COMPLETED_LIST=$(curl -s "$BROPAY/v1/merchant/payouts?status=completed" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
COMPLETED_IDS=$(echo "$COMPLETED_LIST" | json "
d=json.load(sys.stdin)
for x in d.get('data',[]):
    if x['id'] == '$PAYOUT_ID':
        print('found')
        break
else:
    print('not_found')
")
[ "$COMPLETED_IDS" = "not_found" ] || fail "Payout should not appear in completed filter"
pass "Not in completed filter"

# Search by q should find the payout
SEARCH_RES=$(curl -s "$BROPAY/v1/merchant/payouts?q=${PAYOUT_ID:0:8}" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SEARCH_FOUND=$(echo "$SEARCH_RES" | json "
d=json.load(sys.stdin)
for x in d.get('data',[]):
    if x['id'] == '$PAYOUT_ID':
        print('found')
        break
else:
    print('not_found')
")
[ "$SEARCH_FOUND" = "found" ] || warn "Search by q did not find payout (may be unsupported)"
[ "$SEARCH_FOUND" = "not_found" ] || pass "Search by q found payout"

# Filter by source=dashboard (merchant API create uses dashboard source)
DASH_LIST=$(curl -s "$BROPAY/v1/merchant/payouts?source=dashboard&status=pending" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
DASH_FOUND=$(echo "$DASH_LIST" | json "
d=json.load(sys.stdin)
for x in d.get('data',[]):
    if x['id'] == '$PAYOUT_ID':
        print('found')
        break
else:
    print('not_found')
")
[ "$DASH_FOUND" = "found" ] && pass "Found in source=dashboard filter" || warn "Not in source=dashboard filter"

# Sort by amount descending
SORT_LIST=$(curl -s "$BROPAY/v1/merchant/payouts?sort=amount&order=desc&limit=5" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT_OK=$(echo "$SORT_LIST" | json "print(len(json.load(sys.stdin).get('data',[])) >= 1)")
[ "$SORT_OK" = "True" ] && pass "List sort=amount&order=desc returned rows" || warn "List sort returned no rows"

# ── Step 7: Verify wallet reserved ───────────────────────────────────────────
step 7 "Verify wallet reservation"
WALLET_AFTER_CREATE=$(curl -s "$BROPAY/v1/merchant/wallets" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
AVAILABLE_AFTER=$(echo "$WALLET_AFTER_CREATE" | json "
d=json.load(sys.stdin)
w = d['data'][0] if isinstance(d['data'],list) and d['data'] else d.get('data',{})
print(w.get('available_balance', 0))
")
RESERVED_AFTER=$(echo "$WALLET_AFTER_CREATE" | json "
d=json.load(sys.stdin)
w = d['data'][0] if isinstance(d['data'],list) and d['data'] else d.get('data',{})
print(w.get('reserved_balance', 0))
")
EXPECTED_AVAILABLE=$((FUNDED_BALANCE - TOTAL_DEBIT))
[ "$AVAILABLE_AFTER" -eq "$EXPECTED_AVAILABLE" ] || fail "Expected available $EXPECTED_AVAILABLE, got $AVAILABLE_AFTER"
[ "$RESERVED_AFTER" -ge "$TOTAL_DEBIT" ] || fail "Expected reserved >= $TOTAL_DEBIT, got $RESERVED_AFTER"
pass "Available: $AVAILABLE_AFTER, Reserved: $RESERVED_AFTER"

# ── Step 8: Guard: cancel non-pending payout ─────────────────────────────────
step 8 "Guard: cancel non-pending returns 400"
GUARD_PAYOUT_RAW=$(http_post "$BROPAY/v1/merchant/payouts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"amount\":5000,\"merchant_bank_account_id\":\"$BA_ID\",\"description\":\"E2E guard processing cancel\"}")
GUARD_PAYOUT_ID=$(echo "$GUARD_PAYOUT_RAW" | body | json "print(json.load(sys.stdin).get('data',{}).get('id',''))" 2>/dev/null)
GUARD_TOTAL_DEBIT=0
if [ -n "$GUARD_PAYOUT_ID" ]; then
  GUARD_FEE=$(echo "$GUARD_PAYOUT_RAW" | body | json "print(json.load(sys.stdin).get('data',{}).get('fee_amount',0))" 2>/dev/null) || GUARD_FEE=0
  GUARD_TOTAL_DEBIT=$((5000 + GUARD_FEE))
  d1_local_ok "UPDATE payouts SET status = 'processing', updated_at = datetime('now') WHERE id = '$GUARD_PAYOUT_ID'" \
    || fail "Failed to set guard payout to processing in local D1"
  PROC_CANCEL=$(http_post "$BROPAY/v1/merchant/payouts/$GUARD_PAYOUT_ID/cancel" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d '{}')
  PROC_CANCEL_STATUS=$(echo "$PROC_CANCEL" | status)
  [ "$PROC_CANCEL_STATUS" = "400" ] && pass "400 cancelling processing payout" || warn "Expected 400 for processing payout cancel, got $PROC_CANCEL_STATUS"
  # Forcing processing via D1 does not run cancel's wallet release — restore funds so step 10 can assert main payout cancel only.
  if [ "$GUARD_TOTAL_DEBIT" -gt 0 ]; then
    d1_local_ok "UPDATE wallets SET available_balance = available_balance + $GUARD_TOTAL_DEBIT, reserved_balance = MAX(0, reserved_balance - $GUARD_TOTAL_DEBIT), updated_at = datetime('now') WHERE id = '$WALLET_ID'" \
      || fail "Failed to release guard payout reservation in local D1"
    d1_local_ok "UPDATE payouts SET status = 'cancelled', cancellation_reason = 'E2E guard cleanup', updated_at = datetime('now') WHERE id = '$GUARD_PAYOUT_ID'" || true
    pass "Released guard payout reservation ($GUARD_TOTAL_DEBIT satang) after processing-cancel test"
  fi
else
  warn "Could not create guard payout for processing-cancel test"
  GUARD_PAYOUT_ID=""
fi

# ── Step 9: Cancel payout ────────────────────────────────────────────────────
step 9 "Cancel payout"
CANCEL_RES=$(curl -s "$BROPAY/v1/merchant/payouts/$PAYOUT_ID/cancel" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{"cancellation_reason":"E2E test cancellation"}')
CANCEL_STATUS=$(echo "$CANCEL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$CANCEL_STATUS" = "cancelled" ] || fail "Expected status 'cancelled', got '$CANCEL_STATUS'"
pass "Payout cancelled"

# Now verify re-cancelling returns 400
RE_CANCEL_RES=$(http_post "$BROPAY/v1/merchant/payouts/$PAYOUT_ID/cancel" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d '{}')
RE_CANCEL_STATUS=$(echo "$RE_CANCEL_RES" | status)
[ "$RE_CANCEL_STATUS" = "400" ] || fail "Expected 400 re-cancelling cancelled payout, got $RE_CANCEL_STATUS"
pass "400 on re-cancel cancelled payout"

# ── Step 10: Verify wallet balance restored ──────────────────────────────────
step 10 "Verify wallet balance restored"
FINAL_BALANCE=$(curl -s "$BROPAY/v1/merchant/wallets" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" | json "
d=json.load(sys.stdin)
w = d['data'][0] if isinstance(d['data'],list) and d['data'] else d.get('data',{})
print(w.get('available_balance', 0))
")
FINAL_RESERVED=$(curl -s "$BROPAY/v1/merchant/wallets" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" | json "
d=json.load(sys.stdin)
w = d['data'][0] if isinstance(d['data'],list) and d['data'] else d.get('data',{})
print(w.get('reserved_balance', 0))
")
EXPECTED_AFTER_CANCEL=$((AVAILABLE_AFTER + TOTAL_DEBIT))
[ "$FINAL_BALANCE" -eq "$EXPECTED_AFTER_CANCEL" ] || fail "Expected available $EXPECTED_AFTER_CANCEL after cancel (funded=$FUNDED_BALANCE, after_create=$AVAILABLE_AFTER, debit=$TOTAL_DEBIT), got $FINAL_BALANCE"
[ "$FINAL_BALANCE" -eq "$FUNDED_BALANCE" ] || warn "Available $FINAL_BALANCE != funded baseline $FUNDED_BALANCE (other pending payouts may still reserve funds)"
pass "Available restored: $FINAL_BALANCE, Reserved: $FINAL_RESERVED"

# ── Step 11: Verify ledger entry for cancellation ────────────────────────────
step 11 "Verify cancellation ledger"
LEDGER_FILTER=$(curl -s "$BROPAY/v1/merchant/wallets/ledger?reference_type=payout&reference_id=$PAYOUT_ID&limit=20" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
LEDGER_FILTER_COUNT=$(echo "$LEDGER_FILTER" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
[ "${LEDGER_FILTER_COUNT:-0}" -ge 2 ] && pass "Ledger filter reference_type=payout: $LEDGER_FILTER_COUNT entries" || warn "Ledger filter count: $LEDGER_FILTER_COUNT (expected >= 2 for reserve + release)"

LEDGER=$(curl -s "$BROPAY/v1/merchant/wallets/ledger" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
CANCEL_LEDGER=$(echo "$LEDGER" | json "
d=json.load(sys.stdin)
entries = d.get('data', [])
for e in entries:
    if e.get('reference_type') == 'payout' and e.get('reference_id') == '$PAYOUT_ID' and 'cancel' in (e.get('description') or '').lower():
        print(f\"{e['entry_type']} {e['amount']}\")
        break
else:
    print('not_found')
")
# The cancellation creates a credit ledger entry
[ "$CANCEL_LEDGER" != "not_found" ] || warn "No explicit cancellation ledger entry found (may be combined)"
[ "$CANCEL_LEDGER" = "not_found" ] || pass "Cancellation ledger: $CANCEL_LEDGER"

# ── Step 12: Verify payout detail ────────────────────────────────────────────
step 12 "Verify payout detail reflects cancellation"
DETAIL_RES=$(curl -s "$BROPAY/v1/merchant/payouts/$PAYOUT_ID" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
DETAIL_STATUS=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin)['data']['status'])")
DETAIL_REASON=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin)['data']['cancellation_reason'] or '')")
[ "$DETAIL_STATUS" = "cancelled" ] || fail "Detail status should be cancelled, got '$DETAIL_STATUS'"
[ -n "$DETAIL_REASON" ] || fail "Detail missing cancellation_reason"
pass "Detail: status=$DETAIL_STATUS, reason=${DETAIL_REASON:0:30}..."

# Verify events contain cancelled event
EVENTS=$(echo "$DETAIL_RES" | json "
d=json.load(sys.stdin)
events = d.get('data',{}).get('events',[])
for ev in events:
    if ev.get('event_type') == 'cancelled':
        print('found')
        break
else:
    print('not_found')
")
[ "$EVENTS" = "found" ] || fail "Missing 'cancelled' event in payout events"
pass "Cancelled event present"

RELEASED_AT=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('reservation_released_at') or '')")
[ -n "$RELEASED_AT" ] && pass "reservation_released_at set" || warn "reservation_released_at missing on cancelled payout"

TIMELINE_CANCEL=$(echo "$DETAIL_RES" | json "
d=json.load(sys.stdin)
for ev in d.get('data',{}).get('timeline',[]):
    if ev.get('kind') == 'payout.cancelled':
        print('found')
        break
else:
    print('not_found')
")
[ "$TIMELINE_CANCEL" = "found" ] && pass "timeline includes payout.cancelled" || warn "timeline missing payout.cancelled"

PENDING_AFTER=$(curl -s "$BROPAY/v1/merchant/wallets/pending" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
PENDING_AFTER_AMT=$(echo "$PENDING_AFTER" | json "print(json.load(sys.stdin).get('data',{}).get('pending_payouts',{}).get('count',0))")
info "Wallet pending_payouts count after cancel: $PENDING_AFTER_AMT"

# ── Step 13: Cleanup ─────────────────────────────────────────────────────────
step 13 "Cleanup created resources"

# Delete guard payout (if created) + main payout
if [ -n "${GUARD_PAYOUT_ID:-}" ]; then
  d1_local_ok "DELETE FROM payout_events WHERE payout_id = '$GUARD_PAYOUT_ID'" || true
  d1_local_ok "DELETE FROM wallet_ledger_entries WHERE reference_id = '$GUARD_PAYOUT_ID' AND reference_type = 'payout'" || true
  d1_local_ok "DELETE FROM payouts WHERE id = '$GUARD_PAYOUT_ID'" || true
fi

d1_local_ok "DELETE FROM payout_events WHERE payout_id = '$PAYOUT_ID'" || true
d1_local_ok "DELETE FROM wallet_ledger_entries WHERE reference_id = '$PAYOUT_ID' AND reference_type = 'payout'" || true
d1_local_ok "DELETE FROM payouts WHERE id = '$PAYOUT_ID'" || true
d1_local_ok "DELETE FROM merchant_bank_accounts WHERE id = '$BA_ID'" || true
if [ -n "${UNVERIFIED_BA:-}" ] && [ "$UNVERIFIED_BA" != "$BA_ID" ]; then
  d1_local_ok "DELETE FROM merchant_bank_accounts WHERE id = '$UNVERIFIED_BA'" || true
fi
d1_local_ok "UPDATE wallets SET available_balance = $INITIAL_BALANCE, reserved_balance = 0, updated_at = datetime('now') WHERE id = '$WALLET_ID'" || true
d1_local_ok "DELETE FROM wallet_ledger_entries WHERE reference_id = 'e2e-cancel-funding' AND reference_type = 'deposit'" || true
pass "Cleanup complete"

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}━━━ Payout Cancel Flow Complete ━━━${NC}"
echo "Initial:   $INITIAL_BALANCE THB"
echo "Funded:    +$FUND_AMOUNT THB"
echo "Payout:    $PAYOUT_AMOUNT THB + fee $FEE_AMOUNT THB (reserved)"
echo "Cancelled: reservation released"
echo "Final:     $FINAL_BALANCE THB (should equal funded balance)"
