#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'USAGE'
Usage:
  pnpm dev:local:admin
  pnpm dev:local:merchant
  pnpm dev:local:reseller
  pnpm dev:local:checkout
  pnpm dev:local:all
  pnpm dev:local -- admin merchant

Starts the local API plus the selected frontend app(s).

Default ports when free:
  API       http://localhost:8787
  Inspector 127.0.0.1:9229
  Admin     http://localhost:3000
  Merchant  http://localhost:3001
  Reseller  http://localhost:3002
  Checkout  http://localhost:3003

Optional:
  BROPAY_PORT_SLOT=1 pnpm dev:local:admin
  BROPAY_API_PORT=8788 BROPAY_ADMIN_PORT=3010 pnpm dev:local:admin

Port slots are blocks of 10:
  slot 0: API 8787, inspector 9229, apps 3000-3003
  slot 1: API 8797, inspector 9230, apps 3010-3013
  slot 2: API 8807, inspector 9231, apps 3020-3023

Close preview servers with:
  pnpm dev:local:stop
  BROPAY_PORT_SLOT=1 pnpm dev:local:stop
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

if [ "$#" -eq 0 ]; then
  set -- admin
fi

BASE_API_PORT="${BROPAY_BASE_API_PORT:-8787}"
BASE_FRONTEND_PORT="${BROPAY_BASE_FRONTEND_PORT:-3000}"
PORT_SLOT_WIDTH="${BROPAY_PORT_SLOT_WIDTH:-10}"
PREVIEW_HOST="${BROPAY_PREVIEW_HOST:-127.0.0.1}"

frontends=()
start_api=0
explicit_api_target=0

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

for target in "$@"; do
  case "$target" in
    api)
      start_api=1
      explicit_api_target=1
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
      echo "Unknown local preview target: $target" >&2
      usage >&2
      exit 2
      ;;
  esac
done

port_in_use() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

frontend_lock_info() {
  local frontend="$1"
  local lock_file="apps/${frontend}/.vinext/dev/lock.json"
  local app_dir="${ROOT_DIR}/apps/${frontend}"

  if [ ! -f "$lock_file" ]; then
    return 1
  fi

  node - "$lock_file" "$app_dir" <<'NODE'
const fs = require("node:fs")

const [lockFile, appDir] = process.argv.slice(2)

try {
  const lock = JSON.parse(fs.readFileSync(lockFile, "utf8"))
  if (lock.cwd !== appDir || !lock.pid || !lock.port) {
    process.exit(1)
  }

  const appUrl = lock.appUrl || `http://${lock.hostname || "127.0.0.1"}:${lock.port}`
  process.stdout.write(`${lock.pid}\t${lock.port}\t${appUrl}`)
} catch {
  process.exit(1)
}
NODE
}

