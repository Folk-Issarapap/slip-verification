#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E Admin — Audit Logs (Realistic Lifecycle)
#
# Endpoints:
#   GET /v1/admin/audit-logs
#   GET /v1/admin/audit-logs/{id}
#   GET /v1/merchant/audit-logs
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

echo -e "${CYAN}━━━ Admin E2E — Audit Logs (Realistic Lifecycle) ━━━${NC}"

step 1 "Bootstrap demo merchant"
source "$SCRIPT_DIR/../_bootstrap.sh"
bootstrap_demo_merchant
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
OWNER="Authorization: Bearer $DEMO_OWNER_TOKEN"
MERCH="X-Merchant-Id: $DEMO_MERCHANT_ID"
pass "Admin token acquired (super_admin)"

step 2 "Perform mutating actions to generate real audit logs"
# Update merchant limits → audit log with action=update, resource_type=Merchant
UPDATE_RES=$(curl -s "$BROPAY/v1/admin/merchants/$DEMO_MERCHANT_ID" -X PUT \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"daily_transaction_limit":55000000}')
UPDATE_OK=$(echo "$UPDATE_RES" | json "print('data' in json.load(sys.stdin))")
[ "$UPDATE_OK" = "True" ] || warn "Merchant update failed (no audit log expected)"

# Create integration → audit log with action=create, resource_type=Integration
TS=$(date +%s)
INTEG_RES=$(curl -s "$BROPAY/v1/merchant/integrations" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"name\":\"Audit E2E Integration $TS\",\"slug\":\"audit-e2e-$TS\"}")
INTEG_OK=$(echo "$INTEG_RES" | json "print('data' in json.load(sys.stdin))")
[ "$INTEG_OK" = "True" ] || warn "Integration create failed (no audit log expected)"

# Adjust wallet → audit log with action=create, resource_type=Wallet
ADJUST_RES=$(curl -s "$BROPAY/v1/admin/wallets/$DEMO_WALLET_ID/adjust" -X POST \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"type":"credit","amount":1000,"reason":"e2e_audit","description":"Small credit for audit log generation"}')
ADJUST_OK=$(echo "$ADJUST_RES" | json "print('data' in json.load(sys.stdin))")
[ "$ADJUST_OK" = "True" ] || warn "Wallet adjust failed (no audit log expected)"
pass "Mutating actions performed"

step 3 "Seed diverse audit logs via DB for edge cases"
AL_SYSTEM=$(python3 -c "import uuid; print(uuid.uuid4())")
AL_API=$(python3 -c "import uuid; print(uuid.uuid4())")
AL_DELETE=$(python3 -c "import uuid; print(uuid.uuid4())")

pushd "$REPO_ROOT/apps/api" > /dev/null
# Single-line SQL: multiline --command breaks on Windows/Git Bash (SQLITE incomplete input).
if ! wrangler d1 execute bropay-db --local --command "INSERT INTO audit_logs (id, actor_type, actor_id, action, resource_type, resource_id, merchant_id, status, description, diff, created_at) VALUES ('$AL_SYSTEM', 'system', 'settlement-worker', 'delete', 'Settlement', 'settle-system-001', '$DEMO_MERCHANT_ID', 'success', 'Auto-cleanup of stale settlement', NULL, datetime('now', '-2 hours')), ('$AL_API', 'api', 'hmac:demo-key', 'create', 'PaymentIntent', 'pi-api-001', '$DEMO_MERCHANT_ID', 'failure', 'API payment intent creation failed', NULL, datetime('now', '-1 hour')), ('$AL_DELETE', 'user', 'acct-admin-001', 'delete', 'WebhookEndpoint', 'wh-del-001', '$DEMO_MERCHANT_ID', 'success', 'Deleted inactive webhook endpoint', '{\"deleted\":true}', datetime('now', '-30 minutes'));" --json 2>/dev/null | grep -q '"success": true'; then
  popd > /dev/null
  fail "wrangler seed audit_logs failed"
fi
popd > /dev/null
pass "3 edge-case audit logs seeded"

step 4 "Admin lists all audit logs"
LIST_RES=$(curl -s "$BROPAY/v1/admin/audit-logs" -H "$ADMIN" -H "$ORIGIN")
LIST_HAS_META=$(echo "$LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$LIST_HAS_META" = "True" ] || fail "List missing meta"
LIST_TOTAL=$(echo "$LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$LIST_TOTAL" -ge 3 ] || fail "Expected at least 3 audit logs, got $LIST_TOTAL"
pass "Listed $LIST_TOTAL audit log(s)"

step 5 "Admin filters by action=update"
ACT_UPD_RES=$(curl -s "$BROPAY/v1/admin/audit-logs?action=update" -H "$ADMIN" -H "$ORIGIN")
ACT_UPD_TOTAL=$(echo "$ACT_UPD_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$ACT_UPD_TOTAL" -ge 1 ] || fail "Expected at least 1 update audit log, got $ACT_UPD_TOTAL"
pass "$ACT_UPD_TOTAL update audit log(s)"

