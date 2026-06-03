#!/bin/bash
# Shared E2E helpers — source after SCRIPT_DIR is set.
# Git Bash on Windows often has `py -3` but no `python3` on PATH.

if ! command -v python3 >/dev/null 2>&1; then
  if command -v python >/dev/null 2>&1; then
    python3() { python "$@"; }
  elif command -v py >/dev/null 2>&1; then
    python3() { py -3 "$@"; }
  else
    echo "e2e: Python 3 required (install python.org or ensure py/python is on PATH)" >&2
    exit 127
  fi
fi

# Resolve wrangler: global PATH, then apps/api node_modules (incl. .cmd on Windows).
# Requires REPO_ROOT when global wrangler is absent.
wrangler_bin() {
  if command -v wrangler >/dev/null 2>&1; then
    command -v wrangler
    return 0
  fi
  if [ -n "${REPO_ROOT:-}" ]; then
    local bin="$REPO_ROOT/apps/api/node_modules/.bin"
    if [ -f "$bin/wrangler" ]; then
      echo "$bin/wrangler"
      return 0
    fi
    if [ -f "$bin/wrangler.cmd" ]; then
      echo "$bin/wrangler.cmd"
      return 0
    fi
    if [ -f "$bin/wrangler.CMD" ]; then
      echo "$bin/wrangler.CMD"
      return 0
    fi
  fi
  return 1
}

# Run SQL on local D1; return 0 when wrangler reports success for all blocks.
d1_local_ok() {
  local cmd="$1" wr out
  wr=$(wrangler_bin) || return 127
  out=$(cd "${REPO_ROOT}/apps/api" && "$wr" d1 execute bropay-db --local --command "$cmd" --json 2>&1) || {
    echo "$out" >&2
    return 1
  }
  echo "$out" | python3 -c "
import sys, json
try:
    blocks = json.load(sys.stdin)
    ok = bool(blocks) and all(b.get('success') for b in blocks)
except Exception as exc:
    print('e2e: invalid wrangler JSON: ' + str(exc), file=sys.stderr)
    ok = False
sys.exit(0 if ok else 1)
"
}

# Like d1_local_ok but never fails the caller (traps / best-effort cleanup).
d1_local_quiet() {
  d1_local_ok "$@" >/dev/null 2>&1 || true
}

# Print wallet_deposit status|provider_payment_id (or not_found). stderr on wrangler errors.
d1_local_deposit_row() {
  local deposit_id=$1
  local wr out
  wr=$(wrangler_bin) || {
    echo "e2e: wrangler not found (install globally or pnpm install in apps/api)" >&2
    return 127
  }
  out=$(cd "${REPO_ROOT}/apps/api" && "$wr" d1 execute bropay-db --local --command \
    "SELECT id, status, provider_payment_id FROM wallet_deposits WHERE id = '$deposit_id'" --json 2>&1) || {
    echo "$out" >&2
    return 1
  }
  echo "$out" | python3 -c "
import sys, json
blocks = json.load(sys.stdin)
rows = blocks[0].get('results', []) if blocks else []
if not rows:
    print('not_found')
else:
    r = rows[0]
    pp = r.get('provider_payment_id')
    print(str(r.get('status', '')) + '|' + ('null' if pp is None else str(pp)))
"
}

# Safe under set -e: never abort on bad JSON / python errors.
json_has_data() {
  echo "$1" | python3 -c "
import sys, json
try:
    print('True' if 'data' in json.load(sys.stdin) else 'False')
except Exception:
    print('False')
" 2>/dev/null || echo "False"
}
