#!/usr/bin/env sh
# scripts/pipeline-timing-container.sh — runs inside the pipeline-timing Docker service.
#
# Merges logs from the three AI pipeline containers, feeds them through the same
# awk timing processor used by pipeline-timing.sh, and writes per-document timing
# lines to stdout so Dozzle picks them up.
#
# Requires: gawk (installed by the compose service command before exec'ing this)
# Requires: /var/run/docker.sock mounted (to run docker logs)
#
# Container names follow the compose project name convention:
#   <project>-<service>-1  (e.g. paperless-paperless-1)
set -eu

PROJ="${COMPOSE_PROJECT_NAME:-paperless}"
C_PAPERLESS="${PROJ}-paperless-1"
C_GPT="${PROJ}-paperless-gpt-1"
C_AI="${PROJ}-paperless-ai-next-1"

# Wait until all three containers are running before tailing logs.
for c in "$C_PAPERLESS" "$C_GPT" "$C_AI"; do
  until docker inspect --format '{{.State.Running}}' "$c" 2>/dev/null | grep -q true; do
    echo "pipeline-timing: waiting for $c..."
    sleep 5
  done
done

echo "=== Pipeline Timing ready — watching for documents ==="

# Merge the three log streams with a "service  | timestamp message" prefix so the
# awk parser below sees the same format as `docker compose logs --timestamps`.
# Each docker logs process runs in the background; `wait` keeps the subshell alive.
{
  docker logs --follow --timestamps --since 5m "$C_PAPERLESS" 2>&1 \
    | awk '{ print "paperless  | " $0 }' &
  docker logs --follow --timestamps --since 5m "$C_GPT" 2>&1 \
    | awk '{ print "paperless-gpt  | " $0 }' &
  docker logs --follow --timestamps --since 5m "$C_AI" 2>&1 \
    | awk '{ print "paperless-ai-next  | " $0 }' &
  wait
} | gawk -v tz_offset=0 '
BEGIN {
  BLD = "\033[1m"
  CYN = "\033[0;36m"
  RST = "\033[0m"
}

# Parse ISO 8601 UTC timestamp → epoch seconds.
function parse_ts(s,    parts) {
  gsub(/T/, " ", s)
  gsub(/\.[0-9]+Z?$/, "", s)
  gsub(/Z$/, "", s)
  split(s, parts, /[-: ]/)
  return mktime(parts[1] " " parts[2] " " parts[3] " " parts[4] " " parts[5] " " parts[6]) + tz_offset
}

