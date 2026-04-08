#!/usr/bin/env sh
# scripts/pipeline-timing-container.sh — runs inside the pipeline-timing Docker service.
#
# Default (human-readable) output:
#   [HH:MM:SS] #17  INGESTED    "WhatsApp Image 2026-03-22..."
#   [HH:MM:SS] #17  OCR start
#   [HH:MM:SS] #17  OCR done    47s  (1pg, 47s/pg)
#   [HH:MM:SS] #17  CLASSIFIED  "Honorarnote 2026/00263"  classify=18s  total=65s
#
# JSONL output (set OUTPUT_FORMAT=jsonl):
#   {"ts":"2026-04-08T12:01:00.000Z","doc_id":42,"title":"Invoice Telekom","stage":"ingest_start","model":"tesseract","pages":0}
#   {"ts":"2026-04-08T12:01:15.000Z","doc_id":42,"title":"Invoice Telekom","stage":"ingest_end","model":"tesseract","pages":0}
#   ... (ocr_start, ocr_end, classify_start, classify_end)
#
# Requires: gawk, curl (installed by compose service command before exec'ing this)
# Requires: /var/run/docker.sock mounted (to run docker logs)
set -eu

PROJ="${COMPOSE_PROJECT_NAME:-paperless}"
C_PAPERLESS="${PROJ}-paperless-1"
C_GPT="${PROJ}-paperless-gpt-1"
C_AI="${PROJ}-paperless-ai-next-1"

OUTPUT_FORMAT="${OUTPUT_FORMAT:-human}"

for c in "$C_PAPERLESS" "$C_GPT" "$C_AI"; do
  until docker inspect --format '{{.State.Running}}' "$c" 2>/dev/null | grep -q true; do
    echo "pipeline-timing: waiting for $c..."
    sleep 5
  done
done

echo "=== Pipeline Timing ready — watching for documents (format: ${OUTPUT_FORMAT}) ==="

# Fetch doc title from Paperless API by document ID.
# Requires PAPERLESS_URL and PAPERLESS_API_TOKEN env vars.
# Returns "doc_<id>" on failure.
fetch_title() {
  doc_id="$1"
  if [ -z "${PAPERLESS_URL:-}" ] || [ -z "${PAPERLESS_API_TOKEN:-}" ]; then
    echo "doc_${doc_id}"
    return
  fi
  title=$(curl -sf \
    -H "Authorization: Token ${PAPERLESS_API_TOKEN}" \
    "${PAPERLESS_URL}/api/documents/${doc_id}/" \
    2>/dev/null | gawk -F'"title":"' 'NF>1{split($2,a,"\""); print a[1]; exit}')
  if [ -n "$title" ]; then
    echo "$title"
  else
    echo "doc_${doc_id}"
  fi
}
export -f fetch_title 2>/dev/null || true  # bash only; sh ignores

{
  docker logs --follow --timestamps --since 5m "$C_PAPERLESS" 2>&1 \
    | awk '{ print "paperless | " $0 }' &
  docker logs --follow --timestamps --since 5m "$C_GPT" 2>&1 \
    | awk '{ print "paperless-gpt | " $0 }' &
  docker logs --follow --timestamps --since 5m "$C_AI" 2>&1 \
    | awk '{ print "paperless-ai-next | " $0 }' &
  wait
} | gawk -v fmt="${OUTPUT_FORMAT}" \
         -v paperless_url="${PAPERLESS_URL:-}" \
         -v api_token="${PAPERLESS_API_TOKEN:-}" \
'
BEGIN {
  GRN = "\033[0;32m"
  YLW = "\033[0;33m"
  CYN = "\033[0;36m"
  BLD = "\033[1m"
  RST = "\033[0m"
}

function parse_ts(s,    parts) {
  gsub(/T/, " ", s); gsub(/\.[0-9]+Z?$/, "", s); gsub(/Z$/, "", s)
  split(s, parts, /[-: ]/)
  return mktime(parts[1] " " parts[2] " " parts[3] " " parts[4] " " parts[5] " " parts[6])
}

function hms(epoch) {
  return strftime("%H:%M:%S", epoch)
}

function iso8601(epoch) {
  return strftime("%Y-%m-%dT%H:%M:%S.000Z", epoch)
}

function fmt_dur(s) {
  if (s < 60) return s "s"
  return int(s/60) "m " (s%60) "s"
}

function doc_id_from(line,    m) {
  if (match(line, /document_id=([0-9]+)/, m)) return m[1]
  if (match(line, /document ([0-9]+)/, m))    return m[1]
  if (match(line, /documents\/([0-9]+)/, m))  return m[1]
  return ""
}

# Fetch title from Paperless API; cache in doc_name[id]
function ensure_title(id,    cmd, line, title) {
  if (id in doc_name && doc_name[id] != "" && doc_name[id] != "doc_" id) return
  if (paperless_url == "" || api_token == "") {
    if (!(id in doc_name)) doc_name[id] = "doc_" id
    return
  }
  cmd = "curl -sf -H \"Authorization: Token " api_token "\" " \
        paperless_url "/api/documents/" id "/ 2>/dev/null" \
        " | gawk -F'\"title\":\"' 'NF>1{split($2,a,\"\\\"\"); print a[1]; exit}'"
  title = ""
  while ((cmd | getline line) > 0) { title = line }
  close(cmd)
  doc_name[id] = (title != "") ? title : "doc_" id
}

