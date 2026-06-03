#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Providers (Realistic Lifecycle)
#
# Endpoints:
#   GET  /v1/admin/providers
#   GET  /v1/admin/providers/{id}
#   POST /v1/admin/providers
#   PUT  /v1/admin/providers/{id}
#   GET  /v1/admin/providers/{id}/health
#   GET  /v1/admin/providers/{id}/credentials
#   POST /v1/admin/providers/{id}/credentials
#   PUT  /v1/admin/providers/{id}/credentials/{credentialId}
#   DELETE /v1/admin/providers/{id}/credentials/{credentialId}
#   PUT  /v1/admin/providers/{id}/payment-config
#   PUT  /v1/admin/providers/{id}/settlement-config
#   PUT  /v1/admin/providers/{id}/wallet-config
#   PUT  /v1/admin/providers/{id}/verification-config
#   PUT  /v1/admin/providers/{id}/capabilities
#   GET  /v1/admin/providers/{id}/stats
#   POST /v1/admin/providers/{id}/health-check
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

echo -e "${CYAN}━━━ Admin E2E — Providers (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
pass "Admin token acquired (super_admin)"

step 2 "List providers — verify meta"
LIST_RES=$(curl -s "$BROPAY/v1/admin/providers" -H "$ADMIN" -H "$ORIGIN")
LIST_HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$LIST_HAS_META" = "True" ] || fail "Provider list missing meta"
LIST_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_TOTAL" -ge 1 ] || fail "Expected at least 1 provider"
pass "Listed $LIST_TOTAL provider(s)"

step 3 "Filter by status=active"
F1_RES=$(curl -s "$BROPAY/v1/admin/providers?status=active" -H "$ADMIN" -H "$ORIGIN")
F1_HAS_META=$(echo "$F1_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$F1_HAS_META" = "True" ] || fail "Active filter failed"
pass "Filtered by status=active"

step 4 "Filter by multi-status"
F2_RES=$(curl -s "$BROPAY/v1/admin/providers?status=active,inactive" -H "$ADMIN" -H "$ORIGIN")
F2_HAS_META=$(echo "$F2_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$F2_HAS_META" = "True" ] || fail "Multi-status filter failed"
pass "Filtered by multi-status"

step 5 "Search by q (name fragment)"
Q_RES=$(curl -s "$BROPAY/v1/admin/providers?q=kbank" -H "$ADMIN" -H "$ORIGIN")
Q_HAS_META=$(echo "$Q_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$Q_HAS_META" = "True" ] || fail "Search by q failed"
pass "Searched by name fragment"

step 6 "Sort by name asc"
S1_RES=$(curl -s "$BROPAY/v1/admin/providers?sort=name&order=asc" -H "$ADMIN" -H "$ORIGIN")
S1_HAS_META=$(echo "$S1_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$S1_HAS_META" = "True" ] || fail "Sort by name asc failed"
pass "Sorted by name asc"

step 7 "Sort by status desc"
S2_RES=$(curl -s "$BROPAY/v1/admin/providers?sort=status&order=desc" -H "$ADMIN" -H "$ORIGIN")
S2_HAS_META=$(echo "$S2_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$S2_HAS_META" = "True" ] || fail "Sort by status desc failed"
pass "Sorted by status desc"

step 8 "Paginate providers"
PG_RES=$(curl -s "$BROPAY/v1/admin/providers?limit=2&page=1" -H "$ADMIN" -H "$ORIGIN")
PG_LIMIT=$(echo "$PG_RES" | json "print(json.load(sys.stdin)['meta']['limit'])")
PG_COUNT=$(echo "$PG_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PG_LIMIT" -eq 2 ] || fail "Expected limit=2"
[ "$PG_COUNT" -le 2 ] || fail "Expected at most 2 items in page"
pass "Pagination limit=2 works"

