#!/bin/bash
# Withdrawal / KBNK payout-webhook E2E helpers.
# Usage (after _lib.sh + _merchant-lib.sh):
#   source "$SCRIPT_DIR/_withdrawal-lib.sh"
#
# Requires: BROPAY, ORIGIN, CT, OWNER, MERCH (set by caller after bootstrap).

# Must match seedKbnkProvider default in apps/api integration helpers.
KBNK_WEBHOOK_SECRET="${KBNK_WEBHOOK_SECRET:-test-webhook-secret-32-chars-long!!}"

# Baseline reserved_balance after preflight (set by preflight_withdrawal_wallet).
RESERVED_BASELINE=0

http_get() {
  local url=$1
  shift
  local raw
  raw=$(curl -s -w "\n%{http_code}" "$url" "$@")
  HTTP_CODE=$(echo "$raw" | tail -1)
  HTTP_BODY=$(echo "$raw" | sed '$d')
}

http_post() {
  local url=$1
  shift
  local raw
  raw=$(curl -s -w "\n%{http_code}" "$url" -X POST "$@")
  HTTP_CODE=$(echo "$raw" | tail -1)
  HTTP_BODY=$(echo "$raw" | sed '$d')
}

merchant_wallet_field() {
  local field=$1
  http_get "$BROPAY/v1/merchant/wallets" -H "$OWNER" -H "$MERCH" -H "$ORIGIN"
  echo "$HTTP_BODY" | python3 -c "
import json, sys
field = sys.argv[1]
d = json.load(sys.stdin)
w = d['data'][0] if isinstance(d.get('data'), list) else d.get('data', {})
print(int(w.get(field, 0)))
" "$field"
}

e2e_d1_local_scalar() {
  local sql=$1
  local api_dir out label wr
  label="e2e_d1_local_scalar"
  api_dir="${_E2E_REPO_ROOT}/apps/api"
  _e2e_wrangler_bin
  if [ -n "$_E2E_WR_BIN" ]; then
    # shellcheck disable=SC2086
    out=$(cd "$api_dir" && "$_E2E_WR_BIN" d1 execute bropay-db --local --command "$sql" --json 2>&1) || {
      echo "${label}: wrangler failed — $out" >&2
      return 1
    }
  elif command -v pnpm >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    out=$(cd "$api_dir" && pnpm exec wrangler d1 execute bropay-db --local --command "$sql" --json 2>&1) || {
      echo "${label}: wrangler failed — $out" >&2
      return 1
    }
  else
    echo "${label}: need wrangler or pnpm in apps/api" >&2
    return 1
  fi
  echo "$out" | python3 -c "
import sys, json
blocks = json.load(sys.stdin)
rows = blocks[0].get('results', []) if blocks else []
if not rows:
    print('')
else:
    r = rows[0]
    print(next(iter(r.values())))
"
}

# Cancel pending payouts / wallet-withdrawals and seed KBNK creds so reserved/webhook state is clean.
preflight_withdrawal_wallet() {
  seed_kbnk_credentials

  http_get "$BROPAY/v1/merchant/payouts?status=pending&limit=50" -H "$OWNER" -H "$MERCH" -H "$ORIGIN"
  echo "$HTTP_BODY" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for p in d.get('data', []):
    if p.get('status') == 'pending':
        print(p['id'])
" | while read -r pid; do
    [ -n "$pid" ] || continue
    http_post "$BROPAY/v1/merchant/payouts/$pid/cancel" \
      -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
      -d '{"cancellation_reason":"E2E withdrawal preflight"}' || true
  done

  http_get "$BROPAY/v1/merchant/wallet-withdrawals?status=pending&limit=50" \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN"
  echo "$HTTP_BODY" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for w in d.get('data', []):
    if w.get('status') == 'pending':
        print(w['id'])
" | while read -r wid; do
    [ -n "$wid" ] || continue
    http_post "$BROPAY/v1/merchant/wallet-withdrawals/$wid/cancel" \
      -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
      -d '{"cancellation_reason":"E2E withdrawal preflight"}' || true
  done

  http_get "$BROPAY/v1/merchant/wallet-withdrawals?status=processing&limit=50" \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN"
  echo "$HTTP_BODY" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for w in d.get('data', []):
    if w.get('status') == 'processing':
        print(w['id'])
" | while read -r wid; do
    [ -n "$wid" ] || continue
    http_post "$BROPAY/v1/merchant/wallet-withdrawals/$wid/cancel" \
      -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
      -d '{"cancellation_reason":"E2E withdrawal preflight"}' || true
  done

  RESERVED_BASELINE=$(merchant_wallet_field reserved_balance)
}

