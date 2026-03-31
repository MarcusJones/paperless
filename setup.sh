#!/usr/bin/env bash
# setup.sh — first-time stack creation
#
# Creates all containers, starts Ollama, pulls models, and writes the
# paperless-ai config. Safe to re-run — existing containers are skipped.
#
# After first run:
#   1. docker exec -it paperless python3 manage.py createsuperuser
#   2. Log in ->username ->My Profile ->copy API token
#   3. Paste token into .env ->PAPERLESS_API_TOKEN
#   4. docker rm -f paperless-gpt paperless-ai && ./setup.sh   (rebuild with the real token)
#   5. ./bootstrap.sh              (create taxonomy)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

echo "=== Paperless-ngx setup ==="
echo ""

# ── Pre-flight checks ─────────────────────────────────────────────────────────
if ! command -v ollama &>/dev/null; then
  echo "ERROR: Ollama not installed."
  echo "  curl -fsSL https://ollama.com/install.sh | sh"
  echo "  Then disable systemd so we can manage it directly:"
  echo "  sudo systemctl stop ollama && sudo systemctl disable ollama"
  echo "  sudo rm -rf /usr/share/ollama/.ollama"
  exit 1
fi

if ! command -v docker &>/dev/null; then
  echo "ERROR: Docker not found. Install Docker Engine (not Desktop) in WSL2."
  exit 1
fi

if [[ "${PAPERLESS_API_TOKEN}" == "PASTE_YOUR_TOKEN_HERE" ]]; then
  echo "NOTE: API token is still a placeholder."
  echo "  paperless-ai and paperless-gpt will not authenticate until you set it."
  echo "  See the Next steps at the end of this script."
  echo ""
fi

# ── Directories ───────────────────────────────────────────────────────────────
echo "--> Creating directories..."
mkdir -p "$CONSUME_DIR" "$EXPORT_DIR" "$AI_DATA_DIR"
echo "  -->  $CONSUME_DIR"
echo "  -->  $EXPORT_DIR"
echo "  -->  $AI_DATA_DIR"

# ── Ollama ────────────────────────────────────────────────────────────────────
echo ""
echo "--> Starting Ollama..."

# Kill the systemd service if it somehow got re-enabled — it uses a different
# model directory which causes models to appear and vanish unpredictably.
if systemctl is-active ollama &>/dev/null 2>&1; then
  echo "  -->  Stopping systemd ollama (ghost-model prevention)..."
  sudo systemctl stop ollama
  sudo systemctl disable ollama 2>/dev/null || true
fi

if ! curl -sf http://localhost:11434/api/tags &>/dev/null; then
  nohup env OLLAMA_HOST=0.0.0.0 OLLAMA_MAX_LOADED_MODELS=2 OLLAMA_KEEP_ALIVE=30m ollama serve &>/dev/null &
  echo -n "  -->  Waiting for Ollama to be ready"
  for i in $(seq 1 10); do
    sleep 2
    if curl -sf http://localhost:11434/api/tags &>/dev/null; then
      echo " OK"
      break
    fi
    echo -n "."
    if [[ $i -eq 10 ]]; then
      echo ""
      echo "ERROR: Ollama did not start within 20s. Check: ollama serve"
      exit 1
    fi
  done
else
  echo "  -->  Already running (PID $(pgrep -f 'ollama serve' || echo '?'))"
fi

for model in "$OLLAMA_MODEL" "$OLLAMA_VISION_MODEL"; do
  if ollama list 2>/dev/null | grep -q "^${model}"; then
    echo "  -->  $model already present"
  else
    echo "  -->  Pulling $model (this may take several minutes on first run)..."
    ollama pull "$model"
  fi
done

# ── paperless-ai config ───────────────────────────────────────────────────────
echo ""
echo "--> Writing paperless-ai config..."

# These are the values we manage. The setup wizard may add additional keys
# (e.g. SETUP_USERNAME, SETUP_PASSWORD) that we must preserve.
_MANAGED_KEYS=(
  PAPERLESS_API_URL PAPERLESS_API_TOKEN PAPERLESS_NGX_URL PAPERLESS_URL
  PAPERLESS_HOST PAPERLESS_TOKEN PAPERLESS_APIKEY PAPERLESS_USERNAME
  AI_PROVIDER OLLAMA_API_URL OLLAMA_MODEL OLLAMA_MODEL_NAME
  SCAN_INTERVAL ADD_AI_PROCESSED_TAG AI_PROCESSED_TAG_NAME
  USE_PROMPT_TAGS PROMPT_TAGS
  RESTRICT_TO_EXISTING_TAGS RESTRICT_TO_EXISTING_DOCUMENT_TYPES
  RESTRICT_TO_EXISTING_CORRESPONDENTS USE_EXISTING_DATA
  PROCESS_PREDEFINED_DOCUMENTS PAPERLESS_AI_INITIAL_SETUP
  TAGS ACTIVATE_TAGGING ACTIVATE_DOCUMENT_TYPE ACTIVATE_CORRESPONDENTS ACTIVATE_TITLE
)

