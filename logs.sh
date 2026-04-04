#!/usr/bin/env bash
# logs.sh — tail logs from all containers simultaneously with color-coded prefixes
#
# Each container gets a unique color for easy visual scanning.
# Press Ctrl-C to stop.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

# ANSI color codes — one per container, cycling if more containers than colors
COLORS=(
  "31"  # red
  "32"  # green
  "33"  # yellow
  "34"  # blue
  "35"  # magenta
  "36"  # cyan
  "91"  # bright red
  "92"  # bright green
  "93"  # bright yellow
  "94"  # bright blue
)
RESET="\033[0m"

echo "=== Tailing logs (Ctrl-C to stop) ==="
echo ""

# Kill all background log jobs cleanly on exit
trap 'kill $(jobs -p) 2>/dev/null; echo ""; echo "Logs closed."' EXIT INT TERM

i=0
for c in "${CONTAINERS[@]}"; do
  if docker container inspect "$c" &>/dev/null 2>&1; then
    color="${COLORS[$((i % ${#COLORS[@]}))]}"
    docker logs -f --tail=20 --timestamps "$c" 2>&1 | \
      awk -v col="$(printf "\033[${color};1m")" -v rst="$(printf "\033[0m")" -v name="[${c}]" '
        BEGIN {
          w = 23
          # Compute local UTC offset in seconds from system timezone
          _z = strftime("%z", systime())  # e.g. "+0200"
          _sign = (substr(_z,1,1) == "+") ? 1 : -1
          tz_offset = _sign * (substr(_z,2,2)*3600 + substr(_z,4,2)*60)
        }
        function ts_to_epoch(ts,    parts) {
          split(ts, parts, /[-: ]/)
          # mktime treats input as local time; input is UTC, so add offset to correct
          return mktime(parts[1] " " parts[2] " " parts[3] " " parts[4] " " parts[5] " " parts[6]) + tz_offset
        }
        function get_doc_id(line,    i, n, parts) {
          n = split(line, parts, / /)
          for (i = 1; i <= n; i++)
            if (index(parts[i], "document_id=") == 1) return substr(parts[i], 13)
          return ""
        }
        {
          split($1, a, /[T.]/)
          ts = strftime("%Y-%m-%d %H:%M:%S", ts_to_epoch(a[1] " " a[2]))
          sub(/^[^ ]+ /, "")
          sub(/^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2},[0-9]+\] /, "")
          sub(/^time="[^"]+" /, "")
          sub(/level=[a-z]+ /, "")
          if (index($0, "Starting OCR processing") > 0) {
            doc = get_doc_id($0)
            if (doc != "") start_times[doc] = ts_to_epoch(a[1] " " a[2])
          }
          if (index($0, "Successfully processed document OCR") > 0) {
            doc = get_doc_id($0)
            if (doc != "" && doc in start_times) {
              elapsed = ts_to_epoch(a[1] " " a[2]) - start_times[doc]
              delete start_times[doc]
              printf "%s%-*s%s %s  \033[1;7m  OCR doc %s — %ds  \033[0m\n", col, w, name, rst, ts, doc, elapsed
            }
          }
          printf "%s%-*s%s %s  %s\n", col, w, name, rst, ts, $0
        }
      ' &
    (( ++i ))
  else
    echo "  SKIP: $c not found (run ./setup.sh)"
  fi
done

# Wait for all background jobs — exits when Ctrl-C fires the trap above
wait
