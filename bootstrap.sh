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
# Safe to re-run — existing items are looked up and reused, not duplicated.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

API="http://localhost:${PAPERLESS_PORT}/api"
H=(-H "Authorization: Token ${PAPERLESS_API_TOKEN}" -H "Content-Type: application/json")

echo "=== Paperless-ngx bootstrap ==="
echo ""

# Guard: token must be real
if [[ "${PAPERLESS_API_TOKEN}" == "PASTE_YOUR_TOKEN_HERE" ]]; then
  echo "ERROR: PAPERLESS_API_TOKEN is still a placeholder."
  echo "  Update .env -> PAPERLESS_API_TOKEN and re-run."
  exit 1
fi

# Wait for API
echo "--> Waiting for Paperless API..."
until curl -sf "${API}/tags/" "${H[@]}" >/dev/null 2>&1; do
  echo -n "."
  sleep 3
done
echo " ready"
echo ""

# api_post <endpoint> <json_body>
# POSTs to the API. On success (201) prints the response. On 400 (duplicate)
# prints nothing and returns 0. On any other error, prints the response to
# stderr and exits 1.
api_post() {
  local endpoint="$1"
  local body="$2"
  local http_code
  local response
  response=$(curl -s --max-time 10 -w "\n%{http_code}" -X POST "${API}/${endpoint}/" "${H[@]}" -d "$body")
  http_code=$(echo "$response" | tail -1)
  local body_out
  body_out=$(echo "$response" | head -n -1)
  if [[ "$http_code" == "201" ]]; then
    echo "$body_out"
  elif [[ "$http_code" == "400" ]]; then
    : # already exists, not an error
  else
    echo "ERROR: POST ${endpoint} returned HTTP ${http_code}: ${body_out}" >&2
    exit 1
  fi
}

# get_id_by_name <endpoint> <name>
# Fetches all items (page_size=200) and returns the id of the item with the given name.
get_id_by_name() {
  local endpoint="$1"
  local name="$2"
  local resp
  resp=$(curl -sf --max-time 10 "${API}/${endpoint}/?page_size=200" "${H[@]}")
  echo "$resp" | grep -o "\"id\":[0-9]*,\"slug\":\"[^\"]*\",\"name\":\"${name}\"" \
    | grep -o '"id":[0-9]*' | grep -o '[0-9]*' || true
}

