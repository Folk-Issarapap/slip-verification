#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Merchant API Keys (Realistic Lifecycle)
#
# Usage:
#   BROPAY_URL=http://localhost:8787 bash scripts/e2e/admin/merchant-api-keys.sh
#
# Required env: BROPAY_URL (default http://localhost:8787)
# External deps: none (local API + seeded staff via _bootstrap.sh)
#
# Endpoints:
#   GET    /v1/admin/merchant-api-keys?merchant_id=...  (required query)
#   POST   /v1/admin/merchant-api-keys
#   DELETE /v1/admin/merchant-api-keys/{id}
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

echo -e "${CYAN}━━━ Admin E2E — Merchant API Keys (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
pass "Admin token acquired (super_admin)"

TS=$(date +%s)
KEY_NAME="E2E Admin Key $TS"

step 2 "List merchant-scoped API keys (may be empty)"
LIST_RES=$(curl -s "$BROPAY/v1/admin/merchant-api-keys?merchant_id=$DEMO_MERCHANT_ID" \
  -H "$ADMIN" -H "$ORIGIN")
HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$HAS_META" = "True" ] || fail "Key list missing meta"
LIST_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
pass "Listed ${LIST_TOTAL} key(s) for demo merchant"

step 3 "Create merchant-scoped API key"
CREATE_RES=$(curl -s "$BROPAY/v1/admin/merchant-api-keys" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"merchant_id\":\"$DEMO_MERCHANT_ID\",\"name\":\"$KEY_NAME\"}")
KEY_ID=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
PLAINTEXT=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('plaintext',''))")
KEY_HINT=$(echo "$CREATE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('key_hint',''))")
[ -n "$KEY_ID" ] || fail "Key creation failed: $CREATE_RES"
[[ "$PLAINTEXT" == sk_* ]] || fail "Expected sk_* plaintext prefix, got '${PLAINTEXT:0:8}...'"
[ -n "$KEY_HINT" ] || fail "Key hint missing on create"
pass "Created key: ${KEY_ID:0:16}... (hint=...$KEY_HINT)"

step 4 "List active keys and filter by name search"
ACTIVE_RES=$(curl -s "$BROPAY/v1/admin/merchant-api-keys?merchant_id=$DEMO_MERCHANT_ID&state=active" \
  -H "$ADMIN" -H "$ORIGIN")
ACTIVE_TOTAL=$(echo "$ACTIVE_RES" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
[ "${ACTIVE_TOTAL:-0}" -ge 1 ] || fail "Expected at least 1 active key"
SEARCH_RES=$(curl -s "$BROPAY/v1/admin/merchant-api-keys?merchant_id=$DEMO_MERCHANT_ID&q=E2E%20Admin%20Key" \
  -H "$ADMIN" -H "$ORIGIN")
SEARCH_TOTAL=$(echo "$SEARCH_RES" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
[ "${SEARCH_TOTAL:-0}" -ge 1 ] || fail "Expected at least 1 key matching name search"
pass "Active=$ACTIVE_TOTAL search=$SEARCH_TOTAL"

step 5 "Revoke API key"
REVOKE_RES=$(curl -s "$BROPAY/v1/admin/merchant-api-keys/$KEY_ID" -X DELETE \
  -H "$ADMIN" -H "$ORIGIN")
REVOKED=$(echo "$REVOKE_RES" | json "print(json.load(sys.stdin).get('data',{}).get('revoked',''))")
[ "$REVOKED" = "True" ] || fail "Revoke failed: $REVOKE_RES"
pass "Key revoked"

step 6 "List revoked keys includes the revoked key"
REVOKED_RES=$(curl -s "$BROPAY/v1/admin/merchant-api-keys?merchant_id=$DEMO_MERCHANT_ID&state=revoked" \
  -H "$ADMIN" -H "$ORIGIN")
REVOKED_TOTAL=$(echo "$REVOKED_RES" | json "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
[ "${REVOKED_TOTAL:-0}" -ge 1 ] || fail "Expected at least 1 revoked key"
pass "$REVOKED_TOTAL revoked key(s)"

step 7 "Negative: create key for unknown merchant → 404"
FAKE_MERCH="00000000-0000-4000-8000-000000000099"
NEG_CREATE=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/merchant-api-keys" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d "{\"merchant_id\":\"$FAKE_MERCH\",\"name\":\"Should Fail\"}")
NEG_HTTP=$(echo "$NEG_CREATE" | tail -n1 | tr -d '\r')
[ "$NEG_HTTP" = "404" ] || fail "Expected 404 for unknown merchant, got $NEG_HTTP"
pass "Unknown merchant create returned 404"

step 8 "Negative: revoke unknown key → 404"
NEG_REVOKE=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/admin/merchant-api-keys/00000000-0000-4000-8000-000000000098" -X DELETE \
  -H "$ADMIN" -H "$ORIGIN")
NEG_REV_HTTP=$(echo "$NEG_REVOKE" | tail -n1 | tr -d '\r')
[ "$NEG_REV_HTTP" = "404" ] || fail "Expected 404 for unknown key, got $NEG_REV_HTTP"
pass "Unknown key revoke returned 404"

echo -e "\n${GREEN}━━━ Merchant API Keys Realistic Lifecycle Complete ━━━${NC}"
