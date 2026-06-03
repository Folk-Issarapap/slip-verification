#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

usage() {
  cat <<'USAGE'
Usage:
  pnpm dev:local:stop
  pnpm dev:local:close
  BROPAY_PORT_SLOT=1 pnpm dev:local:stop

Stops local preview processes started by scripts/dev/local-preview.sh for this
worktree. Without BROPAY_PORT_SLOT it stops every recorded preview slot in this
worktree.
USAGE
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

STATE_DIR="${BROPAY_PREVIEW_STATE_DIR:-.bropay-preview}"

if [ ! -d "$STATE_DIR" ]; then
  echo "[preview] No local preview state found."
  exit 0
fi

shopt -s nullglob

state_files=()
if [ -n "${BROPAY_PORT_SLOT:-}" ]; then
  state_files=("$STATE_DIR"/local-preview-slot-"$BROPAY_PORT_SLOT"-pid-*.pids)
else
  state_files=("$STATE_DIR"/local-preview-slot-*-pid-*.pids)
fi

if [ "${#state_files[@]}" -eq 0 ]; then
  echo "[preview] No matching local preview processes recorded."
  exit 0
fi

stopped=0

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
        echo "[preview] Stopping listener on port $port (pid $listener_pid)"
        kill "$listener_pid" 2>/dev/null || true
        stopped=$((stopped + 1))
      fi
    done < <(lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null || true)
  done
}

for state_file in "${state_files[@]}"; do
  while IFS=$'\t' read -r pid ports label; do
    if [ -z "${pid:-}" ]; then
      continue
    fi

    if [ -z "${label:-}" ]; then
      label="$ports"
      ports=""
    fi

    if kill -0 "$pid" 2>/dev/null; then
      echo "[preview] Stopping ${label:-process} (pid $pid)"
      kill "$pid" 2>/dev/null || true
      stopped=$((stopped + 1))
    fi

    if [ -n "${ports:-}" ]; then
      stop_listener_ports "$ports"
    fi
  done < "$state_file"

  rm -f "$state_file"
done

if [ "$stopped" -eq 0 ]; then
  echo "[preview] Recorded preview processes were already stopped."
else
  echo "[preview] Stop signal sent to $stopped process(es)."
fi