function emit_human(color, ts, id, stage, detail) {
  printf "%s[%s] #%-5s %-12s%s%s\n", color, hms(ts), id, stage, detail, RST
  fflush()
}

function emit_jsonl(ts_epoch, id, stage, model, pages,    title, safe_title) {
  ensure_title(id)
  title = (id in doc_name) ? doc_name[id] : "doc_" id
  # Escape double quotes and backslashes in title
  safe_title = title
  gsub(/\\/, "\\\\", safe_title)
  gsub(/"/, "\\\"", safe_title)
  printf "{\"ts\":\"%s\",\"doc_id\":%s,\"title\":\"%s\",\"stage\":\"%s\",\"model\":\"%s\",\"pages\":%d}\n",
    iso8601(ts_epoch), id, safe_title, stage, model, pages+0
  fflush()
}

{
  # Parse "service | <docker-ts> <message>"
  if (!match($0, /^([a-zA-Z0-9_-]+) \| ([0-9T:Z.\-]+) (.*)/, m)) next
  svc = m[1]; ts = parse_ts(m[2]); msg = m[3]

  # ── Paperless: ingest ──────────────────────────────────────────────────────
  if (svc == "paperless") {

    # Consuming /path/to/file.pdf  →  record filename + ingest start time
    if (match(msg, /Consuming (.+)/, m)) {
      fname = m[1]; gsub(/\s.*/, "", fname)
      gsub(/.*\//, "", fname)
      pending_fname = fname
      ingest_start  = ts
    }

    # "Created document: 17" → INGESTED
    if (msg ~ /[Cc]reated.*document|[Nn]ew document id/) {
      id = doc_id_from(msg)
      if (id != "" && ingest_start > 0) {
        if (!(id in doc_name) || doc_name[id] == "") {
          doc_name[id] = (pending_fname != "") ? pending_fname : "doc_" id
        }
        ingest_end[id] = ts

        if (fmt == "jsonl") {
          emit_jsonl(ingest_start, id, "ingest_start", "tesseract", 0)
          emit_jsonl(ts,           id, "ingest_end",   "tesseract", 0)
        } else {
          emit_human(GRN, ts, id, "INGESTED", "\"" doc_name[id] "\"  +" fmt_dur(ts - ingest_start))
        }
        pending_fname = ""; ingest_start = 0
      }
    }
  }

  # ── paperless-gpt: vision OCR ──────────────────────────────────────────────
  if (svc == "paperless-gpt") {
    id = doc_id_from(msg)
    if (id == "") next

    if (msg ~ /[Ss]tarting OCR processing/) {
      ocr_start[id] = ts
      if (fmt == "jsonl") {
        emit_jsonl(ts, id, "ocr_start", "qwen2.5vl:7b", 0)
      } else {
        emit_human(YLW, ts, id, "OCR start", "")
      }
    }

    if (msg ~ /[Ss]uccessfully processed document OCR/) {
      pages = 0
      if (match(msg, /([0-9]+) page/, pm)) pages = pm[1]+0
      dur = (id in ocr_start) ? ts - ocr_start[id] : -1
      ocr_end[id] = ts; ocr_dur[id] = (dur >= 0) ? dur : 0

      if (fmt == "jsonl") {
        emit_jsonl(ts, id, "ocr_end", "qwen2.5vl:7b", pages)
      } else {
        detail = (dur >= 0) ? "+" fmt_dur(dur) : ""
        if (pages > 0 && dur > 0) detail = detail "  (" pages "pg, " int(dur/pages) "s/pg)"
        emit_human(YLW, ts, id, "OCR done", detail)
      }
    }
  }

  # ── paperless-ai-next: classification ──────────────────────────────────────
  if (svc == "paperless-ai-next") {

    if (msg ~ /Scan started/) {
      classify_start = ts
    }

    if (match(msg, /\[DEBUG\] Document (.+) added to processed_documents/, m)) {
      pending_title = m[1]
    }

    if (match(msg, /Metrics added for document ([0-9]+)/, m)) {
      id = m[1]
      if (pending_title != "") { doc_name[id] = pending_title; pending_title = "" }
    }

    if (msg ~ /\[SUCCESS\]/ && match(msg, /document ([0-9]+)/, m)) {
      id = m[1]
      title  = (id in doc_name) ? doc_name[id] : "?"
      c_dur  = (classify_start > 0) ? ts - classify_start : -1
      i_ts   = (id in ingest_end)   ? ingest_end[id] : 0
      total  = (i_ts > 0)           ? ts - i_ts : -1

      if (fmt == "jsonl") {
        cs = (classify_start > 0) ? classify_start : ts
        emit_jsonl(cs, id, "classify_start", "qwen3:14b", 0)
        emit_jsonl(ts, id, "classify_end",   "qwen3:14b", 0)
      } else {
        detail = "\"" title "\""
        if (c_dur >= 0) detail = detail "  classify=" fmt_dur(c_dur)
        if (total >= 0) detail = detail "  " BLD "total=" fmt_dur(total) RST CYN
        emit_human(CYN, ts, id, "CLASSIFIED", detail)
      }

      classify_start = 0
      delete ocr_start[id]; delete ocr_end[id]; delete ocr_dur[id]
      delete ingest_end[id]; delete doc_name[id]
    }
  }
}
'
