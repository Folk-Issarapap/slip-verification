#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────────────
# E2E KYC — Bank account verification state machine + gating
#
# Provider webhooks: kyc.verified / kyc.failed (signed Standard Webhooks).
# in_progress / cancelled / expired: no KBNK webhook — mirrored via local D1
# (same terminal fields sync would write; see admin bank-account-verifications sync).
#
# Usage:
#   bash scripts/e2e/e2e-kyc-verification-flow.sh
#
# Prerequisites: pnpm db:seed, pnpm dev:api, apps/api/.dev.vars ENCRYPTION_KEY
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=_lib.sh
source "$SCRIPT_DIR/_lib.sh"
# shellcheck source=_merchant-lib.sh
source "$SCRIPT_DIR/_merchant-lib.sh"
# shellcheck source=_withdrawal-lib.sh
source "$SCRIPT_DIR/_withdrawal-lib.sh"

REPO_ROOT="$_E2E_REPO_ROOT"
BROPAY="${BROPAY_URL:-http://localhost:8787}"
ORIGIN="Origin: http://localhost:3000"
CT="Content-Type: application/json"

echo -e "${CYAN}━━━ BroPay E2E KYC verification ━━━${NC}"

step 1 "Bootstrap demo merchant"
# shellcheck source=_bootstrap.sh
source "$SCRIPT_DIR/_bootstrap.sh"
bootstrap_demo_merchant
merchant_auth_headers
ADMIN="Authorization: Bearer $DEMO_ADMIN_TOKEN"
pass "Merchant: ${DEMO_MERCHANT_ID:0:16}..."

# ── Helpers ───────────────────────────────────────────────────────────────────

# Clear stale provider_credentials then re-encrypt with current ENCRYPTION_KEY.
reset_kbnk_webhook_credentials() {
  e2e_d1_local_sql \
    "DELETE FROM provider_credentials WHERE provider_id = 'prov-kbnk-000000-0000-000000000001'"
  # Unset Cursor/npm env noise (verify-deps-before-run) before pnpm exec npx tsx in seed_kbnk_credentials.
  unset npm_config_verify_deps_before_run NPM_CONFIG_VERIFY_DEPS_BEFORE_RUN 2>/dev/null || true
  seed_kbnk_credentials
  e2e_d1_local_sql \
    "UPDATE providers SET status = 'active', api_endpoint = 'https://api.kbnk.test', token_endpoint = 'https://api.kbnk.test/auth/token' WHERE slug = 'kbnk'"
}

create_merchant_bank_account() {
  local suffix=$1
  http_post "$BROPAY/v1/merchant/bank-accounts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
    -d "{\"bank_id\":\"bank-kbank-0000-0000-000000000001\",\"account_number\":\"${suffix}\",\"account_holder_name\":\"KYC E2E ${suffix}\",\"account_type\":\"savings\"}"
  [ "$HTTP_CODE" = "201" ] || fail "Bank account create failed ($HTTP_CODE): $HTTP_BODY"
  echo "$HTTP_BODY" | json "print(json.load(sys.stdin)['data']['id'])"
}

verification_for_ba() {
  local ba_id=$1
  e2e_d1_local_scalar \
    "SELECT id FROM bank_account_verifications WHERE merchant_bank_account_id = '$ba_id' ORDER BY created_at DESC LIMIT 1"
}

# Lock provider_verification_id immediately before the webhook (avoids async write-back races).
bind_provider_verification_id() {
  local ver_id=$1
  local prov="prov-ver-kyc-$(python3 -c 'import uuid; print(uuid.uuid4())')"
  e2e_d1_local_sql \
    "UPDATE bank_account_verifications SET provider_verification_id = '$prov', updated_at = datetime('now') WHERE id = '$ver_id'"
  echo "$prov"
}

admin_verification_status() {
  local ver_id=$1
  http_get "$BROPAY/v1/admin/bank-account-verifications/$ver_id" -H "$ADMIN" -H "$ORIGIN"
  [ "$HTTP_CODE" = "200" ] || fail "Admin GET verification expected 200, got $HTTP_CODE"
  echo "$HTTP_BODY" | json "print(json.load(sys.stdin)['data']['status'])"
}