reuse_running_frontends() {
  local -a pending=()
  local -a reused=()
  local frontend
  local pid
  local port
  local app_url
  local info

  for frontend in "${frontends[@]}"; do
    if info="$(frontend_lock_info "$frontend" 2>/dev/null)"; then
      IFS=$'\t' read -r pid port app_url <<< "$info"
      if [ -n "$port" ] && port_in_use "$port"; then
        reused+=("$frontend:${app_url}")
        continue
      fi
    fi
    pending+=("$frontend")
  done

  frontends=()
  if [ "${#pending[@]}" -gt 0 ]; then
    frontends=("${pending[@]}")
  fi

  if [ "${#reused[@]}" -gt 0 ]; then
    for info in "${reused[@]}"; do
      frontend="${info%%:*}"
      app_url="${info#*:}"
      echo "[preview] Reusing existing ${frontend} preview at ${app_url}"
    done
  fi

  if [ "${#frontends[@]}" -eq 0 ] && [ "${#reused[@]}" -gt 0 ] && [ "$explicit_api_target" -eq 0 ]; then
    start_api=0
  fi
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

candidate_api_port() {
  local slot="$1"
  echo $((BASE_API_PORT + slot * PORT_SLOT_WIDTH))
}

candidate_frontend_port() {
  local frontend="$1"
  local slot="$2"
  echo $((BASE_FRONTEND_PORT + slot * PORT_SLOT_WIDTH + $(frontend_offset "$frontend")))
}

slot_available() {
  local slot="$1"
  local frontend
  local index

  if [ "$start_api" -eq 1 ] && port_in_use "$(candidate_api_port "$slot")"; then
    return 1
  fi

  for ((index = 0; index < ${#frontends[@]}; index++)); do
    frontend="${frontends[$index]}"
    if port_in_use "$(candidate_frontend_port "$frontend" "$slot")"; then
      return 1
    fi
  done

  return 0
}

reuse_running_frontends

if [ "$start_api" -eq 0 ] && [ "${#frontends[@]}" -eq 0 ]; then
  echo "[preview] All requested frontend previews are already running."
  exit 0
fi

explicit_port_config=0
for var_name in BROPAY_API_PORT BROPAY_ADMIN_PORT BROPAY_MERCHANT_PORT BROPAY_RESELLER_PORT BROPAY_CHECKOUT_PORT; do
  if [ -n "${!var_name:-}" ]; then
    explicit_port_config=1
  fi
done

if [ -n "${BROPAY_PORT_SLOT:-}" ]; then
  PORT_SLOT="$BROPAY_PORT_SLOT"
elif [ "$explicit_port_config" -eq 0 ]; then
  PORT_SLOT=0
  while ! slot_available "$PORT_SLOT"; do
    PORT_SLOT=$((PORT_SLOT + 1))
    if [ "$PORT_SLOT" -gt 20 ]; then
      echo "Could not find a free local preview port slot." >&2
      exit 1
    fi
  done
else
  PORT_SLOT=0
fi

API_PORT="${BROPAY_API_PORT:-$(candidate_api_port "$PORT_SLOT")}"
API_INSPECTOR_PORT="${BROPAY_API_INSPECTOR_PORT:-$((9229 + PORT_SLOT))}"
ADMIN_PORT="${BROPAY_ADMIN_PORT:-$(candidate_frontend_port admin "$PORT_SLOT")}"
MERCHANT_PORT="${BROPAY_MERCHANT_PORT:-$(candidate_frontend_port merchant "$PORT_SLOT")}"
RESELLER_PORT="${BROPAY_RESELLER_PORT:-$(candidate_frontend_port reseller "$PORT_SLOT")}"
CHECKOUT_PORT="${BROPAY_CHECKOUT_PORT:-$(candidate_frontend_port checkout "$PORT_SLOT")}"
API_URL="${NEXT_PUBLIC_API_URL:-http://localhost:${API_PORT}}"
CHECKOUT_URL="${NEXT_PUBLIC_CHECKOUT_URL:-http://localhost:${CHECKOUT_PORT}}"

frontend_port() {
  case "$1" in
    admin) echo "$ADMIN_PORT" ;;
    merchant) echo "$MERCHANT_PORT" ;;
    reseller) echo "$RESELLER_PORT" ;;
    checkout) echo "$CHECKOUT_PORT" ;;
    *)
      echo "Unknown frontend: $1" >&2
      exit 2
      ;;
  esac
}

assert_port_free() {
  local label="$1"
  local port="$2"

  if port_in_use "$port"; then
    cat >&2 <<MSG
Port $port for $label is already in use.
Use a different slot, for example:
  BROPAY_PORT_SLOT=$((PORT_SLOT + 1)) pnpm dev:local:admin
MSG
    exit 1
  fi
}

dev_var_value() {
  local key="$1"
  grep -E "^${key}=" apps/api/.dev.vars 2>/dev/null | tail -n 1 | cut -d= -f2-
}