# Build the managed config block
_MANAGED_CONFIG="PAPERLESS_API_URL=http://paperless:8000
PAPERLESS_API_TOKEN=${PAPERLESS_API_TOKEN}
PAPERLESS_NGX_URL=http://paperless:8000
PAPERLESS_URL=http://paperless:8000
PAPERLESS_HOST=http://paperless:8000
PAPERLESS_TOKEN=${PAPERLESS_API_TOKEN}
PAPERLESS_APIKEY=${PAPERLESS_API_TOKEN}
PAPERLESS_USERNAME=${PAPERLESS_ADMIN_USER}
AI_PROVIDER=ollama
OLLAMA_API_URL=http://172.17.0.1:11434
OLLAMA_MODEL=${OLLAMA_MODEL}
OLLAMA_MODEL_NAME=${OLLAMA_MODEL}
SCAN_INTERVAL=*/5 * * * *
ADD_AI_PROCESSED_TAG=yes
AI_PROCESSED_TAG_NAME=ai-processed
USE_PROMPT_TAGS=yes
PROMPT_TAGS=${PROMPT_TAGS}
RESTRICT_TO_EXISTING_TAGS=yes
RESTRICT_TO_EXISTING_DOCUMENT_TYPES=yes
RESTRICT_TO_EXISTING_CORRESPONDENTS=no
USE_EXISTING_DATA=no
PROCESS_PREDEFINED_DOCUMENTS=yes
TAGS=ai-process
PAPERLESS_AI_INITIAL_SETUP=no
ACTIVATE_TAGGING=yes
ACTIVATE_DOCUMENT_TYPE=yes
ACTIVATE_CORRESPONDENTS=yes
ACTIVATE_TITLE=yes"

