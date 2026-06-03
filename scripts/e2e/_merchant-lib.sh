#!/bin/bash
# Shared helpers for merchant shell E2E scripts.
# Usage: source "$(dirname "$0")/../_merchant-lib.sh"  (from scripts/e2e/merchant/*.sh)
#        source "$SCRIPT_DIR/_merchant-lib.sh"       (from scripts/e2e/e2e-*.sh)

# Repo root resolved at source time (BASH_SOURCE is this file, not the caller).
_E2E_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_E2E_REPO_ROOT="$(cd "${_E2E_LIB_DIR}/../.." && pwd)"

# shellcheck disable=SC2034
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}"; exit 1; }
warn() { echo -e "${YELLOW}! $1${NC}"; }
step() { echo -e "\n${CYAN}━━━ Step $1: $2 ━━━${NC}"; }
json() { python3 -c "import sys,json; $1" 2>/dev/null; }

# Canonical: METHOD.pathname+search.timestamp.body (hmac-auth.ts)
hmac_sign() {
  local SECRET=$1 TIMESTAMP=$2 BODY=$3 METHOD=${4:-POST} PATH_=${5:-/v1/api/payment-intents} SEARCH=${6:-}
  python3 -c "import hmac,hashlib; print(hmac.new('$SECRET'.encode(),'${METHOD}.${PATH_}${SEARCH}.${TIMESTAMP}.${BODY}'.encode(),hashlib.sha256).hexdigest())"
}

# After bootstrap_demo_merchant
merchant_auth_headers() {
  OWNER="Authorization: Bearer $DEMO_OWNER_TOKEN"
  MERCH="X-Merchant-Id: $DEMO_MERCHANT_ID"
}

# POST /v1/merchant/wallet-deposits then complete via local D1 (same pattern as e2e-wallet-flow.sh).
# Prerequisites: source _lib.sh first (d1_local_ok, d1_local_deposit_row); REPO_ROOT or _E2E_REPO_ROOT;
# BROPAY, OWNER, MERCH, ORIGIN, DEMO_WALLET_ID after bootstrap.
# Sets global DEPOSIT_ID for cleanup. Args: amount_satang; description must be SQL-safe (no ').
e2e_fund_wallet_via_deposit() {
  local fund_amount=$1
  local ledger_desc=${2:-E2E wallet funding deposit}
  REPO_ROOT="${REPO_ROOT:-${_E2E_REPO_ROOT}}"
  export REPO_ROOT

  local pre_avail raw http body dep_row bal_after
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

  dep_row=$(d1_local_deposit_row "$DEPOSIT_ID") || fail "d1_local_deposit_row failed (wrangler / apps/api)"
  [ "$dep_row" != "not_found" ] || fail "Deposit $DEPOSIT_ID not in local D1 — run pnpm dev:api from apps/api once"

  d1_local_ok "UPDATE wallet_deposits SET status = 'succeeded', succeeded_at = datetime('now') WHERE id = '$DEPOSIT_ID'" \
    || fail "Mark deposit succeeded failed"
  d1_local_ok "UPDATE wallets SET available_balance = available_balance + $fund_amount, updated_at = datetime('now') WHERE id = '$DEMO_WALLET_ID'" \
    || fail "Credit wallet failed"
  bal_after=$((pre_avail + fund_amount))
  d1_local_ok "INSERT INTO wallet_ledger_entries (wallet_id, entry_type, reference_type, reference_id, amount, currency, balance_before, balance_after, description) VALUES ('$DEMO_WALLET_ID', 'credit', 'deposit', '$DEPOSIT_ID', $fund_amount, 'THB', $pre_avail, $bal_after, '$ledger_desc')" \
    || fail "Insert deposit ledger failed"
}

# Resolve wrangler binary for D1 execute helpers.
# Sets $_E2E_WR_BIN to an executable path, or empty when only pnpm/npx can run it.
_e2e_wrangler_bin() {
  local api_dir=${_E2E_REPO_ROOT}/apps/api
  local bin
  _E2E_WR_BIN=""
  if command -v wrangler >/dev/null 2>&1; then
    _E2E_WR_BIN=wrangler
    return 0
  fi
  for bin in \
    "${api_dir}/node_modules/.bin/wrangler" \
    "${api_dir}/node_modules/.bin/wrangler.cmd" \
    "${api_dir}/node_modules/.bin/wrangler.CMD" \
    "${_E2E_REPO_ROOT}/node_modules/.bin/wrangler" \
    "${_E2E_REPO_ROOT}/node_modules/.bin/wrangler.cmd" \
    "${_E2E_REPO_ROOT}/node_modules/.bin/wrangler.CMD"
  do
    if [ -f "$bin" ]; then
      _E2E_WR_BIN=$bin
      return 0
    fi
  done
}

# Run SQL against D1 via wrangler. Second arg: wrangler d1 flags (default `--local`).
# Fails loudly on error. Repo root is derived from this file, not cwd.
#
# Resolution order: global `wrangler` → repo/api `node_modules/.bin/wrangler` →
# `pnpm exec` / `npx` from apps/api (devDependency).
e2e_d1_sql() {
  local sql=$1
  local d1_flags=${2:---local}
  local api_dir out label
  label="e2e_d1_sql"
  api_dir="${_E2E_REPO_ROOT}/apps/api"
  [ -d "$api_dir" ] || {
    echo "${label}: missing apps/api at $api_dir" >&2
    return 1
  }
  _e2e_wrangler_bin

  if [ -n "$_E2E_WR_BIN" ]; then
    # shellcheck disable=SC2086
    out=$(cd "$api_dir" && "$_E2E_WR_BIN" d1 execute bropay-db $d1_flags --command "$sql" 2>&1) || {
      echo "${label}: wrangler failed — $out" >&2
      return 1
    }
  elif command -v pnpm >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    out=$(cd "$api_dir" && pnpm exec wrangler d1 execute bropay-db $d1_flags --command "$sql" 2>&1) || {
      echo "${label}: wrangler failed — $out" >&2
      return 1
    }
  elif command -v npx >/dev/null 2>&1; then
    # shellcheck disable=SC2086
    out=$(
      cd "$api_dir" && npx --yes wrangler d1 execute bropay-db $d1_flags --command "$sql" 2>&1
    ) || {
      echo "${label}: wrangler failed — $out" >&2
      return 1
    }
  else
    echo "${label}: need wrangler (PATH or node_modules/.bin) or pnpm/npx in apps/api" >&2
    return 1
  fi
  if ! echo "$out" | grep -qE '"success"[[:space:]]*:[[:space:]]*true'; then
    echo "${label}: unexpected wrangler output — $out" >&2
    return 1
  fi
}

e2e_d1_local_sql() {
  e2e_d1_sql "$1" --local
}