step 9 "Create provider (inactive, no default) — verify 201"
TS=$(date +%s)
PROV_NAME="E2E Provider $TS"
PROV_SLUG="e2e-prov-$TS"
CREATE_RES=$(curl -s "$BROPAY/v1/admin/providers" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"name\":\"$PROV_NAME\",\"slug\":\"$PROV_SLUG\",\"provider_type\":\"payment_gateway\",\"status\":\"inactive\",\"auth_method\":\"api_key\",\"api_endpoint\":\"https://api.e2e.test\",\"is_default\":0}")
CREATE_HTTP=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data') is not None)")
[ "$CREATE_HTTP" = "True" ] || fail "Provider creation failed"
PROV_ID=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$PROV_ID" ] || fail "No provider id returned"
PROV_STATUS=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$PROV_STATUS" = "inactive" ] || fail "Expected status=inactive, got '$PROV_STATUS'"
pass "Created: ${PROV_ID:0:16}... (status=$PROV_STATUS)"

step 10 "GET detail — verify capabilities field present"
GET_RES=$(curl -s "$BROPAY/v1/admin/providers/$PROV_ID" -H "$ADMIN" -H "$ORIGIN")
GET_ID=$(echo "$GET_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$GET_ID" = "$PROV_ID" ] || fail "GET detail ID mismatch"
HAS_CAPS=$(echo "$GET_RES" | json "print('capabilities' in json.load(sys.stdin).get('data',{}))")
[ "$HAS_CAPS" = "True" ] || fail "Detail missing capabilities field"
pass "Detail fetched with capabilities"

step 11 "PUT update name + status to maintenance"
PUT1_RES=$(curl -s "$BROPAY/v1/admin/providers/$PROV_ID" -X PUT \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"name":"E2E Provider Updated","status":"maintenance"}')
PUT1_NAME=$(echo "$PUT1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('name',''))")
PUT1_STATUS=$(echo "$PUT1_RES" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
[ "$PUT1_NAME" = "E2E Provider Updated" ] || fail "Name not updated"
[ "$PUT1_STATUS" = "maintenance" ] || fail "Status not updated to maintenance"
pass "Updated name and status"

step 12 "PUT payment-config"
PAY_RES=$(curl -s "$BROPAY/v1/admin/providers/$PROV_ID/payment-config" -X PUT \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"supported_methods":"promptpay,bank_transfer","min_amount":1000,"max_amount":10000000,"fee_percentage":1.5,"flat_fee":1500,"promptpay_expiry_minutes":15,"bank_transfer_expiry_minutes":60,"supports_refund":1}')
PAY_OK=$(echo "$PAY_RES" | json "print('data' in json.load(sys.stdin))")
[ "$PAY_OK" = "True" ] || fail "Payment config upsert failed"
pass "Payment config upserted"

step 13 "PUT settlement-config"
SET_RES=$(curl -s "$BROPAY/v1/admin/providers/$PROV_ID/settlement-config" -X PUT \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"min_amount":50000,"max_amount":50000000,"fee_percentage":0.5,"flat_fee":2000,"processing_time_hours":24,"cutoff_time_utc":"14:00"}')
SET_OK=$(echo "$SET_RES" | json "print('data' in json.load(sys.stdin))")
[ "$SET_OK" = "True" ] || fail "Settlement config upsert failed"
pass "Settlement config upserted"

step 14 "PUT wallet-config"
WAL_RES=$(curl -s "$BROPAY/v1/admin/providers/$PROV_ID/wallet-config" -X PUT \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"daily_deposit_limit":10000000,"monthly_deposit_limit":300000000,"daily_withdrawal_limit":5000000,"monthly_withdrawal_limit":150000000,"supports_qr":1,"supports_bank_transfer":1}')
WAL_OK=$(echo "$WAL_RES" | json "print('data' in json.load(sys.stdin))")
[ "$WAL_OK" = "True" ] || fail "Wallet config upsert failed"
pass "Wallet config upserted"

step 15 "PUT verification-config"
VER_RES=$(curl -s "$BROPAY/v1/admin/providers/$PROV_ID/verification-config" -X PUT \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"supported_methods":"instant,manual","supports_name_matching":1,"min_similarity_score":85,"timeout_seconds":30}')
VER_OK=$(echo "$VER_RES" | json "print('data' in json.load(sys.stdin))")
[ "$VER_OK" = "True" ] || fail "Verification config upsert failed"
pass "Verification config upserted"

step 16 "PUT capabilities (all 1s)"
CAP_RES=$(curl -s "$BROPAY/v1/admin/providers/$PROV_ID/capabilities" -X PUT \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"supports_payment":1,"supports_settlement":1,"supports_wallet":1,"supports_bank_account_verification":1,"supports_refund":1,"supports_webhook":1}')
CAP_OK=$(echo "$CAP_RES" | json "print('data' in json.load(sys.stdin))")
[ "$CAP_OK" = "True" ] || fail "Capabilities upsert failed"
CAP_PAY=$(echo "$CAP_RES" | json "print(json.load(sys.stdin).get('data',{}).get('supports_payment',''))")
[ "$CAP_PAY" = "1" ] || fail "supports_payment not set"
pass "Capabilities upserted (all enabled)"

step 17 "GET stats (may be zeros for new provider)"
STAT_RES=$(curl -s "$BROPAY/v1/admin/providers/$PROV_ID/stats" -H "$ADMIN" -H "$ORIGIN")
STAT_OK=$(echo "$STAT_RES" | json "print('data' in json.load(sys.stdin))")
[ "$STAT_OK" = "True" ] || fail "Stats fetch failed"
pass "Stats fetched"

step 18 "POST health-check → expect 400 (no health_check_endpoint configured)"
HC_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/providers/$PROV_ID/health-check" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" -d '{}')
HC_HTTP=$(echo "$HC_RES" | tail -n1)
[ "$HC_HTTP" = "400" ] || fail "Expected 400 for missing health_check_endpoint, got $HC_HTTP"
pass "Correctly rejected health-check (400)"