AI_ENV="$AI_DATA_DIR/.env"
if [[ -f "$AI_ENV" ]]; then
  # Preserve keys written by the setup wizard (anything we don't manage)
  _WIZARD_LINES=""
  while IFS= read -r line; do
    # Skip blanks and comments
    [[ -z "$line" || "$line" == \#* ]] && continue
    key="${line%%=*}"
    # Keep the line only if it's NOT one of our managed keys
    _keep=true
    for mk in "${_MANAGED_KEYS[@]}"; do
      if [[ "$key" == "$mk" ]]; then _keep=false; break; fi
    done
    if $_keep; then _WIZARD_LINES+="$line"$'\n'; fi
  done < "$AI_ENV"
  echo "$_MANAGED_CONFIG" > "$AI_ENV"
  # Append wizard-managed keys (username, password, etc.)
  if [[ -n "$_WIZARD_LINES" ]]; then
    echo "" >> "$AI_ENV"
    echo "# -- Preserved from setup wizard --" >> "$AI_ENV"
    printf '%s' "$_WIZARD_LINES" >> "$AI_ENV"
  fi
  echo "  -->  Updated $AI_ENV (wizard settings preserved)"
else
  echo "$_MANAGED_CONFIG" > "$AI_ENV"
  echo "  -->  Written to $AI_ENV (first run -- complete setup at http://localhost:${AI_PORT}/setup)"
fi

# ── Docker network ────────────────────────────────────────────────────────────
echo ""
echo "--> Docker network..."
if docker network inspect "$NETWORK" &>/dev/null; then
  echo "  -->  $NETWORK already exists"
else
  docker network create "$NETWORK" >/dev/null
  echo "  -->  Created $NETWORK"
fi

# ── Helper: run a container only if it doesn't already exist ──────────────────
create_if_absent() {
  local name="$1"; shift
  if docker container inspect "$name" &>/dev/null 2>&1; then
    echo "  -->  $name already exists — skipping"
    return
  fi
  docker run -d --name "$name" "$@" >/dev/null
  echo "  -->  Created $name"
}

# ── Containers ────────────────────────────────────────────────────────────────
echo ""
echo "--> Creating containers..."

create_if_absent paperless-redis \
  --add-host host.docker.internal:host-gateway \
  --network "$NETWORK" \
  --restart unless-stopped \
  redis:7

create_if_absent paperless-db \
  --add-host host.docker.internal:host-gateway \
  --network "$NETWORK" \
  --restart unless-stopped \
  -e POSTGRES_DB="$PG_DB" \
  -e POSTGRES_USER="$PG_USER" \
  -e POSTGRES_PASSWORD="$PG_PASSWORD" \
  -v paperless-pgdata:/var/lib/postgresql/data \
  postgres:16

create_if_absent paperless-tika \
  --add-host host.docker.internal:host-gateway \
  --network "$NETWORK" \
  --restart unless-stopped \
  apache/tika:latest

create_if_absent paperless-gotenberg \
  --add-host host.docker.internal:host-gateway \
  --network "$NETWORK" \
  --restart unless-stopped \
  gotenberg/gotenberg:8 \
  gotenberg \
  --chromium-disable-javascript=true \
  --chromium-allow-list=file:///tmp/.*

create_if_absent paperless \
  --add-host host.docker.internal:host-gateway \
  --network "$NETWORK" \
  --restart unless-stopped \
  -p "${PAPERLESS_PORT}:8000" \
  -e PAPERLESS_REDIS=redis://paperless-redis:6379 \
  -e PAPERLESS_DBHOST=paperless-db \
  -e PAPERLESS_DBNAME="$PG_DB" \
  -e PAPERLESS_DBUSER="$PG_USER" \
  -e PAPERLESS_DBPASS="$PG_PASSWORD" \
  -e PAPERLESS_TIKA_ENABLED=1 \
  -e PAPERLESS_TIKA_GOTENBERG_ENDPOINT=http://paperless-gotenberg:3000 \
  -e PAPERLESS_TIKA_ENDPOINT=http://paperless-tika:9998 \
  -e PAPERLESS_TIME_ZONE="$TIMEZONE" \
  -e PAPERLESS_OCR_LANGUAGE="$OCR_LANGUAGES" \
  -e PAPERLESS_OCR_MODE=skip \
  -e PAPERLESS_OCR_DESKEW=true \
  -e PAPERLESS_OCR_ROTATE_PAGES=true \
  -e PAPERLESS_OCR_IMAGE_DPI=300 \
  -e PAPERLESS_CONSUMER_POLLING="$CONSUMER_POLLING" \
  -e PAPERLESS_CONSUMER_POLLING_RETRY_COUNT=5 \
  -e PAPERLESS_CONSUMER_POLLING_DELAY=5 \
  -e PAPERLESS_SECRET_KEY="$SECRET_KEY" \
  -v paperless-data:/usr/src/paperless/data \
  -v paperless-media:/usr/src/paperless/media \
  -v "$CONSUME_DIR":/usr/src/paperless/consume \
  -v "$EXPORT_DIR":/usr/src/paperless/export \
  ghcr.io/paperless-ngx/paperless-ngx:latest

create_if_absent paperless-ai \
  --add-host host.docker.internal:host-gateway \
  --network "$NETWORK" \
  --restart unless-stopped \
  -p "${AI_PORT}:3000" \
  -v "$AI_DATA_DIR":/app/data \
  clusterzx/paperless-ai:latest

create_if_absent paperless-gpt \
  --add-host host.docker.internal:host-gateway \
  --network "$NETWORK" \
  --restart unless-stopped \
  -p "${GPT_PORT}:8080" \
  -e PAPERLESS_BASE_URL=http://paperless:8000 \
  -e PAPERLESS_API_TOKEN="$PAPERLESS_API_TOKEN" \
  -e LLM_PROVIDER=ollama \
  -e LLM_MODEL="$OLLAMA_MODEL" \
  -e OLLAMA_HOST=http://host.docker.internal:11434 \
  -e OCR_PROVIDER=llm \
  -e VISION_LLM_PROVIDER=ollama \
  -e VISION_LLM_MODEL="$OLLAMA_VISION_MODEL" \
  -e PAPERLESS_PUBLIC_URL="http://localhost:${PAPERLESS_PORT}" \
  -e AUTO_TAG="" \
  -e MANUAL_TAG="" \
  -e AUTO_OCR_TAG="paperless-gpt-ocr-auto" \
  -e PDF_OCR_TAGGING=true \
  -e PDF_OCR_COMPLETE_TAG=ocr-complete \
  icereed/paperless-gpt:latest

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "[OK] Setup complete"
echo ""
echo "  Paperless-ngx  -->  http://localhost:${PAPERLESS_PORT}"
echo "  Paperless-AI   -->  http://localhost:${AI_PORT}"
echo "  Paperless-GPT  -->  http://localhost:${GPT_PORT}"
echo "  Ollama         -->  http://localhost:11434"
echo ""
echo "Next steps:"
echo "  1. docker exec -it paperless python3 manage.py createsuperuser"
echo "  2. Log in ->username (top-right) ->My Profile ->copy API token"
echo "  3. Paste token into .env ->PAPERLESS_API_TOKEN"
echo "  4. docker rm -f paperless-gpt paperless-ai && ./setup.sh   (rebuild with the real token)"
echo "  5. ./bootstrap.sh              (create tags, types, custom fields)"
echo ""