reflect_verification_state() {
  local ver_id=$1 ba_id=$2 ver_status=$3 ba_ver_status=$4
  local completed_sql="NULL"
  if [ "$ver_status" = "verified" ] || [ "$ver_status" = "failed" ] || [ "$ver_status" = "cancelled" ] || [ "$ver_status" = "expired" ]; then
    completed_sql="datetime('now')"
  fi
  e2e_d1_local_sql \
    "UPDATE bank_account_verifications SET status = '$ver_status', completed_at = $completed_sql, updated_at = datetime('now') WHERE id = '$ver_id'"
  local active_clause="status = 'pending'"
  if [ "$ba_ver_status" = "verified" ]; then
    active_clause="status = 'active'"
  fi
  e2e_d1_local_sql \
    "UPDATE merchant_bank_accounts SET verification_status = '$ba_ver_status', $active_clause, updated_at = datetime('now') WHERE id = '$ba_id'"
}

post_kyc_webhook() {
  local event=$1 prov_id=$2
  local data_json
  data_json=$(printf '{"verificationId":"%s","similarityScore":97}' "$prov_id")
  post_kbnk_webhook_payload "$event" "$data_json"
  [ "$HTTP_CODE" = "200" ] || fail "KBNK $event webhook expected 200, got $HTTP_CODE — $HTTP_BODY"
}

# Bind provider id, POST webhook, assert via merchant API (source of truth for wrangler dev).
post_kyc_webhook_expect() {
  local ver_id=$1 ba_id=$2 event=$3 expected_vs=$4 expected_acct_status=$5
  local prov attempt vs st admin_st

  prov=$(bind_provider_verification_id "$ver_id")
  post_kyc_webhook "$event" "$prov"

  for attempt in 1 2 3 4 5 6 7 8 9 10; do
    http_get "$BROPAY/v1/merchant/bank-accounts/$ba_id" -H "$OWNER" -H "$MERCH" -H "$ORIGIN"
    [ "$HTTP_CODE" = "200" ] || fail "GET bank account expected 200, got $HTTP_CODE"
    vs=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin)['data']['verification_status'])")
    st=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin)['data']['status'])")
    if [ "$vs" = "$expected_vs" ] && [ "$st" = "$expected_acct_status" ]; then
      admin_st=$(admin_verification_status "$ver_id")
      [ "$admin_st" = "$expected_vs" ] || fail "admin verification status: expected $expected_vs, got $admin_st"
      return 0
    fi
    sleep 0.5
  done

  admin_st="unknown"
  http_get "$BROPAY/v1/admin/bank-account-verifications/$ver_id" -H "$ADMIN" -H "$ORIGIN" || true
  if [ "${HTTP_CODE:-}" = "200" ]; then
    admin_st=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin)['data']['status'])")
  fi
  fail "KYC $event did not update bank account (merchant vs=$vs status=$st, admin ver=$admin_st, provider_id=$prov). Check API logs for [kbnk/webhook] signature validation failed; confirm apps/api/.dev.vars ENCRYPTION_KEY matches pnpm dev:api."
}

# Read ENCRYPTION_KEY with grep (Git Bash /d/... paths break Windows Python pathlib).
load_kbnk_webhook_env() {
  local dev_vars="${REPO_ROOT}/apps/api/.dev.vars"
  if [ -f "$dev_vars" ]; then
    ENCRYPTION_KEY="$(grep -E '^ENCRYPTION_KEY=' "$dev_vars" | head -1 | cut -d= -f2- | tr -d '\r')"
    export ENCRYPTION_KEY
    if [ -z "${ENCRYPTION_KEY:-}" ] || [ "${#ENCRYPTION_KEY}" -lt 32 ]; then
      fail "ENCRYPTION_KEY missing or too short in $dev_vars (need 32+ chars for webhook credential seed)"
    fi
  else
    warn "apps/api/.dev.vars not found — seed_kbnk_credentials will read ENCRYPTION_KEY from apps/api when run"
  fi
  export KBNK_WEBHOOK_SECRET="${KBNK_WEBHOOK_SECRET:-test-webhook-secret-32-chars-long!!}"
}

assert_merchant_ba() {
  local ba_id=$1 expected_vs=$2 expected_status=$3
  http_get "$BROPAY/v1/merchant/bank-accounts/$ba_id" -H "$OWNER" -H "$MERCH" -H "$ORIGIN"
  [ "$HTTP_CODE" = "200" ] || fail "GET bank account expected 200, got $HTTP_CODE"
  local vs st
  vs=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin)['data']['verification_status'])")
  st=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin)['data']['status'])")
  [ "$vs" = "$expected_vs" ] || fail "verification_status: expected $expected_vs, got $vs"
  [ "$st" = "$expected_status" ] || fail "status: expected $expected_status, got $st"
}