assert_wallet_reservation_delta() {
  local expected_delta=$1
  local avail_expected=$2
  local avail actual reserved expected_reserved

  avail=$(merchant_wallet_field available_balance)
  reserved=$(merchant_wallet_field reserved_balance)
  expected_reserved=$((RESERVED_BASELINE + expected_delta))

  [ "$avail" -eq "$avail_expected" ] || fail "available_balance: expected $avail_expected, got $avail"
  [ "$reserved" -eq "$expected_reserved" ] || fail "reserved_balance: expected $expected_reserved (baseline $RESERVED_BASELINE + delta $expected_delta), got $reserved"
}

set_payout_provider_transfer_id() {
  local payout_id=$1
  local provider_transfer_id=$2
  e2e_d1_local_sql \
    "UPDATE payouts SET provider_transfer_id = '$provider_transfer_id' WHERE id = '$payout_id'"
  local got
  got=$(e2e_d1_local_scalar \
    "SELECT provider_transfer_id FROM payouts WHERE id = '$payout_id'")
  [ "$got" = "$provider_transfer_id" ] || fail "provider_transfer_id not set in D1 (got '${got:-null}')"
}

seed_kbnk_credentials() {
  local api_dir sql secret
  secret="${KBNK_WEBHOOK_SECRET}"
  api_dir="${_E2E_REPO_ROOT}/apps/api"
  if ! sql=$(
    cd "$api_dir" && KBNK_WEBHOOK_SECRET="$secret" pnpm exec npx --yes tsx <<'TS'
import { readFileSync } from "node:fs"
import { encrypt } from "./src/lib/crypto.ts"

const secret = process.env.KBNK_WEBHOOK_SECRET ?? "test-webhook-secret-32-chars-long!!"
let encryptionKey = process.env.ENCRYPTION_KEY ?? ""
if (!encryptionKey) {
  try {
    const vars = readFileSync(".dev.vars", "utf8")
    const m = vars.match(/^ENCRYPTION_KEY=(.+)$/m)
    if (m) encryptionKey = m[1].trim()
  } catch { /* empty */ }
}
if (!encryptionKey || encryptionKey.length < 32) {
  console.error("ENCRYPTION_KEY missing or too short in apps/api/.dev.vars")
  process.exit(1)
}

const providerId = "prov-kbnk-000000-0000-000000000001"
const creds = [
  { id: "cred-kbnk-e2e-apikey", name: "api_key", value: "test-api-key" },
  { id: "cred-kbnk-e2e-secret", name: "api_secret", value: "test-api-secret" },
  { id: "cred-kbnk-e2e-webhook", name: "webhook_secret", value: secret },
] as const

const lines: string[] = []
for (const c of creds) {
  const enc = await encrypt(c.value, encryptionKey)
  lines.push(
    `INSERT OR REPLACE INTO provider_credentials (id, provider_id, credential_name, encrypted_value) VALUES ('${c.id}', '${providerId}', '${c.name}', '${enc.replace(/'/g, "''")}');`
  )
}
lines.push(`UPDATE providers SET status = 'active' WHERE id = '${providerId}';`)
console.log(lines.join("\n"))
TS
  ); then
    fail "Failed to seed KBNK provider_credentials (need ENCRYPTION_KEY in apps/api/.dev.vars)"
  fi
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    e2e_d1_local_sql "$cmd"
  done <<<"$sql"
}

# Writable temp prefix (Git Bash / Windows: prefer repo dir over /tmp+mktemp).
_kbnk_temp_dir() {
  local dir="${REPO_ROOT:-${_E2E_REPO_ROOT}}"
  [ -n "$dir" ] || dir="."
  printf '%s' "$dir"
}

