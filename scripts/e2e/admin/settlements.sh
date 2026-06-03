#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Settlements (Realistic Lifecycle)
#
# Endpoints:
#   GET  /v1/admin/settlements
#   GET  /v1/admin/settlements/{id}
#   POST /v1/admin/settlements/{id}/complete
#   POST /v1/admin/settlements/{id}/fail
#   POST /v1/admin/settlements/{id}/slip
#   GET  /v1/admin/settlements/{id}/slip
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
# Safe under set -e: never abort the shell on bad JSON / python errors
json_has_data() {
  echo "$1" | python3 -c "
import sys, json
try:
    print('True' if 'data' in json.load(sys.stdin) else 'False')
except Exception:
    print('False')
" 2>/dev/null || echo "False"
}
d1_local_ok() {
  local cmd="$1"
  local rc=1
  pushd "$REPO_ROOT/apps/api" > /dev/null
  if command -v wrangler >/dev/null 2>&1; then
    wrangler d1 execute bropay-db --local --command "$cmd" >/dev/null 2>&1 && rc=0
  elif command -v pnpm >/dev/null 2>&1; then
    pnpm exec wrangler d1 execute bropay-db --local --command "$cmd" >/dev/null 2>&1 && rc=0
  fi
  popd > /dev/null
  return "$rc"
}

echo -e "${CYAN}━━━ Admin E2E — Settlements (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
MERCHANT_ID="$DEMO_MERCHANT_ID"
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
OWNER="Authorization: Bearer $DEMO_OWNER_TOKEN"
MERCH="X-Merchant-Id: $MERCHANT_ID"
pass "Admin token acquired (super_admin)"

step 2 "Ensure integration exists"
INTEGRATIONS=$(curl -s "$BROPAY/v1/merchant/integrations" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
INTEGRATION_COUNT=$(echo "$INTEGRATIONS" | json "print(len(json.load(sys.stdin).get('data',[])))")
if [ "${INTEGRATION_COUNT:-0}" -eq 0 ]; then
  curl -s "$BROPAY/v1/merchant/integrations" -X POST \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
    -d '{"name":"Demo Integration","slug":"demo"}' > /dev/null
  INTEGRATIONS=$(curl -s "$BROPAY/v1/merchant/integrations" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
fi
INTEGRATION_ID=$(echo "$INTEGRATIONS" | json "d=json.load(sys.stdin)['data']; print(d[0]['id'] if d else '')")
[ -n "$INTEGRATION_ID" ] || fail "No integration found"
pass "Integration: ${INTEGRATION_ID:0:16}..."

step 3 "Ensure bank account exists"
BA_CHECK=$(curl -s "$BROPAY/v1/merchant/bank-accounts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
BA_COUNT=$(echo "$BA_CHECK" | json "print(len(json.load(sys.stdin).get('data',[])))")
if [ "$BA_COUNT" = "0" ]; then
  BA_CREATE_RES=$(curl -s "$BROPAY/v1/merchant/bank-accounts" -X POST \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
    -d '{"bank_id":"bank-kbank-0000-0000-000000000001","account_number":"9876543210","account_holder_name":"Demo Merchant","account_type":"savings"}')
  BA_ID=$(echo "$BA_CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
else
  BA_ID=$(echo "$BA_CHECK" | json "d=json.load(sys.stdin)['data']; print(d[0]['id'] if d else '')")
fi
[ -n "$BA_ID" ] || fail "No bank account ID"
pass "Bank account: ${BA_ID:0:16}..."

step 3b "Verify bank account for settlement (DB update)"
pushd "$REPO_ROOT/apps/api" > /dev/null
wrangler d1 execute bropay-db --local --command \
  "UPDATE merchant_bank_accounts SET verification_status = 'verified', for_settlement = 1, status = 'active', updated_at = datetime('now') WHERE id = '$BA_ID'" 2>/dev/null > /dev/null
popd > /dev/null
pass "Bank account verified for settlement"

step 4 "Insert completed transactions directly"
pushd "$REPO_ROOT/apps/api" > /dev/null
TX1_ID=""; TX2_ID=""; TX3_ID=""; TX4_ID=""
for i in 1 2 3 4; do
  AMOUNT=$((10000 + i * 5000))
  TX_ID=$(python3 -c "import uuid; print(uuid.uuid4())")
  PI_ID=$(python3 -c "import uuid; print(uuid.uuid4())")
  wrangler d1 execute bropay-db --local --command \
    "INSERT INTO transactions (id, merchant_id, integration_id, reference_type, reference_id, amount, currency, direction, fee_amount, net_amount, status, description, created_at) VALUES ('$TX_ID', '$MERCHANT_ID', '$INTEGRATION_ID', 'payment', '$PI_ID', $AMOUNT, 'THB', 'credit', 0, $AMOUNT, 'completed', 'E2E settlement test $i', datetime('now'))" 2>/dev/null > /dev/null
  case $i in
    1) TX1_ID="$TX_ID" ;;
    2) TX2_ID="$TX_ID" ;;
    3) TX3_ID="$TX_ID" ;;
    4) TX4_ID="$TX_ID" ;;
  esac
  pass "Transaction $i: $AMOUNT satang"
