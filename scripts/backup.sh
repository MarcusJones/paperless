#!/usr/bin/env bash
# scripts/backup.sh — export documents and copy the archive to Dropbox
#
# Uses the official document_exporter to export all documents + metadata into
# paperless/export/, then copies the result to a timestamped Dropbox folder.
#
# Run from the repo root on the WSL host:
#   ./scripts/backup.sh
#
# Requires: docker compose up -d (paperless must be running)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load root .env for DROPBOX_USER
ENV_FILE="$REPO_ROOT/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Run from the repo root."
  exit 1
fi
# shellcheck source=../.env
source "$ENV_FILE"

if [[ -z "${DROPBOX_USER:-}" ]]; then
  echo "ERROR: DROPBOX_USER is not set in .env"
  exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DROPBOX_ROOT="/mnt/c/Users/${DROPBOX_USER}/Dropbox"
BACKUP_DIR="${DROPBOX_ROOT}/paperless-backup"
DEST="${BACKUP_DIR}/${TIMESTAMP}"
# Container-internal export path (matches paperless/.env volume mount)
CONTAINER_EXPORT="/usr/src/paperless/export"

echo "=== Paperless-ngx backup ==="
echo ""

# ── Compose stack check ───────────────────────────────────────────────────────
cd "$REPO_ROOT"
if ! docker compose ps paperless --status running 2>/dev/null | grep -q "paperless"; then
  echo "ERROR: paperless container is not running."
  echo "  Start the stack: docker compose up -d"
  exit 1
fi

# ── Export ────────────────────────────────────────────────────────────────────
echo "--> Exporting documents to ${CONTAINER_EXPORT} ..."
docker compose exec paperless document_exporter "${CONTAINER_EXPORT}"
echo "  -> Export written to ./paperless/export/ (bind-mounted from ${CONTAINER_EXPORT})"

# ── Copy to Dropbox ───────────────────────────────────────────────────────────
echo "--> Copying to Dropbox..."
if [[ ! -d "$DROPBOX_ROOT" ]]; then
  echo "ERROR: Dropbox not reachable at $DROPBOX_ROOT"
  echo "  Is Dropbox running on Windows? Is /mnt/c/ mounted?"
  exit 1
fi

mkdir -p "$DEST"
cp -r "${REPO_ROOT}/paperless/export/." "$DEST/"
echo "  -> Backed up to $DEST"

echo ""
echo "[OK] Backup complete: $DEST"
echo ""
