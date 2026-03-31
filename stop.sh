#!/usr/bin/env bash
# stop.sh — stop the stack without losing data
#
# Stops containers in reverse start order (consumers before dependencies),
# then kills the Ollama process.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "=== Stopping Paperless-ngx ==="
echo ""

echo "→ Stopping containers..."
# Reverse the start order so consumers stop before their dependencies
for (( i=${#CONTAINERS[@]}-1; i>=0; i-- )); do
  c="${CONTAINERS[$i]}"
  if docker container inspect "$c" &>/dev/null 2>&1; then
    docker stop "$c" >/dev/null 2>&1 && echo "  ↳ $c" || echo "  ↳ $c (already stopped)"
  fi
done

echo "→ Stopping Ollama..."
if pkill -f 'ollama serve' 2>/dev/null; then
  echo "  ↳ Stopped"
else
  echo "  ↳ Was not running"
fi

echo ""
echo "✓ Stack stopped. Run ./start.sh to resume."
echo ""
