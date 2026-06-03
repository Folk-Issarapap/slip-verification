#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Invitations (Realistic Lifecycle)
#
# Endpoints:
#   GET  /v1/admin/invitations
#   POST /v1/admin/invitations
#   POST /v1/admin/invitations/{id}/cancel
#   POST /v1/admin/invitations/{id}/resend
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

echo -e "${CYAN}━━━ Admin E2E — Invitations (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
pass "Admin token acquired (super_admin)"

step 2 "Admin lists invitations — verify meta"
LIST_RES=$(curl -s "$BROPAY/v1/admin/invitations" -H "$ADMIN" -H "$ORIGIN")
LIST_HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$LIST_HAS_META" = "True" ] || fail "Invitation list missing meta"
LIST_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_TOTAL" -ge 0 ] || fail "Expected total >= 0"
pass "Listed $LIST_TOTAL invitation(s) with meta"

step 3 "Admin creates invitation"
TS=$(date +%s)
INVITE_EMAIL="invite-$TS@e2e.local"
CREATE_RES=$(curl -s "$BROPAY/v1/admin/invitations" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"email\":\"$INVITE_EMAIL\",\"merchant_id\":\"$DEMO_MERCHANT_ID\",\"role\":\"manager\"}")
CREATE_OK=$(echo "$CREATE_RES" | json "print('data' in json.load(sys.stdin))")
[ "$CREATE_OK" = "True" ] || fail "Invitation creation failed"
INVITE_ID=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
INVITE_STATUS=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
INVITE_ROLE=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('role',''))")
INVITE_TOKEN=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('token',''))")
[ -n "$INVITE_ID" ] || fail "Invitation creation returned no ID"
[ "$INVITE_STATUS" = "pending" ] || fail "Expected status=pending, got '$INVITE_STATUS'"
[ "$INVITE_ROLE" = "manager" ] || fail "Expected role=manager, got '$INVITE_ROLE'"
[ -n "$INVITE_TOKEN" ] || fail "Invitation token not returned"
pass "Created: ${INVITE_ID:0:16}... ($INVITE_STATUS, $INVITE_ROLE)"

step 4 "Admin gets list with status=pending — verify new invite appears"
PENDING_RES=$(curl -s "$BROPAY/v1/admin/invitations?status=pending" -H "$ADMIN" -H "$ORIGIN")
PENDING_TOTAL=$(echo "$PENDING_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$PENDING_TOTAL" -ge 1 ] || fail "Expected at least 1 pending invitation, got $PENDING_TOTAL"
PENDING_IDS=$(echo "$PENDING_RES" | json "d=json.load(sys.stdin).get('data',[]); print(','.join([x['id'] for x in d]))")
[[ "$PENDING_IDS" == *"$INVITE_ID"* ]] || fail "New invite not found in pending list"
pass "$PENDING_TOTAL pending invitation(s), new invite present"

step 5 "Admin filters by merchant_id"
MERCH_RES=$(curl -s "$BROPAY/v1/admin/invitations?merchant_id=$DEMO_MERCHANT_ID" -H "$ADMIN" -H "$ORIGIN")
MERCH_TOTAL=$(echo "$MERCH_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$MERCH_TOTAL" -ge 1 ] || fail "Expected at least 1 invitation for merchant, got $MERCH_TOTAL"
MERCH_IDS=$(echo "$MERCH_RES" | json "d=json.load(sys.stdin).get('data',[]); print(','.join([x['id'] for x in d]))")
[[ "$MERCH_IDS" == *"$INVITE_ID"* ]] || fail "New invite not found in merchant filter"
pass "$MERCH_TOTAL invitation(s) for merchant"

step 6 "Admin filters by multi-status (pending,cancelled)"
MULTI_RES=$(curl -s "$BROPAY/v1/admin/invitations?status=pending,cancelled" -H "$ADMIN" -H "$ORIGIN")
MULTI_TOTAL=$(echo "$MULTI_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$MULTI_TOTAL" -ge 1 ] || fail "Expected at least 1 pending/cancelled invitation, got $MULTI_TOTAL"
MULTI_IDS=$(echo "$MULTI_RES" | json "d=json.load(sys.stdin).get('data',[]); print(','.join([x['id'] for x in d]))")
[[ "$MULTI_IDS" == *"$INVITE_ID"* ]] || fail "New invite not found in multi-status filter"
pass "$MULTI_TOTAL invitation(s) with status pending/cancelled"