# Sign and POST a KBNK-shaped JSON body (Standard Webhooks v1 headers).
# Args: event (e.g. deposit.completed); data_json (compact JSON object for "data").
post_kbnk_webhook_payload() {
  local event=$1 data_json=$2
  local payload_file meta_file webhook_id timestamp signature

  payload_file=$(mktemp "$(_kbnk_temp_dir)/.e2e-kbnk-payload.XXXXXX" 2>/dev/null || mktemp "${TMPDIR:-/tmp}/kbnk-payload.XXXXXX")
  meta_file=$(mktemp "$(_kbnk_temp_dir)/.e2e-kbnk-meta.XXXXXX" 2>/dev/null || mktemp "${TMPDIR:-/tmp}/kbnk-meta.XXXXXX")

  python3 - "$event" "$data_json" "$KBNK_WEBHOOK_SECRET" "$payload_file" "$meta_file" <<'PY'
import base64
import hashlib
import hmac
import json
import sys
import time
import uuid

event, data_json, secret, payload_path, meta_path = sys.argv[1:6]
webhook_id = f"evt-kbnk-{uuid.uuid4()}"
timestamp = str(int(time.time()))
data_obj = json.loads(data_json)
body_obj = {"event": event, "data": data_obj, "timestamp": timestamp, "webhookId": webhook_id}
body = json.dumps(body_obj, separators=(",", ":"))
with open(payload_path, "wb") as f:
    f.write(body.encode("utf-8"))
message = f"{webhook_id}.{timestamp}.{body}"
sig = base64.b64encode(hmac.new(secret.encode(), message.encode(), hashlib.sha256).digest()).decode()
with open(meta_path, "w", encoding="utf-8") as f:
    f.write(f"{webhook_id}\n{timestamp}\nv1,{sig}\n")
PY

  webhook_id=$(sed -n '1p' "$meta_file")
  timestamp=$(sed -n '2p' "$meta_file")
  signature=$(sed -n '3p' "$meta_file")

  http_post "$BROPAY/v1/webhooks/kbnk" \
    -H "${CT:-Content-Type: application/json}" \
    -H "webhook-id: $webhook_id" \
    -H "webhook-timestamp: $timestamp" \
    -H "webhook-signature: $signature" \
    --data-binary "@$payload_file"

  rm -f "$payload_file" "$meta_file"
}

# withdrawal.* — data.withdrawalId is provider_transfer_id lookup key (see kbnk mapper).
post_kbnk_webhook() {
  local event=$1 provider_transfer_id=$2 amount=$3
  local debt
  debt=$(printf '{"withdrawalId":"%s","amount":%s,"currency":"THB"}' "$provider_transfer_id" "$amount")
  post_kbnk_webhook_payload "$event" "$debt"
}

post_kbnk_wallet_deposit_completed() {
  local provider_deposit_ref=$1 amount_satang=$2
  local djson
  djson=$(printf '{"depositId":"%s","amount":%s,"currency":"THB"}' "$provider_deposit_ref" "$amount_satang")
  post_kbnk_webhook_payload "deposit.completed" "$djson"
}

