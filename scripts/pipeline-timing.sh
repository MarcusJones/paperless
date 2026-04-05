#!/usr/bin/env bash
# scripts/pipeline-timing.sh — per-document pipeline stage timing
#
# Tails docker compose logs for the three AI pipeline services and prints
# per-document timing across all three stages:
#
#   Stage 1 (Ingest + Tesseract OCR):  paperless consumer
#   Stage 2 (Vision OCR):              paperless-gpt
#   Stage 3 (AI Classification):       paperless-ai-next
#
# Usage:
#   ./scripts/pipeline-timing.sh             # live tail mode (Ctrl-C to stop)
#   ./scripts/pipeline-timing.sh --summary   # aggregate stats from last 24h
#   ./scripts/pipeline-timing.sh --since 1h  # live tail starting 1 hour back
#
# ⚠️  Log format dependency (OQ8):
#   This script parses log lines emitted by paperless, paperless-gpt, and
#   paperless-ai-next. The patterns below are best-effort guesses based on
#   known log output. If timing shows 0s or missing stages, run with --debug
#   to print all matched raw log lines and adjust the patterns.
#
# Run from the repo root on the WSL host.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Parse args ────────────────────────────────────────────────────────────────
MODE="tail"
SINCE="0"
DEBUG=false
for arg in "$@"; do
  case "$arg" in
    --summary) MODE="summary" ;;
    --debug)   DEBUG=true ;;
    --since)   shift; SINCE="${1:-1h}" ;;
    --since=*) SINCE="${arg#--since=}" ;;
  esac
done

cd "$REPO_ROOT"

# ── Check compose stack ───────────────────────────────────────────────────────
if ! docker compose ps 2>/dev/null | grep -q "paperless"; then
  echo "ERROR: Compose stack not running. Run: docker compose up -d"
  exit 1
fi

# ── AWK timing processor ──────────────────────────────────────────────────────
# Reads interleaved docker compose logs and annotates with stage timing.
#
# Log line format from `docker compose logs --timestamps`:
#   <service>  | <ISO8601-timestamp> <log-message>
#   paperless  | 2026-04-04T14:23:01.123456789Z [2026-04-04 14:23:01,456] INFO ...
#
# Stage detection patterns (adjust these if logs differ):
#   Stage 1 start:  paperless "consumer" picks up file → "Consuming" in log
#   Stage 1 end:    paperless "Document created" or "saved document" with id
#   Stage 2 start:  paperless-gpt "Starting OCR processing" with document_id=
#   Stage 2 end:    paperless-gpt "Successfully processed document" with document_id=
#   Stage 3 start:  paperless-ai-next "Processing document" with document id
#   Stage 3 end:    paperless-ai-next "Successfully processed" or "tags applied"

TIMING_AWK='
BEGIN {
  # Color codes
  BLD = "\033[1m"
  GRN = "\033[0;32m"
  CYN = "\033[0;36m"
  YLW = "\033[1;33m"
  MAG = "\033[0;35m"
  RST = "\033[0m"
  BAR = "────────────────────────────────────────────────────────────"
}

# Parse ISO 8601 timestamp from docker compose logs prefix.
# Format: 2026-04-04T14:23:01.123456789Z → epoch seconds
function parse_ts(s,    parts) {
  # Replace T and Z/dot-fractional with spaces
  gsub(/T/, " ", s)
  gsub(/\.[0-9]+Z?$/, "", s)
  gsub(/Z$/, "", s)
  split(s, parts, /[-: ]/)
  # mktime is local time; logs are UTC — add UTC offset
  return mktime(parts[1] " " parts[2] " " parts[3] " " parts[4] " " parts[5] " " parts[6]) + tz_offset
}