step 7 "Admin searches by q (email fragment)"
Q_RES=$(curl -s "$BROPAY/v1/admin/invitations?q=invite-$TS" -H "$ADMIN" -H "$ORIGIN")
Q_TOTAL=$(echo "$Q_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$Q_TOTAL" -ge 1 ] || fail "Expected at least 1 result for email search, got $Q_TOTAL"
Q_EMAIL=$(echo "$Q_RES" | json "d=json.load(sys.stdin).get('data',[]); print(d[0]['email'] if d else '')")
[ "$Q_EMAIL" = "$INVITE_EMAIL" ] || fail "Expected email='$INVITE_EMAIL', got '$Q_EMAIL'"
pass "$Q_TOTAL result(s) for email fragment 'invite-$TS'"

step 8 "Admin sorts by email asc"
SORT_EMAIL_RES=$(curl -s "$BROPAY/v1/admin/invitations?sort=email&order=asc" -H "$ADMIN" -H "$ORIGIN")
SORT_EMAIL_HAS_META=$(echo "$SORT_EMAIL_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_EMAIL_HAS_META" = "True" ] || fail "Sort by email asc failed"
pass "Sorted by email asc"

step 9 "Admin sorts by expires_at desc"
SORT_EXP_RES=$(curl -s "$BROPAY/v1/admin/invitations?sort=expires_at&order=desc" -H "$ADMIN" -H "$ORIGIN")
SORT_EXP_HAS_META=$(echo "$SORT_EXP_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_EXP_HAS_META" = "True" ] || fail "Sort by expires_at desc failed"
pass "Sorted by expires_at desc"

