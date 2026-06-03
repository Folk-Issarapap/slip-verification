#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Payout Completion Flow
#
# Usage:
#   bash scripts/e2e/e2e-payout-completion.sh
#
# Environment: BROPAY_URL, BOOTSTRAP_MERCHANT_* (optional)
#
# Flow:
#   1. Bootstrap demo merchant
#   2. Create + verify bank account
#   3. Fund wallet
#   4. Guard: 401/404/422 errors
#   5. Create payout
#   6. Verify list + filters + wallet reservation
#   7. Simulate payout completion (local D1 — mirrors KBNK withdrawal.completed)
#   8. Verify payout status = completed
#   9. Verify wallet balance + reserved released
#  10. Verify ledger (release entry)
#  11. Guard: cannot cancel completed payout
#  12. Cleanup
#
# Real completion path: POST /v1/webhooks/kbnk (`withdrawal.completed`) keyed on
# `provider_transfer_id`. This script uses D1 when KBNK tunnel is unavailable.
#
# See: scripts/e2e/docs/e2e-payout-completion.md
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

http_get() {
  local url="$1"; shift
  curl -s -w "\n%{http_code}" "$url" "$@"
}
http_post() {
  local url="$1"; shift
  curl -s -w "\n%{http_code}" "$url" -X POST "$@"
}
body() { sed '$d'; }
status() { tail -n1; }

echo -e "${CYAN}━━━ BroPay E2E Payout Completion ━━━${NC}"

# ── Step 1: Bootstrap demo merchant ──────────────────────────────────────────
step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/_bootstrap.sh"
bootstrap_demo_merchant
MERCHANT_ID="$DEMO_MERCHANT_ID"
WALLET_ID="$DEMO_WALLET_ID"
OWNER_TOKEN="$DEMO_OWNER_TOKEN"
ADMIN_TOKEN="$DEMO_ADMIN_TOKEN"
OWNER="Authorization: Bearer $OWNER_TOKEN"
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
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
  || fail "Failed to verify bank account in local D1 (install wrangler: pnpm install in apps/api)"
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
d1_local_ok "INSERT INTO wallet_ledger_entries (wallet_id, entry_type, reference_type, reference_id, amount, currency, balance_before, balance_after, description) VALUES ('$WALLET_ID', 'credit', 'deposit', 'e2e-funding', $FUND_AMOUNT, 'THB', $INITIAL_BALANCE, $INITIAL_BALANCE + $FUND_AMOUNT, 'E2E wallet funding')" \
  || fail "Failed to insert funding ledger entry in local D1"

FUNDED_BALANCE=$((INITIAL_BALANCE + FUND_AMOUNT))
pass "Wallet funded: $FUNDED_BALANCE satang (+$FUND_AMOUNT)"

# ── Step 4: Guard errors ─────────────────────────────────────────────────────
step 4 "Guard: auth, 404, 422 errors"

NO_AUTH=$(http_post "$BROPAY/v1/merchant/payouts" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d '{"amount":1000}')
[ "$(echo "$NO_AUTH" | status)" = "401" ] || fail "Expected 401 without auth, got $(echo "$NO_AUTH" | status)"
pass "401 without auth"