# Extract a document id from a log line. Looks for:
#   document_id=<N>  |  document/<N>  |  #<N>  |  id <N>
function extract_doc_id(line,    m) {
  if (match(line, /document_id=([0-9]+)/, m)) return m[1]
  if (match(line, /documents\/([0-9]+)/, m))  return m[1]
  if (match(line, /document ([0-9]+)/, m))    return m[1]
  if (match(line, /#([0-9]+)/, m))            return m[1]
  return ""
}

# Format elapsed seconds as human-readable: "87s" or "2m 7s"
function fmt(s) {
  if (s < 60) return s "s"
  return int(s/60) "m " (s % 60) "s"
}

{
  # docker compose logs --timestamps format:
  #   service-name  | 2026-04-04T14:23:01.123Z actual log line
  if (match($0, /^([a-zA-Z0-9_-]+)[[:space:]]+\|[[:space:]]+([0-9T:Z.\-]+)[[:space:]]+(.*)/, m)) {
    svc  = m[1]
    raw_ts = m[2]
    msg  = m[3]
  } else {
    # fallback: no prefix
    svc = "unknown"
    msg = $0
    raw_ts = ""
  }

  ts = (raw_ts != "") ? parse_ts(raw_ts) : systime()

  if (debug) printf "DBG  svc=%s  msg=%.80s\n", svc, msg

  # ── Stage 1: Paperless ingest ──────────────────────────────────────────────
  if (svc ~ /^paperless$/) {
    # Start: consumer picks up a file
    if (msg ~ /Consuming|Processing incoming/ && msg !~ /Done|complete/) {
      # Try to get filename as a pseudo-id until we get the real doc id
      fname = msg
      gsub(/.*Consuming /, "", fname)
      gsub(/.*Processing incoming /, "", fname)
      gsub(/[[:space:]].*/, "", fname)
      pending_ingest[fname] = ts
      if (debug) printf "DBG  Stage1 start fname=%s\n", fname
    }

    # End: document assigned an id
    if ((msg ~ /created new document/ || msg ~ /saved document/) && msg ~ /[Ii][Dd]/) {
      doc_id = extract_doc_id(msg)
      if (doc_id != "") {
        # Match against any pending ingest (we may not know which filename maps here)
        for (fname in pending_ingest) {
          stage1_end[doc_id] = ts
          stage1_dur[doc_id] = ts - pending_ingest[fname]
          delete pending_ingest[fname]
          break
        }
        if (debug) printf "DBG  Stage1 end doc_id=%s dur=%ss\n", doc_id, stage1_dur[doc_id]
      }
    }
  }

  # ── Stage 2: paperless-gpt Vision OCR ─────────────────────────────────────
  if (svc ~ /paperless.gpt/) {
    doc_id = extract_doc_id(msg)

    # Start
    if (msg ~ /[Ss]tarting OCR|[Pp]rocessing document|[Ff]etching.*OCR/) {
      if (doc_id != "") {
        stage2_start[doc_id] = ts
        if (debug) printf "DBG  Stage2 start doc_id=%s\n", doc_id
      }
    }

    # End — paperless-gpt logs page count info
    if (msg ~ /[Ss]uccessfully processed|OCR complete|[Ff]inished.*OCR|[Uu]pdating.*content/) {
      if (doc_id != "" && doc_id in stage2_start) {
        stage2_end[doc_id]  = ts
        stage2_dur[doc_id]  = ts - stage2_start[doc_id]

        # Try to extract page count from log line: "N pages" or "page N of M"
        pages = 0
        if (match(msg, /([0-9]+) pages?/, pm)) pages = pm[1]+0
        stage2_pages[doc_id] = pages

        if (debug) printf "DBG  Stage2 end doc_id=%s dur=%ss pages=%d\n", doc_id, stage2_dur[doc_id], pages
      }
    }
  }

  # ── Stage 3: paperless-ai-next Classification ─────────────────────────────
  if (svc ~ /paperless.ai/) {
    doc_id = extract_doc_id(msg)

    # Start
    if (msg ~ /[Pp]rocessing document|[Ss]ending.*Ollama|[Cc]lassif/) {
      if (doc_id != "") {
        stage3_start[doc_id] = ts
        if (debug) printf "DBG  Stage3 start doc_id=%s\n", doc_id
      }
    }

    # End
    if (msg ~ /[Ss]uccessfully processed|[Tt]ags applied|[Cc]lassif.*complete|[Uu]pdated document/) {
      if (doc_id != "" && doc_id in stage3_start) {
        stage3_end[doc_id] = ts
        stage3_dur[doc_id] = ts - stage3_start[doc_id]

        # ── Print per-document row ───────────────────────────────────────────
        total = 0
        row   = ""

        # Stage 1
        s1 = (doc_id in stage1_dur) ? stage1_dur[doc_id]+0 : -1
        total += (s1 > 0) ? s1 : 0
        row = row sprintf("  Ingest: %s", (s1 >= 0) ? fmt(s1) : "?")

        # Model swap (gap between Stage 2 end and Stage 3 start)
        swap = -1
        if (doc_id in stage2_end && doc_id in stage3_start) {
          swap = stage3_start[doc_id] - stage2_end[doc_id]
          if (swap < 0) swap = 0
          total += swap
        }

        # Stage 2
        s2 = (doc_id in stage2_dur) ? stage2_dur[doc_id]+0 : -1
        total += (s2 > 0) ? s2 : 0
        pg = (doc_id in stage2_pages && stage2_pages[doc_id] > 0) ? stage2_pages[doc_id]+0 : 0
        if (s2 >= 0) {
          pgs = (pg > 0) ? sprintf(" (%dpg, %ds/pg)", pg, int(s2/pg)) : ""
          row = row sprintf("  VisionOCR: %s%s", fmt(s2), pgs)
        } else {
          row = row "  VisionOCR: ?"
        }

        # Swap
        if (swap >= 0) row = row sprintf("  Swap: %s", fmt(swap))

        # Stage 3
        s3 = stage3_dur[doc_id]+0
        total += s3
        row = row sprintf("  Classify: %s", fmt(s3))

        # Total
        row = row sprintf("  " BLD "TOTAL: %s" RST, fmt(total))

        # Timestamp prefix
        t = strftime("%Y-%m-%d %H:%M:%S", stage3_end[doc_id])
        printf "%s[%s]  DOC #%-6s%s\n", CYN, t, doc_id, row RST

        # Accumulate stats for --summary
        count++
        sum_total += total
        if (total > max_total) max_total = total
        if (min_total == 0 || total < min_total) min_total = total
        sum_s1 += (s1 > 0) ? s1 : 0
        sum_s2 += (s2 > 0) ? s2 : 0
        sum_s3 += s3

        # Cleanup
        delete stage1_dur[doc_id]; delete stage1_end[doc_id]
        delete stage2_start[doc_id]; delete stage2_end[doc_id]
        delete stage2_dur[doc_id]; delete stage2_pages[doc_id]
        delete stage3_start[doc_id]; delete stage3_end[doc_id]; delete stage3_dur[doc_id]
      }
    }
  }
}

END {
  if (summary_mode && count > 0) {
    printf "\n%s\n", BAR
    printf "Pipeline Summary (%d documents)\n", count
    printf "%s\n", BAR
    printf "Stage 1 (Ingest+OCR):  avg %s\n", fmt(int(sum_s1/count))
    printf "Stage 2 (VisionOCR):   avg %s\n", fmt(int(sum_s2/count))
    printf "Stage 3 (Classify):    avg %s\n", fmt(int(sum_s3/count))
    printf "End-to-end:            avg %s   min %s   max %s\n", \
      fmt(int(sum_total/count)), fmt(min_total), fmt(max_total)
    printf "%s\n\n", BAR
  }
}
'

# ── Compute UTC offset for awk mktime ─────────────────────────────────────────
TZ_OFFSET=$(python3 -c "import time; print(int(-time.timezone + (3600 if time.daylight and time.localtime().tm_isdst else 0)))" 2>/dev/null || echo 0)

# ── Run ────────────────────────────────────────────────────────────────────────
SERVICES="paperless paperless-gpt paperless-ai-next"
AWK_FLAGS="-v debug=${DEBUG} -v tz_offset=${TZ_OFFSET}"

if [[ "$MODE" == "summary" ]]; then
  echo "=== Pipeline Summary (last 24h) ==="
  echo ""
  docker compose logs --timestamps --since 24h $SERVICES 2>&1 | \
    awk $AWK_FLAGS -v summary_mode=1 "$TIMING_AWK"
else
  echo "=== Pipeline Timing (live — Ctrl-C to stop) ==="
  echo ""
  TAIL_ARGS="--timestamps --follow"
  [[ "$SINCE" != "0" ]] && TAIL_ARGS="$TAIL_ARGS --since ${SINCE}"
  # shellcheck disable=SC2086
  docker compose logs $TAIL_ARGS $SERVICES 2>&1 | \
    awk $AWK_FLAGS "$TIMING_AWK"
fi