step 6 "Admin filters by action=create,delete"
ACT_CD_RES=$(curl -s "$BROPAY/v1/admin/audit-logs?action=create,delete" -H "$ADMIN" -H "$ORIGIN")
ACT_CD_TOTAL=$(echo "$ACT_CD_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$ACT_CD_TOTAL" -ge 2 ] || fail "Expected at least 2 create/delete audit logs, got $ACT_CD_TOTAL"
pass "$ACT_CD_TOTAL create/delete audit log(s)"

step 7 "Admin filters by resource_type=merchant"
RT_MERCH_RES=$(curl -s "$BROPAY/v1/admin/audit-logs?resource_type=merchant" -H "$ADMIN" -H "$ORIGIN")
RT_MERCH_TOTAL=$(echo "$RT_MERCH_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$RT_MERCH_TOTAL" -ge 1 ] || fail "Expected at least 1 merchant audit log, got $RT_MERCH_TOTAL"
pass "$RT_MERCH_TOTAL merchant audit log(s)"

step 8 "Admin filters by resource_type=wallet,integration"
RT_WI_RES=$(curl -s "$BROPAY/v1/admin/audit-logs?resource_type=wallet,integration" -H "$ADMIN" -H "$ORIGIN")
RT_WI_TOTAL=$(echo "$RT_WI_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$RT_WI_TOTAL" -ge 2 ] || fail "Expected at least 2 wallet/integration audit logs, got $RT_WI_TOTAL"
pass "$RT_WI_TOTAL wallet/integration audit log(s)"

step 9 "Admin filters by actor_type=user"
AT_USER_RES=$(curl -s "$BROPAY/v1/admin/audit-logs?actor_type=user" -H "$ADMIN" -H "$ORIGIN")
AT_USER_TOTAL=$(echo "$AT_USER_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$AT_USER_TOTAL" -ge 1 ] || fail "Expected at least 1 user actor audit log, got $AT_USER_TOTAL"
pass "$AT_USER_TOTAL user actor audit log(s)"

step 10 "Admin filters by actor_type=system,api"
AT_SA_RES=$(curl -s "$BROPAY/v1/admin/audit-logs?actor_type=system,api" -H "$ADMIN" -H "$ORIGIN")
AT_SA_TOTAL=$(echo "$AT_SA_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$AT_SA_TOTAL" -ge 2 ] || fail "Expected at least 2 system/api audit logs, got $AT_SA_TOTAL"
pass "$AT_SA_TOTAL system/api audit log(s)"

step 11 "Admin filters by merchant_id"
MERCH_RES=$(curl -s "$BROPAY/v1/admin/audit-logs?merchant_id=$DEMO_MERCHANT_ID" -H "$ADMIN" -H "$ORIGIN")
MERCH_TOTAL=$(echo "$MERCH_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$MERCH_TOTAL" -ge 3 ] || fail "Expected at least 3 audit logs for merchant, got $MERCH_TOTAL"
pass "$MERCH_TOTAL audit log(s) for merchant"

step 12 "Admin filters by status=success"
STAT_OK_RES=$(curl -s "$BROPAY/v1/admin/audit-logs?status=success" -H "$ADMIN" -H "$ORIGIN")
STAT_OK_TOTAL=$(echo "$STAT_OK_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$STAT_OK_TOTAL" -ge 2 ] || fail "Expected at least 2 success audit logs, got $STAT_OK_TOTAL"
pass "$STAT_OK_TOTAL success audit log(s)"

step 13 "Admin filters by status=failure"
STAT_FAIL_RES=$(curl -s "$BROPAY/v1/admin/audit-logs?status=failure" -H "$ADMIN" -H "$ORIGIN")
STAT_FAIL_TOTAL=$(echo "$STAT_FAIL_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$STAT_FAIL_TOTAL" -ge 1 ] || fail "Expected at least 1 failure audit log, got $STAT_FAIL_TOTAL"
pass "$STAT_FAIL_TOTAL failure audit log(s)"

step 14 "Admin filters by date range"
# Cross-platform date helpers (GNU vs BSD date)
if date -d "yesterday" +%Y-%m-%d >/dev/null 2>&1; then
  YESTERDAY=$(date -d "yesterday" +%Y-%m-%d)
  TOMORROW=$(date -d "tomorrow" +%Y-%m-%d)
else
  YESTERDAY=$(date -v-1d +%Y-%m-%d)
  TOMORROW=$(date -v+1d +%Y-%m-%d)