# set_tag_matching <name> <algorithm> <match_string>
# PATCHes an existing tag with an automatic matching rule.
# Algorithms: 0=none 1=any-word 2=all-words 3=literal 4=regex 5=fuzzy
set_tag_matching() {
  local name="$1"
  local algorithm="$2"
  local match="$3"
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
# Creates a tag (or finds existing) and returns its id.
create_tag() {
  local name="$1"
  local parent="${2:-null}"
  local body="{\"name\":\"${name}\",\"color\":\"#808080\"}"
  if [[ "$parent" != "null" ]]; then
    body="{\"name\":\"${name}\",\"color\":\"#808080\",\"parent\":${parent}}"
  fi
  local resp
  resp=$(api_post "tags" "$body")
  local id
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

# Tags - nested
echo "--> Creating tags..."
echo "    [test] POST /api/tags/..."
_test=$(api_post "tags" '{"name":"__bootstrap_test__","color":"#808080"}')
if echo "$_test" | grep -q '"id"'; then
  _test_id=$(echo "$_test" | grep -o '"id":[0-9]*' | grep -o '[0-9]*')
  echo "    [test] OK - API accepted POST, got id=${_test_id}, deleting..."
  curl -sf --max-time 10 -X DELETE "${API}/tags/${_test_id}/" "${H[@]}" || true
else
  echo "    [test] Already existed (API reachable, 400 = duplicate) - OK"
fi

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

# Tags - top-level
for tag in "Bank" "School" "Munster" "Hoflein" "Heinl" "Altenberg"; do
  create_tag "$tag" >/dev/null
  echo "  -> $tag"
done

# Tag matching rules — deterministic auto-tagging independent of AI
set_tag_matching "Altenberg" 3 "St. Andra-Wörden"
echo "  -> Altenberg: match literal 'St. Andra-Wörden'"

create_tag "paperless-gpt-ocr-auto" >/dev/null
echo "  -> paperless-gpt-ocr-auto (vision OCR trigger -- OCR only, no tagging)"

create_tag "ocr-complete" >/dev/null
echo "  -> ocr-complete (signals vision OCR is done -- set by paperless-gpt)"

create_tag "ai-process" >/dev/null
echo "  -> ai-process (triggers AI classification -- set by Workflow 2)"

# Document types
echo ""
echo "--> Creating document types..."
echo "    [test] POST /api/document_types/..."
_test=$(api_post "document_types" '{"name":"__bootstrap_test__"}')
if echo "$_test" | grep -q '"id"'; then
  _test_id=$(echo "$_test" | grep -o '"id":[0-9]*' | grep -o '[0-9]*')
  echo "    [test] OK - API accepted POST, got id=${_test_id}, deleting..."
  curl -sf --max-time 10 -X DELETE "${API}/document_types/${_test_id}/" "${H[@]}" || true
else
  echo "    [test] Already existed (API reachable, 400 = duplicate) - OK"
fi
for t in Invoice Contract Receipt Certificate Statement Letter Manual Payslip; do
  api_post "document_types" "{\"name\":\"$t\"}" >/dev/null
  echo "  -> $t"
done

# Custom field: Status
echo ""
echo "--> Creating Status custom field..."
echo "    [test] POST /api/custom_fields/..."
_test=$(api_post "custom_fields" '{"name":"__bootstrap_test__","data_type":"string"}')
if echo "$_test" | grep -q '"id"'; then
  _test_id=$(echo "$_test" | grep -o '"id":[0-9]*' | grep -o '[0-9]*')
  echo "    [test] OK - API accepted POST, got id=${_test_id}, deleting..."
  curl -sf --max-time 10 -X DELETE "${API}/custom_fields/${_test_id}/" "${H[@]}" || true
else
  echo "    [test] Already existed (API reachable, 400 = duplicate) - OK"
fi
api_post "custom_fields" '{
  "name": "Status",
  "data_type": "select",
  "extra_data": {"select_options": [{"label": "Inbox", "id": "1"}, {"label": "Action needed", "id": "2"}, {"label": "Waiting", "id": "3"}, {"label": "Done", "id": "4"}]}
}' >/dev/null
echo "  -> Status (Inbox / Action needed / Waiting / Done)"

# Storage path
echo ""
echo "--> Creating storage path..."
api_post "storage_paths" '{
  "name": "Default",
  "path": "{{ correspondent }}/{{ created_year }}/{{ title }}",
  "match": "",
  "matching_algorithm": 0
}' >/dev/null
echo "  -> correspondent/year/title"

echo ""
echo "[OK] Bootstrap done"
echo ""
echo "Finish in the web UI (http://localhost:${PAPERLESS_PORT}):"
echo ""
echo "  1. Settings -> Workflows -> New workflow:"
echo "       Name:    Auto Vision OCR"
echo "       Trigger: Document Added"
echo "       Action:  Assign tag -> paperless-gpt-ocr-auto"
echo "     (triggers vision OCR on every new document)"
echo ""
echo "  2. Settings -> Workflows -> New workflow:"
echo "       Name:       AI Classification after OCR"
echo "       Trigger:    Document Updated"
echo "       Conditions: Has tag: ocr-complete"
echo "                   Does NOT have tag: paperless-gpt-ocr-auto"
echo "       Action:     Assign tag -> ai-process"
echo "     (triggers AI classification only after vision OCR completes)"
echo ""
echo "  3. Dashboard -> Saved views - create three views:"
echo "       Inbox:         filter Status = Inbox,         sorted newest first"
echo "       Action needed: filter Status = Action needed, sorted oldest first"
echo "       Waiting:       filter Status = Waiting"
echo ""