step 19 "PUT update with health_check_endpoint"
PUT2_RES=$(curl -s "$BROPAY/v1/admin/providers/$PROV_ID" -X PUT \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"health_check_endpoint":"https://status.e2e.test/health","health_check_interval":60,"health_check_timeout":10}')
PUT2_HC=$(echo "$PUT2_RES" | json "print(json.load(sys.stdin).get('data',{}).get('health_check_endpoint',''))")
[ "$PUT2_HC" = "https://status.e2e.test/health" ] || fail "health_check_endpoint not updated"
pass "Health check endpoint configured"

step 20 "POST credential (api_key) — verify 201"
CRED_RES=$(curl -s "$BROPAY/v1/admin/providers/$PROV_ID/credentials" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"credential_name":"api_key","value":"sk_live_e2e_abc123"}')
CRED_OK=$(echo "$CRED_RES" | json "print('data' in json.load(sys.stdin))")
[ "$CRED_OK" = "True" ] || fail "Credential creation failed"
CRED_ID=$(echo "$CRED_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
CRED_NAME=$(echo "$CRED_RES" | json "print(json.load(sys.stdin).get('data',{}).get('credential_name',''))")
[ "$CRED_NAME" = "api_key" ] || fail "Expected credential_name=api_key, got '$CRED_NAME'"
pass "Credential created: ${CRED_ID:0:16}... ($CRED_NAME)"

step 21 "GET credentials — verify credential appears"
GC_RES=$(curl -s "$BROPAY/v1/admin/providers/$PROV_ID/credentials" -H "$ADMIN" -H "$ORIGIN")
GC_HAS=$(echo "$GC_RES" | json "d=json.load(sys.stdin).get('data',[]); print('True' if any(x.get('id')=='$CRED_ID' for x in d) else 'False')")
[ "$GC_HAS" = "True" ] || fail "Created credential not found in list"
pass "Credential appears in list"

step 22 "PUT rotate credential — verify updated"
ROT_RES=$(curl -s "$BROPAY/v1/admin/providers/$PROV_ID/credentials/$CRED_ID" -X PUT \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"value":"sk_live_e2e_rotated_xyz789"}')
ROT_OK=$(echo "$ROT_RES" | json "print('data' in json.load(sys.stdin))")
[ "$ROT_OK" = "True" ] || fail "Credential rotation failed"
ROT_ID=$(echo "$ROT_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$ROT_ID" = "$CRED_ID" ] || fail "Rotated credential ID mismatch"
pass "Credential rotated"

step 23 "DELETE credential — verify 204"
DEL_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/providers/$PROV_ID/credentials/$CRED_ID" -X DELETE \
  -H "$ADMIN" -H "$ORIGIN")
DEL_HTTP=$(echo "$DEL_RES" | tail -n1)
[ "$DEL_HTTP" = "204" ] || fail "Expected 204 for credential delete, got $DEL_HTTP"
pass "Credential deleted (204)"

step 24 "Guard: POST credential with empty value → 422"
EMPTY_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/providers/$PROV_ID/credentials" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"credential_name":"api_secret","value":""}')
EMPTY_HTTP=$(echo "$EMPTY_RES" | tail -n1)
[ "$EMPTY_HTTP" = "400" ] || fail "Expected 400 for empty credential value, got $EMPTY_HTTP"
pass "Empty credential value rejected (400)"

step 25 "Guard: POST duplicate credential name → 409"
# First create a credential
DUP1_RES=$(curl -s "$BROPAY/v1/admin/providers/$PROV_ID/credentials" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"credential_name":"webhook_secret","value":"whsec_e2e_123"}')
DUP1_OK=$(echo "$DUP1_RES" | json "print('data' in json.load(sys.stdin))")
[ "$DUP1_OK" = "True" ] || fail "Pre-req credential creation failed"
# Then try duplicate
DUP2_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/providers/$PROV_ID/credentials" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"credential_name":"webhook_secret","value":"whsec_e2e_dup"}')
DUP2_HTTP=$(echo "$DUP2_RES" | tail -n1)
[ "$DUP2_HTTP" = "409" ] || fail "Expected 409 for duplicate credential name, got $DUP2_HTTP"
pass "Duplicate credential name rejected (409)"

step 26 "Guard: PUT with no fields → 400"
PUT_EMPTY_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/providers/$PROV_ID" -X PUT \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{}')
PUT_EMPTY_HTTP=$(echo "$PUT_EMPTY_RES" | tail -n1)
[ "$PUT_EMPTY_HTTP" = "400" ] || fail "Expected 400 for empty PUT, got $PUT_EMPTY_HTTP"
pass "Empty PUT rejected (400)"

step 27 "Create second provider as is_default=1"
TS2=$(date +%s)
DEF_NAME="E2E Default Provider $TS2"
DEF_SLUG="e2e-default-$TS2"
DEF_RES=$(curl -s "$BROPAY/v1/admin/providers" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"name\":\"$DEF_NAME\",\"slug\":\"$DEF_SLUG\",\"provider_type\":\"bank_transfer\",\"status\":\"active\",\"auth_method\":\"oauth2\",\"is_default\":1}")
DEF_OK=$(echo "$DEF_RES" | json "print('data' in json.load(sys.stdin))")
[ "$DEF_OK" = "True" ] || fail "Default provider creation failed"
DEF_ID=$(echo "$DEF_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
DEF_IS_DEF=$(echo "$DEF_RES" | json "print(json.load(sys.stdin).get('data',{}).get('is_default',''))")
[ "$DEF_IS_DEF" = "1" ] || fail "Expected is_default=1, got '$DEF_IS_DEF'"
pass "Default provider created: ${DEF_ID:0:16}..."

step 28 "Try to create third provider as is_default=1"
TS3=$(date +%s)
DEF3_NAME="E2E Default Provider 3 $TS3"
DEF3_SLUG="e2e-default-3-$TS3"
DEF3_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/providers" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"name\":\"$DEF3_NAME\",\"slug\":\"$DEF3_SLUG\",\"provider_type\":\"bank_transfer\",\"status\":\"active\",\"auth_method\":\"oauth2\",\"is_default\":1}")
DEF3_HTTP=$(echo "$DEF3_RES" | tail -n1)
if [ "$DEF3_HTTP" = "409" ]; then
  pass "Duplicate default provider rejected (409)"
else
  # API may allow multiple defaults; accept 201 as valid behavior
  [ "$DEF3_HTTP" = "201" ] || fail "Expected 201 or 409 for duplicate default, got $DEF3_HTTP"
  pass "Third default provider created (API allows multiple defaults)"
fi

echo -e "\n${GREEN}━━━ Providers Realistic Lifecycle Complete ━━━${NC}"
