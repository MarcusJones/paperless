#!/usr/bin/env bash
# logs.sh — tail logs from all containers simultaneously
#
# Each line is prefixed with the container name for easy filtering.
# Press Ctrl-C to stop.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "=== Tailing logs (Ctrl-C to stop) ==="
echo ""

# Kill all background log jobs cleanly on exit
trap 'kill $(jobs -p) 2>/dev/null; echo ""; echo "Logs closed."' EXIT INT TERM

for c in "${CONTAINERS[@]}"; do
  if docker container inspect "$c" &>/dev/null 2>&1; then
    # --tail=20 so we don't flood the terminal with history on start
    docker logs -f --tail=20 "$c" 2>&1 | sed "s/^/[${c}] /" &
  else
    echo "  SKIP: $c not found (run ./setup.sh)"
  fi
done

# Wait for all background jobs — exits when Ctrl-C fires the trap above
wait