done
popd > /dev/null

step 5 "Fund merchant wallet for fee coverage"
WALLET_RES=$(curl -s "$BROPAY/v1/admin/wallets?merchant_id=$MERCHANT_ID&limit=1" -H "$ADMIN" -H "$ORIGIN")
WALLET_ID=$(echo "$WALLET_RES" | json "
d=json.load(sys.stdin)
items=d.get('data',[])
print(items[0]['id'] if items else '')
")
[ -n "$WALLET_ID" ] || fail "No wallet found for merchant"
pushd "$REPO_ROOT/apps/api" > /dev/null
wrangler d1 execute bropay-db --local --command \
  "UPDATE wallets SET available_balance = available_balance + 500000, updated_at = datetime('now') WHERE id = '$WALLET_ID'" 2>/dev/null > /dev/null
popd > /dev/null
pass "Wallet funded: ${WALLET_ID:0:16}..."

step 5b "Cancel any existing pending settlements for this integration (unique constraint guard)"
# The DB has a UNIQUE constraint: one pending settlement per (merchant_id, integration_id).
# Fail any stale pending settlements before creating new ones.
PENDING_STALE=$(curl -s "$BROPAY/v1/admin/settlements?status=pending&merchant_id=$MERCHANT_ID" \
  -H "$ADMIN" -H "$ORIGIN")
STALE_SETTLE_IDS=$(python3 -c "
import sys, json
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
for s in d.get('data', []):
    if s.get('integration_id') == sys.argv[2]:
        print(s.get('id', ''))
" "$PENDING_STALE" "$INTEGRATION_ID" 2>/dev/null) || STALE_SETTLE_IDS=""
while IFS= read -r s_id; do
  s_id="${s_id//$'\r'/}"
  [ -z "$s_id" ] && continue
  curl -s "$BROPAY/v1/admin/settlements/$s_id/fail" -X POST \
    -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
    -d '{"failure_reason":"other","cancellation_reason":"Stale settlement from previous e2e run - cancelled for test idempotency"}' > /dev/null || true
done <<< "$STALE_SETTLE_IDS"
pass "Stale pending settlements cancelled"

step 6 "Create settlement 1 (merchant API)"
SETTLE1_RES=$(curl -s "$BROPAY/v1/merchant/settlements" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"integration_id\":\"$INTEGRATION_ID\",\"transaction_ids\":[\"$TX1_ID\",\"$TX2_ID\"]}")
SETTLE1_ID=$(echo "$SETTLE1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
SETTLE1_ID="${SETTLE1_ID//$'\r'/}"
[ -n "$SETTLE1_ID" ] || fail "Settlement 1 creation failed: $(echo "$SETTLE1_RES" | json "e=json.load(sys.stdin).get('error',{}); print(e)")"
SETTLE1_STATUS=$(echo "$SETTLE1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$SETTLE1_STATUS" = "pending" ] || fail "Expected pending status"
pass "Settlement 1: ${SETTLE1_ID:0:16}... ($SETTLE1_STATUS)"

step 7 "Create settlement 2 (merchant API)"
# Settlement 2 uses transactions WITHOUT integration_id filter since the unique constraint
# allows only ONE pending settlement per (merchant_id, integration_id).
# We use explicit transaction_ids without scoping to integration_id for the second settlement.
SETTLE2_RES=$(curl -s "$BROPAY/v1/merchant/settlements" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"transaction_ids\":[\"$TX3_ID\",\"$TX4_ID\"]}")
SETTLE2_ID=$(echo "$SETTLE2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
SETTLE2_ID="${SETTLE2_ID//$'\r'/}"
SETTLE2_ERR=$(echo "$SETTLE2_RES" | json "e=json.load(sys.stdin).get('error',{}); print(e.get('code','') + ': ' + e.get('message','') if e else '')" 2>/dev/null || echo "")
[ -n "$SETTLE2_ID" ] || fail "Settlement 2 creation failed (API error: ${SETTLE2_ERR:-unknown})"
pass "Settlement 2: ${SETTLE2_ID:0:16}..."

step 8 "List settlements (admin)"
LIST_RES=$(curl -s "$BROPAY/v1/admin/settlements" -H "$ADMIN" -H "$ORIGIN")
LIST_HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$LIST_HAS_META" = "True" ] || fail "Settlement list missing meta"
LIST_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_TOTAL" -ge 2 ] || fail "Expected at least 2 settlements"
pass "Listed $LIST_TOTAL settlement(s)"

step 9 "Filter settlements by pending status (admin)"
FILTER_RES=$(curl -s "$BROPAY/v1/admin/settlements?status=pending" -H "$ADMIN" -H "$ORIGIN")
FILTER_TOTAL=$(echo "$FILTER_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$FILTER_TOTAL" -ge 2 ] || fail "Expected at least 2 pending settlements"
pass "$FILTER_TOTAL pending settlement(s)"

step 9b "Filter settlements by date_from and date_to (admin)"
TODAY="$(date -u +%Y-%m-%d)"
DATE_FILTER_RES=$(curl -s "$BROPAY/v1/admin/settlements?date_from=$TODAY&date_to=$TODAY" -H "$ADMIN" -H "$ORIGIN")
DATE_FILTER_TOTAL=$(echo "$DATE_FILTER_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$DATE_FILTER_TOTAL" -ge 2 ] || fail "Expected at least 2 settlements within date range"
pass "$DATE_FILTER_TOTAL settlement(s) within date range"

step 9c "Filter settlements by settlement_type (admin)"
TYPE_FILTER_RES=$(curl -s "$BROPAY/v1/admin/settlements?settlement_type=manual" -H "$ADMIN" -H "$ORIGIN")
TYPE_FILTER_TOTAL=$(echo "$TYPE_FILTER_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$TYPE_FILTER_TOTAL" -ge 2 ] || fail "Expected at least 2 manual settlements"
pass "$TYPE_FILTER_TOTAL manual settlement(s)"

step 9d "Combined filter: status=pending + merchant_id (admin)"
COMBINED_RES=$(curl -s "$BROPAY/v1/admin/settlements?status=pending&merchant_id=$MERCHANT_ID" -H "$ADMIN" -H "$ORIGIN")
COMBINED_TOTAL=$(echo "$COMBINED_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$COMBINED_TOTAL" -ge 2 ] || fail "Expected at least 2 pending settlements for merchant"
pass "$COMBINED_TOTAL pending settlement(s) for merchant"

step 9e "Sort by settlement_date desc (admin)"
SORT_RES=$(curl -s "$BROPAY/v1/admin/settlements?sort=settlement_date&order=desc" -H "$ADMIN" -H "$ORIGIN")
SORT_OK=$(echo "$SORT_RES" | json "print('data' in json.load(sys.stdin))")
[ "$SORT_OK" = "True" ] || fail "Sort response missing data"
pass "Sorted by settlement_date desc"

step 9f "Sort by gross_amount asc (admin)"
SORT_ASC_RES=$(curl -s "$BROPAY/v1/admin/settlements?sort=gross_amount&order=asc" -H "$ADMIN" -H "$ORIGIN")
SORT_ASC_OK=$(echo "$SORT_ASC_RES" | json "print('data' in json.load(sys.stdin))")
[ "$SORT_ASC_OK" = "True" ] || fail "Sort asc response missing data"
pass "Sorted by gross_amount asc"

step 9g "Pagination with limit and page (admin)"
PAGE1_RES=$(curl -s "$BROPAY/v1/admin/settlements?limit=1&page=1" -H "$ADMIN" -H "$ORIGIN")
PAGE1_COUNT=$(echo "$PAGE1_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE1_COUNT" -eq 1 ] || fail "Expected 1 settlement on page 1"
PAGE2_RES=$(curl -s "$BROPAY/v1/admin/settlements?limit=1&page=2" -H "$ADMIN" -H "$ORIGIN")
PAGE2_COUNT=$(echo "$PAGE2_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE2_COUNT" -eq 1 ] || fail "Expected 1 settlement on page 2"
pass "Pagination works (limit=1, page=1+2)"

step 10 "GET settlement 1 detail (admin)"
DETAIL1_RES=$(curl -s "$BROPAY/v1/admin/settlements/$SETTLE1_ID" -H "$ADMIN" -H "$ORIGIN")
DETAIL1_ID=$(echo "$DETAIL1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$DETAIL1_ID" = "$SETTLE1_ID" ] || fail "Detail mismatch"
DETAIL1_HAS_ITEMS=$(echo "$DETAIL1_RES" | json "print('items' in json.load(sys.stdin).get('data',{}))")
[ "$DETAIL1_HAS_ITEMS" = "True" ] || fail "Detail missing items"
pass "Detail fetched with items"

step 11 "Upload proof-of-transfer slip (admin)"
SLIP_TMP="$REPO_ROOT/.e2e-slip-$$.jpg"
# Minimal 1×1 JPEG (same bytes as API vitest slip fixtures)
python3 -c "import sys; sys.stdout.buffer.write(bytes([0xff,0xd8,0xff,0xe0,0x00,0x10,0x4a,0x46,0x49,0x46,0x00,0x01,0x01,0x00,0x00,0x01,0x00,0x01,0x00,0x00,0xff,0xd9]))" > "$SLIP_TMP" 2>/dev/null \
  || printf '\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00\xff\xd9' > "$SLIP_TMP"
UPLOAD_RES=$(curl -s "$BROPAY/v1/admin/settlements/$SETTLE1_ID/slip" -X POST \
  -H "$ADMIN" -H "$ORIGIN" \
  -F "file=@$SLIP_TMP;type=image/jpeg;filename=e2e-slip.jpg") || UPLOAD_RES=""
rm -f "$SLIP_TMP"
UPLOAD_OK=$(json_has_data "$UPLOAD_RES")
if [ "$UPLOAD_OK" = "True" ]; then
  pass "Slip uploaded"
else
  warn "Slip upload via API failed (R2 may be unavailable), inserting DB row"
  SLIP_ID=$(python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null) || SLIP_ID=""
  SLIP_ID="${SLIP_ID//$'\r'/}"
  if ! d1_local_ok "INSERT INTO settlement_slips (id, settlement_id, mime_type, original_filename, r2_key, file_size, uploaded_by) VALUES ('$SLIP_ID', '$SETTLE1_ID', 'image/jpeg', 'e2e-slip.jpg', 'e2e/$SETTLE1_ID.jpg', 12345, 'acct-super-admin-0000-000000000001');"; then
    fail "D1 settlement_slips insert failed (is wrangler available via pnpm exec in apps/api?)"
  fi
  pass "Slip inserted (DB fallback)"
fi

step 12 "GET slip metadata (admin)"
SLIP_META_RES=$(curl -s "$BROPAY/v1/admin/settlements/$SETTLE1_ID/slip" -H "$ADMIN" -H "$ORIGIN")
SLIP_META_OK=$(json_has_data "$SLIP_META_RES")
if [ "$SLIP_META_OK" = "True" ]; then
  pass "Slip metadata fetched"
else
  warn "Slip metadata not found (expected if DB fallback used without R2)"
fi

step 13 "Complete settlement 1 (admin)"
COMPLETE_RES=$(curl -s "$BROPAY/v1/admin/settlements/$SETTLE1_ID/complete" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"notes":"E2E test completion","bank_reference":"E2E-REF-001"}')
COMPLETE_STATUS=$(echo "$COMPLETE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$COMPLETE_STATUS" = "completed" ] || fail "Expected completed, got '$COMPLETE_STATUS'"
pass "Settlement completed"

step 14 "Verify completed settlement has events (admin)"
VERIFY1_RES=$(curl -s "$BROPAY/v1/admin/settlements/$SETTLE1_ID" -H "$ADMIN" -H "$ORIGIN")
VERIFY1_EVENTS=$(echo "$VERIFY1_RES" | json "print(len(json.load(sys.stdin).get('data',{}).get('events',[])))")
[ "$VERIFY1_EVENTS" -ge 1 ] || fail "Expected at least 1 event"
pass "$VERIFY1_EVENTS event(s) recorded"

step 15 "Fail settlement 2 (admin)"
FAIL_RES=$(curl -s "$BROPAY/v1/admin/settlements/$SETTLE2_ID/fail" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"failure_reason":"bank_rejected","cancellation_reason":"Bank transfer rejected by recipient bank"}')
FAIL_STATUS=$(echo "$FAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$FAIL_STATUS" = "failed" ] || fail "Expected failed, got '$FAIL_STATUS'"
pass "Settlement marked failed"

step 16 "Verify failed settlement has events (admin)"
VERIFY2_RES=$(curl -s "$BROPAY/v1/admin/settlements/$SETTLE2_ID" -H "$ADMIN" -H "$ORIGIN")
VERIFY2_EVENTS=$(echo "$VERIFY2_RES" | json "print(len(json.load(sys.stdin).get('data',{}).get('events',[])))")
[ "$VERIFY2_EVENTS" -ge 1 ] || fail "Expected at least 1 event"
pass "$VERIFY2_EVENTS event(s) recorded"

step 17 "Guard: complete already-completed settlement → 422"
COMPLETE_AGAIN_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/settlements/$SETTLE1_ID/complete" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"notes":"Should fail"}')
COMPLETE_AGAIN_HTTP=$(echo "$COMPLETE_AGAIN_RES" | tail -n1)
[ "$COMPLETE_AGAIN_HTTP" = "422" ] || fail "Expected 422, got $COMPLETE_AGAIN_HTTP"
pass "Already-completed settlement rejected with 422"

step 18 "Guard: fail already-failed settlement → 422"
FAIL_AGAIN_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/settlements/$SETTLE2_ID/fail" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"failure_reason":"other","cancellation_reason":"Should fail"}')
FAIL_AGAIN_HTTP=$(echo "$FAIL_AGAIN_RES" | tail -n1)
[ "$FAIL_AGAIN_HTTP" = "422" ] || fail "Expected 422, got $FAIL_AGAIN_HTTP"
pass "Already-failed settlement rejected with 422"

step 19 "Guard: complete settlement without slip → 422"
# Insert a fresh transaction not yet in any settlement
step 19a "Insert fresh transaction for guard test"
TX5_ID=$(python3 -c "import uuid; print(uuid.uuid4())")
PI5_ID=$(python3 -c "import uuid; print(uuid.uuid4())")
pushd "$REPO_ROOT/apps/api" > /dev/null
wrangler d1 execute bropay-db --local --command \
  "INSERT INTO transactions (id, merchant_id, integration_id, reference_type, reference_id, amount, currency, direction, fee_amount, net_amount, status, description, created_at) VALUES ('$TX5_ID', '$MERCHANT_ID', '$INTEGRATION_ID', 'payment', '$PI5_ID', 12000, 'THB', 'credit', 0, 12000, 'completed', 'E2E settlement guard test', datetime('now'))" 2>/dev/null > /dev/null
popd > /dev/null
pass "Fresh transaction inserted: ${TX5_ID:0:16}..."

step 19b "Create settlement 3 (no slip) for guard test"
SETTLE3_RES=$(curl -s "$BROPAY/v1/merchant/settlements" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"integration_id\":\"$INTEGRATION_ID\",\"transaction_ids\":[\"$TX5_ID\"]}")
SETTLE3_ID=$(echo "$SETTLE3_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$SETTLE3_ID" ] || fail "Settlement 3 creation failed"
pass "Settlement 3 created: ${SETTLE3_ID:0:16}..."

step 19c "Attempt complete without slip → 422"
NO_SLIP_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/settlements/$SETTLE3_ID/complete" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"notes":"No slip"}')
NO_SLIP_HTTP=$(echo "$NO_SLIP_RES" | tail -n1)
[ "$NO_SLIP_HTTP" = "422" ] || fail "Expected 422, got $NO_SLIP_HTTP"
pass "Completing without slip rejected with 422"

echo -e "\n${GREEN}━━━ Settlements Realistic Lifecycle Complete ━━━${NC}"
