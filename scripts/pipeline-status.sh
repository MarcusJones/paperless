#!/usr/bin/env bash
# scripts/pipeline-status.sh — one-shot summary of every pipeline stage
#
# Shows, as both JSON and a rendered table:
#   - consume_queue    files sitting in ./paperless/consume/ not yet ingested
#   - classification_pending   docs tagged `classification-pending` awaiting qwen3:14b
#   - vision_pending           docs tagged `ocr-pending` awaiting qwen2.5vl:7b re-OCR
#   - processed                docs tagged `processed` (fully classified)
#   - untagged                 docs with none of the three pipeline tags (imports, bypasses)
#
# Usage:
#   ./scripts/pipeline-status.sh         # pretty table + JSON
#   ./scripts/pipeline-status.sh --json  # JSON only
#
# Works from WSL host (localhost:8000) or the dev container (172.17.0.1:8000) — auto-detects.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONSUME_DIR="$REPO_ROOT/paperless/consume"

JSON_ONLY=0
[[ "${1:-}" == "--json" ]] && JSON_ONLY=1

# ── Load secrets ──────────────────────────────────────────────────────────────
ENV_FILE="$REPO_ROOT/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE not found. Run from repo root." >&2
  exit 1
fi
# shellcheck source=../.env
source "$ENV_FILE"
TOKEN="${PAPERLESS_API_TOKEN:-}"
if [[ -z "$TOKEN" || "$TOKEN" == "PASTE_YOUR_TOKEN_HERE" ]]; then
  echo "ERROR: PAPERLESS_API_TOKEN not set in .env" >&2
  exit 1
fi

# ── Auto-detect API URL (WSL host vs dev container) ─────────────────────────
AUTH=(-H "Authorization: Token $TOKEN")
API=""
for url in "http://localhost:8000" "http://172.17.0.1:8000"; do
  if curl -sfm 3 -o /dev/null "${AUTH[@]}" "$url/api/tags/?page_size=1"; then
    API="$url"
    break
  fi
done
if [[ -z "$API" ]]; then
  echo "ERROR: cannot reach Paperless API at localhost:8000 or 172.17.0.1:8000" >&2
  echo "       Is the stack up? docker compose up -d" >&2
  exit 1
fi

# ── Resolve pipeline tag IDs by name (not hardcoded — IDs drift) ────────────
resolve_tag() {
  local name="$1"
  local id
  id=$(curl -sf "${AUTH[@]}" "$API/api/tags/?name__iexact=$name" | jq -r '.results[0].id // empty')
  if [[ -z "$id" ]]; then
    echo "ERROR: tag '$name' not found in Paperless — did bootstrap run?" >&2
    exit 1
  fi
  echo "$id"
}
OCR_ID=$(resolve_tag ocr-pending)
CLASS_ID=$(resolve_tag classification-pending)
PROC_ID=$(resolve_tag processed)

# ── Query counts ─────────────────────────────────────────────────────────────
count_docs() {
  curl -sf "${AUTH[@]}" "$API/api/documents/?$1&page_size=1" | jq '.count // 0'
}
TOTAL=$(count_docs "")
VISION=$(count_docs "tags__id=$OCR_ID")
CLASSIFY=$(count_docs "tags__id=$CLASS_ID")
PROCESSED=$(count_docs "tags__id=$PROC_ID")
UNTAGGED=$(count_docs "tags__id__none=$OCR_ID,$CLASS_ID,$PROC_ID")

# Consume queue (files on disk, not yet ingested). Symlinks count too.
CONSUME=0
if [[ -d "$CONSUME_DIR" ]]; then
  CONSUME=$(find "$CONSUME_DIR" -maxdepth 2 -type f -not -name '.*' 2>/dev/null | wc -l | tr -d ' ')
fi

# In-flight Paperless consume tasks (Tesseract + initial processing).
TASKS_RUNNING=0
TASKS_JSON=$(curl -sf "${AUTH[@]}" "$API/api/tasks/?task_name=consume_file" 2>/dev/null || echo '[]')
if [[ -n "$TASKS_JSON" ]]; then
  TASKS_RUNNING=$(echo "$TASKS_JSON" | jq '[.[] | select(.status == "STARTED" or .status == "PENDING")] | length' 2>/dev/null || echo 0)
fi

# ── Assemble JSON ────────────────────────────────────────────────────────────
JSON=$(jq -n \
  --argjson total "$TOTAL" \
  --argjson consume "$CONSUME" \
  --argjson tasks "$TASKS_RUNNING" \
  --argjson classify "$CLASSIFY" \
  --argjson vision "$VISION" \
  --argjson processed "$PROCESSED" \
  --argjson untagged "$UNTAGGED" \
  --arg api "$API" \
  '{
    api: $api,
    total_documents: $total,
    stages: [
      { stage: "consume_queue",          count: $consume,   detail: "files in ./paperless/consume/ awaiting ingest" },
      { stage: "tesseract_in_flight",    count: $tasks,     detail: "Paperless consume tasks STARTED or PENDING" },
      { stage: "classification_pending", count: $classify,  detail: "tag=classification-pending — waiting on qwen3:14b" },
      { stage: "vision_pending",         count: $vision,    detail: "tag=ocr-pending — user flagged for qwen2.5vl:7b vision OCR" },
      { stage: "processed",              count: $processed, detail: "tag=processed — fully classified, done" },
      { stage: "untagged",               count: $untagged,  detail: "no pipeline tag — imports or workflow bypasses" }
    ]
  }')

if (( JSON_ONLY )); then
  echo "$JSON"
  exit 0
fi

# ── Pretty table ─────────────────────────────────────────────────────────────
{
  echo -e "STAGE\tCOUNT\tDETAIL"
  echo "$JSON" | jq -r '.stages[] | [.stage, .count, .detail] | @tsv'
  echo -e "---\t---\t---"
  echo -e "TOTAL_DOCS\t$TOTAL\t(everything in Paperless)"
} | column -t -s $'\t'
echo ""
echo "API: $API"
echo ""
echo "JSON:"
echo "$JSON" | jq .