# Extract a numeric document id from a log line.
function extract_doc_id(line,    m) {
  if (match(line, /document_id=([0-9]+)/, m)) return m[1]
  if (match(line, /documents\/([0-9]+)/, m))  return m[1]
  if (match(line, /document id ([0-9]+)/, m)) return m[1]
  if (match(line, /document ([0-9]+)/, m))    return m[1]
  if (match(line, /#([0-9]+)/, m))            return m[1]
  return ""
}

# Format elapsed seconds as "87s" or "2m 7s".
function fmt(s) {
  if (s < 60) return s "s"
  return int(s/60) "m " (s % 60) "s"
}

{
  # Parse "service  | 2026-04-04T14:23:01.123Z message"
  if (match($0, /^([a-zA-Z0-9_-]+)[[:space:]]+\|[[:space:]]+([0-9T:Z.\-]+)[[:space:]]+(.*)/, m)) {
    svc    = m[1]
    raw_ts = m[2]
    msg    = m[3]
  } else {
    svc    = "unknown"
    msg    = $0
    raw_ts = ""
  }
  ts = (raw_ts != "") ? parse_ts(raw_ts) : systime()

  # ── Stage 1: Paperless ingest + Tesseract OCR ────────────────────────────────
  if (svc ~ /^paperless(-[0-9]+)?$/) {
    if (msg ~ /Consuming|Processing incoming/ && msg !~ /Done|complete/) {
      fname = msg
      gsub(/.*Consuming /, "", fname)
      gsub(/.*Processing incoming /, "", fname)
      gsub(/[[:space:]].*/, "", fname)
      pending_ingest[fname] = ts
    }
    if (msg ~ /New document id [0-9]+ created/ || msg ~ /created new document/ || msg ~ /saved document/) {
      doc_id = extract_doc_id(msg)
      if (doc_id != "") {
        for (fname in pending_ingest) {
          stage1_end[doc_id] = ts
          stage1_dur[doc_id] = ts - pending_ingest[fname]
          delete pending_ingest[fname]
          break
        }
      }
    }
  }

  # ── Stage 2: paperless-gpt vision OCR ───────────────────────────────────────
  if (svc ~ /paperless.gpt/) {
    doc_id = extract_doc_id(msg)
    if (msg ~ /[Ss]tarting OCR|[Pp]rocessing document|[Ff]etching.*OCR/) {
      if (doc_id != "") stage2_start[doc_id] = ts
    }
    if (msg ~ /[Ss]uccessfully processed|OCR complete|[Ff]inished.*OCR|[Uu]pdating.*content/) {
      if (doc_id != "" && doc_id in stage2_start && !(doc_id in stage2_end)) {
        stage2_end[doc_id] = ts
        stage2_dur[doc_id] = ts - stage2_start[doc_id]
        pages = 0
        if (match(msg, /([0-9]+) pages?/, pm)) pages = pm[1]+0
        stage2_pages[doc_id] = pages
        pgs = (pages > 0) ? sprintf(" (%dpg, %ds/pg)", pages, int(stage2_dur[doc_id]/pages)) : ""
        printf "%s  VisionOCR done  DOC #%-6s %s%s — waiting for classify...%s\n", CYN, doc_id, fmt(stage2_dur[doc_id]), pgs, RST
        fflush()
      }
    }
  }

  # ── Stage 3: paperless-ai-next classification ────────────────────────────────
  if (svc ~ /paperless.ai/) {
    doc_id = extract_doc_id(msg)
    # Mark start on "Scan started" (no per-doc start line exists in this app)
    if (msg ~ /Scan started/) {
      scan_start = ts
    }
    # End: "[SUCCESS] Updated document X with:" is the only per-doc completion line
    if (msg ~ /\[SUCCESS\].*[Uu]pdated document|[Ss]uccessfully.*updated.*document/) {
      if (doc_id != "") {
        stage3_end[doc_id] = ts
        # Use scan_start as best approximation if we have it; otherwise stage3 dur = "?"
        if (scan_start > 0) {
          stage3_dur[doc_id] = ts - scan_start
          scan_start = 0
        } else {
          stage3_dur[doc_id] = -1
        }

        total = 0; row = ""

        s1 = (doc_id in stage1_dur) ? stage1_dur[doc_id]+0 : -1
        total += (s1 > 0) ? s1 : 0
        row = row sprintf("  Ingest: %s", (s1 >= 0) ? fmt(s1) : "?")

        s2 = (doc_id in stage2_dur) ? stage2_dur[doc_id]+0 : -1
        total += (s2 > 0) ? s2 : 0
        pg = (doc_id in stage2_pages && stage2_pages[doc_id] > 0) ? stage2_pages[doc_id]+0 : 0
        if (s2 >= 0) {
          pgs = (pg > 0) ? sprintf(" (%dpg, %ds/pg)", pg, int(s2/pg)) : ""
          row = row sprintf("  VisionOCR: %s%s", fmt(s2), pgs)
        } else {
          row = row "  VisionOCR: ?"
        }

        s3 = stage3_dur[doc_id]+0
        if (s3 >= 0) {
          total += s3
          row = row sprintf("  Classify: %s", fmt(s3))
        } else {
          row = row "  Classify: ?"
        }
        row = row sprintf("  " BLD "TOTAL: %s" RST, (total > 0) ? fmt(total) : "?")

        t = strftime("%Y-%m-%dT%H:%M:%SZ", stage3_end[doc_id])
        printf "%s[%s]  DOC #%-6s%s\n", CYN, t, doc_id, row RST
        fflush()

        delete stage1_dur[doc_id]; delete stage1_end[doc_id]
        delete stage2_start[doc_id]; delete stage2_end[doc_id]
        delete stage2_dur[doc_id];   delete stage2_pages[doc_id]
        delete stage3_end[doc_id]; delete stage3_dur[doc_id]
      }
    }
  }
}
'
