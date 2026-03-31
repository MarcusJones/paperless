#!/usr/bin/env bash
# backup.sh — export documents and copy the archive to Dropbox
#
# Runs document_exporter inside the paperless container, then copies
# the result to $BACKUP_DIR (timestamped subfolder on the Windows side).
#
# Requires the paperless container to be running.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
DEST="${BACKUP_DIR}/${TIMESTAMP}"

echo "=== Paperless-ngx backup ==="
echo ""

# ── Container check ───────────────────────────────────────────────────────────
CONTAINER_STATUS=$(docker inspect --format='{{.State.Status}}' paperless 2>/dev/null || echo "missing")
if [[ "$CONTAINER_STATUS" != "running" ]]; then
  echo "ERROR: paperless container is not running (status: $CONTAINER_STATUS)."
  echo "  Start the stack first: ./start.sh"
  exit 1
fi

# ── Export ────────────────────────────────────────────────────────────────────
echo "→ Exporting documents..."
docker exec paperless document_exporter /usr/src/paperless/export
echo "  ↳ Export written to $EXPORT_DIR"

# ── Copy to Dropbox ───────────────────────────────────────────────────────────
echo "→ Copying to Dropbox..."
DROPBOX_ROOT="/mnt/c/Users/${DROPBOX_USER}/Dropbox"
if [[ ! -d "$DROPBOX_ROOT" ]]; then
  echo "ERROR: Dropbox not reachable at $DROPBOX_ROOT"
  echo "  Is Dropbox running on Windows? Is /mnt/c/ mounted?"
  exit 1
fi

mkdir -p "$DEST"
cp -r "$EXPORT_DIR/." "$DEST/"
echo "  ↳ Backed up to $DEST"

echo ""
echo "✓ Backup complete: $DEST"
echo ""
