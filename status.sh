#!/usr/bin/env bash
# status.sh — show stack health at a glance
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "=== Paperless-ngx status ==="
echo ""

# ── Ollama ────────────────────────────────────────────────────────────────────
echo "Ollama"
OLLAMA_PID=$(pgrep -f 'ollama serve' 2>/dev/null || true)
if [[ -n "$OLLAMA_PID" ]]; then
  echo "  process  UP (PID $OLLAMA_PID)"
  if curl -sf http://localhost:11434/api/tags &>/dev/null; then
    echo "  api      reachable at http://localhost:11434"
    MODELS=$(ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' | paste -sd', ' 2>/dev/null || true)
    echo "  models   ${MODELS:-none pulled yet}"
  else
    echo "  api      WARNING: process running but API not responding"
    echo "           Fix: pkill -f 'ollama serve' && OLLAMA_HOST=0.0.0.0 ollama serve &"
  fi
else
  echo "  process  NOT running — run ./start.sh"
fi

echo ""

# ── Containers ────────────────────────────────────────────────────────────────
echo "Containers"
for c in "${CONTAINERS[@]}"; do
  if ! docker container inspect "$c" &>/dev/null 2>&1; then
    printf "  %-28s  MISSING (run ./setup.sh)\n" "$c"
    continue
  fi
  STATUS=$(docker inspect --format='{{.State.Status}}' "$c" 2>/dev/null)
  case "$STATUS" in
    running) printf "  %-28s  UP\n"      "$c" ;;
    exited)  printf "  %-28s  STOPPED\n" "$c" ;;
    *)       printf "  %-28s  %s\n"      "$c" "$STATUS" ;;
  esac
done

echo ""

# ── Service URLs ──────────────────────────────────────────────────────────────
echo "Services"
echo "  Paperless-ngx  →  http://localhost:${PAPERLESS_PORT}"
echo "  Paperless-AI   →  http://localhost:${AI_PORT}"
echo "  Paperless-GPT  →  http://localhost:${GPT_PORT}"
echo "  Ollama         →  http://localhost:11434"
echo ""
