#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'USAGE'
Usage:
  pnpm test:codex:lifecycle
  pnpm test:codex:lifecycle -- merchant
  BROPAY_PORT_SLOT=9 pnpm test:codex:lifecycle -- admin merchant

Starts a local preview, waits for API/frontend HTTP readiness, closes it through
pnpm dev:local:stop, and verifies the preview ports are free afterward.

Defaults:
  target: admin
  slot:   9
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -eq 0 ]; then
  set -- admin
fi

PORT_SLOT="${BROPAY_PORT_SLOT:-9}"
BASE_API_PORT="${BROPAY_BASE_API_PORT:-8787}"
BASE_FRONTEND_PORT="${BROPAY_BASE_FRONTEND_PORT:-3000}"
PORT_SLOT_WIDTH="${BROPAY_PORT_SLOT_WIDTH:-10}"
API_PORT="${BROPAY_API_PORT:-$((BASE_API_PORT + PORT_SLOT * PORT_SLOT_WIDTH))}"
API_INSPECTOR_PORT="${BROPAY_API_INSPECTOR_PORT:-$((9229 + PORT_SLOT))}"
LOG_DIR="${BROPAY_PREVIEW_STATE_DIR:-.bropay-preview}"
LOG_FILE="${LOG_DIR}/lifecycle-smoke-slot-${PORT_SLOT}.log"
TIMEOUT_SECONDS="${BROPAY_LIFECYCLE_TIMEOUT_SECONDS:-90}"

frontends=()
start_api=0
runner_pid=""

add_frontend() {
  local candidate="$1"
  local existing
  local index
  for ((index = 0; index < ${#frontends[@]}; index++)); do
    existing="${frontends[$index]}"
    if [ "$existing" = "$candidate" ]; then
      return
    fi
  done
  frontends+=("$candidate")
}

frontend_offset() {
  case "$1" in
    admin) echo 0 ;;
    merchant) echo 1 ;;
    reseller) echo 2 ;;
    checkout) echo 3 ;;
    *)
      echo "Unknown frontend: $1" >&2
      exit 2
      ;;
  esac
}

frontend_port() {
  local frontend="$1"
  echo $((BASE_FRONTEND_PORT + PORT_SLOT * PORT_SLOT_WIDTH + $(frontend_offset "$frontend")))
}

for target in "$@"; do
  case "$target" in
    api)
      start_api=1
      ;;
    admin|merchant|reseller|checkout)
      add_frontend "$target"
      start_api=1
      ;;
    all)
      add_frontend admin
      add_frontend merchant
      add_frontend reseller
      add_frontend checkout
      start_api=1
      ;;
    *)
      echo "Unknown lifecycle smoke target: $target" >&2
      usage >&2
      exit 2
      ;;
  esac
done

wait_for_api() {
  local attempt
  for ((attempt = 1; attempt <= TIMEOUT_SECONDS; attempt++)); do
    if [ -n "$runner_pid" ] && ! kill -0 "$runner_pid" 2>/dev/null; then
      echo "[lifecycle] Preview runner exited before API became ready; see ${LOG_FILE}" >&2
      return 1
    fi

    if curl -fsS "http://127.0.0.1:${API_PORT}/" 2>/dev/null | grep -q '"status":"ok"'; then
      echo "[lifecycle] API ready on http://127.0.0.1:${API_PORT}"
      return 0
    fi
    sleep 1
  done

  echo "[lifecycle] API did not become ready within ${TIMEOUT_SECONDS}s" >&2
  return 1
}

wait_for_frontend() {
  local frontend="$1"
  local port="$2"
  local attempt
  local code

  for ((attempt = 1; attempt <= TIMEOUT_SECONDS; attempt++)); do
    if [ -n "$runner_pid" ] && ! kill -0 "$runner_pid" 2>/dev/null; then
      echo "[lifecycle] Preview runner exited before $frontend responded; see ${LOG_FILE}" >&2
      return 1
    fi

    code="$(curl -sS -L -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null || true)"
    case "$code" in
      2*|3*|4*)
        echo "[lifecycle] $frontend responded with HTTP $code on http://127.0.0.1:${port}"
        return 0
        ;;
    esac
    sleep 1
  done

  echo "[lifecycle] $frontend did not respond within ${TIMEOUT_SECONDS}s" >&2
  return 1
}

assert_port_closed() {
  local label="$1"
  local port="$2"

  if [ -z "$port" ] || [ "$port" = "0" ]; then
    return
  fi

  if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "[lifecycle] Port $port for $label is still listening after close" >&2
    lsof -nP -iTCP:"$port" -sTCP:LISTEN >&2 || true
    return 1
  fi
}

cleanup() {
  set +e
  BROPAY_PORT_SLOT="$PORT_SLOT" pnpm dev:local:stop >/dev/null 2>&1
  if [ -n "$runner_pid" ] && kill -0 "$runner_pid" 2>/dev/null; then
    kill "$runner_pid" 2>/dev/null || true
  fi
}

mkdir -p "$LOG_DIR"
: > "$LOG_FILE"
trap cleanup EXIT

echo "[lifecycle] Starting preview slot ${PORT_SLOT}; log: ${LOG_FILE}"
BROPAY_PORT_SLOT="$PORT_SLOT" bash scripts/dev/local-preview.sh "$@" > "$LOG_FILE" 2>&1 &
runner_pid="$!"

if [ "$start_api" -eq 1 ]; then
  wait_for_api
fi

for ((frontend_index = 0; frontend_index < ${#frontends[@]}; frontend_index++)); do
  frontend="${frontends[$frontend_index]}"
  wait_for_frontend "$frontend" "$(frontend_port "$frontend")"
done

echo "[lifecycle] Closing preview slot ${PORT_SLOT}"
BROPAY_PORT_SLOT="$PORT_SLOT" pnpm dev:local:stop
wait "$runner_pid" 2>/dev/null || true
runner_pid=""

assert_port_closed api "$API_PORT"
assert_port_closed api-inspector "$API_INSPECTOR_PORT"
for ((frontend_index = 0; frontend_index < ${#frontends[@]}; frontend_index++)); do
  frontend="${frontends[$frontend_index]}"
  assert_port_closed "$frontend" "$(frontend_port "$frontend")"
done

trap - EXIT
rm -f "$LOG_FILE"
echo "[lifecycle] OK"
