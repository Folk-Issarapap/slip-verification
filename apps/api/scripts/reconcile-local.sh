#!/bin/bash
# One-shot reconciliation check for the local D1 dev database.
# Reports per-wallet drift between available_balance, legacy wallet_ledger_entries
# sum, and the new general-ledger balance.
#
# Usage: bash apps/api/scripts/reconcile-local.sh
# Exits 0 if all wallets are in sync; exits 1 if any wallet has drift.
set -euo pipefail

command -v wrangler >/dev/null 2>&1 || { echo "Error: wrangler is required" >&2; exit 1; }
command -v jq       >/dev/null 2>&1 || { echo "Error: jq is required" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

SQL="
SELECT
  w.id                                                        AS wallet_id,
  CAST(w.available_balance AS INTEGER)                        AS available_balance,
  CAST(COALESCE(
    SUM(CASE WHEN wle.entry_type = 'credit' THEN  wle.amount
             WHEN wle.entry_type = 'debit'  THEN -wle.amount
             ELSE 0 END), 0
  ) AS INTEGER)                                               AS legacy_sum,
  CAST(COALESCE((
    SELECT SUM(CASE WHEN le.direction = 'credit' THEN  le.amount
                    WHEN le.direction = 'debit'  THEN -le.amount
                    ELSE 0 END)
    FROM ledger_entries le
    JOIN ledger_accounts la ON la.id = le.account_id
    WHERE la.account_type = 'wallet' AND la.owner_id = w.id
  ), 0) AS INTEGER)                                           AS gl_balance
FROM wallets w
LEFT JOIN wallet_ledger_entries wle
  ON wle.wallet_id = w.id
  AND wle.entry_type IN ('credit', 'debit')
GROUP BY w.id, w.available_balance
ORDER BY w.id;
"

RAW=$(pushd "$API_DIR" > /dev/null && \
  wrangler d1 execute bropay-db --local --json --command "$SQL" 2>/dev/null; \
  popd > /dev/null)

ROWS=$(echo "$RAW" | jq -r '.[0].results // []')

if [ "$(echo "$ROWS" | jq 'length')" -eq 0 ]; then
  echo "No wallets found — is the local DB seeded?" >&2
  exit 1
fi

# Print table header
printf "%-44s  %18s  %18s  %18s  %12s\n" \
  "wallet_id" "available_balance" "legacy_sum" "gl_balance" "drift"
printf "%-44s  %18s  %18s  %18s  %12s\n" \
  "$(printf '%0.s-' {1..44})" "$(printf '%0.s-' {1..18})" \
  "$(printf '%0.s-' {1..18})" "$(printf '%0.s-' {1..18})" \
  "$(printf '%0.s-' {1..12})"

HAS_DRIFT=0
while IFS= read -r ROW; do
  wid=$(echo "$ROW" | jq -r '.wallet_id')
  avail=$(echo "$ROW" | jq -r '.available_balance')
  legacy=$(echo "$ROW" | jq -r '.legacy_sum')
  gl=$(echo "$ROW" | jq -r '.gl_balance')
  # drift = available_balance - gl_balance (GL is the new source of truth)
  drift=$(( avail - gl ))
  [ "$drift" -ne 0 ] && HAS_DRIFT=1
  printf "%-44s  %18d  %18d  %18d  %12d\n" "$wid" "$avail" "$legacy" "$gl" "$drift"
done < <(echo "$ROWS" | jq -c '.[]')

echo ""
if [ "$HAS_DRIFT" -eq 0 ]; then
  echo "All wallets in sync."
else
  echo "DRIFT DETECTED — run pnpm fresh to reseed with matching ledger entries." >&2
  exit 1
fi
