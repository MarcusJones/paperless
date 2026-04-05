#!/usr/bin/env bash
# scripts/bootstrap.sh — create taxonomy via the Paperless API (run once after first boot)
#
# Creates:
#   - Nested tags (Finance/Tax, Health/Medical, etc.)
#   - Workflow tags (paperless-gpt-ocr-auto, ai-process, ai-processed)
#   - Document types (Invoice, Contract, Receipt, ...)
#   - Status custom field (select: Inbox / Action needed / Waiting / Done)
#   - XNC Medical document type (for kids medical invoices)
#   - Default storage path (correspondent/year/title)
#
# Run from the repo root:
#   ./scripts/bootstrap.sh
#
# Safe to re-run — existing items return HTTP 400 (treated as success).
# Requires: docker compose up -d (paperless must be healthy)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load root .env for secrets
ENV_FILE="$REPO_ROOT/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found."
  echo "  cp .env.example .env && fill in PAPERLESS_API_TOKEN"
  exit 1
fi
# shellcheck source=../.env
source "$ENV_FILE"

if [[ -z "${PAPERLESS_API_TOKEN:-}" ]]; then
  echo "ERROR: PAPERLESS_API_TOKEN is not set in .env"
  exit 1
fi

if [[ "${PAPERLESS_API_TOKEN}" == "PASTE_YOUR_TOKEN_HERE" ]]; then
  echo "ERROR: PAPERLESS_API_TOKEN is still a placeholder."
  echo "  Get the token: docker compose exec paperless python3 manage.py dumpdata authtoken"
  echo "  Or: log in at http://localhost:8000 → username → My Profile → API Token"
  exit 1
fi

API="http://localhost:8000/api"
H=(-H "Authorization: Token ${PAPERLESS_API_TOKEN}" -H "Content-Type: application/json")

echo "=== Paperless-ngx bootstrap ==="
echo ""

# ── Wait for API ───────────────────────────────────────────────────────────────
echo "--> Waiting for Paperless API..."
until curl -sf "${API}/tags/" "${H[@]}" >/dev/null 2>&1; do
  echo -n "."
  sleep 3
done
echo " ready"
echo ""

# ── Helpers ────────────────────────────────────────────────────────────────────

# api_post <endpoint> <json_body>
# POSTs to the API. 201 = created. 400 = already exists (OK). Other = error.
api_post() {
  local endpoint="$1"
  local body="$2"
  local response http_code body_out
  response=$(curl -s --max-time 10 -w "\n%{http_code}" -X POST "${API}/${endpoint}/" "${H[@]}" -d "$body")
  http_code=$(echo "$response" | tail -1)
  body_out=$(echo "$response" | head -n -1)
  if [[ "$http_code" == "201" ]]; then
    echo "$body_out"
  elif [[ "$http_code" == "400" ]]; then
    : # already exists — idempotent, not an error
  else
    echo "ERROR: POST ${endpoint} returned HTTP ${http_code}: ${body_out}" >&2
    exit 1
  fi
}

# get_id_by_name <endpoint> <name>
# Returns the numeric id of the item with the given name, or empty string.
get_id_by_name() {
  local endpoint="$1"
  local name="$2"
  local resp
  resp=$(curl -sf --max-time 10 "${API}/${endpoint}/?page_size=200" "${H[@]}")
  echo "$resp" | grep -o "\"id\":[0-9]*,\"slug\":\"[^\"]*\",\"name\":\"${name}\"" \
    | grep -o '"id":[0-9]*' | grep -o '[0-9]*' || true
}

# set_tag_matching <name> <algorithm> <match_string>
# Algorithms: 0=none 1=any-word 2=all-words 3=literal 4=regex 5=fuzzy
set_tag_matching() {
  local name="$1" algorithm="$2" match="$3"
  local id
  id=$(get_id_by_name "tags" "$name")
  if [[ -z "$id" ]]; then
    echo "ERROR: Tag '${name}' not found for matching setup" >&2
    exit 1
  fi
  curl -sf --max-time 10 -X PATCH "${API}/tags/${id}/" "${H[@]}" \
    -d "{\"matching_algorithm\":${algorithm},\"match\":\"${match}\",\"is_insensitive\":true}" >/dev/null
}

# create_tag <name> [parent_id]
# Creates tag (or finds existing) and echoes its id.
create_tag() {
  local name="$1"
  local parent="${2:-null}"
  local body="{\"name\":\"${name}\",\"color\":\"#808080\"}"
  [[ "$parent" != "null" ]] && body="{\"name\":\"${name}\",\"color\":\"#808080\",\"parent\":${parent}}"
  local resp id
  resp=$(api_post "tags" "$body")
  id=$(echo "$resp" | grep -o '"id":[0-9]*' | head -1 | grep -o '[0-9]*' || true)
  if [[ -z "$id" ]]; then
    id=$(get_id_by_name "tags" "$name")
  fi
  if [[ -z "$id" ]]; then
    echo "ERROR: Could not create or find tag '${name}'" >&2
    exit 1
  fi
  echo "$id"
}