# Fund wallet the way task-e2e.txt specifies: POST wallet-deposit + signed KBNK deposit.completed.
# Sets global DEPOSIT_ID. Requires _lib.sh + _merchant-lib + this file; BROPAY OWNER MERCH ORIGIN CT DEMO_WALLET_ID.
e2e_fund_wallet_via_kbnk_deposit_webhook() {
  local fund_amount=$1
  local provider_ref=${2:-}
  REPO_ROOT="${REPO_ROOT:-${_E2E_REPO_ROOT}}"
  export REPO_ROOT

  seed_kbnk_credentials

  local pre_avail raw http body
  pre_avail=$(curl -s "$BROPAY/v1/merchant/wallets" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" | json "
d=json.load(sys.stdin)
w=d.get('data',{})
if isinstance(w,list):
    w=w[0] if w else {}
print(int(w.get('available_balance',0)))
")

  raw=$(curl -s -w "\n%{http_code}" "$BROPAY/v1/merchant/wallet-deposits" -X POST \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "${CT:-Content-Type: application/json}" \
    -d "{\"amount\":$fund_amount}")
  http=$(echo "$raw" | tail -n 1)
  body=$(echo "$raw" | sed '$d')
  [ "$http" = "201" ] || fail "Expected 201 on wallet-deposit create, got $http — $body"

  DEPOSIT_ID=$(echo "$body" | json "print(json.load(sys.stdin).get('data',{}).get('id',''))")
  [ -n "$DEPOSIT_ID" ] || fail "Missing wallet deposit id"

  local dep_row
  dep_row=$(d1_local_deposit_row "$DEPOSIT_ID") || fail "d1_local_deposit_row failed (wrangler / apps/api)"
  [ "$dep_row" != "not_found" ] || fail "Deposit $DEPOSIT_ID not in local D1 — run pnpm dev:api from apps/api once"

  if [ -z "$provider_ref" ]; then
    provider_ref="e2e-kbnk-dep-${DEPOSIT_ID//-/}"
  fi

  e2e_d1_local_sql \
    "UPDATE wallet_deposits SET provider_payment_id = '${provider_ref}' WHERE id = '${DEPOSIT_ID}'" \
    || fail "Could not set provider_payment_id on wallet_deposit (local D1). Is wrangler available?"

  post_kbnk_wallet_deposit_completed "$provider_ref" "$fund_amount"
  # Handler always returns 200 to the provider; assert economic effect via wallet API below.
  local post_avail
  post_avail=$(curl -s "$BROPAY/v1/merchant/wallets" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" | json "
d=json.load(sys.stdin)
w=d.get('data',{})
if isinstance(w,list):
    w=w[0] if w else {}
print(int(w.get('available_balance',0)))
")
  [ "$post_avail" -gt "$pre_avail" ] || fail "deposit.completed webhook did not credit wallet (before=$pre_avail after=$post_avail). Check ENCRYPTION_KEY in apps/api/.dev.vars matches seed_kbnk_credentials."

  http_get "$BROPAY/v1/merchant/wallet-deposits/$DEPOSIT_ID" -H "$OWNER" -H "$MERCH" -H "$ORIGIN"
  [ "${HTTP_CODE:-}" = "200" ] || fail "GET wallet-deposit detail expected 200 got ${HTTP_CODE:-?}"
  local st
  st=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin).get('data',{}).get('status',''))")
  [ "$st" = "succeeded" ] || fail "Expected wallet deposit status succeeded after webhook, got $st"
}

# Requires wallet_withdrawals.provider_transfer_id (API migration — see task boat).
e2e_link_wallet_withdrawal_provider_transfer() {
  local withdrawal_id=$1 provider_transfer_ref=$2
  e2e_d1_local_sql \
    "UPDATE wallet_withdrawals SET provider_transfer_id = '${provider_transfer_ref}' WHERE id = '${withdrawal_id}'" \
    || fail "Could not SET provider_transfer_id on wallet_withdrawals — add the column/migration + provider-driven withdrawal row updates in apps/api."
}

# POST webhook (200) then assert payout reached expected terminal status via merchant API.
post_kbnk_webhook_expect_payout() {
  local event=$1 provider_transfer_id=$2 amount=$3 payout_id=$4 expected_status=$5

  post_kbnk_webhook "$event" "$provider_transfer_id" "$amount"
  [ "$HTTP_CODE" = "200" ] || fail "KBNK webhook expected 200, got $HTTP_CODE — $HTTP_BODY"

  http_get "$BROPAY/v1/merchant/payouts/$payout_id" -H "$OWNER" -H "$MERCH" -H "$ORIGIN"
  local status
  status=$(echo "$HTTP_BODY" | json "print(json.load(sys.stdin)['data']['status'])")
  [ "$status" = "$expected_status" ] || fail "Payout $payout_id: expected status '$expected_status' after $event, got '$status' (webhook may have failed HMAC — check API logs)"
}

ensure_verified_bank_account() {
  http_get "$BROPAY/v1/merchant/bank-accounts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN"
  local count
  count=$(echo "$HTTP_BODY" | json "print(len(json.load(sys.stdin).get('data',[])))")
  if [ "$count" = "0" ]; then
    http_post "$BROPAY/v1/merchant/bank-accounts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
      -d '{"bank_id":"bank-kbank-0000-0000-000000000001","account_number":"9876543210","account_holder_name":"Demo Merchant","account_type":"savings"}'
    [ "$HTTP_CODE" = "201" ] || fail "Bank account create failed ($HTTP_CODE)"
  fi
  http_get "$BROPAY/v1/merchant/bank-accounts" -H "$OWNER" -H "$MERCH" -H "$ORIGIN"
  BA_ID=$(echo "$HTTP_BODY" | json "d=json.load(sys.stdin)['data']; print(d[0]['id'] if d else '')")
  [ -n "$BA_ID" ] || fail "No bank account found"
  e2e_d1_local_sql \
    "UPDATE merchant_bank_accounts SET verification_status = 'verified', status = 'active' WHERE id = '$BA_ID'"
}