upsert_dev_var() {
  local key="$1"
  local value="$2"
  local mode="${3:-always}"
  local current
  local tmp

  if [ ! -f apps/api/.dev.vars ]; then
    return
  fi

  current="$(dev_var_value "$key" || true)"
  if [ "$mode" = "local-only" ] &&
    [ -n "$current" ] &&
    [[ "$current" != http://localhost:* ]] &&
    [[ "$current" != http://127.0.0.1:* ]]; then
    return
  fi

  tmp="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN { updated = 0 }
    $0 ~ "^" key "=" {
      print key "=" value
      updated = 1
      next
    }
    { print }
    END {
      if (updated == 0) {
        print key "=" value
      }
    }
  ' apps/api/.dev.vars > "$tmp"
  mv "$tmp" apps/api/.dev.vars
}

sync_preview_dev_vars() {
  local origins
  local frontend
  local origin
  local port

  if [ ! -f apps/api/.dev.vars ]; then
    cat >&2 <<'MSG'
[preview] apps/api/.dev.vars is missing. Run `pnpm setup:codex` before preview.
MSG
    return
  fi

  origins="$(dev_var_value ALLOWED_ORIGINS || true)"
  for frontend in admin merchant reseller checkout; do
    port="$(frontend_port "$frontend")"
    for origin in "http://localhost:${port}" "http://${PREVIEW_HOST}:${port}"; do
      if [ "$origin" = "http://0.0.0.0:${port}" ]; then
        continue
      fi
      case ",$origins," in
        *",$origin,"*) ;;
        *)
          if [ -n "$origins" ]; then
            origins="${origins},${origin}"
          else
            origins="$origin"
          fi
          ;;
      esac
    done
  done

  upsert_dev_var ALLOWED_ORIGINS "$origins"
  upsert_dev_var GOOGLE_REDIRECT_URI "http://localhost:${API_PORT}/v1/auth/google/callback" local-only
  upsert_dev_var WEB_URL "http://localhost:${ADMIN_PORT}" local-only
  upsert_dev_var MERCHANT_WEB_URL "http://localhost:${MERCHANT_PORT}" local-only
  upsert_dev_var ASSETS_URL "http://localhost:${API_PORT}/assets" local-only
}

if [ "$start_api" -eq 1 ]; then
  assert_port_free api "$API_PORT"
  if [ "$API_INSPECTOR_PORT" != "0" ]; then
    assert_port_free api-inspector "$API_INSPECTOR_PORT"
  fi
fi

for ((frontend_index = 0; frontend_index < ${#frontends[@]}; frontend_index++)); do
  frontend="${frontends[$frontend_index]}"
  assert_port_free "$frontend" "$(frontend_port "$frontend")"
done

sync_preview_dev_vars

pids=()
pid_ports=()
STATE_DIR="${BROPAY_PREVIEW_STATE_DIR:-.bropay-preview}"
STATE_FILE="${STATE_DIR}/local-preview-slot-${PORT_SLOT}-pid-$$.pids"

mkdir -p "$STATE_DIR"
: > "$STATE_FILE"

stop_listener_ports() {
  local ports="$1"
  local port
  local listener_pid
  local port_values
  local port_index

  IFS=',' read -r -a port_values <<< "$ports"
  for ((port_index = 0; port_index < ${#port_values[@]}; port_index++)); do
    port="${port_values[$port_index]}"
    if [ -z "$port" ] || [ "$port" = "0" ]; then
      continue
    fi

    while IFS= read -r listener_pid; do
      if [ -n "$listener_pid" ] && kill -0 "$listener_pid" 2>/dev/null; then
        kill "$listener_pid" 2>/dev/null || true
      fi
    done < <(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
  done
}

cleanup() {
  local pid
  local index
  trap - INT TERM EXIT
  for ((index = 0; index < ${#pids[@]}; index++)); do
    pid="${pids[$index]}"
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
    fi
    stop_listener_ports "${pid_ports[$index]}"
  done
  wait 2>/dev/null || true
  rm -f "$STATE_FILE"
}

start_process() {
  local label="$1"
  local ports="$2"
  shift 2
  echo "[preview] Starting $label"
  "$@" &
  pids+=("$!")
  pid_ports+=("$ports")
  printf '%s\t%s\t%s\n' "$!" "$ports" "$label" >> "$STATE_FILE"
}

trap cleanup INT TERM EXIT

echo "[preview] Using port slot ${PORT_SLOT}"

if [ "$start_api" -eq 1 ]; then
  start_process "api on http://localhost:${API_PORT}" "${API_PORT},${API_INSPECTOR_PORT}" \
    env WRANGLER_WRITE_LOGS="${WRANGLER_WRITE_LOGS:-false}" \
    pnpm --filter api exec wrangler dev \
      --ip "$PREVIEW_HOST" \
      --port "$API_PORT" \
      --inspector-ip "$PREVIEW_HOST" \
      --inspector-port "$API_INSPECTOR_PORT" \
      --test-scheduled
fi

for ((frontend_index = 0; frontend_index < ${#frontends[@]}; frontend_index++)); do
  frontend="${frontends[$frontend_index]}"
  frontend_port_value="$(frontend_port "$frontend")"
  start_process "$frontend on http://localhost:${frontend_port_value} with NEXT_PUBLIC_API_URL=${API_URL}" "$frontend_port_value" \
    env NEXT_PUBLIC_API_URL="$API_URL" NEXT_PUBLIC_CHECKOUT_URL="$CHECKOUT_URL" \
    pnpm --filter "$frontend" exec vinext dev --hostname "$PREVIEW_HOST" --port "$frontend_port_value"
done

if [ "${#pids[@]}" -eq 0 ]; then
  usage
  exit 0
fi

echo "[preview] Press Ctrl-C to stop all local preview processes."
wait
