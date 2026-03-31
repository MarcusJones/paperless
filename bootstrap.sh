#!/usr/bin/env bash
# bootstrap.sh — create taxonomy via the Paperless API (run once after setup)
#
# Creates:
#   - Nested tags (Finance/Tax, Health/Medical, etc.)
#   - Top-level tags (Bank, School, Munster, etc.)
#   - paperless-gpt-auto tag (triggers vision OCR workflow)
#   - Document types (Invoice, Contract, Receipt, ...)
#   - Status custom field (select: Inbox / Action needed / Waiting / Done)
#   - Default storage path (correspondent/year/title)
#
# Run: ./bootstrap.sh
# Safe to re-run — duplicate-name errors are suppressed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

API="http://localhost:${PAPERLESS_PORT}/api"
H=(-H "Authorization: Token ${PAPERLESS_API_TOKEN}" -H "Content-Type: application/json")

echo "=== Paperless-ngx bootstrap ==="
echo ""

# ── Guard: token must be real ─────────────────────────────────────────────────
if [[ "${PAPERLESS_API_TOKEN}" == "PASTE_YOUR_TOKEN_HERE" ]]; then
  echo "ERROR: PAPERLESS_API_TOKEN is still a placeholder."
  echo "  Update .env → PAPERLESS_API_TOKEN and re-run."
  exit 1
fi

# ── Wait for API ──────────────────────────────────────────────────────────────
echo "→ Waiting for Paperless API..."
until curl -sf "${API}/tags/" "${H[@]}" >/dev/null 2>&1; do
  echo -n "."
  sleep 3
done
echo " ready"
echo ""

# ── Helpers ───────────────────────────────────────────────────────────────────

# Create a tag and return its numeric ID.
# Silently skips if a tag with the same name already exists (409 ignored).
# Usage: id=$(create_tag "Name" [parent_id])
create_tag() {
  local name="$1"
  local parent="${2:-null}"
  local body="{\"name\":\"${name}\",\"color\":\"#808080\"}"
  if [[ "$parent" != "null" ]]; then
    body="{\"name\":\"${name}\",\"color\":\"#808080\",\"parent\":${parent}}"
  fi
  local resp
  resp=$(curl -sf -X POST "${API}/tags/" "${H[@]}" -d "$body" 2>/dev/null) || true
  # Extract id from response; empty string if creation was silently skipped
  echo "$resp" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*'
}

# ── Tags — nested ─────────────────────────────────────────────────────────────
echo "→ Creating tags..."

FIN=$(create_tag "Finance")
create_tag "Tax"       "$FIN" >/dev/null
create_tag "Insurance" "$FIN" >/dev/null
create_tag "Banking"   "$FIN" >/dev/null
echo "  ↳ Finance / Tax, Insurance, Banking"

HOUSING=$(create_tag "Housing")
create_tag "Rent"      "$HOUSING" >/dev/null
create_tag "Utilities" "$HOUSING" >/dev/null
echo "  ↳ Housing / Rent, Utilities"

HEALTH=$(create_tag "Health")
create_tag "Medical"    "$HEALTH" >/dev/null
create_tag "Dental"     "$HEALTH" >/dev/null
create_tag "health-xnc" "$HEALTH" >/dev/null
create_tag "health-ms"  "$HEALTH" >/dev/null
create_tag "health-po"  "$HEALTH" >/dev/null
echo "  ↳ Health / Medical, Dental, health-xnc, health-ms, health-po"

CAR=$(create_tag "Car")
create_tag "Car Insurance" "$CAR" >/dev/null
create_tag "Service"       "$CAR" >/dev/null
echo "  ↳ Car / Car Insurance, Service"

WORK=$(create_tag "Work")
create_tag "Payslip"    "$WORK" >/dev/null
create_tag "Employment" "$WORK" >/dev/null
echo "  ↳ Work / Payslip, Employment"

# ── Tags — top-level ──────────────────────────────────────────────────────────
for tag in "Bank" "School" "Munster" "Hoflein" "Heinl" "Altenberg"; do
  create_tag "$tag" >/dev/null
  echo "  ↳ $tag"
done

# Special tag: triggers vision OCR via paperless-gpt workflow
create_tag "paperless-gpt-auto" >/dev/null
echo "  ↳ paperless-gpt-auto (vision OCR trigger)"

# ── Document types ────────────────────────────────────────────────────────────
echo ""
echo "→ Creating document types..."
for t in Invoice Contract Receipt Certificate Statement Letter Manual Payslip; do
  curl -sf -X POST "${API}/document_types/" "${H[@]}" \
    -d "{\"name\":\"$t\"}" >/dev/null 2>&1 || true
  echo "  ↳ $t"
done

# ── Custom field: Status ──────────────────────────────────────────────────────
echo ""
echo "→ Creating Status custom field..."
curl -sf -X POST "${API}/custom_fields/" "${H[@]}" -d '{
  "name": "Status",
  "data_type": "select",
  "extra_data": {
    "select_options": ["Inbox", "Action needed", "Waiting", "Done"]
  }
}' >/dev/null 2>&1 || true
echo "  ↳ Status (Inbox / Action needed / Waiting / Done)"

# ── Storage path ──────────────────────────────────────────────────────────────
echo ""
echo "→ Creating storage path..."
curl -sf -X POST "${API}/storage_paths/" "${H[@]}" -d '{
  "name": "Default",
  "path": "{{ correspondent }}/{{ created_year }}/{{ title }}",
  "match": "",
  "matching_algorithm": 0
}' >/dev/null 2>&1 || true
echo "  ↳ correspondent/year/title"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "✓ Bootstrap complete"
echo ""
echo "Finish in the web UI (http://localhost:${PAPERLESS_PORT}):"
echo ""
echo "  1. Settings → Workflows → New workflow:"
echo "       Trigger: Document Added"
echo "       Action:  Assign tag → paperless-gpt-auto"
echo "     (makes every document go through vision OCR automatically)"
echo ""
echo "  2. Dashboard → Saved views — create three views:"
echo "       Inbox:         filter Status = Inbox,         sorted newest first"
echo "       Action needed: filter Status = Action needed, sorted oldest first"
echo "       Waiting:       filter Status = Waiting"
echo ""
