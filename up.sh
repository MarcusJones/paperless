#!/usr/bin/env bash
# up.sh — Bring up the compose stack.
#
# Usage: ./up.sh          (detached, same as docker compose up -d)
#
# All extra args are forwarded to docker compose up.
# Default: detached mode (-d). Pass -d explicitly or omit — same result.
#
# Note: Ollama is now a service in the compose stack (with nvidia GPU passthrough).
# If you have a host Ollama process still running on port 11434, stop it first:
#   pkill ollama

set -euo pipefail

COMPOSE_ARGS=()

for arg in "$@"; do
  COMPOSE_ARGS+=("$arg")
done

# Default to detached if no -d / --detach flag provided
if [[ ! " ${COMPOSE_ARGS[*]} " =~ " -d " ]] && [[ ! " ${COMPOSE_ARGS[*]} " =~ " --detach " ]]; then
  COMPOSE_ARGS+=("-d")
fi

docker compose up "${COMPOSE_ARGS[@]}"

echo ""
echo "  Paperless stack is up:"
echo ""
echo "    Dashboard       →  http://localhost:5000"
echo "    Paperless-ngx   →  http://localhost:8000"
echo "    AI Next         →  http://localhost:3000"
echo "    Vision OCR      →  http://localhost:8080"
echo "    Open WebUI      →  http://localhost:3001"
echo "    Dozzle (logs)   →  http://localhost:9999"
echo "    Ollama API      →  http://localhost:11434"
echo ""
echo "  Document pipeline tags — remember the flow:"
echo ""
echo "    classification-pending   →  Applied automatically on ingest. Fires"
echo "                                webhook to paperless-ai-next (qwen3:14b)"
echo "                                for tags/type/correspondent/title."
echo "    processed                →  Added by paperless-ai-next after classify."
echo "                                Workflow strips classification-pending."
echo "    ocr-pending              →  Apply MANUALLY (UI, single or bulk-edit)"
echo "                                when Tesseract text is bad. Triggers"
echo "                                paperless-gpt (qwen2.5vl:7b) vision OCR."
echo "                                Will RE-CLASSIFY everything after OCR."
echo "                                Beware: ~90s per page, blocks GPU."
echo ""
echo "  Default path:  ingest → classification-pending → processed   (fast, no GPU)"
echo "  Opt-in path:   + ocr-pending → vision OCR → re-classify      (slow, GPU)"
echo ""
