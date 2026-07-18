#!/bin/zsh
# tb-watch: persistent Thunderbolt/NVMe incident recorder.
# Streams curated kernel/storage events to ~/Library/Logs/tb-watch.log so
# post-incident forensics survive reboots and lost sessions.
# Managed by the com.tech-utils.tb-watch LaunchAgent (see install.sh).
#
# Disk use is hard-capped: the live log rotates to tb-watch.log.1 (discarding
# the previous .1) whenever it passes MAX_BYTES, checked every CHECK_INTERVAL
# seconds while streaming — worst case on disk is ~2 x MAX_BYTES.

LOG_DIR="$HOME/Library/Logs"
LOG_FILE="$LOG_DIR/tb-watch.log"
MAX_BYTES=$((25 * 1024 * 1024))
CHECK_INTERVAL=300

# One event vocabulary for both failure signatures seen in the Jul 2026
# investigation: drive-level NVMe fatals and whole-domain PCIe teardowns.
PREDICATE='(eventMessage CONTAINS "FatalHandling") OR (eventMessage CONTAINS "CommandTimeout") OR (eventMessage CONTAINS "AppleNVMe Assert") OR (eventMessage CONTAINS "hotpInt") OR (eventMessage CONTAINS "disableGated") OR (eventMessage CONTAINS "needing hardware reset") OR (eventMessage CONTAINS "dead child") OR (eventMessage CONTAINS "marking child") OR (eventMessage CONTAINS "unmounting volume") OR (sender == "IOThunderboltFamily")'

STREAM_PID=""
cleanup() {
  [[ -n "$STREAM_PID" ]] && kill "$STREAM_PID" 2>/dev/null
  exit 0
}
trap cleanup TERM INT

size_of() { stat -f%z "$1" 2>/dev/null || print 0; }

mkdir -p "$LOG_DIR"

while true; do
  if (( $(size_of "$LOG_FILE") > MAX_BYTES )); then
    mv -f "$LOG_FILE" "$LOG_FILE.1"
  fi
  print "===== tb-watch (re)started $(date '+%Y-%m-%d %H:%M:%S') =====" >> "$LOG_FILE"

  /usr/bin/log stream --info --style compact --predicate "$PREDICATE" >> "$LOG_FILE" 2>&1 &
  STREAM_PID=$!

  while kill -0 "$STREAM_PID" 2>/dev/null; do
    sleep "$CHECK_INTERVAL"
    if (( $(size_of "$LOG_FILE") > MAX_BYTES )); then
      kill "$STREAM_PID" 2>/dev/null
      break
    fi
  done
  wait "$STREAM_PID" 2>/dev/null
  STREAM_PID=""
  sleep 1  # stream rotated or died; loop restarts it (launchd KeepAlive is the outer guard)
done