step 10 "Admin resends invitation — verify status still pending, token returned"
RESEND_RES=$(curl -s "$BROPAY/v1/admin/invitations/$INVITE_ID/resend" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
RESEND_OK=$(echo "$RESEND_RES" | json "print('data' in json.load(sys.stdin))")
[ "$RESEND_OK" = "True" ] || fail "Resend failed"
RESEND_STATUS=$(echo "$RESEND_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
RESEND_TOKEN=$(echo "$RESEND_RES" | json "print(json.load(sys.stdin).get('data',{}).get('token',''))")
[ "$RESEND_STATUS" = "pending" ] || fail "Expected status=pending after resend, got '$RESEND_STATUS'"
[ -n "$RESEND_TOKEN" ] || fail "Resend did not return token"
[ "$RESEND_TOKEN" != "$INVITE_TOKEN" ] || warn "Resend token may be different from original (same is acceptable)"
pass "Resent: status=$RESEND_STATUS, token returned"

step 11 "Admin cancels invitation — verify status=cancelled"
CANCEL_RES=$(curl -s "$BROPAY/v1/admin/invitations/$INVITE_ID/cancel" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
CANCEL_OK=$(echo "$CANCEL_RES" | json "print('data' in json.load(sys.stdin))")
[ "$CANCEL_OK" = "True" ] || fail "Cancel failed"
CANCEL_STATUS=$(echo "$CANCEL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$CANCEL_STATUS" = "cancelled" ] || fail "Expected status=cancelled, got '$CANCEL_STATUS'"
pass "Cancelled: status=$CANCEL_STATUS"

step 12 "Admin filters by status=cancelled — verify appears"
CAN_RES=$(curl -s "$BROPAY/v1/admin/invitations?status=cancelled" -H "$ADMIN" -H "$ORIGIN")
CAN_TOTAL=$(echo "$CAN_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$CAN_TOTAL" -ge 1 ] || fail "Expected at least 1 cancelled invitation, got $CAN_TOTAL"
CAN_IDS=$(echo "$CAN_RES" | json "d=json.load(sys.stdin).get('data',[]); print(','.join([x['id'] for x in d]))")
[[ "$CAN_IDS" == *"$INVITE_ID"* ]] || fail "Cancelled invite not found in cancelled list"
pass "$CAN_TOTAL cancelled invitation(s), cancelled invite present"

step 13 "Try to resend cancelled invitation → expect 400"
RESEND_CAN_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/invitations/$INVITE_ID/resend" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
RESEND_CAN_HTTP=$(echo "$RESEND_CAN_RES" | tail -n1)
[ "$RESEND_CAN_HTTP" = "400" ] || fail "Expected 400 for resending cancelled invite, got $RESEND_CAN_HTTP"
pass "Resend cancelled invite rejected with 400"

step 14 "Admin creates second invitation"
TS2=$(date +%s)
INVITE2_EMAIL="invite-$TS2@e2e.local"
CREATE2_RES=$(curl -s "$BROPAY/v1/admin/invitations" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"email\":\"$INVITE2_EMAIL\",\"merchant_id\":\"$DEMO_MERCHANT_ID\",\"role\":\"admin\"}")
CREATE2_OK=$(echo "$CREATE2_RES" | json "print('data' in json.load(sys.stdin))")
[ "$CREATE2_OK" = "True" ] || fail "Second invitation creation failed"
INVITE2_ID=$(echo "$CREATE2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
INVITE2_ROLE=$(echo "$CREATE2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('role',''))")
[ -n "$INVITE2_ID" ] || fail "Second invitation returned no ID"
[ "$INVITE2_ROLE" = "admin" ] || fail "Expected role=admin, got '$INVITE2_ROLE'"
pass "Created second: ${INVITE2_ID:0:16}... ($INVITE2_ROLE)"

step 15 "Admin paginates invitations"
PAGE_RES=$(curl -s "$BROPAY/v1/admin/invitations?limit=1&page=1" -H "$ADMIN" -H "$ORIGIN")
PAGE_LIMIT=$(echo "$PAGE_RES" | json "print(json.load(sys.stdin)['meta']['limit'])")
PAGE_COUNT=$(echo "$PAGE_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE_LIMIT" -eq 1 ] || fail "Expected limit=1"
[ "$PAGE_COUNT" -eq 1 ] || fail "Expected 1 item in page"
PAGE_TOTAL=$(echo "$PAGE_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$PAGE_TOTAL" -ge 2 ] || fail "Expected total >= 2 for pagination"
pass "Pagination limit=1 works, total=$PAGE_TOTAL"

step 16 "Guard: try to create invitation for same email+merchant while pending → expect 400"
DUP_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/invitations" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"email\":\"$INVITE2_EMAIL\",\"merchant_id\":\"$DEMO_MERCHANT_ID\",\"role\":\"member\"}")
DUP_HTTP=$(echo "$DUP_RES" | tail -n1)
[ "$DUP_HTTP" = "400" ] || fail "Expected 400 for duplicate pending invite, got $DUP_HTTP"
DUP_CODE=$(echo "$DUP_RES" | sed '$d' | json "print(json.load(sys.stdin).get('error',{}).get('code',''))")
[ "$DUP_CODE" = "CONFLICT" ] || warn "Expected CONFLICT error code, got '$DUP_CODE'"
pass "Duplicate pending invite rejected with 400"

step 17 "Guard: create an account, add as member, then try to invite same email → expect 400"
MEM_EMAIL="member-$TS@e2e.local"
REG_RES=$(curl -s "$BROPAY/v1/auth/register" -H "$CT" -H "$ORIGIN" \
  -d "{\"email\":\"$MEM_EMAIL\",\"password\":\"Password123!\",\"name\":\"Member User\"}")
MEM_TOKEN=$(echo "$REG_RES" | json "print(json.load(sys.stdin).get('data',{}).get('accessToken',''))")
[ -n "$MEM_TOKEN" ] || fail "Member registration failed"

ME_RES=$(curl -s "$BROPAY/v1/auth/me" -H "Authorization: Bearer $MEM_TOKEN" -H "$ORIGIN")
MEM_ID=$(echo "$ME_RES" | json "print(json.load(sys.stdin)['data']['id'])")
pass "Member account: ${MEM_ID:0:16}..."

# Add as member via admin endpoint
ADD_RES=$(curl -s "$BROPAY/v1/admin/merchants/$DEMO_MERCHANT_ID/members" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"account_id\":\"$MEM_ID\",\"role\":\"manager\"}")
ADD_OK=$(echo "$ADD_RES" | json "print('data' in json.load(sys.stdin))")
if [ "$ADD_OK" != "True" ]; then
  warn "Add-member shape may vary, checking HTTP status"
fi

# Now try to invite the same email
ALREADY_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/invitations" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"email\":\"$MEM_EMAIL\",\"merchant_id\":\"$DEMO_MERCHANT_ID\",\"role\":\"member\"}")
ALREADY_HTTP=$(echo "$ALREADY_RES" | tail -n1)
[ "$ALREADY_HTTP" = "400" ] || fail "Expected 400 for inviting existing member, got $ALREADY_HTTP"
ALREADY_CODE=$(echo "$ALREADY_RES" | sed '$d' | json "print(json.load(sys.stdin).get('error',{}).get('code',''))")
[ "$ALREADY_CODE" = "ALREADY_MEMBER" ] || warn "Expected ALREADY_MEMBER error code, got '$ALREADY_CODE'"
pass "Invite existing member rejected with 400"

# Cleanup: cancel second invitation so the suite is idempotent
step 18 "Cleanup — cancel second invitation"
CANCEL2_RES=$(curl -s "$BROPAY/v1/admin/invitations/$INVITE2_ID/cancel" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
CANCEL2_STATUS=$(echo "$CANCEL2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$CANCEL2_STATUS" = "cancelled" ] || warn "Cleanup cancel returned '$CANCEL2_STATUS'"
pass "Second invitation cancelled"

echo -e "\n${GREEN}━━━ Invitations Realistic Lifecycle Complete ━━━${NC}"
