#!/usr/bin/env bash
# remove.sh — full teardown including all Docker data (DESTRUCTIVE)
#
# Stops and removes all containers, the Docker network, and named volumes.
# Your files in $EXPORT_DIR and $CONSUME_DIR are NOT touched.
# After this, run ./setup.sh to start fresh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "=== Paperless-ngx full teardown ==="
echo ""
echo "This will permanently delete:"
echo "  Containers : ${CONTAINERS[*]}"
echo "  Network    : $NETWORK"
echo "  Volumes    : ${VOLUMES[*]}"
echo ""
echo "Your files in $EXPORT_DIR and $CONSUME_DIR are NOT deleted."
echo ""
read -rp "Type 'yes' to confirm: " confirm
if [[ "$confirm" != "yes" ]]; then
  echo "Aborted."
  exit 0
fi
echo ""

echo "--> Stopping containers..."
for (( i=${#CONTAINERS[@]}-1; i>=0; i-- )); do
  c="${CONTAINERS[$i]}"
  docker stop "$c" 2>/dev/null && echo "  -->  stopped $c" || true
done

echo "--> Removing containers..."
for c in "${CONTAINERS[@]}"; do
  docker rm "$c" 2>/dev/null && echo "  -->  removed $c" || true
done

echo "--> Removing network..."
docker network rm "$NETWORK" 2>/dev/null && echo "  -->  removed $NETWORK" || true

echo "--> Removing volumes..."
for v in "${VOLUMES[@]}"; do
  docker volume rm "$v" 2>/dev/null && echo "  -->  removed $v" || true
done

echo "--> Stopping Ollama..."
pkill -f 'ollama serve' 2>/dev/null && echo "  -->  Stopped" || echo "  -->  Was not running"

echo ""
echo "[OK] Fully removed. Run ./setup.sh to start fresh."
echo ""
