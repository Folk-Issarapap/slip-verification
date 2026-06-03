#!/bin/bash
# ──────────────────────────────────────────────────────────────────────────────
#                       ╔════════════════════════════════╗
#                       ║   LOCAL DEV ONLY — NOT PROD    ║
#                       ╚════════════════════════════════╝
#
# Realistic activity seeder for the LOCAL D1 dev database.
#
# This script writes a small but realistic activity set into
# the preview merchant, then wires the preview reseller's downline (3 sub-merchants
# + commission flows) so the reseller app is populated too. Running it
# against staging or production would corrupt
# real merchant data. Two hard-stop guards below refuse to run if (a) the
# API URL is not localhost or (b) any --remote flag exists in this file.
#
# App coverage after a run:
#   admin     — all merchants + reseller hierarchy (staff: super@bropay.com)
#   merchant  — the preview merchant (login: merchant.owner@bropay.com / password123)
#   reseller  — preview reseller downline (login: reseller.owner@bropay.com / password123)
#
# Prerequisites:
#   pnpm dev:api must be running (port 8787)
#   pnpm db:seed must have been run first (seeds staff + KBNK provider +
#     the preview reseller owner & reseller merchant rows this script needs)
#
# Idempotent: reruns fill missing rows and still run reconcile/audit.
#
# Scale knobs:
#   SEED_CUSTOMERS=500 SEED_PIS=3000 SEED_RSUB_PIS=30 SEED_PAYOUTS=50 SEED_WEBHOOK_EVENTS=30 pnpm db:seed:realistic
#
# Disposable validation:
#   SEED_WRANGLER_PERSIST_TO=/tmp/bropay-seed pnpm db:seed:realistic
# ──────────────────────────────────────────────────────────────────────────────
set -euo pipefail

command -v python3 >/dev/null 2>&1 || { echo "Error: python3 is required"; exit 1; }
command -v curl    >/dev/null 2>&1 || { echo "Error: curl is required"; exit 1; }
command -v wrangler >/dev/null 2>&1 || { echo "Error: wrangler is required — run: npm i -g wrangler"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BROPAY="${BROPAY_URL:-http://localhost:8787}"
ORIGIN="Origin: http://localhost:3000"
CT="Content-Type: application/json"
SEED_CUSTOMERS="${SEED_CUSTOMERS:-30}"
SEED_PIS="${SEED_PIS:-120}"
SEED_RSUB_PIS="${SEED_RSUB_PIS:-8}"
SEED_PAYOUTS="${SEED_PAYOUTS:-12}"
SEED_WEBHOOK_EVENTS="${SEED_WEBHOOK_EVENTS:-12}"
SEED_WRANGLER_PERSIST_TO="${SEED_WRANGLER_PERSIST_TO:-}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
pass() { echo -e "${GREEN}✓ $1${NC}"; }
fail() { echo -e "${RED}✗ $1${NC}" >&2; exit 1; }
info() { echo -e "${CYAN}→ $1${NC}"; }
warn() { echo -e "${YELLOW}! $1${NC}"; }
json() { python3 -c "import sys,json; $1" 2>/dev/null; }

d1_execute_once() {
  if [ -n "$SEED_WRANGLER_PERSIST_TO" ]; then
    wrangler --cwd "$REPO_ROOT/apps/api" d1 execute bropay-db --local --persist-to "$SEED_WRANGLER_PERSIST_TO" "$@"
  else
    wrangler --cwd "$REPO_ROOT/apps/api" d1 execute bropay-db --local "$@"
  fi
}

d1_execute() {
  local attempt=1
  local max_attempts=6
  local output
  local status

  while true; do
    if output="$(d1_execute_once "$@" 2>&1)"; then
      printf '%s\n' "$output"
      return 0
    fi
    status=$?

    if [ "$attempt" -ge "$max_attempts" ] || ! printf '%s' "$output" | grep -Eqi 'SQLITE_BUSY|database is locked'; then
      printf '%s\n' "$output" >&2
      return "$status"
    fi

    sleep "$attempt"
    attempt=$((attempt + 1))
  done
}

d1_scalar() {
  local sql="$1"
  d1_execute --json --command "$sql" 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
rows = d[0].get('results', []) if d else []
if rows:
    print(next(iter(rows[0].values())))
" 2>/dev/null
}

export SEED_WRANGLER_PERSIST_TO

case "$SEED_CUSTOMERS" in
  ''|*[!0-9]*) fail "SEED_CUSTOMERS must be a positive integer" ;;
esac
case "$SEED_PIS" in
  ''|*[!0-9]*) fail "SEED_PIS must be a positive integer" ;;
esac
case "$SEED_RSUB_PIS" in
  ''|*[!0-9]*) fail "SEED_RSUB_PIS must be a positive integer" ;;
esac
case "$SEED_PAYOUTS" in
  ''|*[!0-9]*) fail "SEED_PAYOUTS must be a positive integer" ;;
esac
case "$SEED_WEBHOOK_EVENTS" in
  ''|*[!0-9]*) fail "SEED_WEBHOOK_EVENTS must be a positive integer" ;;
esac
if [ "$SEED_CUSTOMERS" -lt 1 ]; then fail "SEED_CUSTOMERS must be at least 1"; fi
if [ "$SEED_PIS" -lt 1 ]; then fail "SEED_PIS must be at least 1"; fi
if [ "$SEED_RSUB_PIS" -lt 1 ]; then fail "SEED_RSUB_PIS must be at least 1"; fi
if [ "$SEED_PAYOUTS" -lt 1 ]; then fail "SEED_PAYOUTS must be at least 1"; fi
if [ "$SEED_WEBHOOK_EVENTS" -lt 1 ]; then fail "SEED_WEBHOOK_EVENTS must be at least 1"; fi

# ─── HARD STOP: refuse to run against anything but local ──────────────────────
# Guard 1 — BROPAY_URL must point at localhost or 127.0.0.1. This blocks
# the most common foot-gun: someone exporting BROPAY_URL=https://api.example.com
# then running pnpm db:seed:realistic and obliterating prod fixtures.
case "$BROPAY" in
  http://localhost:*|http://127.0.0.1:*) ;;
  *)
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  REFUSING — BROPAY_URL is not localhost                  ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "  BROPAY_URL = $BROPAY"
    echo ""
    echo "  This seeder writes realistic fixture rows and is LOCAL-ONLY by design."
    echo "  Pointing it at staging or production would corrupt real merchant data."
    echo ""
    echo "  Fix: unset BROPAY_URL, or set it to http://localhost:8787"
    echo ""
    exit 1
    ;;
esac

# Guard 2 — refuse if any uncommented wrangler invocation targets remote.
# Paranoia against future edits that swap --local for --remote.
# Strips comment lines AND echo/printf lines so this file's own diagnostic
# strings mentioning the forbidden flag don't false-positive the guard.
if grep -v '^[[:space:]]*#' "$0" \
   | grep -v '^[[:space:]]*echo' \
   | grep -v '^[[:space:]]*printf' \
   | grep -Eq 'wrangler[[:space:]].*--remote'; then
  echo ""
  echo -e "${RED}REFUSING — found a wrangler remote-flag call in this script.${NC}"
  echo "  This seeder must only ever target the local D1 database."
  echo "  Replace the remote flag with --local before re-running."
  echo ""
  exit 1
fi

# ── Preflight: API reachable? ─────────────────────────────────────────────────

if ! curl -sf "$BROPAY/health" -o /dev/null 2>/dev/null && \
   ! curl -sf "$BROPAY/v1/auth/staff/login" -o /dev/null --max-time 2 2>/dev/null; then
  # Try a more permissive check — just connecting
  if ! curl -s --connect-timeout 3 "$BROPAY" -o /dev/null 2>/dev/null; then
    echo ""
    echo -e "${RED}Cannot reach $BROPAY${NC}"
    echo "Start the API dev server first:  pnpm dev:api"
    echo ""
    exit 1
  fi
fi

# ── Bootstrap ─────────────────────────────────────────────────────────────────

echo ""
echo -e "${CYAN}━━━ Realistic Seeder — Merchant Operations ━━━${NC}"
echo ""

source "$SCRIPT_DIR/../e2e/_bootstrap.sh"
bootstrap_demo_merchant || fail "Bootstrap failed"

MERCHANT_ID="$DEMO_MERCHANT_ID"
ADMIN_TOKEN="$DEMO_ADMIN_TOKEN"
OWNER_TOKEN="$DEMO_OWNER_TOKEN"
WALLET_ID="$DEMO_WALLET_ID"
ADMIN="Authorization: Bearer $ADMIN_TOKEN"
OWNER="Authorization: Bearer $OWNER_TOKEN"
MERCH="X-Merchant-Id: $MERCHANT_ID"

pass "Merchant: $MERCHANT_ID"

# Platform fee GL helpers require an active platform wallet. Keep this local
# fixture deterministic so direct seed postings and API routes resolve the same
# account as the tests (`wallet__platform__`).
PLATFORM_SQL_FILE="$(mktemp -t bropay-platform-wallet).sql"
cat > "$PLATFORM_SQL_FILE" << 'PLATFORMSQL'
INSERT OR IGNORE INTO merchants (
  id, name, slug, status, merchant_type, primary_currency,
  settlement_frequency, settlement_method, auto_settlement_enabled,
  allow_auto_customer_creation, created_by, approved_by, approved_at
) VALUES (
  '__platform__', 'BroPay Platform', 'platform', 'active', 'other', 'THB',
  'daily', 'transaction_based', 0, 0,
  'acct-super-admin-0000-000000000001',
  'acct-super-admin-0000-000000000001',
  datetime('now')
);
INSERT OR IGNORE INTO wallets (id, merchant_id, currency, status)
VALUES ('wallet__platform__', '__platform__', 'THB', 'active');
INSERT OR IGNORE INTO ledger_accounts (account_type, owner_id, currency, normal_balance)
VALUES ('wallet', 'wallet__platform__', 'THB', 'credit');
INSERT OR IGNORE INTO ledger_accounts (account_type, owner_id, currency, normal_balance)
VALUES ('wallet_reserved', 'wallet__platform__', 'THB', 'credit');
INSERT OR IGNORE INTO ledger_accounts (account_type, owner_id, currency, normal_balance)
VALUES ('wallet', 'wall-demo-reseller-0000-000000000001', 'THB', 'credit');
INSERT OR IGNORE INTO ledger_accounts (account_type, owner_id, currency, normal_balance)
VALUES ('wallet_reserved', 'wall-demo-reseller-0000-000000000001', 'THB', 'credit');
INSERT OR IGNORE INTO ledger_accounts (account_type, owner_id, currency, normal_balance)
VALUES ('customer_bank', NULL, 'THB', 'debit');
INSERT OR IGNORE INTO ledger_accounts (account_type, owner_id, currency, normal_balance)
VALUES ('provider_clearing', NULL, 'THB', 'credit');
PLATFORMSQL
pushd "$REPO_ROOT/apps/api" > /dev/null
d1_execute --json --file="$PLATFORM_SQL_FILE" > /dev/null 2>&1
popd > /dev/null
rm -f "$PLATFORM_SQL_FILE"

# ━━━ Reseller activity data ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# The dedicated preview reseller entity (resellers row + owner + membership +
# wallet) is created by `pnpm db:seed` (seed.sql).
# Here we populate its downline: 3 sub-merchants assigned to the reseller,
# modest payment volume, and completed settlements so commission ledger entries
# are generated for the reseller wallet.

echo -e "\n${CYAN}━━━ Reseller: downline sub-merchants + commission flows ━━━${NC}"

RESELLER_ID="res-demo-reseller-0000-000000000001"
RESELLER_WALLET_ID="wall-demo-reseller-0000-000000000001"

# ── Idempotency guard — skip if sub-merchants already present ─────────────────
pushd "$REPO_ROOT/apps/api" > /dev/null
RSUB_COUNT=$(d1_execute --json \
  --command "SELECT COUNT(*) as n FROM merchants WHERE reseller_id='$RESELLER_ID'" \
  2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d[0]['results'][0]['n'] if d else 0)
" 2>/dev/null || echo "0")
popd > /dev/null

if [ "${RSUB_COUNT:-0}" -ge 3 ]; then
  warn "Reseller downline already present ($RSUB_COUNT sub-merchants) — skipping"
else
  info "Preparing 3 reseller sub-merchants (reseller_id=$RESELLER_ID)…"

  # ── Insert accounts, merchants, wallets, fee_configs, memberships via SQL ────
  RSUB_SQL_FILE="$(mktemp -t bropay-rsub).sql"

  python3 << PYEOF_RSUB
import uuid

