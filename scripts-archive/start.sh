#!/usr/bin/env bash
# start.sh — start the full stack (daily use)
#
# Starts Ollama if not running, then starts all containers.
# Run ./setup.sh first if containers don't exist yet.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "=== Starting Paperless-ngx ==="
echo ""

# ── Ollama ────────────────────────────────────────────────────────────────────
# Stop the systemd service if it crept back — it uses a separate model store.
if systemctl is-active ollama &>/dev/null 2>&1; then
  sudo systemctl stop ollama
fi

if curl -sf http://localhost:11434/api/tags &>/dev/null; then
  echo "--> Ollama already running (PID $(pgrep -f 'ollama serve' || echo '?'))"
else
  echo "--> Starting Ollama..."
  nohup env OLLAMA_HOST=0.0.0.0 OLLAMA_MAX_LOADED_MODELS=2 OLLAMA_KEEP_ALIVE=30m ollama serve &>/dev/null &
  echo -n "  -->  Waiting"
  for i in $(seq 1 10); do
    sleep 2
    if curl -sf http://localhost:11434/api/tags &>/dev/null; then
      echo " OK"
      break
    fi
    echo -n "."
    if [[ $i -eq 10 ]]; then
      echo ""
      echo "ERROR: Ollama did not start. Run: OLLAMA_HOST=0.0.0.0 ollama serve"
      exit 1
    fi
  done
fi

# ── Containers ────────────────────────────────────────────────────────────────
echo "--> Starting containers..."
for c in "${CONTAINERS[@]}"; do
  if ! docker container inspect "$c" &>/dev/null; then
    echo "  ERROR: $c not found — run ./setup.sh first"
    exit 1
  fi
  docker start "$c" >/dev/null
  echo "  -->  $c"
done

echo ""
echo "[OK] Stack is up"
echo ""
echo "  Paperless-ngx  -->  http://localhost:${PAPERLESS_PORT}"
echo "  Paperless-AI   -->  http://localhost:${AI_PORT}"
echo "  Paperless-GPT  -->  http://localhost:${GPT_PORT}"
echo ""