assert_verification_status() {
  local ver_id=$1 expected=$2
  local got
  got=$(e2e_d1_local_scalar "SELECT status FROM bank_account_verifications WHERE id = '$ver_id'")
  [ "$got" = "$expected" ] || fail "verification row: expected status $expected, got $got"
}

step 1b "Seed KBNK webhook credentials"
load_kbnk_webhook_env
reset_kbnk_webhook_credentials
pass "KBNK credentials ready"

# ── Path A: pending → in_progress → verified (kyc.verified) ─────────────────

step 2 "Create bank account (pending)"
SUFFIX_A="$(python3 -c 'import time; print(int(time.time()))')1111"
BA_VERIFIED=$(create_merchant_bank_account "$SUFFIX_A")
assert_merchant_ba "$BA_VERIFIED" "pending" "pending"
VER_A=$(verification_for_ba "$BA_VERIFIED")
[ -n "$VER_A" ] || fail "Missing verification row for verified path"
assert_verification_status "$VER_A" "pending"
pass "Bank account + verification pending"

step 3 "Provider processing → in_progress"
reflect_verification_state "$VER_A" "$BA_VERIFIED" "in_progress" "in_progress"
assert_verification_status "$VER_A" "in_progress"
assert_merchant_ba "$BA_VERIFIED" "in_progress" "pending"
pass "Verification in_progress"

step 4 "kyc.verified webhook"
post_kyc_webhook_expect "$VER_A" "$BA_VERIFIED" "kyc.verified" "verified" "active"
pass "kyc.verified → account active"

# ── Path B: failed (kyc.failed) ───────────────────────────────────────────────

step 5 "Create bank account for failed path"
SUFFIX_B="$(python3 -c 'import time; print(int(time.time()))')2222"
BA_FAILED=$(create_merchant_bank_account "$SUFFIX_B")
VER_B=$(verification_for_ba "$BA_FAILED")
reflect_verification_state "$VER_B" "$BA_FAILED" "in_progress" "in_progress"
post_kyc_webhook_expect "$VER_B" "$BA_FAILED" "kyc.failed" "failed" "pending"
pass "kyc.failed → account stays inactive"

# ── Path C: cancelled ─────────────────────────────────────────────────────────

step 6 "Create bank account for cancelled terminal state"
SUFFIX_C="$(python3 -c 'import time; print(int(time.time()))')3333"
BA_CANCEL=$(create_merchant_bank_account "$SUFFIX_C")
VER_C=$(verification_for_ba "$BA_CANCEL")
reflect_verification_state "$VER_C" "$BA_CANCEL" "cancelled" "cancelled"
assert_verification_status "$VER_C" "cancelled"
assert_merchant_ba "$BA_CANCEL" "cancelled" "pending"
pass "cancelled terminal state reflected"

# ── Path D: expired ───────────────────────────────────────────────────────────

step 7 "Create bank account for expired terminal state"
SUFFIX_D="$(python3 -c 'import time; print(int(time.time()))')4444"
BA_EXPIRED=$(create_merchant_bank_account "$SUFFIX_D")
VER_D=$(verification_for_ba "$BA_EXPIRED")
reflect_verification_state "$VER_D" "$BA_EXPIRED" "expired" "expired"
assert_verification_status "$VER_D" "expired"
assert_merchant_ba "$BA_EXPIRED" "expired" "pending"
pass "expired terminal state reflected"

# ── Reverify + override (failed → pending → verified) ───────────────────────────