# Deterministic IDs so re-runs are safe with INSERT OR IGNORE
subs = [
  {
    "acct_id":   "acct-rsub-1-000-0000-000000000301",
    "merch_id":  "merch-rsub-1-0000-000000000001",
    "wallet_id": "wall-rsub-1-0000-000000000001",
    "mm_id":     "mm-rsub-1-owner-00000000000000001",
    "fee_in":    "fee-rsub-1-inbound-000000000001",
    "fee_out":   "fee-rsub-1-outbound-00000000001",
    "email":     "rsub1.owner@bropay.com",
    "name":      "Bangkok Supply Co.",
    "slug":      "bangkok-supply",
    "status":    "active",
  },
  {
    "acct_id":   "acct-rsub-2-000-0000-000000000302",
    "merch_id":  "merch-rsub-2-0000-000000000002",
    "wallet_id": "wall-rsub-2-0000-000000000002",
    "mm_id":     "mm-rsub-2-owner-00000000000000002",
    "fee_in":    "fee-rsub-2-inbound-000000000002",
    "fee_out":   "fee-rsub-2-outbound-00000000002",
    "email":     "rsub2.owner@bropay.com",
    "name":      "Chiang Mai Market Hub",
    "slug":      "chiang-mai-market-hub",
    "status":    "active",
  },
  {
    "acct_id":   "acct-rsub-3-000-0000-000000000303",
    "merch_id":  "merch-rsub-3-0000-000000000003",
    "wallet_id": "wall-rsub-3-0000-000000000003",
    "mm_id":     "mm-rsub-3-owner-00000000000000003",
    "fee_in":    "fee-rsub-3-inbound-000000000003",
    "fee_out":   "fee-rsub-3-outbound-00000000003",
    "email":     "rsub3.owner@bropay.com",
    "name":      "Phuket Service Group",
    "slug":      "phuket-service-group",
    "status":    "suspended",  # 1 of 3 suspended for variety
  },
]

pw_hash = "\$2b\$10\$ySGg52sE9F7ILSe6At2aGeByewBmz/j9AYDdG/T7xzsubNZyE.gFa"
reseller_id = "res-demo-reseller-0000-000000000001"
admin_id    = "acct-super-admin-0000-000000000001"

lines = ["PRAGMA foreign_keys = ON;", ""]

for s in subs:
    # account (kind='merchant' — these are merchant-portal logins)
    lines.append(
        f"INSERT OR IGNORE INTO accounts (id, email, name, display_name, password_hash, status, kind, email_verified_at, last_login_at, must_change_password) VALUES ("
        f"  '{s['acct_id']}', '{s['email']}', '{s['name']} Owner', '{s['name']}', '{pw_hash}', 'active', 'merchant', datetime('now'), datetime('now'), 0);"
    )
    # merchant row WITH reseller_id
    lines.append(
        f"INSERT OR IGNORE INTO merchants (id, name, slug, status, merchant_type, primary_currency, "
        f"settlement_frequency, settlement_method, auto_settlement_enabled, allow_auto_customer_creation, "
        f"reseller_id, created_by, approved_by, approved_at) VALUES ("
        f"  '{s['merch_id']}', '{s['name']}', '{s['slug']}', '{s['status']}', 'other', 'THB', "
        f"  'daily', 'transaction_based', 0, 1, '{reseller_id}', '{admin_id}', '{admin_id}', datetime('now'));"
    )
    # wallet
    lines.append(
        f"INSERT OR IGNORE INTO wallets (id, merchant_id, currency, status) VALUES ("
        f"  '{s['wallet_id']}', '{s['merch_id']}', 'THB', 'active');"
    )
    # fee_configurations (inbound + outbound)
    lines.append(
        f"INSERT OR IGNORE INTO fee_configurations "
        f"(id, merchant_id, integration_id, stream_type, fee_percentage, flat_fee_amount, min_fee, max_fee, calculation_method, effective_from, is_active, created_by) VALUES "
        f"('{s['fee_in']}', '{s['merch_id']}', NULL, 'inbound',  1.50, 0, 0, NULL, 'transaction_based', datetime('now'), 1, '{admin_id}');"
    )
    lines.append(
        f"INSERT OR IGNORE INTO fee_configurations "
        f"(id, merchant_id, integration_id, stream_type, fee_percentage, flat_fee_amount, min_fee, max_fee, calculation_method, effective_from, is_active, created_by) VALUES "
        f"('{s['fee_out']}', '{s['merch_id']}', NULL, 'outbound', 1.50, 0, 0, NULL, 'transaction_based', datetime('now'), 1, '{admin_id}');"
    )
    # merchant membership (owner)
    lines.append(
        f"INSERT OR IGNORE INTO merchant_memberships (id, account_id, merchant_id, role, status, invited_by, joined_at) VALUES ("
        f"  '{s['mm_id']}', '{s['acct_id']}', '{s['merch_id']}', 'owner', 'active', '{admin_id}', datetime('now'));"
    )
    lines.append("")

with open("$RSUB_SQL_FILE", "w") as f:
    f.write("\n".join(lines))
print("SQL written")
PYEOF_RSUB

  pushd "$REPO_ROOT/apps/api" > /dev/null
  RSUB_OUT=$(d1_execute --file="$RSUB_SQL_FILE" 2>&1) || {
    echo "$RSUB_OUT" | tail -10
    rm -f "$RSUB_SQL_FILE"
    fail "Sub-merchant SQL insert failed"
  }
  popd > /dev/null
  rm -f "$RSUB_SQL_FILE"
  pass "3 reseller sub-merchants inserted"

  # ── Give each ACTIVE sub-merchant 30 bank-routed PIs + GL entries ────────────
  # Active subs: rsub-1 (Alpha) and rsub-2 (Beta)
  ACTIVE_SUBS_JSON='[
    {"merch_id":"merch-rsub-1-0000-000000000001","wallet_id":"wall-rsub-1-0000-000000000001","label":"Alpha"},
    {"merch_id":"merch-rsub-2-0000-000000000002","wallet_id":"wall-rsub-2-0000-000000000002","label":"Beta"}
  ]'

  RSUB_VOL_SQL_FILE="$(mktemp -t bropay-rsub-vol).sql"

  python3 << PYEOF_VOL
import random, math

random.seed(12345)
RSUB_TOTAL = int("$SEED_RSUB_PIS")

admin_id = "acct-super-admin-0000-000000000001"

subs = [
    {"merch_id": "merch-rsub-1-0000-000000000001", "wallet_id": "wall-rsub-1-0000-000000000001", "label": "Alpha"},
    {"merch_id": "merch-rsub-2-0000-000000000002", "wallet_id": "wall-rsub-2-0000-000000000002", "label": "Beta"},
]

lines = ["PRAGMA foreign_keys = ON;", ""]

for idx, s in enumerate(subs):
    mid = s["merch_id"]
    wid = s["wallet_id"]
    label = s["label"]

    lines.append(f"UPDATE merchants SET deposit_destination='bank', updated_at=datetime('now') WHERE id='{mid}';")
    lines.append(
        f"INSERT OR IGNORE INTO ledger_accounts (account_type, owner_id, currency, normal_balance) "
        f"VALUES ('wallet', '{wid}', 'THB', 'credit');"
    )
    lines.append(
        f"INSERT OR IGNORE INTO ledger_accounts (account_type, owner_id, currency, normal_balance) "
        f"VALUES ('wallet_reserved', '{wid}', 'THB', 'credit');"
    )
    lines.append("INSERT OR IGNORE INTO ledger_accounts (account_type, owner_id, currency, normal_balance) VALUES ('provider_clearing', NULL, 'THB', 'credit');")
    lines.append("INSERT OR IGNORE INTO ledger_accounts (account_type, owner_id, currency, normal_balance) VALUES ('customer_bank', NULL, 'THB', 'debit');")

    # Small realistic payment intents — all succeeded so they can settle.
    pi_rows = []
    ledger_rows = []
    total_gross = 0
    sub_descriptor = f"SUB MERCHANT {chr(ord('A')+idx)}"[:22]
    for i in range(RSUB_TOTAL):
        pi_id = f"pi-rsub-{idx+1}-ops-{i:04d}"
        pi_ref = f"PIN-RSUB{idx+1}-{i:05d}"
        lo, hi = math.log(10000), math.log(100000)
        amount = int(round(math.exp(random.uniform(lo, hi)) / 100) * 100)
        total_gross += amount
        cs = f"cs_pay_rsub_{idx+1}_{i:04d}"
        desc = f"Sub order #{1000+i}".replace("'", "''")
        # Merchant-side identifiers — realistic distribution so admin has
        # populated Invoice / Refs columns instead of dashes everywhere.
        invoice = f"'INV-2026-{idx+1:02d}{1000+i:05d}'" if random.random() < 0.75 else "NULL"
        ref1 = f"'ORD{1000+i:06d}'"  # always present (Thai PG order ref)
        ref2 = f"'CUST{random.randint(100, 9999):04d}'" if random.random() < 0.50 else "NULL"
        ref3 = f"'PO{random.randint(10, 99):02d}'" if random.random() < 0.15 else "NULL"
        order_id = f"'ord-{idx+1}-{1000+i}'" if random.random() < 0.70 else "NULL"
        descriptor = f"'{sub_descriptor}'" if random.random() < 0.80 else "NULL"

        pi_rows.append(
            f"('{pi_id}','{pi_ref}','{mid}',NULL,NULL,"
            f"{amount},'THB','succeeded','promptpay',"
            f"'{cs}',"
            f"datetime('now'),NULL,NULL,NULL,NULL,'{desc}',"
            f"{invoice},{ref1},{ref2},{ref3},{order_id},{descriptor})"
        )
        txid = f"gl-rsub-{idx+1}-pi-{i:04d}"
        ledger_rows.append(
            f"('le-rsub-{idx+1}-pi-{i:04d}-debit','{txid}',"
            f"(SELECT id FROM ledger_accounts WHERE account_type='customer_bank' AND owner_id IS NULL LIMIT 1),"
            f"'debit',{amount},'THB','payment_intent','{pi_id}','Customer payment gross')"
        )
        ledger_rows.append(
            f"('le-rsub-{idx+1}-pi-{i:04d}-credit','{txid}',"
            f"(SELECT id FROM ledger_accounts WHERE account_type='provider_clearing' AND owner_id IS NULL LIMIT 1),"
            f"'credit',{amount},'THB','payment_intent','{pi_id}','Payment held for bank settlement')"
        )

    # Bulk insert PIs + GL entries
    lines.append(
        "INSERT OR IGNORE INTO payment_intents "
        "(id,reference_number,merchant_id,integration_id,customer_id,"
        "amount,currency,status,payment_method,"
        "client_secret,"
        "succeeded_at,failed_at,cancelled_at,cancellation_reason,"
        "expires_at,description,"
        "invoice_number,ref1,ref2,ref3,order_id,statement_descriptor) VALUES\n" +
        ",\n".join(pi_rows) + ";"
    )
    lines.append(
        "INSERT OR IGNORE INTO ledger_entries "
        "(id,transaction_id,account_id,direction,amount,currency,source_type,source_id,description) VALUES\n" +
        ",\n".join(ledger_rows) + ";"
    )

    # Top up wallet so fee is always covered (use 10% of gross as conservative buffer).
    # Wallet funding is a GL adjustment. Wallet projection columns are rebuilt
    # from GL in the final pass.
    top_up = max(int(total_gross * 0.10), 1000000)
    topup_tx_id = f"bank-topup-tx-{wid}"
    lines.append(
        # GL double-entry: credit the wallet account
        f"INSERT OR IGNORE INTO ledger_entries "
        f"(id, transaction_id, account_id, direction, amount, currency, source_type, source_id, description) VALUES ("
        f"  'le-topup-{wid}-credit', '{topup_tx_id}', "
        f"  (SELECT id FROM ledger_accounts WHERE account_type = 'wallet' AND owner_id = '{wid}'), "
        f"  'credit', {top_up}, 'THB', 'adjustment', 'bank-topup-{wid}', 'Bank transfer top-up');"
    )
    lines.append(
        # GL double-entry: debit the customer_bank singleton (balancing entry)
        f"INSERT OR IGNORE INTO ledger_entries "
        f"(id, transaction_id, account_id, direction, amount, currency, source_type, source_id, description) VALUES ("
        f"  'le-topup-{wid}-debit', '{topup_tx_id}', "
        f"  (SELECT id FROM ledger_accounts WHERE account_type = 'customer_bank' AND owner_id IS NULL), "
        f"  'debit', {top_up}, 'THB', 'adjustment', 'bank-topup-{wid}', 'Bank transfer top-up');"
    )
    lines.append("")

# Store per-sub data for use by the settlement phase
with open("$RSUB_VOL_SQL_FILE", "w") as f:
    f.write("\n".join(lines))