# ── Tags ───────────────────────────────────────────────────────────────────────
echo "--> Creating tags..."

FIN=$(create_tag "Finance")
create_tag "Tax"       "$FIN" >/dev/null
create_tag "Insurance" "$FIN" >/dev/null
create_tag "Banking"   "$FIN" >/dev/null
echo "  -> Finance / Tax, Insurance, Banking"

HOUSING=$(create_tag "Housing")
create_tag "Rent"      "$HOUSING" >/dev/null
create_tag "Utilities" "$HOUSING" >/dev/null
echo "  -> Housing / Rent, Utilities"

HEALTH=$(create_tag "Health")
create_tag "Medical"    "$HEALTH" >/dev/null
create_tag "Dental"     "$HEALTH" >/dev/null
create_tag "health-xnc" "$HEALTH" >/dev/null
create_tag "health-ms"  "$HEALTH" >/dev/null
create_tag "health-po"  "$HEALTH" >/dev/null
echo "  -> Health / Medical, Dental, health-xnc, health-ms, health-po"

CAR=$(create_tag "Car")
create_tag "Car Insurance" "$CAR" >/dev/null
create_tag "Service"       "$CAR" >/dev/null
echo "  -> Car / Car Insurance, Service"

WORK=$(create_tag "Work")
create_tag "Payslip"    "$WORK" >/dev/null
create_tag "Employment" "$WORK" >/dev/null
echo "  -> Work / Payslip, Employment"

for tag in "Bank" "School" "Munster" "Hoflein" "Heinl" "Altenberg"; do
  create_tag "$tag" >/dev/null
  echo "  -> $tag"
done

# Auto-matching rule: "Altenberg" tag fires on literal match "St. Andra-Wörden"
set_tag_matching "Altenberg" 3 "St. Andra-Wörden"
echo "  -> Altenberg: match literal 'St. Andra-Wörden'"

# Pipeline / workflow tags (NOT in PROMPT_TAGS — AI must never self-assign these)
create_tag "paperless-gpt-ocr-auto" >/dev/null
echo "  -> paperless-gpt-ocr-auto (Stage 1→2: triggers vision OCR)"
create_tag "ai-process" >/dev/null
echo "  -> ai-process            (Stage 2→3: triggers AI classification)"
create_tag "ai-processed" >/dev/null
echo "  -> ai-processed          (Stage 3 complete: classification done)"

# ── Document types ─────────────────────────────────────────────────────────────
echo ""
echo "--> Creating document types..."
for t in Invoice Contract Receipt Certificate Statement Letter Manual Payslip; do
  api_post "document_types" "{\"name\":\"$t\"}" >/dev/null
  echo "  -> $t"
done
# Special type for kids medical invoices (used by SYSTEM_PROMPT conditional rule)
api_post "document_types" '{"name":"XNC medical"}' >/dev/null
echo "  -> XNC medical"

# ── Custom field: Status ───────────────────────────────────────────────────────
echo ""
echo "--> Creating Status custom field..."
api_post "custom_fields" '{
  "name": "Status",
  "data_type": "select",
  "extra_data": {
    "select_options": [
      {"label": "Inbox",         "id": "1"},
      {"label": "Action needed", "id": "2"},
      {"label": "Waiting",       "id": "3"},
      {"label": "Done",          "id": "4"}
    ]
  }
}' >/dev/null
echo "  -> Status (Inbox / Action needed / Waiting / Done)"

# ── Storage path ──────────────────────────────────────────────────────────────
echo ""
echo "--> Creating storage path..."
api_post "storage_paths" '{
  "name": "Default",
  "path": "{{ correspondent }}/{{ created_year }}/{{ title }}",
  "match": "",
  "matching_algorithm": 0
}' >/dev/null
echo "  -> correspondent/year/title"

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo "[OK] Bootstrap done"
echo ""
echo "Required: configure two Workflows in the Paperless UI (Settings → Workflows):"
echo ""
echo "  Workflow 1 — Auto Vision OCR"
echo "    Trigger:  Document Added"
echo "    Action:   Assign tag → paperless-gpt-ocr-auto"
echo "    Effect:   Every new document gets queued for vision OCR"
echo ""
echo "  Workflow 2 — AI Classification after OCR  (webhook trigger)"
echo "    Trigger:  Document Updated"
echo "    Conditions: has tag 'ai-process'"
echo "    Action:   Webhook POST → http://paperless-ai-next:3000/api/webhook/document"
echo "    Headers:  x-api-key: <PAPERLESS_AI_NEXT_API_KEY from root .env>"
echo "    Body:     {\"doc_url\": \"{{ doc_url }}\"}"
echo "    Effect:   paperless-ai-next processes the document immediately (zero polling delay)"
echo ""
echo "  Optional: create Saved Views in the dashboard:"
echo "    Inbox:         filter Status = Inbox,         sort newest first"
echo "    Action needed: filter Status = Action needed, sort oldest first"
echo "    Waiting:       filter Status = Waiting"
echo ""
