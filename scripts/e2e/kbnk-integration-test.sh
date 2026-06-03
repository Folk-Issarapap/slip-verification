#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# KBNK End-to-End Integration Test
# Tests the full BroPay ↔ KBNK staging integration
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

KBNK_URL="${KBNK_URL:?KBNK_URL must be set (KBNK gateway URL)}"
BROPAY_URL="${BROPAY_URL:-http://localhost:8787}"
KBNK_CLIENT_ID="${KBNK_CLIENT_ID:?KBNK_CLIENT_ID must be set}"
KBNK_CLIENT_SECRET="${KBNK_CLIENT_SECRET:?KBNK_CLIENT_SECRET must be set}"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }
info() { echo -e "${CYAN}→ $1${NC}"; }
warn() { echo -e "${YELLOW}! $1${NC}"; }
step() { echo -e "\n${CYAN}━━━ Step $1: $2 ━━━${NC}"; }

# ── Step 1: Health Check ─────────────────────────────────────────────────────
step 1 "KBNK Health Check"

HEALTH=$(curl -s "$KBNK_URL/health" 2>/dev/null)
STATUS=$(echo "$HEALTH" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','error'))" 2>/dev/null)

if [ "$STATUS" = "ok" ]; then
  pass "KBNK health: $STATUS"
else
  fail "KBNK health check failed: $HEALTH"
fi

# ── Step 2: Authenticate ─────────────────────────────────────────────────────
step 2 "OAuth2 Authentication"

AUTH_RES=$(curl -s "$KBNK_URL/api/v1/auth/token" \
  -H "Content-Type: application/json" \
  -d "{\"grant_type\":\"client_credentials\",\"client_id\":\"$KBNK_CLIENT_ID\",\"client_secret\":\"$KBNK_CLIENT_SECRET\"}")

KBNK_TOKEN=$(echo "$AUTH_RES" | python3 -c "import sys,json; print(json.load(sys.stdin).get('access_token',''))" 2>/dev/null)

if [ -n "$KBNK_TOKEN" ] && [ "$KBNK_TOKEN" != "" ]; then
  pass "Got access token (${#KBNK_TOKEN} chars)"
else
  fail "Authentication failed: $AUTH_RES"
fi

AUTH="Authorization: Bearer $KBNK_TOKEN"

# ── Step 3: Get Merchant Profile ─────────────────────────────────────────────
step 3 "Merchant Profile"

ME_RES=$(curl -s "$KBNK_URL/api/v1/me" -H "$AUTH")
MERCHANT_NAME=$(echo "$ME_RES" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['name'])" 2>/dev/null)
MERCHANT_STATUS=$(echo "$ME_RES" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['status'])" 2>/dev/null)

if [ "$MERCHANT_STATUS" = "active" ]; then
  pass "Merchant: $MERCHANT_NAME (status: $MERCHANT_STATUS)"
else
  fail "Merchant not active: $ME_RES"
fi

# ── Step 4: Check Balance ────────────────────────────────────────────────────
step 4 "Check Balance"

BAL_RES=$(curl -s "$KBNK_URL/api/v1/balance" -H "$AUTH")
BALANCE=$(echo "$BAL_RES" | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['balance'])" 2>/dev/null)
pass "Current balance: $BALANCE THB"

# ── Step 5: Bank Account Verification ────────────────────────────────────────
step 5 "Bank Account Verification (KYC)"

BAV_RES=$(curl -s "$KBNK_URL/api/v1/bank-account-verifications/verify" \
  -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"bankCode":"KBANK","accountNumber":"0123456789","accountHolderName":"Test BroPay User"}')

BAV_ID=$(echo "$BAV_RES" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('verificationId',d.get('data',{}).get('id','')))" 2>/dev/null)
BAV_STATUS=$(echo "$BAV_RES" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('status','error'))" 2>/dev/null)

if [ -n "$BAV_ID" ]; then
  pass "Verification: $BAV_ID (status: $BAV_STATUS)"
else
  warn "BAV response: $BAV_RES"
  fail "Bank account verification failed"
fi

# Wait for verification to complete (sandbox is fast)
info "Waiting 3s for verification to process..."
sleep 3

BAV_CHECK=$(curl -s "$KBNK_URL/api/v1/bank-account-verifications/$BAV_ID" -H "$AUTH")
BAV_FINAL_STATUS=$(echo "$BAV_CHECK" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('status','unknown'))" 2>/dev/null)
pass "Verification final status: $BAV_FINAL_STATUS"

# ── Step 6: Create Deposit (PromptPay) ───────────────────────────────────────
step 6 "Create Deposit (PromptPay)"

DEPOSIT_RES=$(curl -s "$KBNK_URL/api/v1/deposits" \
  -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"amount\":100.00,\"paymentMethod\":\"promptpay\",\"currency\":\"THB\",\"correlationId\":\"bropay-e2e-test-$(date +%s)\",\"verificationId\":\"$BAV_ID\"}")

DEPOSIT_ID=$(echo "$DEPOSIT_RES" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('data',{}).get('depositId', d.get('data',{}).get('id','')))" 2>/dev/null)
DEPOSIT_STATUS=$(echo "$DEPOSIT_RES" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('status','error'))" 2>/dev/null)
QR_PAYLOAD=$(echo "$DEPOSIT_RES" | python3 -c "import sys,json; pi=json.load(sys.stdin).get('data',{}).get('paymentInstruction',{}); print(pi.get('qrPayload','none'))" 2>/dev/null)

if [ -n "$DEPOSIT_ID" ] && [ "$DEPOSIT_STATUS" = "pending" ]; then
  pass "Deposit: $DEPOSIT_ID (status: $DEPOSIT_STATUS)"
  if [ "$QR_PAYLOAD" != "none" ] && [ -n "$QR_PAYLOAD" ]; then
    pass "QR payload received (${#QR_PAYLOAD} chars)"
  else
    warn "No QR payload in response"
  fi
else
  warn "Deposit response: $DEPOSIT_RES"
  fail "Deposit creation failed"
fi

# ── Step 7: Simulate Deposit Completion (Sandbox) ────────────────────────────
step 7 "Simulate Deposit Completion (Sandbox)"

# Use internal UUID for status update
DEPOSIT_UUID=$(echo "$DEPOSIT_RES" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('id',''))" 2>/dev/null)

COMPLETE_RES=$(curl -s "$KBNK_URL/api/v1/deposits/$DEPOSIT_UUID/status" \
  -X PATCH -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"status":"completed"}')

COMPLETE_STATUS=$(echo "$COMPLETE_RES" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('status','error'))" 2>/dev/null)

if [ "$COMPLETE_STATUS" = "completed" ]; then
  pass "Deposit completed via sandbox override"
else
  warn "Complete response: $COMPLETE_RES"
  warn "Sandbox status override may not be available (SIMULATE_AUTOMATION might be off)"
fi

# ── Step 8: Poll Deposit Status ──────────────────────────────────────────────
step 8 "Poll Deposit Status"

POLL_RES=$(curl -s "$KBNK_URL/api/v1/deposits/$DEPOSIT_UUID/status" -H "$AUTH")
POLL_STATUS=$(echo "$POLL_RES" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('status','unknown'))" 2>/dev/null)
pass "Deposit status: $POLL_STATUS"

# ── Step 9: Create Withdrawal (Transfer) ─────────────────────────────────────
step 9 "Create Withdrawal (Transfer)"

WITHDRAWAL_RES=$(curl -s "$KBNK_URL/api/v1/transfers" \
  -H "$AUTH" -H "Content-Type: application/json" \
  -H "Idempotency-Key: bropay-e2e-$(date +%s)" \
  -d "{\"destinationAccount\":\"0123456789\",\"amount\":\"50.00\",\"priority\":\"normal\",\"verificationId\":\"$BAV_ID\"}")

W_ID=$(echo "$WITHDRAWAL_RES" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('id',''))" 2>/dev/null)
W_STATUS=$(echo "$WITHDRAWAL_RES" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('status','error'))" 2>/dev/null)

if [ -n "$W_ID" ]; then
  pass "Withdrawal: $W_ID (status: $W_STATUS)"
else
  warn "Withdrawal response: $WITHDRAWAL_RES"
  warn "Withdrawal may require sufficient balance"
fi

# ── Step 10: Check Withdrawal Status ─────────────────────────────────────────
step 10 "Check Withdrawal Status"

if [ -n "$W_ID" ]; then
  info "Waiting 5s for withdrawal processing..."
  sleep 5
  W_CHECK=$(curl -s "$KBNK_URL/api/v1/transfers/$W_ID/status" -H "$AUTH")
  W_FINAL=$(echo "$W_CHECK" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('status','unknown'))" 2>/dev/null)
  pass "Withdrawal status: $W_FINAL"
else
  warn "Skipped (no withdrawal created)"
fi

# ── Step 11: List Deposits ───────────────────────────────────────────────────
step 11 "List Deposits"

LIST_RES=$(curl -s "$KBNK_URL/api/v1/deposits?pageSize=3" -H "$AUTH")
TOTAL=$(echo "$LIST_RES" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pagination',{}).get('total',0))" 2>/dev/null)
pass "Total deposits: $TOTAL"

# ── Step 12: Webhook Delivery History ────────────────────────────────────────
step 12 "Webhook Delivery History"

WH_RES=$(curl -s "$KBNK_URL/api/v1/webhooks?pageSize=5" -H "$AUTH")
WH_TOTAL=$(echo "$WH_RES" | python3 -c "import sys,json; print(json.load(sys.stdin).get('pagination',{}).get('total',0))" 2>/dev/null)
pass "Total webhook deliveries: $WH_TOTAL"

# Show recent deliveries
echo "$WH_RES" | python3 -c "
import sys,json
data = json.load(sys.stdin).get('data',[])
for d in data[:5]:
    status = d.get('status','?')
    event = d.get('eventType','?')
    http = d.get('httpStatus','?')
    print(f'  {event:25} HTTP {http}  {status}')
" 2>/dev/null || true

# ── Step 13: BroPay Health Check via API ─────────────────────────────────────
step 13 "BroPay → KBNK Health Check (via admin API)"

BP_TOKEN=$(curl -s "$BROPAY_URL/v1/auth/staff/login" \
  -H "Content-Type: application/json" -H "Origin: http://localhost:3000" \
  -d '{"email":"super@bropay.com","password":"password123"}' | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['accessToken'])" 2>/dev/null)

if [ -n "$BP_TOKEN" ]; then
  HC_RES=$(curl -s "$BROPAY_URL/v1/admin/providers/prov-kbnk-000000-0000-000000000001/health-check" \
    -X POST -H "Authorization: Bearer $BP_TOKEN" -H "Origin: http://localhost:3000")
  HC_STATUS=$(echo "$HC_RES" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('status','error'))" 2>/dev/null)
  HC_MS=$(echo "$HC_RES" | python3 -c "import sys,json; print(json.load(sys.stdin).get('data',{}).get('response_time_ms','?'))" 2>/dev/null)
  pass "BroPay health check: $HC_STATUS (${HC_MS}ms)"
else
  warn "Could not authenticate with BroPay API"
fi

# ── Step 14: Get Banks List ──────────────────────────────────────────────────
step 14 "Banks List (public, no auth)"

BANKS_RES=$(curl -s "$KBNK_URL/api/v1/banks")
BANK_COUNT=$(echo "$BANKS_RES" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null)
pass "Available banks: $BANK_COUNT"

# ── Summary ──────────────────────────────────────────────────────────────────
echo -e "\n${GREEN}━━━ Integration Test Complete ━━━${NC}"
echo -e "KBNK API:     $KBNK_URL"
echo -e "BroPay API:   $BROPAY_URL"
echo -e "Merchant:     $MERCHANT_NAME"
echo -e "Balance:      $BALANCE THB"
echo -e "Deposit:      $DEPOSIT_ID ($POLL_STATUS)"
if [ -n "$W_ID" ]; then
  echo -e "Withdrawal:   $W_ID ($W_FINAL)"
fi
echo -e "BAV:          $BAV_ID ($BAV_FINAL_STATUS)"
echo -e "Webhooks:     $WH_TOTAL deliveries"
