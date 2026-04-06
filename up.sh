#!/usr/bin/env bash
# up.sh — Start Ollama on the WSL host (if not running), then bring up the compose stack.
#
# Usage: ./scripts/up.sh          (detached, same as docker compose up -d)
#        ./scripts/up.sh --no-ollama   (skip Ollama check, just compose up)
#
# All extra args are forwarded to docker compose up.
# Default: detached mode (-d). Pass -d explicitly or omit — same result.

set -euo pipefail

SKIP_OLLAMA=false
COMPOSE_ARGS=()

for arg in "$@"; do
  if [[ "$arg" == "--no-ollama" ]]; then
    SKIP_OLLAMA=true
  else
    COMPOSE_ARGS+=("$arg")
  fi
done

# Default to detached if no -d / --detach flag provided
if [[ ! " ${COMPOSE_ARGS[*]} " =~ " -d " ]] && [[ ! " ${COMPOSE_ARGS[*]} " =~ " --detach " ]]; then
  COMPOSE_ARGS+=("-d")
fi

if [[ "$SKIP_OLLAMA" == false ]]; then
  if pgrep -x ollama > /dev/null 2>&1; then
    echo "Ollama already running."
  else
    echo "Starting Ollama (OLLAMA_HOST=0.0.0.0)..."
    OLLAMA_HOST=0.0.0.0 ollama serve > /tmp/ollama.log 2>&1 &
    # Give it a moment to bind before compose services try to connect
    sleep 2
    echo "Ollama started (logs: /tmp/ollama.log)"
  fi
fi

docker compose up "${COMPOSE_ARGS[@]}"

echo ""
echo "  Paperless stack is up:"
echo ""
echo "    Paperless-ngx   →  http://localhost:8000"
echo "    AI Next         →  http://localhost:3000"
echo "    Vision OCR      →  http://localhost:8080"
echo "    Open WebUI      →  http://localhost:3001"
echo "    Dozzle (logs)   →  http://localhost:9999"
echo ""
