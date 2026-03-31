#!/usr/bin/env bash
# config.sh — all non-secret configuration for the Paperless-ngx stack
#
# Every other script sources this file. To change a setting, edit here.
# Secrets (API token, Dropbox username) live in .env — see .env.example.
#
# Usage (in every script):
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/config.sh"

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ── Secrets (.env) ────────────────────────────────────────────────────────────
ENV_FILE="$SCRIPT_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: .env not found."
  echo "  cp $SCRIPT_DIR/.env.example $SCRIPT_DIR/.env"
  echo "  Then fill in: PAPERLESS_API_TOKEN, DROPBOX_USER, SECRET_KEY, PG_PASSWORD"
  exit 1
fi
# shellcheck source=.env
source "$ENV_FILE"

# ── Required secrets validation ───────────────────────────────────────────────
# Fail loudly here rather than letting containers start with empty/wrong values.
_missing=()
[[ -z "${PAPERLESS_API_TOKEN:-}" ]] && _missing+=("PAPERLESS_API_TOKEN")
[[ -z "${DROPBOX_USER:-}"        ]] && _missing+=("DROPBOX_USER")
[[ -z "${SECRET_KEY:-}"          ]] && _missing+=("SECRET_KEY")
[[ -z "${PG_PASSWORD:-}"         ]] && _missing+=("PG_PASSWORD")
if [[ ${#_missing[@]} -gt 0 ]]; then
  echo "ERROR: Missing required values in .env: ${_missing[*]}"
  echo "  See .env.example for instructions."
  exit 1
fi
unset _missing

# ── Locale ────────────────────────────────────────────────────────────────────
TIMEZONE="Europe/Vienna"
OCR_LANGUAGES="deu+eng"

# ── Ports ─────────────────────────────────────────────────────────────────────
PAPERLESS_PORT=8000
AI_PORT=3000
GPT_PORT=8080

# ── Docker ────────────────────────────────────────────────────────────────────
NETWORK="paperless"

# Ordered start sequence (dependencies first)
CONTAINERS=(
  paperless-redis
  paperless-db
  paperless-tika
  paperless-gotenberg
  paperless
  paperless-ai
  paperless-gpt
)

VOLUMES=(paperless-pgdata paperless-data paperless-media)

# ── Database ──────────────────────────────────────────────────────────────────
PG_DB="paperless"
PG_USER="paperless"
# PG_PASSWORD comes from .env

# ── Paperless admin ───────────────────────────────────────────────────────────
# Must match the username you create with: docker exec -it paperless python3 manage.py createsuperuser
PAPERLESS_ADMIN_USER="admin"

# ── Ollama ────────────────────────────────────────────────────────────────────
OLLAMA_MODEL="llama3.1"
OLLAMA_VISION_MODEL="minicpm-v:8b"

# ── Paths ─────────────────────────────────────────────────────────────────────
# Dropbox folder on the Windows side — documents dropped here are auto-ingested.
# inotify does not work across the WSL2 bridge, so polling is used instead.
CONSUME_DIR="/mnt/c/Users/${DROPBOX_USER}/Dropbox/paperless-consume"
EXPORT_DIR="$HOME/paperless-ngx/export"
AI_DATA_DIR="$HOME/paperless-ai-data"

# Dropbox backup destination
BACKUP_DIR="/mnt/c/Users/${DROPBOX_USER}/Dropbox/paperless-backup"

# ── Polling ───────────────────────────────────────────────────────────────────
# Must be >0 for /mnt/c/ paths (inotify broken on WSL2 bridge)
CONSUMER_POLLING=10
