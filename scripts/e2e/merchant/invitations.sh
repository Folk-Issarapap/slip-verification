#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Merchant — Invitations (Realistic Lifecycle)
#
# Endpoints:
#   GET  /v1/merchant/invitations
#   POST /v1/merchant/invitations
#   POST /v1/merchant/invitations/{id}/cancel
#   POST /v1/merchant/invitations/{id}/resend
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

echo -e "${CYAN}━━━ Merchant E2E — Invitations (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
OWNER="Authorization: Bearer $DEMO_OWNER_TOKEN"
MERCH="X-Merchant-Id: $DEMO_MERCHANT_ID"
pass "Merchant: ${DEMO_MERCHANT_ID:0:16}..."

step 2 "Create invitation A (manager)"
TS=$(date +%s)
INVITE_A_EMAIL="invite-a-$TS@e2e.local"
CREATE_A_RES=$(curl -s "$BROPAY/v1/merchant/invitations" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"email\":\"$INVITE_A_EMAIL\",\"role\":\"manager\"}")
INV_A_ID=$(echo "$CREATE_A_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$INV_A_ID" ] || fail "Invitation A creation failed"
INV_A_STATUS=$(echo "$CREATE_A_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$INV_A_STATUS" = "pending" ] || fail "Invitation A status not pending"
pass "Invitation A created: ${INV_A_ID:0:16}... ($INVITE_A_EMAIL)"

step 3 "Create invitation B (member)"
INVITE_B_EMAIL="invite-b-$TS@e2e.local"
CREATE_B_RES=$(curl -s "$BROPAY/v1/merchant/invitations" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"email\":\"$INVITE_B_EMAIL\",\"role\":\"member\"}")
INV_B_ID=$(echo "$CREATE_B_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$INV_B_ID" ] || fail "Invitation B creation failed"
pass "Invitation B created: ${INV_B_ID:0:16}... ($INVITE_B_EMAIL)"

step 4 "List invitations — verify both appear"
LIST_RES=$(curl -s "$BROPAY/v1/merchant/invitations" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
LIST_COUNT=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_COUNT" -ge 2 ] || fail "Expected at least 2 invitations, got $LIST_COUNT"
pass "Listed $LIST_COUNT invitation(s)"

step 5 "Filter invitations by status=pending"
FILT_RES=$(curl -s "$BROPAY/v1/merchant/invitations?status=pending" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
FILT_COUNT=$(echo "$FILT_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FILT_COUNT" -ge 2 ] || fail "Expected at least 2 pending invitations, got $FILT_COUNT"
pass "$FILT_COUNT pending invitation(s)"

step 6 "Search invitations by email fragment"
Q_RES=$(curl -s "$BROPAY/v1/merchant/invitations?q=invite-a-$TS" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
Q_COUNT=$(echo "$Q_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$Q_COUNT" -ge 1 ] || fail "Expected at least 1 result for email search, got $Q_COUNT"
pass "$Q_COUNT result(s) for email search"

step 7 "Sort invitations by created_at desc"
SORT_RES=$(curl -s "$BROPAY/v1/merchant/invitations?sort=created_at&order=desc" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT_OK=$(echo "$SORT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_OK" = "True" ] || fail "Sort by created_at desc failed"
pass "Sorted by created_at desc"

step 8 "Sort invitations by expires_at asc"
SORT2_RES=$(curl -s "$BROPAY/v1/merchant/invitations?sort=expires_at&order=asc" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
SORT2_OK=$(echo "$SORT2_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT2_OK" = "True" ] || fail "Sort by expires_at asc failed"
pass "Sorted by expires_at asc"

step 9 "Pagination limit=1"
PAGE_RES=$(curl -s "$BROPAY/v1/merchant/invitations?limit=1&page=1" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
PAGE_LIMIT=$(echo "$PAGE_RES" | json "print(json.load(sys.stdin)['meta']['limit'])")
PAGE_COUNT=$(echo "$PAGE_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE_LIMIT" -eq 1 ] || fail "Expected limit=1, got $PAGE_LIMIT"
[ "$PAGE_COUNT" -eq 1 ] || fail "Expected 1 item in page, got $PAGE_COUNT"
pass "Pagination limit=1 works"

step 10 "Resend invitation A (refresh token + expiry)"
RESEND_RES=$(curl -s "$BROPAY/v1/merchant/invitations/$INV_A_ID/resend" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d '{}')
RESEND_ID=$(echo "$RESEND_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$RESEND_ID" = "$INV_A_ID" ] || fail "Resend returned different ID"
RESEND_STATUS=$(echo "$RESEND_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$RESEND_STATUS" = "pending" ] || fail "Resend status not pending"
pass "Invitation A resent"

step 11 "Cancel invitation B"
CANCEL_RES=$(curl -s "$BROPAY/v1/merchant/invitations/$INV_B_ID/cancel" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d '{}')
CANCEL_STATUS=$(echo "$CANCEL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$CANCEL_STATUS" = "cancelled" ] || fail "Cancel failed"
pass "Invitation B cancelled"

step 12 "Verify cancelled invitation not in pending filter"
FILT_P_RES=$(curl -s "$BROPAY/v1/merchant/invitations?status=pending" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
FILT_P_COUNT=$(echo "$FILT_P_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
# Invitation B should be gone from pending; other pre-existing pending invitations may remain
FILT_P_IDS=$(echo "$FILT_P_RES" | json "print(json.dumps([d['id'] for d in json.load(sys.stdin).get('data',[])]))")
if echo "$FILT_P_IDS" | grep -q "$INV_B_ID"; then
  fail "Cancelled invitation B still in pending filter"
fi
pass "Cancelled invitation B no longer in pending filter"

step 13 "Guard: resend cancelled invitation returns 400"
RESEND2_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/invitations/$INV_B_ID/resend" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d '{}')
RESEND2_HTTP=$(echo "$RESEND2_RES" | tail -n1)
[ "$RESEND2_HTTP" = "400" ] || fail "Expected 400 for resending cancelled invitation, got $RESEND2_HTTP"
pass "Resend cancelled invitation rejected with 400"

step 14 "Guard: cancel already-cancelled invitation"
CANCEL2_RES=$(curl -s "$BROPAY/v1/merchant/invitations/$INV_B_ID/cancel" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" -d '{}')
CANCEL2_STATUS=$(echo "$CANCEL2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$CANCEL2_STATUS" = "cancelled" ] || fail "Re-cancel did not return cancelled"
pass "Re-cancel returns cancelled"

step 15 "Guard: duplicate pending invitation for same email returns 409"
DUP_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/invitations" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"email\":\"$INVITE_A_EMAIL\",\"role\":\"member\"}")
DUP_HTTP=$(echo "$DUP_RES" | tail -n1)
[ "$DUP_HTTP" = "409" ] || fail "Expected 409 for duplicate pending invitation, got $DUP_HTTP"
pass "Duplicate pending invitation rejected with 409"

echo -e "\n${GREEN}━━━ Invitations Realistic Lifecycle Complete ━━━${NC}"
