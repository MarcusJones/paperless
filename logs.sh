#!/usr/bin/env bash
# logs.sh — tail logs from all containers simultaneously with color-coded prefixes
#
# Each container gets a unique color for easy visual scanning.
# Press Ctrl-C to stop.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ANSI color codes — one per container, cycling if more containers than colors
COLORS=(
  "31"  # red
  "32"  # green
  "33"  # yellow
  "34"  # blue
  "35"  # magenta
  "36"  # cyan
  "91"  # bright red
  "92"  # bright green
  "93"  # bright yellow
  "94"  # bright blue
)
RESET="\033[0m"

echo "=== Tailing logs (Ctrl-C to stop) ==="
echo ""

# Kill all background log jobs cleanly on exit
trap 'kill $(jobs -p) 2>/dev/null; echo ""; echo "Logs closed."' EXIT INT TERM

i=0
for c in "${CONTAINERS[@]}"; do
  if docker container inspect "$c" &>/dev/null 2>&1; then
    color="${COLORS[$((i % ${#COLORS[@]}))]}"
    docker logs -f --tail=20 "$c" 2>&1 | sed "s/^/$(printf "\033[${color};1m")[${c}]$(printf "\033[0m") /" &
    (( ++i ))
  else
    echo "  SKIP: $c not found (run ./setup.sh)"
  fi
done

# Wait for all background jobs — exits when Ctrl-C fires the trap above
wait