step 8 "Reverify after failed"
http_post "$BROPAY/v1/admin/bank-account-verifications/$VER_B/reverify" \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT"
  if [ "$HTTP_CODE" = "200" ]; then
    REV_STATUS=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin)['data']['status'])")
    [ "$REV_STATUS" = "pending" ] || fail "Reverify expected pending status, got $REV_STATUS"
    pass "POST /reverify returned pending"
  elif [ "$HTTP_CODE" = "502" ] || [ "$HTTP_CODE" = "503" ]; then
    PROV_B2="prov-ver-e2e-rev-$(python3 -c 'import uuid; print(uuid.uuid4())')"
    e2e_d1_local_sql \
      "UPDATE bank_account_verifications SET status = 'pending', provider_verification_id = '$PROV_B2', manually_overridden = 0, override_reason = NULL, overridden_by = NULL, overridden_at = NULL, completed_at = NULL, updated_at = datetime('now') WHERE id = '$VER_B'"
    e2e_d1_local_sql \
      "UPDATE merchant_bank_accounts SET verification_status = 'pending', status = 'pending', updated_at = datetime('now') WHERE id = '$BA_FAILED'"
    assert_verification_status "$VER_B" "pending"
    pass "Reverify pending (local provider offline — mirrored via D1)"
  else
    fail "Reverify unexpected HTTP $HTTP_CODE — $HTTP_BODY"
  fi

step 9 "Admin override pending → verified"
http_post "$BROPAY/v1/admin/bank-account-verifications/$VER_B/override" \
  -H "$ADMIN" -H "$ORIGIN" -H "$CT" \
  -d '{"status":"verified","override_reason":"Manual review after provider failure"}'
[ "$HTTP_CODE" = "200" ] || fail "Override expected 200, got $HTTP_CODE — $HTTP_BODY"
OV_STATUS=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin)['data']['status'])")
[ "$OV_STATUS" = "verified" ] || fail "Override status expected verified, got $OV_STATUS"
assert_merchant_ba "$BA_FAILED" "verified" "active"
http_post "$BROPAY/v1/merchant/bank-accounts/$BA_FAILED/set-default" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{"designation":"for_settlement"}'
[ "$HTTP_CODE" = "200" ] || fail "Set for_settlement after override failed ($HTTP_CODE)"
pass "Override → verified; account usable for settlement"

# ── Gating: unverified accounts blocked ───────────────────────────────────────

step 10 "Gating: unverified merchant BA cannot be for_settlement"
http_post "$BROPAY/v1/merchant/bank-accounts/$BA_CANCEL/set-default" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{"designation":"for_settlement"}'
[ "$HTTP_CODE" = "400" ] || fail "Expected 400 for unverified for_settlement, got $HTTP_CODE"
GATE_CODE=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin).get('error',{}).get('code',''))")
[ "$GATE_CODE" = "BANK_ACCOUNT_NOT_VERIFIED" ] || fail "Expected BANK_ACCOUNT_NOT_VERIFIED, got $GATE_CODE"
pass "for_settlement blocked on cancelled account"

step 11 "Gating: payout to unverified customer bank account"
CUST_RES=$(curl -s "$BROPAY/v1/merchant/customers" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d '{"first_name":"KYC","last_name":"Gate","email":"kyc-gate-'$(python3 -c 'import uuid; print(uuid.uuid4())')'@test.local"}')
CUST_ID=$(echo "$CUST_RES" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
[ -n "$CUST_ID" ] || fail "Customer create failed"

CBA_RES=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/customer-bank-accounts" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"customer_id\":\"$CUST_ID\",\"bank_id\":\"bank-kbank-0000-0000-000000000001\",\"account_number\":\"8888999900\",\"account_holder_name\":\"KYC Customer\"}")
CBA_HTTP=$(echo "$CBA_RES" | tail -n1)
CBA_BODY=$(echo "$CBA_RES" | sed '$d')
[ "$CBA_HTTP" = "201" ] || fail "CBA create failed ($CBA_HTTP)"
CBA_ID=$(echo "$CBA_BODY" | json "print(json.load(sys.stdin)['data']['id'])")

http_post "$BROPAY/v1/merchant/payouts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"amount\":10000,\"customer_bank_account_id\":\"$CBA_ID\",\"description\":\"KYC gate test\"}"
[ "$HTTP_CODE" = "400" ] || fail "Expected 400 payout to unverified CBA, got $HTTP_CODE"
PAYOUT_GATE=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin).get('error',{}).get('code',''))")
[ "$PAYOUT_GATE" = "BANK_ACCOUNT_NOT_VERIFIED" ] || fail "Expected BANK_ACCOUNT_NOT_VERIFIED on payout, got $PAYOUT_GATE"
pass "Payout blocked for unverified customer bank account"

echo -e "\n${GREEN}━━━ KYC verification E2E complete ━━━${NC}"
