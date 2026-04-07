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

# create_workflow <name> <json_body>
# Creates a workflow if one with the same name doesn't already exist.
create_workflow() {
  local name="$1"
  local body="$2"
  local resp existing_id
  resp=$(curl -sf --max-time 10 "${API}/workflows/?page_size=200" "${H[@]}")
  existing_id=$(echo "$resp" | python3 -c "
import json,sys
d=json.load(sys.stdin)
results=d.get('results',d) if isinstance(d,dict) else d
ids=[str(r['id']) for r in results if r.get('name')=='${name}']
print(ids[0] if ids else '')
" 2>/dev/null || true)
  if [[ -n "$existing_id" ]]; then
    echo "  -> '${name}' already exists (id=${existing_id})"
    return
  fi
  local response http_code body_out
  response=$(curl -s --max-time 10 -w "\n%{http_code}" -X POST "${API}/workflows/" "${H[@]}" -d "$body")
  http_code=$(echo "$response" | tail -1)
  body_out=$(echo "$response" | head -n -1)
  if [[ "$http_code" == "201" ]]; then
    local id
    id=$(echo "$body_out" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])" 2>/dev/null || true)
    echo "  -> '${name}' created (id=${id})"
  else
    echo "ERROR: POST workflows returned HTTP ${http_code}: ${body_out}" >&2
    exit 1
  fi
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
# Capture IDs — needed below when creating workflows
OCR_TAG_ID=$(create_tag "paperless-gpt-ocr-auto")
echo "  -> paperless-gpt-ocr-auto (Stage 1→2: triggers vision OCR) [id=${OCR_TAG_ID}]"
AI_PROCESS_TAG_ID=$(create_tag "ai-process")
echo "  -> ai-process            (Stage 2→3: triggers AI classification) [id=${AI_PROCESS_TAG_ID}]"
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

# ── Workflows ─────────────────────────────────────────────────────────────────
echo ""
echo "--> Creating workflows..."

# Workflow 1: every new document → assign paperless-gpt-ocr-auto → queues vision OCR
create_workflow "Auto Vision OCR" "$(cat <<EOF
{
  "name": "Auto Vision OCR",
  "order": 1,
  "enabled": true,
  "triggers": [
    {
      "type": 2,
      "sources": ["1", "2", "3"],
      "matching_algorithm": 0,
      "match": "",
      "is_insensitive": true,
      "filter_filename": null,
      "filter_path": null,
      "filter_mailrule": null,
      "filter_has_tags": [],
      "filter_has_all_tags": [],
      "filter_has_not_tags": []
    }
  ],
  "actions": [
    {
      "type": 1,
      "assign_tags": [${OCR_TAG_ID}]
    }
  ]
}
EOF
)"

# Workflow 2: document updated + has ai-process tag → webhook to paperless-ai-next
create_workflow "AI Classification after OCR" "$(cat <<EOF
{
  "name": "AI Classification after OCR",
  "order": 2,
  "enabled": true,
  "triggers": [
    {
      "type": 3,
      "sources": ["1", "2", "3"],
      "matching_algorithm": 0,
      "match": "",
      "is_insensitive": true,
      "filter_filename": null,
      "filter_path": null,
      "filter_mailrule": null,
      "filter_has_tags": [],
      "filter_has_all_tags": [${AI_PROCESS_TAG_ID}],
      "filter_has_not_tags": []
    }
  ],
  "actions": [
    {
      "type": 4,
      "webhook": {
        "url": "http://paperless-ai-next:3000/api/webhook/document",
        "use_params": false,
        "as_json": false,
        "params": null,
        "body": "{\"doc_url\": \"{{ doc_url }}\"}",
        "headers": {
          "Content-Type": "application/json",
          "x-api-key": "${PAPERLESS_AI_NEXT_API_KEY:-}"
        },
        "include_document": false
      }
    }
  ]
}
EOF
)"

# ── paperless-ai-next internal config ─────────────────────────────────────────
# The setup wizard writes this file on first run. Pre-seeding it means the wizard
# is never needed — a fresh stack is fully configured after bootstrap alone.
echo ""
echo "--> Pre-seeding paperless-ai-next setup state..."
mkdir -p "${REPO_ROOT}/paperless-ai-next/data"
cat > "${REPO_ROOT}/paperless-ai-next/data/.env" <<EOF
PAPERLESS_API_URL=http://paperless:8000
PAPERLESS_API_TOKEN=${PAPERLESS_API_TOKEN}
PAPERLESS_USERNAME=root
PROCESS_PREDEFINED_DOCUMENTS=yes
TAGS=ai-process
IGNORE_TAGS=
ADD_AI_PROCESSED_TAG=yes
AI_PROCESSED_TAG_NAME=ai-processed
DISABLE_AUTOMATIC_PROCESSING=no
SCAN_INTERVAL=*/5 * * * *
AI_PROVIDER=ollama
OLLAMA_API_URL=http://ollama:11434
OLLAMA_MODEL=qwen3:14b
MISTRAL_OCR_ENABLED=no
MISTRAL_API_KEY=
MISTRAL_OCR_MODEL=mistral-ocr-latest
EOF
echo "  -> paperless-ai-next/data/.env written (setup wizard skipped on next start)"

# ── paperless-ai-next admin user ──────────────────────────────────────────────
# Run with paperless-ai-next stopped to avoid DB lock:
#   docker compose stop paperless-ai-next && ./scripts/bootstrap.sh
echo ""
echo "--> Creating paperless-ai-next admin user..."
if [[ -z "${PAPERLESS_AI_ADMIN_USER:-}" ]] || [[ -z "${PAPERLESS_AI_ADMIN_PASSWORD:-}" ]]; then
  echo "  SKIP: set PAPERLESS_AI_ADMIN_USER and PAPERLESS_AI_ADMIN_PASSWORD in .env"
else
  docker run --rm \
    -v "${REPO_ROOT}/paperless-ai-next/data:/app/data" \
    -w /app \
    admonstrator/paperless-ai-next:latest \
    node -e "
const b=require('/app/node_modules/bcryptjs'),dm=require('/app/models/document.js');
b.hash('${PAPERLESS_AI_ADMIN_PASSWORD}',15).then(h=>dm.addUser('${PAPERLESS_AI_ADMIN_USER}',h)).then(()=>{console.log('  -> user created: ${PAPERLESS_AI_ADMIN_USER}');process.exit(0)}).catch(e=>{console.error(e.message);process.exit(1)});
" && true || { echo "  ERROR: user creation failed" >&2; exit 1; }
fi

# ── Done ───────────────────────────────────────────────────────────────────────
echo ""
echo "[OK] Bootstrap done"
echo ""
echo "Next steps:"
echo "  1. Pull models via Open WebUI: http://localhost:3001"
echo "     Pull: qwen3:14b  and  qwen2.5vl:7b"
echo ""
echo "  Optional: create Saved Views in the dashboard (Settings → Saved Views):"
echo "    Inbox:         filter Status = Inbox,         sort newest first"
echo "    Action needed: filter Status = Action needed, sort oldest first"
echo "    Waiting:       filter Status = Waiting"
echo ""
