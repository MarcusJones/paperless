#!/usr/bin/env bash
# scripts/pipeline-queue.sh — list documents currently in a pipeline stage
#
# Usage:
#   ./scripts/pipeline-queue.sh                   # all stages (grouped)
#   ./scripts/pipeline-queue.sh classification    # only classification-pending
#   ./scripts/pipeline-queue.sh vision            # only ocr-pending
#   ./scripts/pipeline-queue.sh processed         # only processed
#   ./scripts/pipeline-queue.sh untagged          # no pipeline tag
#   ./scripts/pipeline-queue.sh --json [stage]    # raw JSON (default: all)
#
# For each doc, shows: id, title (trimmed), document_type (resolved), correspondent
# (resolved), added date. Works from WSL host or dev container — auto-detects URL.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

JSON_ONLY=0
STAGE="all"
for arg in "$@"; do
  case "$arg" in
    --json) JSON_ONLY=1 ;;
    classification|vision|processed|untagged|all) STAGE="$arg" ;;
    -h|--help)
      sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$arg'. See --help." >&2
      exit 1
      ;;
  esac
done

# ── Load secrets ──────────────────────────────────────────────────────────────
ENV_FILE="$REPO_ROOT/.env"
[[ -f "$ENV_FILE" ]] || { echo "ERROR: $ENV_FILE not found." >&2; exit 1; }
# shellcheck source=../.env
source "$ENV_FILE"
TOKEN="${PAPERLESS_API_TOKEN:-}"
[[ -n "$TOKEN" && "$TOKEN" != "PASTE_YOUR_TOKEN_HERE" ]] || { echo "ERROR: PAPERLESS_API_TOKEN not set." >&2; exit 1; }

# ── Auto-detect API URL ───────────────────────────────────────────────────────
AUTH=(-H "Authorization: Token $TOKEN")
API=""
for url in "http://localhost:8000" "http://172.17.0.1:8000"; do
  if curl -sfm 3 -o /dev/null "${AUTH[@]}" "$url/api/tags/?page_size=1"; then
    API="$url"; break
  fi
done
[[ -n "$API" ]] || { echo "ERROR: cannot reach Paperless API. Is the stack up?" >&2; exit 1; }

# ── Resolve tag IDs by name ──────────────────────────────────────────────────
resolve_tag() {
  curl -sf "${AUTH[@]}" "$API/api/tags/?name__iexact=$1" | jq -r '.results[0].id // empty'
}
OCR_ID=$(resolve_tag ocr-pending)
CLASS_ID=$(resolve_tag classification-pending)
PROC_ID=$(resolve_tag processed)

# ── Build id→name lookups for document_types & correspondents ────────────────
DTYPES=$(curl -sf "${AUTH[@]}" "$API/api/document_types/?page_size=200" \
         | jq '[.results[] | {(.id|tostring): .name}] | add // {}')
CORRS=$(curl -sf "${AUTH[@]}" "$API/api/correspondents/?page_size=500" \
         | jq '[.results[] | {(.id|tostring): .name}] | add // {}')

# ── Fetch docs for a stage ───────────────────────────────────────────────────
# Arg: query string (without leading ?). Returns JSON array of simplified doc objects.
fetch_stage() {
  local q="$1"
  curl -sf "${AUTH[@]}" "$API/api/documents/?$q&page_size=200&ordering=added" \
    | jq --argjson dtypes "$DTYPES" --argjson corrs "$CORRS" '
        [.results[] | {
          id,
          title,
          added,
          document_type: ($dtypes[(.document_type // 0 | tostring)] // null),
          correspondent: ($corrs[(.correspondent // 0 | tostring)] // null),
          tag_ids: .tags
        }]
      '
}

declare -A STAGE_QUERY=(
  [classification]="tags__id=$CLASS_ID"
  [vision]="tags__id=$OCR_ID"
  [processed]="tags__id=$PROC_ID"
  [untagged]="tags__id__none=$OCR_ID,$CLASS_ID,$PROC_ID"
)

if [[ "$STAGE" == "all" ]]; then
  CLASS_DOCS=$(fetch_stage "${STAGE_QUERY[classification]}")
  VISION_DOCS=$(fetch_stage "${STAGE_QUERY[vision]}")
  UNTAGGED_DOCS=$(fetch_stage "${STAGE_QUERY[untagged]}")
  # Skip processed when dumping "all" — it's typically the largest and least interesting.
  # The user can pass `processed` explicitly to see it.
  JSON=$(jq -n \
    --argjson c "$CLASS_DOCS" \
    --argjson v "$VISION_DOCS" \
    --argjson u "$UNTAGGED_DOCS" \
    '{ classification_pending: $c, vision_pending: $v, untagged: $u }')
else
  DOCS=$(fetch_stage "${STAGE_QUERY[$STAGE]}")
  JSON=$(jq -n --arg stage "$STAGE" --argjson docs "$DOCS" '{($stage): $docs}')
fi

if (( JSON_ONLY )); then
  echo "$JSON"
  exit 0
fi

# ── Pretty table ─────────────────────────────────────────────────────────────
render_table() {
  local label="$1" docs_json="$2"
  local n
  n=$(echo "$docs_json" | jq 'length')
  echo ""
  echo "── $label  ($n)  ──────────────────────────────────────────────────"
  if (( n == 0 )); then
    echo "  (empty)"
    return
  fi
  {
    echo -e "ID\tADDED\tTYPE\tCORRESP\tTITLE"
    echo "$docs_json" | jq -r '
      .[] |
      [
        (.id|tostring),
        ((.added // "") | .[0:10]),
        (.document_type // "—"),
        (.correspondent // "—"),
        ((.title // "") | .[0:60])
      ] | @tsv'
  } | column -t -s $'\t' | sed 's/^/  /'
}

echo "API: $API"
if [[ "$STAGE" == "all" ]]; then
  render_table "CLASSIFICATION PENDING (queued for qwen3:14b)" "$(echo "$JSON" | jq '.classification_pending')"
  render_table "VISION PENDING (queued for qwen2.5vl:7b)"        "$(echo "$JSON" | jq '.vision_pending')"
  render_table "UNTAGGED (no pipeline tag — stuck or bypassed)"  "$(echo "$JSON" | jq '.untagged')"
  echo ""
  echo "  Tip: ./scripts/pipeline-queue.sh processed   # to see completed docs"
else
  render_table "$STAGE" "$(echo "$JSON" | jq --arg s "$STAGE" '.[$s]')"
fi
