#!/usr/bin/env sh
# scripts/pipeline-timing-container.sh — runs inside the pipeline-timing Docker service.
# Prints one status line per pipeline event so Dozzle shows live progress per document.
#
# Output format:
#   [HH:MM:SS] #17  INGESTED    "WhatsApp Image 2026-03-22..."
#   [HH:MM:SS] #17  OCR start
#   [HH:MM:SS] #17  OCR done    47s  (1pg, 47s/pg)
#   [HH:MM:SS] #17  CLASSIFIED  "Honorarnote 2026/00263"  classify=18s  total=65s
#
# Requires: gawk (installed by the compose service command before exec'ing this)
# Requires: /var/run/docker.sock mounted (to run docker logs)
set -eu

PROJ="${COMPOSE_PROJECT_NAME:-paperless}"
C_PAPERLESS="${PROJ}-paperless-1"
C_GPT="${PROJ}-paperless-gpt-1"
C_AI="${PROJ}-paperless-ai-next-1"

for c in "$C_PAPERLESS" "$C_GPT" "$C_AI"; do
  until docker inspect --format '{{.State.Running}}' "$c" 2>/dev/null | grep -q true; do
    echo "pipeline-timing: waiting for $c..."
    sleep 5
  done
done

echo "=== Pipeline Timing ready — watching for documents ==="

{
  docker logs --follow --timestamps --since 5m "$C_PAPERLESS" 2>&1 \
    | awk '{ print "paperless | " $0 }' &
  docker logs --follow --timestamps --since 5m "$C_GPT" 2>&1 \
    | awk '{ print "paperless-gpt | " $0 }' &
  docker logs --follow --timestamps --since 5m "$C_AI" 2>&1 \
    | awk '{ print "paperless-ai-next | " $0 }' &
  wait
} | gawk '
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

function fmt(s) {
  if (s < 60) return s "s"
  return int(s/60) "m " (s%60) "s"
}

function doc_id_from(line,    m) {
  if (match(line, /document_id=([0-9]+)/, m)) return m[1]
  if (match(line, /document ([0-9]+)/, m))    return m[1]
  if (match(line, /documents\/([0-9]+)/, m))  return m[1]
  return ""
}

function emit(color, ts, id, stage, detail) {
  printf "%s[%s] #%-5s %-12s%s%s\n", color, hms(ts), id, stage, detail, RST
  fflush()
}

{
  # Parse "service | <docker-ts> <message>"
  if (!match($0, /^([a-zA-Z0-9_-]+) \| ([0-9T:Z.\-]+) (.*)/, m)) next
  svc = m[1]; ts = parse_ts(m[2]); msg = m[3]

  # ── Paperless: ingest ────────────────────────────────────────────────────────
  if (svc == "paperless") {

    # Consuming /path/to/file.pdf  →  record filename + ingest start time
    if (match(msg, /Consuming (.+)/, m)) {
      fname = m[1]; gsub(/\s.*/, "", fname)          # strip trailing noise
      gsub(/.*\//, "", fname)                        # basename only
      pending_fname = fname
      ingest_start  = ts
    }

    # "Created document: 17" or "New document id 17 created" → INGESTED
    if (msg ~ /[Cc]reated.*document|[Nn]ew document id/) {
      id = doc_id_from(msg)
      if (id != "" && ingest_start > 0) {
        doc_name[id]    = (pending_fname != "") ? pending_fname : "?"
        ingest_end[id]  = ts
        emit(GRN, ts, id, "INGESTED", "\"" doc_name[id] "\"  +" fmt(ts - ingest_start))
        pending_fname = ""; ingest_start = 0
      }
    }
  }

  # ── paperless-gpt: vision OCR ────────────────────────────────────────────────
  if (svc == "paperless-gpt") {
    id = doc_id_from(msg)
    if (id == "") next

    # OCR start
    if (msg ~ /[Ss]tarting OCR processing/) {
      ocr_start[id] = ts
      emit(YLW, ts, id, "OCR start", "")
    }

    # OCR done
    if (msg ~ /[Ss]uccessfully processed document OCR/) {
      dur = (id in ocr_start) ? ts - ocr_start[id] : -1
      pages = 0
      if (match(msg, /([0-9]+) page/, pm)) pages = pm[1]+0
      detail = (dur >= 0) ? "+" fmt(dur) : ""
      if (pages > 0 && dur > 0) detail = detail "  (" pages "pg, " int(dur/pages) "s/pg)"
      ocr_end[id] = ts; ocr_dur[id] = (dur >= 0) ? dur : 0
      emit(YLW, ts, id, "OCR done", detail)
    }
  }

  # ── paperless-ai-next: classification ────────────────────────────────────────
  if (svc == "paperless-ai-next") {

    # "Scan started" → record classify start time
    if (msg ~ /Scan started/) {
      classify_start = ts
    }

    # "[DEBUG] Document <title> added to processed_documents" → capture title (no ID yet)
    if (match(msg, /\[DEBUG\] Document (.+) added to processed_documents/, m)) {
      pending_title = m[1]
    }

    # "[DEBUG] Metrics added for document N" → associate pending title with ID
    if (match(msg, /Metrics added for document ([0-9]+)/, m)) {
      id = m[1]
      if (pending_title != "") { doc_name[id] = pending_title; pending_title = "" }
    }

    # "[SUCCESS] Updated document N with:" → CLASSIFIED
    if (msg ~ /\[SUCCESS\]/ && match(msg, /document ([0-9]+)/, m)) {
      id = m[1]
      title  = (id in doc_name) ? doc_name[id] : "?"
      c_dur  = (classify_start > 0) ? ts - classify_start : -1
      i_ts   = (id in ingest_end)   ? ingest_end[id] : 0
      total  = (i_ts > 0)           ? ts - i_ts : -1

      detail = "\"" title "\""
      if (c_dur >= 0) detail = detail "  classify=" fmt(c_dur)
      if (total >= 0) detail = detail "  " BLD "total=" fmt(total) RST CYN

      emit(CYN, ts, id, "CLASSIFIED", detail)
      classify_start = 0

      delete ocr_start[id]; delete ocr_end[id]; delete ocr_dur[id]
      delete ingest_end[id]; delete doc_name[id]
    }
  }
}
'