print("volume SQL written")
PYEOF_VOL

  pushd "$REPO_ROOT/apps/api" > /dev/null
  VOL_OUT=$(d1_execute --file="$RSUB_VOL_SQL_FILE" 2>&1) || {
    echo "$VOL_OUT" | tail -10
    rm -f "$RSUB_VOL_SQL_FILE"
    fail "Sub-merchant volume insert failed"
  }
  popd > /dev/null
  rm -f "$RSUB_VOL_SQL_FILE"
  pass "Payment intents + GL entries inserted for active sub-merchants"

  # ── For each active sub: bank account → completed settlement + GL ───────────
  # Two active subs: Alpha (merch-rsub-1) and Beta (merch-rsub-2).
  # The completed settlement GL mirrors appendSettlementCompletionLedger:
  # provider_clearing debit + customer_bank credit + merchant fee debit +
  # reseller commission credit + platform residual credit.

  RSUB_SETTLE_SQL="$(mktemp -t bropay-rsub-settle).sql"
  export RSUB_SETTLE_SQL
  export RSUB_API_DIR="$REPO_ROOT/apps/api"

  python3 << 'PYEOF_SETTLE'
import subprocess, json, sys, os, math

api_dir  = os.environ["RSUB_API_DIR"]
out_file = os.environ["RSUB_SETTLE_SQL"]
persist_to = os.environ.get("SEED_WRANGLER_PERSIST_TO")
persist_args = ["--persist-to", persist_to] if persist_to else []
admin_id = "acct-super-admin-0000-000000000001"
bank_id  = "bank-kbank-0000-0000-000000000001"
reseller_wallet_id = "wall-demo-reseller-0000-000000000001"
platform_wallet_id = "wallet__platform__"

# Alpha = sub 1, Beta = sub 2  (Gamma/sub-3 is suspended → no settlements)
subs = [
    {
        "idx":      1,
        "label":    "Alpha",
        "merch_id": "merch-rsub-1-0000-000000000001",
        "wallet_id":"wall-rsub-1-0000-000000000001",
        "ba_id":    "mba-rsub-1-0000-000000000001",
        "settle_id":"stl-rsub-1-0000-000000000001",
        "slip_id":  "slip-rsub-1-0000-000000000001",
        "acct_num": "9876543210",
    },
    {
        "idx":      2,
        "label":    "Beta",
        "merch_id": "merch-rsub-2-0000-000000000002",
        "wallet_id":"wall-rsub-2-0000-000000000002",
        "ba_id":    "mba-rsub-2-0000-000000000002",
        "settle_id":"stl-rsub-2-0000-000000000002",
        "slip_id":  "slip-rsub-2-0000-000000000002",
        "acct_num": "9876543220",
    },
]

sql_lines = ["PRAGMA foreign_keys = ON;", ""]

def wrangler_query(sql_cmd):
    r = subprocess.run(
        ["wrangler","d1","execute","bropay-db","--local",*persist_args,"--json","--command", sql_cmd],
        capture_output=True, text=True, cwd=api_dir
    )
    try:
        return json.loads(r.stdout)
    except Exception:
        return []

for s in subs:
    mid  = s["merch_id"]
    wid  = s["wallet_id"]
    ba   = s["ba_id"]
    sid  = s["settle_id"]
    slip = s["slip_id"]
    lbl  = s["label"]
    idx  = s["idx"]

    # 1. Bank account (idempotent via INSERT OR IGNORE)
    sql_lines.append(
        f"INSERT OR IGNORE INTO merchant_bank_accounts "
        f"(id, merchant_id, bank_id, account_number, account_holder_name, "
        f"account_type, verification_status, for_settlement, status) VALUES "
        f"('{ba}', '{mid}', '{bank_id}', '{s['acct_num']}', "
        f"'Sub-Merchant {lbl} Co.', 'savings', 'verified', 1, 'active');"
    )

    # 2. Select eligible bank-routed succeeded PIs that are not already pending/completed.
    pi_rows = wrangler_query(
        f"SELECT pi.id, pi.amount "
        f"FROM payment_intents pi "
        f"WHERE pi.merchant_id='{mid}' AND pi.status='succeeded' "
        f"AND EXISTS ("
        f"  SELECT 1 FROM ledger_entries le "
        f"  JOIN ledger_accounts la ON la.id=le.account_id "
        f"  WHERE le.source_type='payment_intent' AND le.source_id=pi.id "
        f"    AND la.account_type='provider_clearing' AND le.direction='credit'"
        f") "
        f"AND pi.id NOT IN ("
        f"  SELECT payment_intent_id FROM settlement_items"
        f") "
        f"ORDER BY pi.created_at ASC"
    )
    rows = pi_rows[0].get("results", []) if pi_rows and pi_rows[0].get("results") else []
    if not rows:
        print(f"[{lbl}] No unsettled payment intents — skipping", file=sys.stderr)
        continue

    gross = sum(int(r["amount"]) for r in rows)
    fees = [int(math.floor(int(r["amount"]) * 0.015 + 0.5)) for r in rows]
    fee = sum(fees)
    net = max(0, gross - fee)
    cnt = len(rows)
    commission = int(math.floor(fee * 0.015))
    platform_residual = fee - commission
    print(f"[{lbl}] gross={gross} fee={fee} commission={commission} net={net} cnt={cnt}", file=sys.stderr)

    # 3. Create completed settlement row.
    sql_lines.append(
        f"INSERT OR IGNORE INTO settlements "
        f"(id, merchant_id, integration_id, bank_account_id, wallet_id, "
        f"settlement_date, transaction_count, gross_amount, fee_amount, net_amount, "
        f"currency, status, settlement_type, created_by, completed_at) VALUES "
        f"('{sid}', '{mid}', NULL, '{ba}', '{wid}', "
        f"date('now'), {cnt}, {gross}, {fee}, {net}, "
        f"'THB', 'completed', 'manual', '{admin_id}', datetime('now'));"
    )

    # 4. Link settlement_items to payment_intents.
    for n, pi in enumerate(rows):
        amount = int(pi["amount"])
        pi_fee = fees[n]
        pi_net = max(0, amount - pi_fee)
        sql_lines.append(
            f"INSERT OR IGNORE INTO settlement_items "
            f"(settlement_id, payment_intent_id, amount, fee_amount, net_amount, currency) VALUES "
            f"('{sid}', '{pi['id']}', {amount}, {pi_fee}, {pi_net}, 'THB');"
        )

    # 5. Slip and lifecycle events.
    sql_lines.append(
        f"INSERT OR IGNORE INTO settlement_slips "
        f"(id, settlement_id, r2_key, mime_type, file_size, original_filename, uploaded_by) "
        f"VALUES ('{slip}', '{sid}', 'settlements/rsub-{idx}-slip.pdf', 'application/pdf', "
        f"1024, 'settlement-slip.pdf', '{admin_id}');"
    )
    sql_lines.append(
        f"INSERT OR IGNORE INTO settlement_events "
        f"(settlement_id, event_type, status, description, performed_by) VALUES "
        f"('{sid}', 'created', 'pending', 'Settlement created', '{admin_id}');"
    )
    sql_lines.append(
        f"INSERT OR IGNORE INTO settlement_events "
        f"(settlement_id, event_type, status, description, performed_by) VALUES "
        f"('{sid}', 'completed', 'completed', 'Settlement completed', '{admin_id}');"
    )

    # 6. Completed settlement GL.
    txid = f"gl-rsub-{idx}-settlement"
    ledger_rows = [
        (f"le-rsub-{idx}-settle-provider", "provider_clearing", "NULL", "debit", gross, "Settlement gross cleared"),
        (f"le-rsub-{idx}-settle-bank", "customer_bank", "NULL", "credit", gross, "Settlement transferred to merchant bank"),
        (f"le-rsub-{idx}-settle-merchant-fee", "wallet", f"'{wid}'", "debit", fee, "Settlement fee debit"),
    ]
    if commission > 0:
        ledger_rows.append((f"le-rsub-{idx}-settle-commission", "wallet", f"'{reseller_wallet_id}'", "credit", commission, "Reseller commission"))
    if platform_residual > 0:
        ledger_rows.append((f"le-rsub-{idx}-settle-platform", "wallet", f"'{platform_wallet_id}'", "credit", platform_residual, "Platform fee residual"))
    for entry_id, account_type, owner_sql, direction, amount, desc in ledger_rows:
        sql_lines.append(
            f"INSERT OR IGNORE INTO ledger_entries "
            f"(id, transaction_id, account_id, direction, amount, currency, source_type, source_id, description) VALUES ("
            f"'{entry_id}', '{txid}', "
            f"(SELECT id FROM ledger_accounts WHERE account_type='{account_type}' AND "
            f"({'owner_id IS NULL' if owner_sql == 'NULL' else 'owner_id=' + owner_sql}) LIMIT 1), "
            f"'{direction}', {amount}, 'THB', 'settlement', '{sid}', '{desc}');"
        )
    sql_lines.append("")

with open(out_file, "w") as f:
    f.write("\n".join(sql_lines))