BAD_BA=$(http_post "$BROPAY/v1/merchant/payouts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{"amount":5000,"merchant_bank_account_id":"does-not-exist"}')
[ "$(echo "$BAD_BA" | status)" = "404" ] || fail "Expected 404 for missing bank account, got $(echo "$BAD_BA" | status)"
pass "404 for missing bank account"

BELOW_MIN=$(http_post "$BROPAY/v1/merchant/payouts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"amount\":1,\"merchant_bank_account_id\":\"$BA_ID\"}")
[ "$(echo "$BELOW_MIN" | status)" = "422" ] || fail "Expected 422 for amount below min, got $(echo "$BELOW_MIN" | status)"
pass "422 for amount below minimum"

NO_DEST=$(http_post "$BROPAY/v1/merchant/payouts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d '{"amount":5000}')
NO_DEST_STATUS=$(echo "$NO_DEST" | status)
[ "$NO_DEST_STATUS" = "400" ] || [ "$NO_DEST_STATUS" = "422" ] || fail "Expected 400/422 without bank account, got $NO_DEST_STATUS"
pass "400/422 without destination bank account ($NO_DEST_STATUS)"

NEG=$(http_post "$BROPAY/v1/merchant/payouts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"amount\":-100,\"merchant_bank_account_id\":\"$BA_ID\"}")
NEG_STATUS=$(echo "$NEG" | status)
[ "$NEG_STATUS" = "400" ] || [ "$NEG_STATUS" = "422" ] && pass "400/422 for negative amount ($NEG_STATUS)" || warn "Expected 400/422 for negative amount, got $NEG_STATUS"

NO_AUTH_LIST=$(http_get "$BROPAY/v1/merchant/payouts" -H "$MERCH" -H "$ORIGIN")
[ "$(echo "$NO_AUTH_LIST" | status)" = "401" ] && pass "401 on GET payouts without token" || warn "Expected 401 on GET list, got $(echo "$NO_AUTH_LIST" | status)"

DETAIL_404=$(http_get "$BROPAY/v1/merchant/payouts/nonexistent-payout-id" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
[ "$(echo "$DETAIL_404" | status)" = "404" ] && pass "404 for missing payout detail" || warn "Expected 404 for missing payout detail"

UNVERIFIED_CREATE=$(curl -s "$BROPAY/v1/merchant/bank-accounts" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{"bank_id":"bank-kbank-0000-0000-000000000001","account_number":"1111222233","account_holder_name":"Unverified BA","account_type":"savings"}')
UNVERIFIED_BA=$(echo "$UNVERIFIED_CREATE" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
if [ -n "$UNVERIFIED_BA" ]; then
  UNVERIFIED_PAYOUT=$(http_post "$BROPAY/v1/merchant/payouts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
    -d "{\"amount\":5000,\"merchant_bank_account_id\":\"$UNVERIFIED_BA\"}")
  [ "$(echo "$UNVERIFIED_PAYOUT" | status)" = "400" ] && pass "400 for unverified bank account" || warn "Expected 400 for unverified BA"
fi

# ── Step 5: Create payout ────────────────────────────────────────────────────
step 5 "Create payout (1,000 THB)"
PAYOUT_AMOUNT=10000
E2E_IDEM_KEY="e2e-payout-complete-$(date +%s)"
PAYOUT_RAW=$(http_post "$BROPAY/v1/merchant/payouts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"amount\":$PAYOUT_AMOUNT,\"merchant_bank_account_id\":\"$BA_ID\",\"description\":\"E2E payout completion test\",\"idempotency_key\":\"$E2E_IDEM_KEY\"}")
PAYOUT_HTTP=$(echo "$PAYOUT_RAW" | status)
PAYOUT_RES=$(echo "$PAYOUT_RAW" | body)
[ "$PAYOUT_HTTP" = "201" ] || fail "Expected 201 on payout create, got $PAYOUT_HTTP — $PAYOUT_RES"

PAYOUT_ID=$(echo "$PAYOUT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
PAYOUT_STATUS=$(echo "$PAYOUT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ -n "$PAYOUT_ID" ] && [ "$PAYOUT_STATUS" = "pending" ] || fail "Payout creation failed: $PAYOUT_STATUS"

FEE_AMOUNT=$(echo "$PAYOUT_RES" | json "print(json.load(sys.stdin)['data']['fee_amount'])")
NET_AMOUNT=$(echo "$PAYOUT_RES" | json "print(json.load(sys.stdin)['data']['net_amount'])")
PAYOUT_REF=$(echo "$PAYOUT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('reference_number',''))")
TOTAL_DEBIT=$((PAYOUT_AMOUNT + FEE_AMOUNT))
pass "Payout created: ${PAYOUT_ID:0:16}... ref=$PAYOUT_REF (net=$NET_AMOUNT, debit=$TOTAL_DEBIT)"

step "5b" "Idempotency key replay"
IDEM_RAW=$(http_post "$BROPAY/v1/merchant/payouts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"amount\":$PAYOUT_AMOUNT,\"merchant_bank_account_id\":\"$BA_ID\",\"description\":\"E2E payout completion test\",\"idempotency_key\":\"$E2E_IDEM_KEY\"}")
IDEM_HTTP=$(echo "$IDEM_RAW" | status)
IDEM_ID=$(echo "$IDEM_RAW" | body | json "print(json.load(sys.stdin).get('data',{}).get('id',''))" 2>/dev/null)
[ "$IDEM_HTTP" = "201" ] && [ "$IDEM_ID" = "$PAYOUT_ID" ] && pass "Idempotent replay (201, same id)" || warn "Idempotency: HTTP $IDEM_HTTP id=$IDEM_ID"

step "5c" "GET payout detail (before completion)"
PRE_DETAIL=$(curl -s "$BROPAY/v1/merchant/payouts/$PAYOUT_ID" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
PRE_STATUS=$(echo "$PRE_DETAIL" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
DEST_KIND=$(echo "$PRE_DETAIL" | json "print(json.load(sys.stdin).get('data',{}).get('destination_bank_account',{}).get('kind',''))")
[ "$PRE_STATUS" = "pending" ] && pass "Detail before completion: pending" || warn "Detail status: $PRE_STATUS"
[ "$DEST_KIND" = "merchant" ] && pass "destination_bank_account.kind=merchant" || warn "destination_bank_account.kind=$DEST_KIND"

step "5d" "Payout stats + wallet pending"
STATS_PENDING=$(curl -s "$BROPAY/v1/merchant/payouts/stats" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" \
  | json "print(json.load(sys.stdin).get('data',{}).get('pending_count',0))")
[ "${STATS_PENDING:-0}" -ge 1 ] && pass "Stats pending_count: $STATS_PENDING" || warn "Stats pending_count: $STATS_PENDING"

PENDING_RESERVED=$(curl -s "$BROPAY/v1/merchant/wallets/pending" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" \
  | json "print(json.load(sys.stdin).get('data',{}).get('pending_payouts',{}).get('total_reserved',0))")
[ "${PENDING_RESERVED:-0}" -ge "$TOTAL_DEBIT" ] && pass "pending_payouts.total_reserved: $PENDING_RESERVED" || warn "pending_payouts.total_reserved: $PENDING_RESERVED"

BA_DETAIL_CODE=$(http_get "$BROPAY/v1/merchant/bank-accounts/$BA_ID" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" | status)
[ "$BA_DETAIL_CODE" = "200" ] && pass "GET bank account detail → 200" || warn "GET bank account detail: $BA_DETAIL_CODE"

# ── Step 6: Verify list + filters + reservation ─────────────────────────────
step 6 "Verify payout list, filters, wallet reservation"

LIST_COUNT=$(curl -s "$BROPAY/v1/merchant/payouts?limit=10" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" \
  | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
[ "$LIST_COUNT" -ge 1 ] || fail "Expected list count >= 1, got $LIST_COUNT"
pass "List count: $LIST_COUNT"

PENDING_COUNT=$(curl -s "$BROPAY/v1/merchant/payouts?status=pending" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" \
  | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
[ "$PENDING_COUNT" -ge 1 ] || fail "Expected pending count >= 1, got $PENDING_COUNT"
pass "Pending filter count: $PENDING_COUNT"

SEARCH_FOUND=$(curl -s "$BROPAY/v1/merchant/payouts?q=${PAYOUT_ID:0:8}" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" | json "
d=json.load(sys.stdin)
print('found' if any(x['id']=='$PAYOUT_ID' for x in d.get('data',[])) else 'not_found')
")
[ "$SEARCH_FOUND" = "found" ] && pass "Search by q found payout" || warn "Search by q did not find payout"

DASH_FOUND=$(curl -s "$BROPAY/v1/merchant/payouts?source=dashboard&status=pending" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" | json "
d=json.load(sys.stdin)
print('found' if any(x['id']=='$PAYOUT_ID' for x in d.get('data',[])) else 'not_found')
")
[ "$DASH_FOUND" = "found" ] && pass "source=dashboard filter" || warn "Not in source=dashboard filter"

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
pass "Reserved: available=$AVAILABLE_AFTER, reserved=$RESERVED_AFTER"

# ── Step 7: Simulate payout completion (D1 — mirrors withdrawal.completed) ─
step 7 "Simulate payout completion (local D1)"

PROVIDER_TRANSFER_ID="e2e-wd-${PAYOUT_ID:0:20}"

# Link provider_transfer_id (webhook handler matches on this column)
d1_local_ok "UPDATE payouts SET provider_transfer_id = '$PROVIDER_TRANSFER_ID', status = 'processing', processing_started_at = datetime('now'), updated_at = datetime('now') WHERE id = '$PAYOUT_ID'" \
  || fail "Failed to set payout processing in local D1"
# Terminal transition + reservation_released_at (same fields as kbnk handleWithdrawalCompleted)
d1_local_ok "UPDATE payouts SET status = 'completed', completed_at = datetime('now'), reservation_released_at = datetime('now'), updated_at = datetime('now') WHERE id = '$PAYOUT_ID'" \
  || fail "Failed to mark payout completed in local D1"
d1_local_ok "UPDATE wallets SET reserved_balance = MAX(0, reserved_balance - $TOTAL_DEBIT), updated_at = datetime('now') WHERE id = '$WALLET_ID'" \
  || fail "Failed to release wallet reservation in local D1"
d1_local_ok "INSERT INTO payout_events (payout_id, event_type, status, description) VALUES ('$PAYOUT_ID', 'completed', 'completed', 'E2E simulated completion')" \
  || fail "Failed to insert payout event in local D1"
# release ledger (reserved_balance) — not a second available_balance debit
d1_local_ok "INSERT INTO wallet_ledger_entries (wallet_id, entry_type, reference_type, reference_id, amount, currency, balance_before, balance_after, description) VALUES ('$WALLET_ID', 'release', 'payout', '$PAYOUT_ID', $TOTAL_DEBIT, 'THB', $RESERVED_AFTER, MAX(0, $RESERVED_AFTER - $TOTAL_DEBIT), 'Payout completed — reservation released (E2E)')" \
  || fail "Failed to insert release ledger entry in local D1"
pass "Payout marked completed (D1, provider_transfer_id=$PROVIDER_TRANSFER_ID)"

# ── Step 8: Verify payout status + detail enrichment ─────────────────────────
step 8 "Verify payout status and detail"
PAYOUT_CHECK=$(curl -s "$BROPAY/v1/merchant/payouts/$PAYOUT_ID" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
FINAL_STATUS=$(echo "$PAYOUT_CHECK" | json "print(json.load(sys.stdin)['data']['status'])")
[ "$FINAL_STATUS" = "completed" ] || fail "Expected status 'completed', got '$FINAL_STATUS'"
pass "Payout status: $FINAL_STATUS"

COMPLETED_AT=$(echo "$PAYOUT_CHECK" | json "print(json.load(sys.stdin).get('data',{}).get('completed_at') or '')")
RELEASED_AT=$(echo "$PAYOUT_CHECK" | json "print(json.load(sys.stdin).get('data',{}).get('reservation_released_at') or '')")
[ -n "$COMPLETED_AT" ] && pass "completed_at set" || warn "completed_at missing"
[ -n "$RELEASED_AT" ] && pass "reservation_released_at set" || warn "reservation_released_at missing"

EVENTS_OK=$(echo "$PAYOUT_CHECK" | json "
d=json.load(sys.stdin)
print('found' if any(ev.get('event_type')=='completed' for ev in d.get('data',{}).get('events',[])) else 'not_found')
")
[ "$EVENTS_OK" = "found" ] && pass "events include completed" || fail "Missing completed event in payout detail"

TIMELINE_OK=$(echo "$PAYOUT_CHECK" | json "
d=json.load(sys.stdin)
print('found' if any(ev.get('kind')=='payout.completed' for ev in d.get('data',{}).get('timeline',[])) else 'not_found')
")
[ "$TIMELINE_OK" = "found" ] && pass "timeline includes payout.completed" || warn "timeline missing payout.completed"

COMPLETED_LIST=$(curl -s "$BROPAY/v1/merchant/payouts?status=completed" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" | json "
d=json.load(sys.stdin)
print('found' if any(x['id']=='$PAYOUT_ID' for x in d.get('data',[])) else 'not_found')
")
[ "$COMPLETED_LIST" = "found" ] && pass "Appears in status=completed filter" || warn "Not in completed filter"

STATS_COMPLETED=$(curl -s "$BROPAY/v1/merchant/payouts/stats" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" \
  | json "print(json.load(sys.stdin).get('data',{}).get('completed_count',0))")
[ "${STATS_COMPLETED:-0}" -ge 1 ] && pass "Stats completed_count: $STATS_COMPLETED" || warn "Stats completed_count: $STATS_COMPLETED"

step "8b" "Admin payout read"
ADMIN_DETAIL=$(http_get "$BROPAY/v1/admin/payouts/$PAYOUT_ID" -H "$ADMIN" -H "$ORIGIN")
ADMIN_CODE=$(echo "$ADMIN_DETAIL" | status)
ADMIN_STATUS=$(echo "$ADMIN_DETAIL" | body | json "print(json.load(sys.stdin).get('data',{}).get('status',''))" 2>/dev/null)
[ "$ADMIN_CODE" = "200" ] && [ "$ADMIN_STATUS" = "completed" ] && pass "Admin GET payout → completed" || warn "Admin detail: HTTP $ADMIN_CODE status=$ADMIN_STATUS"

# ── Step 9: Verify wallet balance ────────────────────────────────────────────
step 9 "Verify wallet balance"
FINAL_WALLET=$(curl -s "$BROPAY/v1/merchant/wallets" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
FINAL_BALANCE=$(echo "$FINAL_WALLET" | json "
d=json.load(sys.stdin)
w = d['data'][0] if isinstance(d['data'],list) and d['data'] else d.get('data',{})
print(w.get('available_balance', 0))
")
FINAL_RESERVED=$(echo "$FINAL_WALLET" | json "
d=json.load(sys.stdin)
w = d['data'][0] if isinstance(d['data'],list) and d['data'] else d.get('data',{})
print(w.get('reserved_balance', 0))
")
EXPECTED_BALANCE=$((FUNDED_BALANCE - TOTAL_DEBIT))
[ "$FINAL_BALANCE" -eq "$EXPECTED_BALANCE" ] || fail "Expected balance $EXPECTED_BALANCE, got $FINAL_BALANCE"
pass "Available: $FINAL_BALANCE satang (debit $TOTAL_DEBIT = amount $PAYOUT_AMOUNT + fee $FEE_AMOUNT)"
info "Reserved after completion: $FINAL_RESERVED satang"

# ── Step 10: Verify ledger ───────────────────────────────────────────────────
step 10 "Verify ledger"
LEDGER_FILTER=$(curl -s "$BROPAY/v1/merchant/wallets/ledger?reference_type=payout&reference_id=$PAYOUT_ID&limit=20" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
LEDGER_COUNT=$(echo "$LEDGER_FILTER" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
[ "${LEDGER_COUNT:-0}" -ge 2 ] && pass "Ledger filter entries: $LEDGER_COUNT" || warn "Ledger filter count: $LEDGER_COUNT (expected >= 2)"

RELEASE_FOUND=$(echo "$LEDGER_FILTER" | json "
d=json.load(sys.stdin)
print('found' if any(e.get('entry_type')=='release' for e in d.get('data',[])) else 'not_found')
")
[ "$RELEASE_FOUND" = "found" ] && pass "Ledger includes release entry" || warn "No release entry in ledger filter"

# ── Step 11: Guard: cannot cancel completed payout ─────────────────────────────
step 11 "Guard: cancel completed payout returns 400"
CANCEL_COMPLETED=$(http_post "$BROPAY/v1/merchant/payouts/$PAYOUT_ID/cancel" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d '{}')
[ "$(echo "$CANCEL_COMPLETED" | status)" = "400" ] || fail "Expected 400 cancelling completed payout, got $(echo "$CANCEL_COMPLETED" | status)"
pass "400 on cancel completed payout"

# ── Step 12: Cleanup ─────────────────────────────────────────────────────────
step 12 "Cleanup created resources"
d1_local_ok "DELETE FROM payout_events WHERE payout_id = '$PAYOUT_ID'" || true
d1_local_ok "DELETE FROM wallet_ledger_entries WHERE reference_id = '$PAYOUT_ID' AND reference_type = 'payout'" || true
d1_local_ok "DELETE FROM payouts WHERE id = '$PAYOUT_ID'" || true
d1_local_ok "DELETE FROM merchant_bank_accounts WHERE id = '$BA_ID'" || true
if [ -n "${UNVERIFIED_BA:-}" ] && [ "$UNVERIFIED_BA" != "$BA_ID" ]; then
  d1_local_ok "DELETE FROM merchant_bank_accounts WHERE id = '$UNVERIFIED_BA'" || true
fi
d1_local_ok "UPDATE wallets SET available_balance = $INITIAL_BALANCE, reserved_balance = 0, updated_at = datetime('now') WHERE id = '$WALLET_ID'" || true
d1_local_ok "DELETE FROM wallet_ledger_entries WHERE reference_id = 'e2e-funding' AND reference_type = 'deposit'" || true
pass "Cleanup complete"

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}━━━ Payout Completion Flow Complete ━━━${NC}"
echo "Initial:   $INITIAL_BALANCE satang"
echo "Funded:    +$FUND_AMOUNT satang"
echo "Payout:    $PAYOUT_AMOUNT satang + fee $FEE_AMOUNT satang = $TOTAL_DEBIT satang"
echo "Final:     $FINAL_BALANCE satang (available)"
echo "Payout:    ${PAYOUT_ID:0:20}... ($FINAL_STATUS)"
