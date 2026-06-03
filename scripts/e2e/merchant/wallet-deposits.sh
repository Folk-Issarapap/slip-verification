#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Merchant — Wallet Deposits
#
# Prerequisites: API worker, python3, curl
#
# Usage:
#   BROPAY_URL=http://localhost:8787 bash scripts/e2e/merchant/wallet-deposits.sh
#
# Environment:
#   BROPAY_URL              Base API URL (default: http://localhost:8787)
#   BOOTSTRAP_MERCHANT_ID   Override merchant (optional)
#
# External dependencies:
#   - Provider may be required for POST / (create); local runs accept 201 or documented 4xx
#
# Endpoints:
#   GET  /v1/merchant/wallet-deposits
#   GET  /v1/merchant/wallet-deposits/{id}
#   POST /v1/merchant/wallet-deposits
#   POST /v1/merchant/wallet-deposits/{id}/cancel
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../_merchant-lib.sh
source "$SCRIPT_DIR/../_merchant-lib.sh"

BROPAY="${BROPAY_URL:-http://localhost:8787}"
ORIGIN="Origin: http://localhost:3000"
CT="Content-Type: application/json"

echo -e "${CYAN}━━━ Merchant E2E — Wallet Deposits ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
merchant_auth_headers
pass "Merchant: ${DEMO_MERCHANT_ID:0:16}..."

step 2 "List wallet deposits"
LIST_RES=$(curl -s "$BROPAY/v1/merchant/wallet-deposits" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$HAS_META" = "True" ] || fail "List missing meta: $LIST_RES"
pass "List OK (total=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])"))"

step 3 "Filter by status=processing"
FILT_RES=$(curl -s "$BROPAY/v1/merchant/wallet-deposits?status=processing&limit=5" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
FILT_OK=$(echo "$FILT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$FILT_OK" = "True" ] || fail "status filter failed"
pass "status=processing filter OK"

step 4 "Create wallet deposit"
TS=$(date +%s)
CREATE_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/wallet-deposits" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"amount\":50000,\"payment_method\":\"promptpay\",\"notes\":\"E2E deposit $TS\"}")
CREATE_HTTP=$(echo "$CREATE_RES" | tail -n1)
CREATE_BODY=$(echo "$CREATE_RES" | sed '$d')
if [ "$CREATE_HTTP" = "201" ]; then
  DEP_ID=$(echo "$CREATE_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
  [ -n "$DEP_ID" ] || fail "Create missing data.id"
  pass "Created deposit ${DEP_ID:0:16}..."
elif [ "$CREATE_HTTP" = "422" ] || [ "$CREATE_HTTP" = "400" ]; then
  warn "Create returned $CREATE_HTTP (limits/provider) — skipping detail/cancel steps"
  DEP_ID=""
  pass "Create endpoint contract OK ($CREATE_HTTP)"
else
  fail "Unexpected create HTTP $CREATE_HTTP: $CREATE_BODY"
fi

if [ -n "${DEP_ID:-}" ]; then
  step 5 "GET wallet deposit detail"
  GET_RES=$(curl -s "$BROPAY/v1/merchant/wallet-deposits/$DEP_ID" \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
  GET_ID=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
  [ "$GET_ID" = "$DEP_ID" ] || fail "Detail id mismatch: $GET_RES"
  pass "Detail fetched"

  step 6 "Cancel wallet deposit"
  CANCEL_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/wallet-deposits/$DEP_ID/cancel" -X POST \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
    -d '{}')
  CANCEL_HTTP=$(echo "$CANCEL_RES" | tail -n1)
  case "$CANCEL_HTTP" in
    200|202) pass "Cancel accepted ($CANCEL_HTTP)" ;;
    409) warn "Already terminal (409) — OK for idempotent rerun" ; pass "Cancel guard OK" ;;
    *) fail "Unexpected cancel HTTP $CANCEL_HTTP: $(echo "$CANCEL_RES" | sed '$d')" ;;
  esac
fi

step 7 "Guard: GET unknown deposit returns 404"
BAD_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/wallet-deposits/nonexistent-deposit-id" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
BAD_HTTP=$(echo "$BAD_RES" | tail -n1)
[ "$BAD_HTTP" = "404" ] || fail "Expected 404, got $BAD_HTTP"
pass "Unknown deposit → 404"

step 8 "Guard: invalid amount returns 400 or 422"
BAD_AMT_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/wallet-deposits" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{"amount":-1}')
BAD_AMT_HTTP=$(echo "$BAD_AMT_RES" | tail -n1)
[ "$BAD_AMT_HTTP" = "400" ] || [ "$BAD_AMT_HTTP" = "422" ] || fail "Expected 400/422 for negative amount, got $BAD_AMT_HTTP"
pass "Negative amount rejected ($BAD_AMT_HTTP)"

echo -e "\n${GREEN}━━━ Wallet Deposits Complete ━━━${NC}"