print("Settlement SQL written", file=sys.stderr)
PYEOF_SETTLE

  pushd "$REPO_ROOT/apps/api" > /dev/null
  RSUB_SETTLE_OUT=$(d1_execute --file="$RSUB_SETTLE_SQL" 2>&1) \
    && pass "Sub-merchant completed settlements + GL inserted" \
    || { echo "$RSUB_SETTLE_OUT" | tail -6; fail "Sub-merchant settlement SQL failed; kept at $RSUB_SETTLE_SQL"; }
  echo "$RSUB_SETTLE_OUT" | grep -qiE "error" || rm -f "$RSUB_SETTLE_SQL"
  popd > /dev/null

  # ── Verify commission ledger ──────────────────────────────────────────────────
  pushd "$REPO_ROOT/apps/api" > /dev/null
  COMM_CHECK=$(d1_execute --json \
    --command "SELECT COUNT(*) as cnt, COALESCE(SUM(le.amount),0) as total FROM ledger_entries le JOIN ledger_accounts la ON la.id=le.account_id WHERE la.account_type='wallet' AND la.owner_id='$RESELLER_WALLET_ID' AND le.source_type='settlement' AND le.direction='credit'" \
    2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
if d and d[0].get('results'):
    r = d[0]['results'][0]
    print(f'count={r[\"cnt\"]} total={r[\"total\"]}')
else:
    print('count=? total=?')
" 2>/dev/null || echo "count=? total=?")
  popd > /dev/null
  pass "Reseller commission ledger: $COMM_CHECK"
fi

# ── Idempotency baseline ──────────────────────────────────────────────────────

EXISTING_CUSTOMER_IDS_RAW=$(d1_execute --json --command "
  SELECT c.id
  FROM customers c
  JOIN customer_merchants cm ON cm.customer_id = c.id
  WHERE cm.merchant_id = '$MERCHANT_ID'
  ORDER BY c.created_at, c.id
  LIMIT $SEED_CUSTOMERS
" 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
for row in (d[0].get('results', []) if d else []):
    print(row['id'])
" 2>/dev/null || true)

EXISTING_CUSTOMER_IDS=()
while IFS= read -r _CID; do
  [ -n "$_CID" ] && EXISTING_CUSTOMER_IDS+=("$_CID")
done <<< "$EXISTING_CUSTOMER_IDS_RAW"

EXISTING_COUNT="${#EXISTING_CUSTOMER_IDS[@]}"
CUSTOMERS_TO_CREATE=$((SEED_CUSTOMERS - EXISTING_COUNT))
if [ "$CUSTOMERS_TO_CREATE" -lt 0 ]; then
  CUSTOMERS_TO_CREATE=0
fi

if [ "$EXISTING_COUNT" -gt 0 ]; then
  info "Existing customers: $EXISTING_COUNT/$SEED_CUSTOMERS (creating $CUSTOMERS_TO_CREATE)"
fi

# ━━━ Phase 1: Legacy integration compatibility record ━━━━━━━━━━━━━━━━━━━━━━━

echo -e "\n${CYAN}━━━ Phase 1: Legacy integration compatibility record ━━━${NC}"

INTEGRATIONS=$(curl -s "$BROPAY/v1/merchant/integrations" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")

INTEGRATION_ID=$(echo "$INTEGRATIONS" | json \
  "d=json.load(sys.stdin).get('data',[]); \
   m=[i for i in d if i.get('slug')=='primary']; \
   print(m[0]['id'] if m else '')")

if [ -z "$INTEGRATION_ID" ]; then
  info "Creating one legacy integration for webhook compatibility…"
  CREATE_INTEGRATION=$(curl -s "$BROPAY/v1/merchant/integrations" -X POST \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
    -d '{"name":"Primary Checkout","slug":"primary","deposit_destination":"bank"}')
  INTEGRATION_ID=$(echo "$CREATE_INTEGRATION" | json \
    "print(json.load(sys.stdin).get('data',{}).get('id',''))")
fi

# Re-fetch after ensures/create calls
INTEGRATIONS=$(curl -s "$BROPAY/v1/merchant/integrations" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")

INTEGRATION_ID=$(echo "$INTEGRATIONS" | json \
  "d=json.load(sys.stdin).get('data',[]); \
   m=[i for i in d if i.get('slug')=='primary']; \
   print(m[0]['id'] if m else '')")
[ -n "$INTEGRATION_ID" ] || fail "Legacy integration not found after ensure"

# Runtime money routing is merchant-scoped now; seed rows use NULL integration_id.
pushd "$REPO_ROOT/apps/api" > /dev/null
d1_execute --json \
  --command "UPDATE merchants SET deposit_destination='bank', updated_at=datetime('now') WHERE id='$MERCHANT_ID'" \
  > /dev/null 2>&1
d1_execute --json \
  --command "DELETE FROM integration_hmac_credentials WHERE merchant_id='$MERCHANT_ID' AND integration_id IS NOT NULL AND integration_id <> '$INTEGRATION_ID' AND integration_id NOT IN (SELECT integration_id FROM payment_intents WHERE integration_id IS NOT NULL)" \
  > /dev/null 2>&1
d1_execute --json \
  --command "DELETE FROM integrations WHERE merchant_id='$MERCHANT_ID' AND id <> '$INTEGRATION_ID' AND id NOT IN (SELECT integration_id FROM payment_intents WHERE integration_id IS NOT NULL)" \
  > /dev/null 2>&1
popd > /dev/null

pass "Legacy integration: $INTEGRATION_ID"

# ━━━ Phase 2: Customers via API ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo -e "\n${CYAN}━━━ Phase 2: Customers ($SEED_CUSTOMERS target) ━━━${NC}"

CUSTOMER_IDS=()
if [ "$EXISTING_COUNT" -gt 0 ]; then
  for _CID in "${EXISTING_CUSTOMER_IDS[@]}"; do
    CUSTOMER_IDS+=("$_CID")
  done
fi
CUSTOMER_NAMES=()

# Generate all customer definitions in one python call
CUST_DATA=$(python3 -c "
import random, json, sys
random.seed(42)
total = int('$CUSTOMERS_TO_CREATE')

first_names = [
  'สมชาย','สมหญิง','นภัส','ปรีชา','อนัน','ธนากร','พัชรี','รัตนา','วิชัย','ศรีสุดา',
  'มนัส','กมลา','ชลธิชา','วรรณา','สุภาพ','ชาญ','Somchai','Pim','Apichart','Napat',
  'Warisa','Kittipong','Suwan','Malee','Boonmee','Chalerm','Duangjai','Ekkachai',
  'Fon','Ganya'
]
last_names = [
  'ใจดี','สุขสม','วงศ์ทอง','มีชัย','เจริญสุข','รุ่งเรือง','สายทอง','ทองดี','บุญมา',
  'พงษ์ไพร','Rattanakul','Srisombat','Phongphan','Wongwai','Thaweewat','Charoen',
  'Niratpattanasai','Somsak','Bunyarak','Jitpraphawan','Kamolwat','Limcharoen',
  'Mongkol','Naklang','Ongsakul','Panyarat','Rungrojn','Suksawat','Thongchai',
  'Udomsak'
]
biz_templates = [
  'Siam Tech Solutions','Bangkok Logistics Co.','Thai Digital Services','Golden Gate Trading',
  'Northern Star Import','Phuket Beach Resort','Chiangmai Craft Co.','BroPay Coffee Co.',
  'Central E-Commerce','Metro Delivery','Sunshine Retail','Eastern Seaboard Supply',
  'Royal Palm Holdings','Skyline Construction','Pacific Rim Trading','Lotus Financial',
  'Emerald Bay Hospitality','Summit Auto Parts','River City Textiles','Harbor Freight TH',
]
domains = ['gmail.com','hotmail.com','yahoo.com','outlook.com','icloud.com','me.com']
phone_mid_prefixes = ['80','81','82','83','84','85','86','87','88','89','90','91','95','97','98']

records = []
for i in range(total):
  r = random.random()
  fn = random.choice(first_names)
  ln = random.choice(last_names)
  biz = random.choice(biz_templates)

  if r < 0.70:         # individual
    rec = {'first_name': fn, 'last_name': ln, 'biz': None,  'display': fn+' '+ln}
  elif r < 0.95:       # business only
    rec = {'first_name': None, 'last_name': None, 'biz': biz, 'display': biz}
  else:                # both
    rec = {'first_name': fn, 'last_name': ln, 'biz': biz,  'display': fn+' '+biz}

  # email (80% chance) — only emit when both fn and ln slug down to >=1 ASCII char.
  # Thai-only names skip email rather than produce 'user' placeholders.
  def _ascii_slug(s, fallback):
    s = (s or '').lower()
    out = ''.join(c for c in s if c.isascii() and c.isalnum())
    return out[:8] if out else fallback
  fn_slug = _ascii_slug(fn, '')
  ln_slug = _ascii_slug(ln, '')
  if random.random() < 0.80 and fn_slug and ln_slug:
    rec['email'] = f'{fn_slug}.{ln_slug}{i}@{random.choice(domains)}'
  else:
    rec['email'] = None

  # phone (90% chance, +66 8X/9X XXXX XXXX format)
  if random.random() < 0.90:
    mid = random.choice(phone_mid_prefixes)
    num4a = str(random.randint(1000,9999))
    num4b = str(random.randint(1000,9999))
    rec['phone'] = f'+66{mid}{num4a}{num4b}'
  else:
    rec['phone'] = None

  records.append(rec)

print(json.dumps(records))
")

# Create customers using a single python subprocess loop to avoid many fork/execs.
CUST_IDS_RAW=""
if [ "$CUSTOMERS_TO_CREATE" -gt 0 ]; then
  CUST_IDS_RAW=$(python3 << PYEOF
import json, subprocess, sys, time

records = json.loads(r'''$CUST_DATA''')
merchant_id = "$MERCHANT_ID"
admin_token = "$ADMIN_TOKEN"
bropay = "$BROPAY"

created_ids = []
created_names = []
failed = 0

total = len(records)
progress_every = max(1, min(50, total // 10 or 1))

for i, rec in enumerate(records):
    body = {"merchant_id": merchant_id}
    if rec.get("first_name"):
        body["first_name"] = rec["first_name"]
    if rec.get("last_name"):
        body["last_name"] = rec["last_name"]
    if rec.get("biz"):
        body["business_name"] = rec["biz"]
    if rec.get("email"):
        body["email"] = rec["email"]
    if rec.get("phone"):
        body["phone"] = rec["phone"]

    result = subprocess.run([
        "curl", "-s", f"{bropay}/v1/admin/customers", "-X", "POST",
        "-H", f"Authorization: Bearer {admin_token}",
        "-H", "Origin: http://localhost:3000",
        "-H", "Content-Type: application/json",
        "-d", json.dumps(body)
    ], capture_output=True, text=True, timeout=15)

    try:
        resp = json.loads(result.stdout)
        cid = resp.get("data", {}).get("id", "")
        if cid:
            created_ids.append(cid)
            created_names.append(rec.get("display", "?"))
        else:
            failed += 1
            if failed <= 3:
                print(f"WARN:customer {i+1} failed: {result.stdout[:120]}", file=sys.stderr)
    except Exception:
        failed += 1

    if (i + 1) % progress_every == 0 or (i + 1) == total:
        print(f"PROGRESS:{i+1}/{total} customers created ({failed} failed)", file=sys.stderr)

# Output: one id per line
for cid in created_ids:
    print(cid)
PYEOF
)
fi

while IFS= read -r _CID; do
  [ -n "$_CID" ] && CUSTOMER_IDS+=("$_CID")
done <<< "$CUST_IDS_RAW"
CUST_COUNT="${#CUSTOMER_IDS[@]}"
pass "$CUST_COUNT customers available ($CUSTOMERS_TO_CREATE created this run)"

if [ "$CUST_COUNT" -eq 0 ]; then
  fail "No customers were created — check API is running and accepting requests"
fi

# ━━━ Phase 3: Bank Accounts for customers ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo -e "\n${CYAN}━━━ Phase 3: Customer Bank Accounts ━━━${NC}"

# 60% of customers get 1-2 bank accounts. Built using a single python subprocess.
EXISTING_CUSTOMER_BANK_ACCOUNTS=$(d1_scalar "
  SELECT COUNT(*)
  FROM customer_bank_accounts cba
  JOIN customer_merchants cm ON cm.customer_id = cba.customer_id
  WHERE cm.merchant_id = '$MERCHANT_ID'
")
MIN_REALISTIC_BANK_ACCOUNTS=$((SEED_CUSTOMERS * 6 / 10))
if [ "$MIN_REALISTIC_BANK_ACCOUNTS" -lt 1 ]; then
  MIN_REALISTIC_BANK_ACCOUNTS=1
fi

if [ "${EXISTING_CUSTOMER_BANK_ACCOUNTS:-0}" -ge "$MIN_REALISTIC_BANK_ACCOUNTS" ]; then
  pass "Customer bank accounts already realistic: $EXISTING_CUSTOMER_BANK_ACCOUNTS"
else
python3 << PYEOF
import json, subprocess, sys, random

random.seed(99)

customer_ids = """$(printf '%s\n' "${CUSTOMER_IDS[@]}")""".strip().split("\n")
merchant_id = "$MERCHANT_ID"
owner_token = "$OWNER_TOKEN"
bropay = "$BROPAY"

bank_ids = [
    "bank-kbank-0000-0000-000000000001",
    "bank-scb00-0000-0000-000000000002",
    "bank-bbl00-0000-0000-000000000003",
    "bank-ktb00-0000-0000-000000000004",
    "bank-ttb00-0000-0000-000000000005",
    "bank-bay00-0000-0000-000000000006",
]

holder_names = [
    "Somchai Jaidee","Malee Sukhsom","Apichart Wongthong","Pim Meechai",
    "Kittipong Charoen","Warisa Rungrod","Napat Thongdee","Duangjai Boonma",
    "Chalerm Phongprai","Ekkachai Rattana","Ganya Srisombat","Fon Bunyarak",
    "Boonmee Kamolwat","Suwan Naklang","Chawin Panyarat","Sunee Mongkol",
]

created = 0
failed = 0

for i, cid in enumerate(customer_ids):
    count = random.choices([0, 1, 2, 3], weights=[30, 45, 18, 7], k=1)[0]
    if count == 0:
        continue
    chosen_banks = random.sample(bank_ids, min(count, len(bank_ids)))
    for bank_id in chosen_banks:
        acct_num = "".join([str(random.randint(0,9)) for _ in range(10)])
        body = {
            "customer_id": cid,
            "bank_id": bank_id,
            "account_number": acct_num,
            "account_holder_name": random.choice(holder_names),
        }
        result = subprocess.run([
            "curl", "-s", f"{bropay}/v1/merchant/customer-bank-accounts", "-X", "POST",
            "-H", f"Authorization: Bearer {owner_token}",
            "-H", f"X-Merchant-Id: {merchant_id}",
            "-H", "Origin: http://localhost:3000",
            "-H", "Content-Type: application/json",
            "-d", json.dumps(body)
        ], capture_output=True, text=True, timeout=15)

        try:
            resp = json.loads(result.stdout)
            if resp.get("data", {}).get("id"):
                created += 1
            else:
                failed += 1
        except Exception:
            failed += 1

    if (i + 1) % 100 == 0:
        print(f"PROGRESS: {i+1}/{len(customer_ids)} bank account batches done", file=sys.stderr)

print(f"Done: {created} bank accounts, {failed} failed", file=sys.stderr)
PYEOF

pass "Customer bank accounts seeded"
fi

# ━━━ Phase 4: Payment Intents + GL payment entries ━━━━━━━━━━━━━━━━━━━━━━━━━━

echo -e "\n${CYAN}━━━ Phase 4: Payment Intents + GL entries ($SEED_PIS rows via SQL) ━━━${NC}"

# Generate deterministic IDs and all PI/GL data in python, write to temp SQL, execute in chunks.
# Preview merchant is bank-destination, so succeeded PIs post:
#   debit customer_bank / credit provider_clearing
PI_SQL_FILE="$(mktemp -t bropay-activity-pis).sql"
GL_SQL_FILE="$(mktemp -t bropay-activity-gl-pis).sql"

python3 << PYEOF
import uuid, random, math, json, sys

random.seed(7777)

merchant_id = "$MERCHANT_ID"
customer_ids = """$(printf '%s\n' "${CUSTOMER_IDS[@]}")""".strip().split("\n")
# filter empties
customer_ids = [c for c in customer_ids if c]

# Power-law customer activity: top 10% are whales, bottom 10% are dormant (receive 0 PIs).
# Weights built ONCE here; random.paretovariate advances RNG by active_count draws
# before the main loop — deterministic because seed(7777) is set above.
active_count = int(len(customer_ids) * 0.90)  # 10% dormant
active_ids = customer_ids[:active_count]
customer_weights = [min(random.paretovariate(1.2), 50.0) for _ in active_ids]

descriptions = [
    "Order #INV-{n}",
    "Subscription — Pro plan",
        "Wallet top-up",
    "Coffee + pastries",
    "Online purchase",
    "Service fee",
    "ค่าจัดส่งกรุงเทพ",
    "Booking deposit",
    "Donation — community fund",
    "Membership renewal",
    "ค่าสินค้าออนไลน์",
    "Refundable deposit",
    "ค่าบริการรายเดือน",
    "Flash sale item",
    "ค่าซ่อมบำรุง",
]

statuses_dist = (
    ["succeeded"] * 75 +
    ["failed"] * 15 +
    ["cancelled"] * 7 +
    ["expired"] * 3
)

payment_methods = ["promptpay"] * 80 + ["bank_transfer"] * 20

cancel_reasons_dist = (
    ["customer_abandoned"] * 50 +
    ["timeout"] * 20 +
    ["duplicate_request"] * 15 +
    ["invalid_method"] * 10 +
    ["merchant_cancelled"] * 5
)

outlier_amounts = [500_000, 750_000, 1_000_000, 1_500_000, 2_000_000]

TOTAL = int("$SEED_PIS")
CHUNK = 200

pi_rows = []
ledger_rows = []
succeeded_count = 0

for i in range(TOTAL):
    pi_id = f"pi-ops-{i:05d}"
    # Deterministic unique reference numbers — random 6-hex defaults collide
    # too often on large generated runs.
    pi_ref = f"PIN-260519-S{i:05d}"

    # Change 4: first 8 PIs are high-value outliers, always succeeded
    if i < 8:
        amount = random.choice(outlier_amounts)
        status = "succeeded"
    else:
        # log-uniform amount 5000–200000 satang
        lo, hi = math.log(5000), math.log(200000)
        amount = int(round(math.exp(random.uniform(lo, hi)) / 100) * 100)
        if amount < 5000: amount = 5000
        status = random.choice(statuses_dist)

    method = random.choice(payment_methods)
    desc = descriptions[i % len(descriptions)].replace("{n}", str(1000 + i))
    client_secret = f"cs_pay_{i:05d}_{merchant_id[-8:]}"
    client_secret = client_secret[:48]  # keep reasonable length

    # customer_id: 90% have one (power-law weighted), 10% guest
    if active_ids and random.random() < 0.90:
        cust_id = random.choices(active_ids, weights=customer_weights, k=1)[0]
    else:
        cust_id = None

    # status-specific timestamps — expressed as offsets from created_at
    # backdate.sql will rewrite created_at; we set these relative to 'now'
    # The backdate pass will also sync them, so just need something plausible.
    if status == "succeeded":
        succeeded_at = "datetime('now')"
        failed_at = "NULL"
        cancelled_at = "NULL"
        cancel_reason = "NULL"
        expires_at = "NULL"
    elif status == "failed":
        succeeded_at = "NULL"
        failed_at = "datetime('now')"
        cancelled_at = "NULL"
        cancel_reason = "NULL"
        expires_at = "NULL"
    elif status == "cancelled":
        succeeded_at = "NULL"
        failed_at = "NULL"
        cancelled_at = "datetime('now')"
        # Change 3: varied cancellation reasons
        cancel_reason = "'" + random.choice(cancel_reasons_dist) + "'"
        expires_at = "NULL"
    else:  # expired
        succeeded_at = "NULL"
        failed_at = "NULL"
        cancelled_at = "NULL"
        cancel_reason = "NULL"
        expires_at = "datetime('now', '-1 hour')"

    cust_val = f"'{cust_id}'" if cust_id else "NULL"
    desc_escaped = desc.replace("'", "''")
    # Merchant-side identifiers — realistic distribution so admin has
    # populated Invoice / Refs columns instead of dashes everywhere.
    invoice = f"'INV-2026-{1000+i:05d}'" if random.random() < 0.75 else "NULL"
    ref1 = f"'ORD{100000+i:07d}'"  # always present (Thai PG order ref, <=20 chars)
    ref2 = f"'CUST{random.randint(100, 9999):04d}'" if random.random() < 0.50 else "NULL"
    ref3 = f"'PO{random.randint(10, 99):02d}'" if random.random() < 0.15 else "NULL"
    order_id_val = f"'ord-{100000+i:07d}'" if random.random() < 0.70 else "NULL"
    descriptor = "'BANGKOK RETAIL'" if random.random() < 0.80 else "NULL"

    pi_rows.append(
        f"('{pi_id}','{pi_ref}','{merchant_id}',NULL,{cust_val},"
        f"{amount},'THB','{status}','{method}',"
        f"'{client_secret}',"
        f"{succeeded_at},{failed_at},{cancelled_at},{cancel_reason},"
        f"{expires_at},'{desc_escaped}',"
        f"{invoice},{ref1},{ref2},{ref3},{order_id_val},{descriptor})"
    )

    if status == "succeeded":
        succeeded_count += 1
        txid = f"gl-ops-pi-{i:05d}"
        ledger_rows.append(
            f"('le-ops-pi-{i:05d}-debit','{txid}',"
            f"(SELECT id FROM ledger_accounts WHERE account_type='customer_bank' AND owner_id IS NULL LIMIT 1),"
            f"'debit',{amount},'THB','payment_intent','{pi_id}','Customer payment gross')"
        )
        ledger_rows.append(
            f"('le-ops-pi-{i:05d}-credit','{txid}',"
            f"(SELECT id FROM ledger_accounts WHERE account_type='provider_clearing' AND owner_id IS NULL LIMIT 1),"
            f"'credit',{amount},'THB','payment_intent','{pi_id}','Payment held for bank settlement')"
        )

# Write PI chunks
with open("$PI_SQL_FILE", "w") as f:
    chunk_start = 0
    chunk_num = 0
    while chunk_start < len(pi_rows):
        chunk_num += 1
        chunk = pi_rows[chunk_start:chunk_start + CHUNK]
        f.write(
            "INSERT OR IGNORE INTO payment_intents "
            "(id,reference_number,merchant_id,integration_id,customer_id,"
            "amount,currency,status,payment_method,"
            "client_secret,"
            "succeeded_at,failed_at,cancelled_at,cancellation_reason,"
            "expires_at,description,"
            "invoice_number,ref1,ref2,ref3,order_id,statement_descriptor) VALUES\n"
        )
        f.write(",\n".join(chunk) + ";\n\n")
        chunk_start += CHUNK

# Write GL chunks
with open("$GL_SQL_FILE", "w") as f:
    f.write("INSERT OR IGNORE INTO ledger_accounts (account_type, owner_id, currency, normal_balance) VALUES ('provider_clearing', NULL, 'THB', 'credit');\n")
    f.write("INSERT OR IGNORE INTO ledger_accounts (account_type, owner_id, currency, normal_balance) VALUES ('customer_bank', NULL, 'THB', 'debit');\n\n")
    chunk_start = 0
    while chunk_start < len(ledger_rows):
        chunk = ledger_rows[chunk_start:chunk_start + CHUNK * 2]
        f.write(
            "INSERT OR IGNORE INTO ledger_entries "
            "(id,transaction_id,account_id,direction,amount,currency,source_type,source_id,description) VALUES\n"
        )
        f.write(",\n".join(chunk) + ";\n\n")
        chunk_start += CHUNK * 2

total_pi = len(pi_rows)
print(f"{total_pi} {succeeded_count}")
PYEOF

pushd "$REPO_ROOT/apps/api" > /dev/null

CHUNK_NUM=0
while IFS= read -r LINE; do
  if [[ "$LINE" == INSERT* ]]; then
    CHUNK_NUM=$((CHUNK_NUM + 1))
    info "[chunk $CHUNK_NUM] inserting PI batch…"
  fi
done < "$PI_SQL_FILE"

# Execute PI SQL file
info "Inserting payment_intents…"
PI_OUT=$(d1_execute --file="$PI_SQL_FILE" 2>&1) || {
  echo "$PI_OUT" | tail -10
  fail "PI insert failed; SQL kept at $PI_SQL_FILE"
}
pass "Payment intents inserted"

info "Inserting GL payment entries…"
GL_OUT=$(d1_execute --file="$GL_SQL_FILE" 2>&1) || {
  echo "$GL_OUT" | tail -10
  fail "GL payment entry insert failed; SQL kept at $GL_SQL_FILE"
}
pass "GL payment entries inserted"

popd > /dev/null
# Keep SQL files when insert failed for debugging; otherwise clean up.
if echo "$PI_OUT $GL_OUT" | grep -q "ERROR\|Error\|error"; then
  info "Seed SQL files kept at $PI_SQL_FILE / $GL_SQL_FILE for debugging"
else
  rm -f "$PI_SQL_FILE" "$GL_SQL_FILE"
fi

# Count actual rows
pushd "$REPO_ROOT/apps/api" > /dev/null
PI_ACTUAL=$(d1_execute --json \
  --command "SELECT COUNT(*) as n FROM payment_intents WHERE merchant_id='$MERCHANT_ID'" \
  2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['results'][0]['n'] if d else 0)" 2>/dev/null || echo "?")
GL_PI_ACTUAL=$(d1_execute --json \
  --command "SELECT COUNT(DISTINCT le.source_id) as n FROM ledger_entries le JOIN payment_intents pi ON pi.id=le.source_id WHERE le.source_type='payment_intent' AND pi.merchant_id='$MERCHANT_ID'" \
  2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['results'][0]['n'] if d else 0)" 2>/dev/null || echo "?")
popd > /dev/null

pass "payment_intents: $PI_ACTUAL rows, GL-backed succeeded PIs: $GL_PI_ACTUAL"

# ━━━ Phase 5: Merchant Bank Account + Settlements ━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo -e "\n${CYAN}━━━ Phase 5: Settlements ━━━${NC}"

# Ensure merchant has a verified bank account for settlement
BA_LIST=$(curl -s "$BROPAY/v1/merchant/bank-accounts" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
BA_ID=$(echo "$BA_LIST" | json \
  "d=json.load(sys.stdin)['data']; print(d[0]['id'] if d else '')")

if [ -z "$BA_ID" ]; then
  info "Creating merchant bank account…"
  BA_CREATE=$(curl -s "$BROPAY/v1/merchant/bank-accounts" -X POST \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
    -d '{"bank_id":"bank-kbank-0000-0000-000000000001","account_number":"9876543210","account_holder_name":"Bangkok Retail Group Co., Ltd.","account_type":"savings"}')
  BA_ID=$(echo "$BA_CREATE" | json \
    "print(json.load(sys.stdin).get('data',{}).get('id',''))")
fi

if [ -z "$BA_ID" ]; then
  warn "Could not obtain merchant bank account — skipping settlements"
else
  # Force-verify the bank account via DB (bypass async verification flow)
  pushd "$REPO_ROOT/apps/api" > /dev/null
  d1_execute --json \
    --command "UPDATE merchant_bank_accounts SET verification_status='verified', for_settlement=1, status='active', updated_at=datetime('now') WHERE id='$BA_ID'" \
    > /dev/null 2>&1
  pass "Merchant bank account: ${BA_ID:0:16}… (verified)"

  # Fund wallet through a GL adjustment. Projection columns are rebuilt from GL
  # in the final pass.
  TOPUP_SQL_FILE="$(mktemp -t bropay-bank-topup).sql"
  cat > "$TOPUP_SQL_FILE" << TOPSQL
PRAGMA foreign_keys = ON;
INSERT OR IGNORE INTO ledger_accounts (account_type, owner_id, currency, normal_balance)
  VALUES ('wallet', '${WALLET_ID}', 'THB', 'credit');
INSERT OR IGNORE INTO ledger_accounts (account_type, owner_id, currency, normal_balance)
  VALUES ('wallet_reserved', '${WALLET_ID}', 'THB', 'credit');
INSERT OR IGNORE INTO ledger_entries
  (id, transaction_id, account_id, direction, amount, currency, source_type, source_id, description)
  VALUES (
    'le-topup-${WALLET_ID}-credit', 'bank-topup-tx-${WALLET_ID}',
    (SELECT id FROM ledger_accounts WHERE account_type = 'wallet' AND owner_id = '${WALLET_ID}'),
    'credit', 100000000, 'THB', 'adjustment', 'bank-topup-${WALLET_ID}', 'Bank transfer top-up');
INSERT OR IGNORE INTO ledger_entries
  (id, transaction_id, account_id, direction, amount, currency, source_type, source_id, description)
  VALUES (
    'le-topup-${WALLET_ID}-debit', 'bank-topup-tx-${WALLET_ID}',
    (SELECT id FROM ledger_accounts WHERE account_type = 'customer_bank' AND owner_id IS NULL),
    'debit', 100000000, 'THB', 'adjustment', 'bank-topup-${WALLET_ID}', 'Bank transfer top-up');
TOPSQL
  d1_execute --file="$TOPUP_SQL_FILE" > /dev/null 2>&1
  rm -f "$TOPUP_SQL_FILE"
  popd > /dev/null
  pass "Wallet funded through GL adjustment"

  # Create settlements by picking batches of unsettled GL-backed succeeded PI IDs.
  pushd "$REPO_ROOT/apps/api" > /dev/null
  UNSETTLED_PI_JSON=$(d1_execute --json \
    --command "SELECT pi.id, pi.amount FROM payment_intents pi WHERE pi.merchant_id='$MERCHANT_ID' AND pi.status='succeeded' AND EXISTS (SELECT 1 FROM ledger_entries le JOIN ledger_accounts la ON la.id=le.account_id WHERE le.source_type='payment_intent' AND le.source_id=pi.id AND la.account_type='provider_clearing' AND le.direction='credit') AND pi.id NOT IN (SELECT payment_intent_id FROM settlement_items) ORDER BY pi.created_at ASC LIMIT $SEED_PIS" \
    2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = [{'id': r['id'], 'amount': r['amount']} for r in d[0].get('results', [])] if d else []
print(json.dumps(rows))
" 2>/dev/null || echo "[]")
  popd > /dev/null

  python3 << PYEOF2
import json, subprocess, sys, random, math, os

random.seed(13)

unsettled_rows = json.loads("""$UNSETTLED_PI_JSON""")
merchant_id = "$MERCHANT_ID"
wallet_id = "$WALLET_ID"
bank_account_id = "$BA_ID"
admin_id = "acct-super-admin-0000-000000000001"
platform_wallet_id = "wallet__platform__"
api_cwd = "$REPO_ROOT/apps/api"
persist_to = os.environ.get("SEED_WRANGLER_PERSIST_TO")
persist_args = ["--persist-to", persist_to] if persist_to else []

if not unsettled_rows:
    print("No unsettled payment intents found — skipping settlement creation", file=sys.stderr)
    sys.exit(0)

failure_reasons = ['bank_rejected','insufficient_funds','provider_timeout','provider_error','manual_review_required']
cancellation_reasons = ['merchant_requested','duplicate','amount_changed','compliance_hold']

random.shuffle(unsettled_rows)
target_settlements = min(150, max(1, len(unsettled_rows) // 10))
sql_lines = [
    "PRAGMA foreign_keys = ON;",
    "INSERT OR IGNORE INTO ledger_accounts (account_type, owner_id, currency, normal_balance) VALUES ('wallet', 'wallet__platform__', 'THB', 'credit');",
    f"INSERT OR IGNORE INTO ledger_accounts (account_type, owner_id, currency, normal_balance) VALUES ('wallet', '{wallet_id}', 'THB', 'credit');",
    f"INSERT OR IGNORE INTO ledger_accounts (account_type, owner_id, currency, normal_balance) VALUES ('wallet_reserved', '{wallet_id}', 'THB', 'credit');",
]

created = 0
cursor = 0
while cursor < len(unsettled_rows) and created < target_settlements:
    batch_size = random.randint(8, 20)
    batch = unsettled_rows[cursor:cursor + batch_size]
    if not batch:
        break
    cursor += batch_size
    created += 1

    sid = f"stl-ops-{created:04d}"
    slip = f"slip-ops-{created:04d}"
    gross = sum(int(row["amount"]) for row in batch)
    fees = [int(math.floor(int(row["amount"]) * 0.015 + 0.5)) for row in batch]
    fee = sum(fees)
    net = max(0, gross - fee)
    is_last = created == target_settlements
    r = random.random()
    if is_last:
        status = "pending"
    elif r < 0.80:
        status = "completed"
    elif r < 0.85:
        status = "processing"
    elif r < 0.95:
        status = "failed"
    else:
        status = "cancelled"

    completed_at = "datetime('now')" if status == "completed" else "NULL"
    failed_at = "datetime('now')" if status == "failed" else "NULL"
    cancelled_at = "datetime('now')" if status == "cancelled" else "NULL"
    processing_started_at = "datetime('now')" if status == "processing" else "NULL"
    failure_reason = f"'{random.choice(failure_reasons)}'" if status == "failed" else "NULL"
    cancellation_reason = f"'{random.choice(cancellation_reasons)}'" if status == "cancelled" else "NULL"

    sql_lines.append(
        "INSERT OR IGNORE INTO settlements "
        "(id, merchant_id, integration_id, bank_account_id, wallet_id, settlement_date, "
        "transaction_count, gross_amount, fee_amount, net_amount, currency, status, "
        "settlement_type, created_by, completed_at, failed_at, cancelled_at, "
        "processing_started_at, failure_reason, cancellation_reason) VALUES "
        f"('{sid}', '{merchant_id}', NULL, '{bank_account_id}', '{wallet_id}', date('now'), "
        f"{len(batch)}, {gross}, {fee}, {net}, 'THB', '{status}', 'manual', '{admin_id}', "
        f"{completed_at}, {failed_at}, {cancelled_at}, {processing_started_at}, "
        f"{failure_reason}, {cancellation_reason});"
    )

    for n, row in enumerate(batch):
        amount = int(row["amount"])
        pi_fee = fees[n]
        pi_net = max(0, amount - pi_fee)
        sql_lines.append(
            "INSERT OR IGNORE INTO settlement_items "
            "(settlement_id, payment_intent_id, amount, fee_amount, net_amount, currency) VALUES "
            f"('{sid}', '{row['id']}', {amount}, {pi_fee}, {pi_net}, 'THB');"
        )

    sql_lines.append(
        "INSERT OR IGNORE INTO settlement_slips "
        "(id, settlement_id, r2_key, mime_type, file_size, original_filename, uploaded_by) VALUES "
        f"('{slip}', '{sid}', 'settlements/{created:04d}-slip.pdf', 'application/pdf', 1024, 'settlement-slip.pdf', '{admin_id}');"
    )
    sql_lines.append(
        "INSERT OR IGNORE INTO settlement_events "
        "(settlement_id, event_type, status, description, performed_by) VALUES "
        f"('{sid}', 'created', 'pending', 'Settlement created', '{admin_id}');"
    )

    if status == "completed":
        txid = f"gl-ops-settlement-{created:04d}"
        ledger_rows = [
            (f"le-ops-settle-{created:04d}-provider", "provider_clearing", "NULL", "debit", gross, "Settlement gross cleared"),
            (f"le-ops-settle-{created:04d}-bank", "customer_bank", "NULL", "credit", gross, "Settlement transferred to merchant bank"),
            (f"le-ops-settle-{created:04d}-merchant-fee", "wallet", f"'{wallet_id}'", "debit", fee, "Settlement fee debit"),
        ]
        if fee > 0:
            ledger_rows.append((f"le-ops-settle-{created:04d}-platform", "wallet", f"'{platform_wallet_id}'", "credit", fee, "Platform fee residual"))
        for entry_id, account_type, owner_sql, direction, amount, desc in ledger_rows:
            sql_lines.append(
                "INSERT OR IGNORE INTO ledger_entries "
                "(id, transaction_id, account_id, direction, amount, currency, source_type, source_id, description) VALUES ("
                f"'{entry_id}', '{txid}', "
                f"(SELECT id FROM ledger_accounts WHERE account_type='{account_type}' AND "
                f"({'owner_id IS NULL' if owner_sql == 'NULL' else 'owner_id=' + owner_sql}) LIMIT 1), "
                f"'{direction}', {amount}, 'THB', 'settlement', '{sid}', '{desc}');"
            )
        sql_lines.append(
            "INSERT OR IGNORE INTO settlement_events "
            "(settlement_id, event_type, status, description, performed_by) VALUES "
            f"('{sid}', 'completed', 'completed', 'Settlement completed', '{admin_id}');"
        )

sql_file = os.path.join("/tmp", f"bropay-settlements-{os.getpid()}.sql")
with open(sql_file, "w") as f:
    f.write("\n".join(sql_lines) + "\n")

result = subprocess.run(
    ["wrangler", "d1", "execute", "bropay-db", "--local", *persist_args, "--file", sql_file],
    capture_output=True, text=True, timeout=60, cwd=api_cwd
)
if result.returncode != 0:
    print(result.stdout[-1000:], file=sys.stderr)
    print(result.stderr[-1000:], file=sys.stderr)
    sys.exit(result.returncode)
try:
    os.remove(sql_file)
except OSError:
    pass
print(f"Settlements total created: {created}", file=sys.stderr)
PYEOF2

  SETTLE_COUNT_ACTUAL=$(curl -s \
    "$BROPAY/v1/admin/settlements?merchant_id=$MERCHANT_ID&limit=1" \
    -H "$ADMIN" -H "$ORIGIN" | json \
    "print(json.load(sys.stdin).get('meta',{}).get('total',0))")
  pass "Settlements created: $SETTLE_COUNT_ACTUAL total for merchant"
fi

# ━━━ Phase 6: Payouts (bulk SQL — avoids wallet balance complexity) ━━━━━━━━━━

echo -e "\n${CYAN}━━━ Phase 6: Payouts ($SEED_PAYOUTS via SQL) ━━━${NC}"

if [ -z "$BA_ID" ]; then
  warn "No merchant bank account — skipping payouts"
else
  PAYOUT_SQL_FILE="$(mktemp -t bropay-activity-payouts).sql"

  python3 << PYEOF3
import random, math, json

random.seed(55)
PAYOUT_TOTAL = int("$SEED_PAYOUTS")

merchant_id = "$MERCHANT_ID"
wallet_id = "$WALLET_ID"
ba_id = "$BA_ID"

status_values = ["pending", "processing", "completed", "failed", "cancelled"]
status_weights = [16, 24, 40, 16, 4]
statuses = random.choices(status_values, weights=status_weights, k=PAYOUT_TOTAL)
if PAYOUT_TOTAL >= 1 and "completed" not in statuses:
    statuses[0] = "completed"
if PAYOUT_TOTAL >= 4 and "failed" not in statuses:
    statuses[-1] = "failed"
random.shuffle(statuses)
descriptions = [
    "Vendor payout — weekly","Supplier transfer","Staff payroll partial",
    "ค่าสินค้าออกร้าน","โอนเงินซัพพลายเออร์","Affiliate commission",
    "Partner payout","ค่าบริการรายเดือน","Refund to vendor","Bulk settlement",
]
failure_reasons = ["bank_rejected","insufficient_funds","account_invalid","provider_error","fraud_check_failed"]
cancellation_reasons = ["merchant_requested","duplicate","expired"]

rows = []
evt_rows = []
ledger_rows = [
    "INSERT OR IGNORE INTO ledger_accounts (account_type, owner_id, currency, normal_balance) VALUES ('wallet', 'wallet__platform__', 'THB', 'credit');",
    f"INSERT OR IGNORE INTO ledger_accounts (account_type, owner_id, currency, normal_balance) VALUES ('wallet', '{wallet_id}', 'THB', 'credit');",
    f"INSERT OR IGNORE INTO ledger_accounts (account_type, owner_id, currency, normal_balance) VALUES ('wallet_reserved', '{wallet_id}', 'THB', 'credit');",
    "INSERT OR IGNORE INTO ledger_accounts (account_type, owner_id, currency, normal_balance) VALUES ('customer_bank', NULL, 'THB', 'debit');",
]

for i in range(PAYOUT_TOTAL):
    pid = f"payout-ops-{i:04d}"
    status = statuses[i]
    lo, hi = math.log(10000), math.log(500000)
    amount = int(round(math.exp(random.uniform(lo, hi)) / 100) * 100)
    fee = int(amount * 0.015)
    net = amount - fee
    desc = random.choice(descriptions)
    desc_esc = desc.replace("'","''")
    prov_ref = f"tx-payout-{i:04d}"

    reserved_at = "datetime('now', '-3 hours')"
    processing_started_at = "NULL"
    completed_at = "NULL"
    failed_at = "NULL"
    cancelled_at = "NULL"
    cancellation_reason = "NULL"

    if status == "processing":
        processing_started_at = "datetime('now', '-2 hours')"
    elif status == "completed":
        processing_started_at = "datetime('now', '-2 hours')"
        completed_at = "datetime('now', '-1 hour')"
    elif status == "failed":
        processing_started_at = "datetime('now', '-2 hours')"
        failed_at = "datetime('now', '-30 minutes')"
        cancellation_reason = f"'{random.choice(failure_reasons)}'"
    elif status == "cancelled":
        cancelled_at = "datetime('now', '-1 hour')"
        cancellation_reason = f"'{random.choice(cancellation_reasons)}'"

    rows.append(
        f"('{pid}','{merchant_id}','{wallet_id}','{ba_id}',"
        f"{amount},'THB',{fee},{net},'{status}','dashboard',"
        f"'{desc_esc}','{prov_ref}',{reserved_at},"
        f"{processing_started_at},"
        f"datetime('now'),datetime('now'),"
        f"{completed_at},{failed_at},{cancelled_at},{cancellation_reason})"
    )

    total = amount + fee
    reserve_txid = f"gl-payout-{i:04d}-reserve"
    ledger_rows.extend([
        "INSERT OR IGNORE INTO ledger_entries "
        "(id, transaction_id, account_id, direction, amount, currency, source_type, source_id, description) VALUES "
        f"('le-payout-{i:04d}-reserve-wallet','{reserve_txid}',"
        f"(SELECT id FROM ledger_accounts WHERE account_type='wallet' AND owner_id='{wallet_id}' LIMIT 1),"
        f"'debit',{total},'THB','payout','{pid}','Payout reserved');",
        "INSERT OR IGNORE INTO ledger_entries "
        "(id, transaction_id, account_id, direction, amount, currency, source_type, source_id, description) VALUES "
        f"('le-payout-{i:04d}-reserve-held','{reserve_txid}',"
        f"(SELECT id FROM ledger_accounts WHERE account_type='wallet_reserved' AND owner_id='{wallet_id}' LIMIT 1),"
        f"'credit',{total},'THB','payout','{pid}','Payout reserved');",
    ])
    if status == "completed":
        complete_txid = f"gl-payout-{i:04d}-complete"
        ledger_rows.extend([
            "INSERT OR IGNORE INTO ledger_entries "
            "(id, transaction_id, account_id, direction, amount, currency, source_type, source_id, description) VALUES "
            f"('le-payout-{i:04d}-complete-held','{complete_txid}',"
            f"(SELECT id FROM ledger_accounts WHERE account_type='wallet_reserved' AND owner_id='{wallet_id}' LIMIT 1),"
            f"'debit',{total},'THB','payout','{pid}','Payout completed');",
            "INSERT OR IGNORE INTO ledger_entries "
            "(id, transaction_id, account_id, direction, amount, currency, source_type, source_id, description) VALUES "
            f"('le-payout-{i:04d}-complete-bank','{complete_txid}',"
            "(SELECT id FROM ledger_accounts WHERE account_type='customer_bank' AND owner_id IS NULL LIMIT 1),"
            f"'credit',{amount},'THB','payout','{pid}','Payout external transfer');",
        ])
        if fee > 0:
            ledger_rows.append(
                "INSERT OR IGNORE INTO ledger_entries "
                "(id, transaction_id, account_id, direction, amount, currency, source_type, source_id, description) VALUES "
                f"('le-payout-{i:04d}-complete-platform','{complete_txid}',"
                "(SELECT id FROM ledger_accounts WHERE account_type='wallet' AND owner_id='wallet__platform__' LIMIT 1),"
                f"'credit',{fee},'THB','payout','{pid}','Platform fee on payout');"
            )
    elif status in ("failed", "cancelled"):
        release_txid = f"gl-payout-{i:04d}-release"
        ledger_rows.extend([
            "INSERT OR IGNORE INTO ledger_entries "
            "(id, transaction_id, account_id, direction, amount, currency, source_type, source_id, description) VALUES "
            f"('le-payout-{i:04d}-release-held','{release_txid}',"
            f"(SELECT id FROM ledger_accounts WHERE account_type='wallet_reserved' AND owner_id='{wallet_id}' LIMIT 1),"
            f"'debit',{total},'THB','payout','{pid}','Payout reserve released');",
            "INSERT OR IGNORE INTO ledger_entries "
            "(id, transaction_id, account_id, direction, amount, currency, source_type, source_id, description) VALUES "
            f"('le-payout-{i:04d}-release-wallet','{release_txid}',"
            f"(SELECT id FROM ledger_accounts WHERE account_type='wallet' AND owner_id='{wallet_id}' LIMIT 1),"
            f"'credit',{total},'THB','payout','{pid}','Payout funds returned');",
        ])

    # Events for all statuses
    if status == "pending":
        for ev_type, ev_status, offset in [("created","pending","-180 minutes")]:
            eid = f"evt-payout-{i:04d}-{ev_type}"
            evt_rows.append(f"('{eid}','{pid}','{ev_type}','{ev_status}','Payout event',datetime('now','{offset}'))")
    elif status == "processing":
        for ev_type, ev_status, offset in [("created","pending","-180 minutes"),("processing","processing","-120 minutes")]:
            eid = f"evt-payout-{i:04d}-{ev_type}"
            evt_rows.append(f"('{eid}','{pid}','{ev_type}','{ev_status}','Payout event',datetime('now','{offset}'))")
    elif status == "completed":
        for ev_type, ev_status, offset in [("created","pending","-180 minutes"),("processing","processing","-120 minutes"),("completed","completed","-60 minutes")]:
            eid = f"evt-payout-{i:04d}-{ev_type}"
            evt_rows.append(f"('{eid}','{pid}','{ev_type}','{ev_status}','Payout event',datetime('now','{offset}'))")
    elif status == "failed":
        for ev_type, ev_status, offset in [("created","pending","-180 minutes"),("processing","processing","-120 minutes"),("failed","failed","-30 minutes")]:
            eid = f"evt-payout-{i:04d}-{ev_type}"
            evt_rows.append(f"('{eid}','{pid}','{ev_type}','{ev_status}','Payout event',datetime('now','{offset}'))")
    elif status == "cancelled":
        for ev_type, ev_status, offset in [("created","pending","-180 minutes"),("cancelled","cancelled","-60 minutes")]:
            eid = f"evt-payout-{i:04d}-{ev_type}"
            evt_rows.append(f"('{eid}','{pid}','{ev_type}','{ev_status}','Payout event',datetime('now','{offset}'))")

sql = (
    "INSERT OR IGNORE INTO payouts (id,merchant_id,wallet_id,merchant_bank_account_id,"
    "amount,currency,fee_amount,net_amount,status,source,"
    "description,provider_transfer_id,reserved_at,"
    "processing_started_at,"
    "created_at,updated_at,"
    "completed_at,failed_at,cancelled_at,cancellation_reason) VALUES\n" +
    ",\n".join(rows) + ";\n\n"
)

if evt_rows:
    sql += (
        "INSERT OR IGNORE INTO payout_events (id,payout_id,event_type,status,description,created_at) VALUES\n" +
        ",\n".join(evt_rows) + ";\n"
    )

sql += "\n" + "\n".join(ledger_rows) + "\n"

with open("$PAYOUT_SQL_FILE", "w") as f:
    f.write(sql)
PYEOF3

  pushd "$REPO_ROOT/apps/api" > /dev/null
  d1_execute --file="$PAYOUT_SQL_FILE" --json > /dev/null 2>&1 \
    && pass "$SEED_PAYOUTS payouts inserted" \
    || fail "Payout insert failed; SQL kept at $PAYOUT_SQL_FILE"
  popd > /dev/null
  rm -f "$PAYOUT_SQL_FILE"
fi

# ━━━ Phase 7: Webhook Endpoints + Deliveries ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo -e "\n${CYAN}━━━ Phase 7: Webhook Endpoints + Deliveries ━━━${NC}"

# Clean up old generated webhook endpoints to avoid the 5-per-integration cap
EXISTING_HOOKS=$(curl -s \
  "$BROPAY/v1/merchant/webhook-endpoints?integration_id=$INTEGRATION_ID" \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN")
echo "$EXISTING_HOOKS" | json "
import sys, json
d = json.load(sys.stdin)
for h in d.get('data', []):
    url = h.get('url','')
    if 'webhook.site' in url or 'callback-' in url:
        print(h.get('id',''))
" 2>/dev/null | while read -r HOOK_ID; do
  [ -n "$HOOK_ID" ] && curl -s "$BROPAY/v1/merchant/webhook-endpoints/$HOOK_ID" -X DELETE \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN" > /dev/null
done

TS=$(date +%s)

# Active endpoint — all events
WH_ACTIVE_RES=$(curl -s "$BROPAY/v1/merchant/webhook-endpoints" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"integration_id\":\"$INTEGRATION_ID\",\"url\":\"https://callbacks.merchant.example/payments/callback-active-$TS\",\"subscribed_events\":[\"payment.created\",\"payment.completed\",\"payment.failed\",\"settlement.created\",\"settlement.completed\",\"payout.created\",\"payout.completed\"],\"description\":\"Primary endpoint\"}")
WH_ACTIVE_ID=$(echo "$WH_ACTIVE_RES" | json \
  "print(json.load(sys.stdin).get('data',{}).get('id',''))")

# Paused — payment.completed only, disabled
WH_PAUSED_RES=$(curl -s "$BROPAY/v1/merchant/webhook-endpoints" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"integration_id\":\"$INTEGRATION_ID\",\"url\":\"https://callbacks.merchant.example/payments/callback-paused-$TS\",\"subscribed_events\":[\"payment.completed\"],\"description\":\"Paused endpoint\"}")
WH_PAUSED_ID=$(echo "$WH_PAUSED_RES" | json \
  "print(json.load(sys.stdin).get('data',{}).get('id',''))")

if [ -n "$WH_PAUSED_ID" ]; then
  curl -s "$BROPAY/v1/merchant/webhook-endpoints/$WH_PAUSED_ID" -X PUT \
    -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
    -d '{"is_active":0}' > /dev/null
fi

# Failing endpoint
WH_FAIL_RES=$(curl -s "$BROPAY/v1/merchant/webhook-endpoints" -X POST \
  -H "$OWNER" -H "$MERCH" -H "$ORIGIN" -H "$CT" \
  -d "{\"integration_id\":\"$INTEGRATION_ID\",\"url\":\"https://callbacks.merchant.example/payments/callback-retry-$TS\",\"subscribed_events\":[\"payment.created\",\"payment.completed\",\"payment.failed\",\"payment.expired\",\"payment.cancelled\",\"settlement.created\",\"settlement.completed\",\"settlement.failed\",\"payout.created\",\"payout.completed\",\"payout.failed\"],\"description\":\"Retry endpoint\"}")
WH_FAIL_ID=$(echo "$WH_FAIL_RES" | json \
  "print(json.load(sys.stdin).get('data',{}).get('id',''))")

[ -n "$WH_ACTIVE_ID" ] && pass "Active endpoint: ${WH_ACTIVE_ID:0:16}…" || fail "Active webhook endpoint creation failed"
[ -n "$WH_PAUSED_ID" ] && pass "Paused endpoint: ${WH_PAUSED_ID:0:16}…" || fail "Paused webhook endpoint creation failed"
[ -n "$WH_FAIL_ID" ]   && pass "Failing endpoint: ${WH_FAIL_ID:0:16}…" || fail "Failing webhook endpoint creation failed"

pushd "$REPO_ROOT/apps/api" > /dev/null
d1_execute --json \
  --command "DELETE FROM webhook_events WHERE merchant_id='$MERCHANT_ID' AND payload LIKE '%\"sequence\"%'" \
  > /dev/null 2>&1 || fail "Could not clean old generated webhook events"
popd > /dev/null

# Bulk-insert webhook_events + webhook_deliveries via SQL
if [ -n "$WH_ACTIVE_ID" ] || [ -n "$WH_FAIL_ID" ]; then
  WH_SQL_FILE="$(mktemp -t bropay-webhook-events).sql"

  python3 << PYEOF4
import uuid, random, json

random.seed(123)
WEBHOOK_EVENT_TOTAL = int("$SEED_WEBHOOK_EVENTS")

merchant_id = "$MERCHANT_ID"
integration_id = "$INTEGRATION_ID"
wh_active = "$WH_ACTIVE_ID"
wh_fail = "$WH_FAIL_ID"
wh_paused = "$WH_PAUSED_ID"

event_types = [
    "payment.created","payment.completed","payment.failed",
    "settlement.created","settlement.completed",
    "payout.created","payout.completed",
]
delivery_statuses = ["delivered"]*15 + ["failed"]*8 + ["retrying"]*5 + ["permanently_failed"]*2

evt_rows = []
del_rows = []

for i in range(WEBHOOK_EVENT_TOTAL):
    eid = str(uuid.uuid4())
    etype = random.choice(event_types)
    payload = json.dumps({"event": etype, "sequence": i}).replace("'","''")
    ref_id = str(uuid.uuid4())

    evt_rows.append(
        f"('{eid}','{integration_id}','{merchant_id}','{etype}',"
        f"'{payload}','1','{ref_id}','event')"
    )

    endpoints = [ep for ep in [wh_active, wh_fail] if ep]
    for ep_id in endpoints:
        did = str(uuid.uuid4())
        dstatus = random.choice(delivery_statuses)
        attempts = 1 if dstatus == "delivered" else random.randint(1,3)
        last_attempt = "datetime('now', '-" + str(random.randint(1,120)) + " minutes')"
        del_rows.append(
            f"('{did}','{eid}','{ep_id}','{dstatus}',{attempts},3,"
            f"{last_attempt},datetime('now'))"
        )

sql = ""
for r in evt_rows:
    sql += (
        "INSERT INTO webhook_events (id,integration_id,merchant_id,event_type,"
        "payload,payload_version,reference_id,reference_type) VALUES " + r + ";\n"
    )
for r in del_rows:
    sql += (
        "INSERT INTO webhook_deliveries (id,webhook_event_id,endpoint_id,status,"
        "attempt_count,max_attempts,last_attempt_at,updated_at) VALUES " + r + ";\n"
    )

with open("$WH_SQL_FILE", "w") as f:
    f.write(sql)
PYEOF4

  pushd "$REPO_ROOT/apps/api" > /dev/null
  WH_OUT=$(d1_execute --file="$WH_SQL_FILE" 2>&1) && \
    pass "Webhook events + deliveries inserted" || {
      echo "$WH_OUT" | tail -8
      fail "Webhook delivery insert failed; SQL kept at $WH_SQL_FILE"
    }
  popd > /dev/null
  echo "$WH_OUT" | grep -q "ERROR\|Error" || rm -f "$WH_SQL_FILE"
fi

# ━━━ Phase 8: Backdate timestamps ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo -e "\n${CYAN}━━━ Phase 8: Backdate timestamps (90-day spread) ━━━${NC}"

pushd "$REPO_ROOT/apps/api" > /dev/null
d1_execute \
  --file="$REPO_ROOT/scripts/seed/backdate.sql" \
  --json > /dev/null 2>&1 \
  && pass "Timestamps backdated" \
  || fail "Backdate SQL failed"
popd > /dev/null

# ━━━ Phase 9: Rebuild wallet projections from GL + reconcile ━━━━━━━━━━━━━━━━

echo -e "\n${CYAN}━━━ Phase 9: GL wallet projection rebuild + reconcile ━━━${NC}"

BALANCE_SQL_FILE="$(mktemp -t bropay-wallet-gl-rebuild).sql"
cat > "$BALANCE_SQL_FILE" << 'BALSQL'
UPDATE wallets
SET
  available_balance = COALESCE((
    SELECT SUM(CASE WHEN le.direction = 'credit' THEN le.amount ELSE -le.amount END)
    FROM ledger_accounts la
    LEFT JOIN ledger_entries le ON le.account_id = la.id
    WHERE la.account_type = 'wallet'
      AND la.owner_id = wallets.id
  ), 0),
  reserved_balance = COALESCE((
    SELECT SUM(CASE WHEN le.direction = 'credit' THEN le.amount ELSE -le.amount END)
    FROM ledger_accounts la
    LEFT JOIN ledger_entries le ON le.account_id = la.id
    WHERE la.account_type = 'wallet_reserved'
      AND la.owner_id = wallets.id
  ), 0),
  updated_at = datetime('now');
BALSQL

pushd "$REPO_ROOT/apps/api" > /dev/null
d1_execute --file="$BALANCE_SQL_FILE" --json > /dev/null 2>&1 \
  && pass "Wallet balances rebuilt from GL" \
  || fail "Wallet balance rebuild from GL failed"
popd > /dev/null
rm -f "$BALANCE_SQL_FILE"

RECON_RES=$(curl -s "$BROPAY/v1/admin/cron/reconcile-wallets" -X POST \
  -H "$ADMIN" -H "$ORIGIN")
RECON_MISMATCHED=$(echo "$RECON_RES" | json \
  "print(json.load(sys.stdin).get('data',{}).get('mismatched_count','ERR'))")
RECON_HAS_VIOLATIONS=$(echo "$RECON_RES" | json \
  "print(json.load(sys.stdin).get('data',{}).get('gl_invariants',{}).get('hasViolations','ERR'))")

if [ "$RECON_MISMATCHED" != "0" ] || [ "$RECON_HAS_VIOLATIONS" != "False" ]; then
  echo "$RECON_RES" | python3 -m json.tool 2>/dev/null || echo "$RECON_RES"
  fail "Reconcile gate failed (mismatched_count=$RECON_MISMATCHED, hasViolations=$RECON_HAS_VIOLATIONS)"
fi
pass "Reconcile gate passed (mismatched_count=0, gl_invariants.hasViolations=false)"

# ━━━ Phase 10: Consistency audit ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo -e "\n${CYAN}━━━ Phase 10: Seed consistency audit ━━━${NC}"

AUDIT_SQL="
WITH
wallet_projection AS (
  SELECT
    w.id,
    w.available_balance,
    w.reserved_balance,
    COALESCE((
      SELECT SUM(CASE WHEN le.direction = 'credit' THEN le.amount ELSE -le.amount END)
      FROM ledger_accounts la
      LEFT JOIN ledger_entries le ON le.account_id = la.id
      WHERE la.account_type = 'wallet'
        AND la.owner_id = w.id
    ), 0) AS computed_available,
    COALESCE((
      SELECT SUM(CASE WHEN le.direction = 'credit' THEN le.amount ELSE -le.amount END)
      FROM ledger_accounts la
      LEFT JOIN ledger_entries le ON le.account_id = la.id
      WHERE la.account_type = 'wallet_reserved'
        AND la.owner_id = w.id
    ), 0) AS computed_reserved
  FROM wallets w
),
settlement_totals AS (
  SELECT
    settlement_id,
    SUM(amount) AS gross_amount,
    SUM(fee_amount) AS fee_amount,
    SUM(net_amount) AS net_amount,
    COUNT(*) AS transaction_count
  FROM settlement_items
  GROUP BY settlement_id
),
gl_totals AS (
  SELECT
    transaction_id,
    SUM(CASE WHEN direction = 'debit' THEN amount ELSE 0 END) AS debit_amount,
    SUM(CASE WHEN direction = 'credit' THEN amount ELSE 0 END) AS credit_amount
  FROM ledger_entries
  GROUP BY transaction_id
),
checks(check_name, failures) AS (
  VALUES
    ('foreign_key_violations', (
      SELECT COUNT(*) FROM pragma_foreign_key_check
    )),
    ('unbalanced_gl_transactions', (
      SELECT COUNT(*) FROM gl_totals WHERE debit_amount <> credit_amount
    )),
    ('wallet_projection_mismatch', (
      SELECT COUNT(*) FROM wallet_projection
      WHERE available_balance <> computed_available OR reserved_balance <> computed_reserved
    )),
    ('settlement_item_total_mismatch', (
      SELECT COUNT(*) FROM settlements s
      JOIN settlement_totals st ON st.settlement_id = s.id
      WHERE s.gross_amount <> st.gross_amount
         OR s.fee_amount <> st.fee_amount
         OR s.net_amount <> st.net_amount
         OR s.transaction_count <> st.transaction_count
    )),
    ('succeeded_pi_missing_gl', (
      SELECT COUNT(*) FROM payment_intents pi
      WHERE pi.merchant_id = '$MERCHANT_ID'
        AND pi.status = 'succeeded'
        AND NOT EXISTS (
          SELECT 1
          FROM ledger_entries le
          JOIN ledger_accounts la ON la.id = le.account_id
          WHERE le.source_type = 'payment_intent'
            AND le.source_id = pi.id
            AND la.account_type = 'provider_clearing'
            AND le.direction = 'credit'
        )
    )),
    ('completed_settlement_missing_gl', (
      SELECT COUNT(*) FROM settlements s
      WHERE s.status = 'completed'
        AND NOT EXISTS (
          SELECT 1 FROM ledger_entries le
          WHERE le.source_type = 'settlement'
            AND le.source_id = s.id
        )
    )),
    ('missing_customers', (
      SELECT CASE WHEN COUNT(*) >= $SEED_CUSTOMERS THEN 0 ELSE $SEED_CUSTOMERS - COUNT(*) END
      FROM customer_merchants
      WHERE merchant_id = '$MERCHANT_ID'
    )),
    ('missing_payment_intents', (
      SELECT CASE WHEN COUNT(*) >= $SEED_PIS THEN 0 ELSE $SEED_PIS - COUNT(*) END
      FROM payment_intents
      WHERE merchant_id = '$MERCHANT_ID'
    )),
    ('missing_payouts', (
      SELECT CASE WHEN COUNT(*) >= $SEED_PAYOUTS THEN 0 ELSE $SEED_PAYOUTS - COUNT(*) END
      FROM payouts
      WHERE merchant_id = '$MERCHANT_ID'
    )),
    ('missing_webhook_endpoints', (
      SELECT CASE WHEN COUNT(*) >= 3 THEN 0 ELSE 3 - COUNT(*) END
      FROM webhook_endpoints
      WHERE merchant_id = '$MERCHANT_ID'
        AND substr(url, 1, length('https://callbacks.merchant.example/payments/callback-')) = 'https://callbacks.merchant.example/payments/callback-'
    )),
    ('missing_reseller_sub_merchants', (
      SELECT CASE WHEN COUNT(*) >= 3 THEN 0 ELSE 3 - COUNT(*) END
      FROM merchants
      WHERE reseller_id = '$RESELLER_ID'
    )),
    ('missing_reseller_commission_entries', (
      SELECT CASE WHEN COUNT(*) >= 1 THEN 0 ELSE 1 END
      FROM ledger_entries le
      JOIN ledger_accounts la ON la.id = le.account_id
      WHERE le.source_type = 'settlement'
        AND le.direction = 'credit'
        AND la.account_type = 'wallet'
        AND la.owner_id = '$RESELLER_WALLET_ID'
    ))
)
SELECT check_name, failures FROM checks;
"

pushd "$REPO_ROOT/apps/api" > /dev/null
AUDIT_JSON=$(d1_execute --json --command "$AUDIT_SQL")
popd > /dev/null

AUDIT_FAILURES=$(echo "$AUDIT_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
rows = d[0].get('results', []) if d else []
bad = [row for row in rows if int(row.get('failures') or 0) != 0]
for row in bad:
    print(f\"{row['check_name']}={row['failures']}\")
")

if [ -n "$AUDIT_FAILURES" ]; then
  echo "$AUDIT_FAILURES"
  fail "Seed consistency audit failed"
fi
pass "Seed consistency audit passed"

# ━━━ Summary ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

echo -e "\n${CYAN}━━━ Final counts ━━━${NC}"

pushd "$REPO_ROOT/apps/api" > /dev/null
python3 << PYEOF5
import subprocess, json, sys
import os

persist_to = os.environ.get("SEED_WRANGLER_PERSIST_TO")
persist_args = ["--persist-to", persist_to] if persist_to else []

def count(table, where=""):
    sql = f"SELECT COUNT(*) as n FROM {table}" + (f" WHERE {where}" if where else "")
    result = subprocess.run(
        ["wrangler","d1","execute","bropay-db","--local",*persist_args,"--json","--command",sql],
        capture_output=True, text=True, cwd="$REPO_ROOT/apps/api"
    )
    try:
        d = json.loads(result.stdout)
        return d[0]["results"][0]["n"] if d else "?"
    except:
        return "?"

mid = "$MERCHANT_ID"
reseller_id = "res-demo-reseller-0000-000000000001"
reseller_wallet_id = "wall-demo-reseller-0000-000000000001"
# (label, table, where) — label is for display; table is the real SQL table.
rows = [
    ("customers",              "customers",               f"id IN (SELECT customer_id FROM customer_merchants WHERE merchant_id='{mid}')"),
    ("customer_bank_accounts", "customer_bank_accounts",  ""),
    ("payment_intents",        "payment_intents",         f"merchant_id='{mid}'"),
    ("GL payment movements",   "ledger_entries",          f"source_type='payment_intent' AND source_id IN (SELECT id FROM payment_intents WHERE merchant_id='{mid}')"),
    ("settlements",            "settlements",             f"merchant_id='{mid}'"),
    ("payouts",                "payouts",                 f"merchant_id='{mid}'"),
    ("webhook_endpoints",      "webhook_endpoints",       f"merchant_id='{mid}'"),
    ("webhook_deliveries",     "webhook_deliveries",      ""),
    ("reseller sub-merchants", "merchants",               f"reseller_id='{reseller_id}'"),
    ("reseller commission GL", "ledger_entries",          f"source_type='settlement' AND direction='credit' AND account_id IN (SELECT id FROM ledger_accounts WHERE account_type='wallet' AND owner_id='{reseller_wallet_id}')"),
]

print("")
for label, table, where in rows:
    n = count(table, where)
    print(f"  {label:<30} {n}")
print("")
PYEOF5
popd > /dev/null

echo -e "${GREEN}━━━ Realistic seed complete ━━━${NC}"
echo ""