fi
DATE_FROM="$YESTERDAY"
DATE_TO="$TOMORROW"
DATE_RES=$(curl -s "$BROPAY/v1/admin/audit-logs?date_from=$DATE_FROM&date_to=$DATE_TO" -H "$ADMIN" -H "$ORIGIN")
DATE_TOTAL=$(echo "$DATE_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$DATE_TOTAL" -ge 3 ] || fail "Expected at least 3 audit logs in range, got $DATE_TOTAL"
pass "$DATE_TOTAL audit log(s) in date range"

step 15 "Admin searches by q (resource_type)"
SEARCH_RES=$(curl -s "$BROPAY/v1/admin/audit-logs?q=Settlement" -H "$ADMIN" -H "$ORIGIN")
SEARCH_TOTAL=$(echo "$SEARCH_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$SEARCH_TOTAL" -ge 1 ] || fail "Expected at least 1 result for 'Settlement'"
pass "$SEARCH_TOTAL result(s) for 'Settlement'"

step 16 "Admin searches by q (actor_id)"
SEARCH_ACT_RES=$(curl -s "$BROPAY/v1/admin/audit-logs?q=settlement-worker" -H "$ADMIN" -H "$ORIGIN")
SEARCH_ACT_TOTAL=$(echo "$SEARCH_ACT_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$SEARCH_ACT_TOTAL" -ge 1 ] || fail "Expected at least 1 result for actor search"
pass "$SEARCH_ACT_TOTAL result(s) for actor search"

step 17 "Admin sorts by action"
SORT_ACT_RES=$(curl -s "$BROPAY/v1/admin/audit-logs?sort=action&order=asc" -H "$ADMIN" -H "$ORIGIN")
SORT_ACT_HAS_META=$(echo "$SORT_ACT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_ACT_HAS_META" = "True" ] || fail "Sort by action failed"
pass "Sorted by action asc"

step 18 "Admin sorts by actor_type"
SORT_AT_RES=$(curl -s "$BROPAY/v1/admin/audit-logs?sort=actor_type&order=desc" -H "$ADMIN" -H "$ORIGIN")
SORT_AT_HAS_META=$(echo "$SORT_AT_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$SORT_AT_HAS_META" = "True" ] || fail "Sort by actor_type failed"
pass "Sorted by actor_type desc"

step 19 "Admin gets audit log detail"
DETAIL_RES=$(curl -s "$BROPAY/v1/admin/audit-logs/$AL_DELETE" -H "$ADMIN" -H "$ORIGIN")
DETAIL_ID=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ "$DETAIL_ID" = "$AL_DELETE" ] || fail "Detail ID mismatch"
DETAIL_ACTOR=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('actor_type',''))")
[ "$DETAIL_ACTOR" = "user" ] || fail "Expected actor_type=user, got '$DETAIL_ACTOR'"
DETAIL_ACTION=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('action',''))")
[ "$DETAIL_ACTION" = "delete" ] || fail "Expected action=delete, got '$DETAIL_ACTION'"
pass "Detail fetched (actor=$DETAIL_ACTOR, action=$DETAIL_ACTION)"

step 20 "Admin verifies detail has diff field"
DETAIL_DIFF=$(echo "$DETAIL_RES" | json "print(json.load(sys.stdin).get('data',{}).get('diff',''))")
[ -n "$DETAIL_DIFF" ] || fail "Expected diff field to be present"
pass "Detail has diff field"

step 21 "Admin paginates audit logs"
PAGE_RES=$(curl -s "$BROPAY/v1/admin/audit-logs?limit=5&page=1" -H "$ADMIN" -H "$ORIGIN")
PAGE_LIMIT=$(echo "$PAGE_RES" | json "print(json.load(sys.stdin)['meta']['limit'])")
PAGE_COUNT=$(echo "$PAGE_RES" | json "print(len(json.load(sys.stdin).get('data',[])))")
[ "$PAGE_LIMIT" -eq 5 ] || fail "Expected limit=5"
[ "$PAGE_COUNT" -eq 5 ] || fail "Expected 5 items in page"
pass "Pagination limit=5 works"

step 22 "Merchant views scoped audit logs"
MERCH_LIST_RES=$(curl -s "$BROPAY/v1/merchant/audit-logs" -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
MERCH_LIST_HAS_META=$(echo "$MERCH_LIST_RES" | json "print('meta' in json.load(sys.stdin))")
[ "$MERCH_LIST_HAS_META" = "True" ] || fail "Merchant audit log list missing meta"
MERCH_LIST_TOTAL=$(echo "$MERCH_LIST_RES" | json "print(json.load(sys.stdin)['meta']['total'])")
[ "$MERCH_LIST_TOTAL" -ge 3 ] || fail "Expected at least 3 merchant-scoped audit logs, got $MERCH_LIST_TOTAL"
pass "$MERCH_LIST_TOTAL merchant-scoped audit log(s)"

echo -e "\n${GREEN}━━━ Audit Logs Realistic Lifecycle Complete ━━━${NC}"
