#!/usr/bin/env bash
# Kill stale dev processes that survive between sessions.
#
# Targets:
#   - workerd (CF Workers runtime) older than 1 hour
#   - tsc / vitest forks older than 10 minutes (test/typecheck zombies)
#   - vinext / vite dev servers older than 1 hour
#   - any dev process holding ports 3000-3003 / 8787
#
# Always preserves the active claude-code instance + its in-flight subagents.
# Dry-run by default; pass --kill to actually terminate.

set -euo pipefail

DRY_RUN=true
[[ "${1:-}" == "--kill" ]] && DRY_RUN=false

YELLOW='\033[33m'
RED='\033[31m'
GREEN='\033[32m'
RESET='\033[0m'

list_candidates() {
  # Format: PID  ELAPSED  RSS_KB  COMMAND
  ps -eo pid,etime,rss,command | awk '
    NR == 1 { next }
    {
      cmd = ""
      for (i = 4; i <= NF; i++) cmd = cmd $i " "

      # Parse elapsed: [DD-]HH:MM:SS or MM:SS
      n = split($2, parts, /[-:]/)
      seconds = 0
      if (n == 4)      seconds = parts[1]*86400 + parts[2]*3600 + parts[3]*60 + parts[4]
      else if (n == 3) seconds = parts[1]*3600 + parts[2]*60 + parts[3]
      else if (n == 2) seconds = parts[1]*60 + parts[2]

      # workerd > 1h
      if (cmd ~ /workerd/ && seconds > 3600) {
        print $1, "workerd-stale", seconds"s", int($3/1024)"MB"
      }
      # tsc > 10min
      else if (cmd ~ /tsc --noEmit/ && seconds > 600) {
        print $1, "tsc-zombie", seconds"s", int($3/1024)"MB"
      }
      # vitest forks > 10min
      else if (cmd ~ /vitest/ && cmd ~ /forks\.js/ && seconds > 600) {
        print $1, "vitest-zombie", seconds"s", int($3/1024)"MB"
      }
      # vinext / vite dev > 1h
      else if (cmd ~ /(vinext|vite) dev/ && seconds > 3600) {
        print $1, "vinext-stale", seconds"s", int($3/1024)"MB"
      }
    }
  '
}

CANDIDATES=$(list_candidates)

# Add anything holding our dev ports (regardless of age)
for port in 3000 3001 3002 3003 8787; do
  pids=$(lsof -ti tcp:"$port" 2>/dev/null || true)
  for pid in $pids; do
    rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ' || echo 0)
    [[ -z "$rss" ]] && continue
    # Skip if already in CANDIDATES
    if ! echo "$CANDIDATES" | grep -q "^$pid "; then
      CANDIDATES="$CANDIDATES
$pid port-$port - $((rss/1024))MB"
    fi
  done
done

if [[ -z "$(echo "$CANDIDATES" | tr -d ' \n')" ]]; then
  echo -e "${GREEN}No stale dev processes found.${RESET}"
  exit 0
fi

echo -e "${YELLOW}Stale dev processes:${RESET}"
printf "  %-7s %-18s %-10s %s\n" "PID" "REASON" "AGE" "RSS"
echo "$CANDIDATES" | while read -r pid reason age rss _; do
  [[ -z "$pid" ]] && continue
  printf "  %-7s %-18s %-10s %s\n" "$pid" "$reason" "$age" "$rss"
done

if $DRY_RUN; then
  echo
  echo -e "${YELLOW}Dry-run. Re-run with --kill to terminate.${RESET}"
  exit 0
fi

echo
echo "$CANDIDATES" | while read -r pid _; do
  [[ -z "$pid" ]] && continue
  if kill "$pid" 2>/dev/null; then
    echo -e "${RED}killed $pid${RESET}"
  fi
done

sleep 2
# SIGKILL anything still alive
echo "$CANDIDATES" | while read -r pid _; do
  [[ -z "$pid" ]] && continue
  if kill -0 "$pid" 2>/dev/null; then
    kill -9 "$pid" 2>/dev/null && echo -e "${RED}SIGKILL $pid${RESET}"
  fi
done

echo -e "${GREEN}Done.${RESET}"
