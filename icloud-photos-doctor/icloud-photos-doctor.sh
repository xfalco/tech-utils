#!/bin/zsh
# Diagnose iCloud Photos sync from the ground truth (Photos.sqlite + the sync
# engine's own state files) instead of the Photos UI, which shows a stale
# "Last Synced" label and hides stuck uploads entirely.
#
#   ./icloud-photos-doctor.sh                diagnose (read-only)
#   ./icloud-photos-doctor.sh --kick         apply the safe unwedge (restart cloudphotod)
#   ./icloud-photos-doctor.sh --library PATH use a specific .photoslibrary
#   ./icloud-photos-doctor.sh --logs         also scan recent logs for quota errors (slow)
#
# Run it twice, ~15+ minutes apart: the second run measures upload movement
# against a snapshot and can tell "slow" from "stuck".
#
# Distilled from a July 2026 investigation of an eight-day up-sync wedge:
# pending soft resets in resetevents.plist blocked all outgoing work while the
# engine reported itself healthy and the UI showed nothing.
set -euo pipefail

LIBRARY=""
KICK=0
SCAN_LOGS=0
while (( $# > 0 )); do
  case "$1" in
    --library) LIBRARY="$2"; shift 2 ;;
    --kick) KICK=1; shift ;;
    --logs) SCAN_LOGS=1; shift ;;
    *) print "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# ---------- discover the system photo library ----------
if [[ -z "$LIBRARY" ]]; then
  PLD_PID=$(pgrep -x photolibraryd | head -1 || true)
  if [[ -n "$PLD_PID" ]]; then
    LIBRARY=$(lsof -p "$PLD_PID" 2>/dev/null | grep -o '/.*\.photoslibrary' | head -1 || true)
  fi
fi
if [[ -z "$LIBRARY" ]]; then
  for candidate in "$HOME/Pictures/"*.photoslibrary(N); do
    LIBRARY="$candidate"; break
  done
fi
if [[ -z "$LIBRARY" || ! -d "$LIBRARY" ]]; then
  print "🔴 No Photos library found (photolibraryd not running, nothing in ~/Pictures)."
  print "   Pass one explicitly: --library '/path/to/Photos Library.photoslibrary'"
  exit 1
fi

CPL="$LIBRARY/resources/cpl/cloudsync.noindex"
NOW=$(date +%s)
print "iCloud Photos doctor — $(date '+%Y-%m-%d %H:%M')"
print "Library: $LIBRARY"
print "${(l:64::-:):-}"

# ---------- safe copy of the database trio ----------
if [[ ! -f "$LIBRARY/database/Photos.sqlite" ]]; then
  print "🔴 No database/Photos.sqlite inside the library — wrong path, or the volume just remounted?"
  exit 1
fi
SCRATCH=$(mktemp -d -t icloud-photos-doctor)
trap 'rm -rf "$SCRATCH"' EXIT
for suffix in "" "-wal" "-shm"; do
  [[ -f "$LIBRARY/database/Photos.sqlite$suffix" ]] && cp "$LIBRARY/database/Photos.sqlite$suffix" "$SCRATCH/"
done
DB="$SCRATCH/Photos.sqlite"

# ---------- library integrity (matters after drive drops) ----------
CHECK=$(sqlite3 "$DB" 'PRAGMA quick_check(3);' 2>&1 | head -1)
if [[ "$CHECK" != "ok" ]]; then
  print "🔴 Database integrity: $CHECK"
  print "   → The library database is damaged. Quit Photos, relaunch holding Option+Command,"
  print "     and run Repair Library. Diagnose sync again afterwards."
  exit 1
fi
print "Database integrity      : ok"

# ---------- core counts ----------
read -r TOTAL SYNCED AWAITING OTHER <<< "$(sqlite3 -readonly "$DB" "
  SELECT COUNT(*),
         SUM(ZCLOUDLOCALSTATE = 1),
         SUM(ZCLOUDLOCALSTATE = 0),
         SUM(ZCLOUDLOCALSTATE NOT IN (0,1))
  FROM ZASSET WHERE ZBUNDLESCOPE = 0 AND ZTRASHEDSTATE = 0;" | tr '|' ' ')"
DAY_CUT=$(( NOW - 978307200 - 86400 ))
WEEK_CUT=$(( NOW - 978307200 - 604800 ))
read -r ADDED_DAY ADDED_WEEK <<< "$(sqlite3 -readonly "$DB" "
  SELECT SUM(ZADDEDDATE > $DAY_CUT), SUM(ZADDEDDATE > $WEEK_CUT)
  FROM ZASSET WHERE ZBUNDLESCOPE = 0 AND ZTRASHEDSTATE = 0;" | tr '|' ' ')"
print "Library assets          : $TOTAL  (synced: $SYNCED, awaiting upload: $AWAITING, other: ${OTHER:-0})"
print "Down-sync (added 24h/7d): ${ADDED_DAY:-0} / ${ADDED_WEEK:-0}"

# ---------- sync engine state files ----------
PENDING_RESETS=0
OLDEST_RESET_AGE_H=0
if [[ -f "$CPL/resetevents.plist" ]]; then
  PENDING_RESETS=$(plutil -p "$CPL/resetevents.plist" 2>/dev/null | grep -cE '"pending" => true' || true)
  RESET_MTIME=$(stat -f %m "$CPL/resetevents.plist" 2>/dev/null || print 0)
  OLDEST_RESET_AGE_H=$(( (NOW - RESET_MTIME) / 3600 ))
fi
LIB_EXISTS=$(plutil -p "$CPL/syncstatus.plist" 2>/dev/null | grep iCloudLibraryExists | grep -c true || true)
INITIAL_SYNC=$(plutil -p "$CPL/syncstatus.plist" 2>/dev/null | grep initialSyncDate | grep -o '20[0-9-]* [0-9:]*' | head -1 || true)
CLOUD_COUNT=$(plutil -p "$CPL/syncstatus.plist" 2>/dev/null | grep -E 'public\.(image|movie)' | grep -o '[0-9]*$' | paste -sd+ - | bc 2>/dev/null || true)
OUT_MTIME=$(stat -f %m "$CPL/outgoingRecordComputeStates" 2>/dev/null || print 0)
OUT_AGE_H=$(( (NOW - OUT_MTIME) / 3600 ))
ENABLED=0
[[ -f "$CPL/cpl_enabled_marker" ]] && ENABLED=1

print "Pending engine resets   : $PENDING_RESETS$([[ $PENDING_RESETS -gt 0 ]] && print -n \" (file age ${OLDEST_RESET_AGE_H}h)\")"
print "Cloud library attached  : $([[ ${LIB_EXISTS:-0} -ge 1 ]] && print yes || print NO)"
[[ -n "$CLOUD_COUNT" ]] && print "Cloud-side asset count  : $CLOUD_COUNT  (local minus cloud: $(( TOTAL - CLOUD_COUNT )))"
[[ -n "$INITIAL_SYNC" ]] && print "Engine initial sync     : $INITIAL_SYNC  ← the UI's “Last Synced” label often shows this, not reality"
print "Outgoing pipeline touch : $([[ $OUT_MTIME -eq 0 ]] && print never || print "${OUT_AGE_H}h ago")"

# ---------- daemons ----------
for daemon in cloudphotod photolibraryd; do
  DPID=$(pgrep -x "$daemon" | head -1 || true)
  if [[ -n "$DPID" ]]; then
    print "Daemon $daemon : up since $(ps -p "$DPID" -o lstart= | sed 's/^ *//'), cpu $(ps -p "$DPID" -o time= | tr -d ' ')"
  else
    print "Daemon $daemon : NOT RUNNING"
  fi
done

# ---------- optional: quota errors in recent logs ----------
if (( SCAN_LOGS )); then
  print "Scanning 30m of logs for quota/storage errors (slow)…"
  HITS=$(log show --last 30m --predicate 'process == "cloudphotod" AND (eventMessage CONTAINS[c] "quota" OR eventMessage CONTAINS[c] "insufficient" OR eventMessage CONTAINS[c] "storage full")' 2>/dev/null | grep -vcE "^Timestamp|^Filtering" || true)
  print "Quota-ish log lines     : ${HITS:-0}"
fi

# ---------- movement vs last run ----------
CACHE_DIR="$HOME/.cache/icloud-photos-doctor"
mkdir -p "$CACHE_DIR"
SNAP="$CACHE_DIR/$(print "$LIBRARY" | shasum | cut -c1-12).snap"
MOVEMENT=""
if [[ -f "$SNAP" ]]; then
  read -r PREV_TS PREV_AWAITING < "$SNAP"
  ELAPSED_M=$(( (NOW - PREV_TS) / 60 ))
  DELTA=$(( PREV_AWAITING - AWAITING ))
  if (( ELAPSED_M >= 5 )); then
    MOVEMENT="measured"
    if (( DELTA > 0 )); then
      RATE=$(( DELTA / (ELAPSED_M > 0 ? ELAPSED_M : 1) ))
      ETA_H=$(( RATE > 0 ? AWAITING / RATE / 60 : 0 ))
      print "Upload movement         : $DELTA fewer awaiting than ${ELAPSED_M}m ago (~$RATE/min$( (( RATE > 0 && AWAITING > 0 )) && print -n \", rough ETA ${ETA_H}h\"))"
    elif (( DELTA < 0 )); then
      print "Upload movement         : awaiting GREW by $(( -DELTA )) in ${ELAPSED_M}m (new items, or a re-baseline re-marking the library)"
    else
      print "Upload movement         : none in ${ELAPSED_M}m"
    fi
  fi
fi
print "$NOW $AWAITING" > "$SNAP"

# ---------- verdict ----------
print "${(l:64::-:):-}"
if (( PENDING_RESETS > 0 && OLDEST_RESET_AGE_H > 24 )); then
  print "🔴 WEDGED: $PENDING_RESETS engine reset(s) pending for ${OLDEST_RESET_AGE_H}h. While resets are"
  print "   pending, no uploads are scheduled — this survives reboots."
  print "   1. Try: $0 --kick   (each fresh cloudphotod sometimes clears one reset)"
  print "   2. If resets stay pending: Photos → Settings → iCloud → uncheck iCloud Photos,"
  print "      wait 2–3 min, re-check it (keep/download originals at every prompt)."
  print "      That re-baseline discards the stuck state; expect it to chew for hours."
elif [[ ${LIB_EXISTS:-0} -eq 0 && $ENABLED -eq 1 ]]; then
  print "🟠 ATTACH LIMBO: iCloud Photos is enabled but the engine hasn't attached to the"
  print "   cloud library (seen after an interrupted enable or a drive drop mid-sync)."
  print "   Run: $0 --kick"
elif (( AWAITING == 0 )); then
  print "✅ Fully uploaded. $([[ ${ADDED_WEEK:-0} -eq 0 ]] && print 'Note: nothing added in 7 days — if other devices are taking photos, check down-sync.' || print 'Down-sync is alive.')"
elif (( TOTAL > 0 && AWAITING * 100 / TOTAL > 60 )); then
  print "🔵 RE-BASELINE IN PROGRESS: most of the library is marked un-synced, which is"
  print "   normal right after toggling iCloud Photos — the count climbs, then drains"
  print "   (fast fingerprint matching first, real uploads after). Keep Photos open on AC."
elif [[ "$MOVEMENT" == "measured" ]] && (( DELTA <= 0 )) && (( OUT_AGE_H >= 1 )); then
  print "🟠 STUCK: $AWAITING awaiting upload, no movement, and the outgoing pipeline"
  print "   hasn't been touched in ${OUT_AGE_H}h. The scheduler is dormant."
  print "   Run: $0 --kick   then re-run this doctor in ~15 min."
elif [[ "$MOVEMENT" == "measured" ]] && (( DELTA > 0 )); then
  print "🟢 UPLOADING NORMALLY: $AWAITING to go and draining. Keep Photos open on AC power."
else
  print "🟡 $AWAITING awaiting upload — no movement baseline yet."
  print "   Re-run in ~15 min; the second run measures whether uploads are draining or stuck."
fi

# ---------- the safe fix ----------
if (( KICK )); then
  print "${(l:64::-:):-}"
  print "Kicking cloudphotod (launchctl kickstart is SIP-blocked; killall works)…"
  killall cloudphotod 2>/dev/null || true
  sleep 5
  open -a Photos
  sleep 5
  NEW=$(pgrep -x cloudphotod | head -1 || true)
  if [[ -n "$NEW" ]]; then
    print "Fresh cloudphotod up (pid $NEW). Re-run this doctor in ~15 min to measure."
  else
    print "cloudphotod not up yet — it spawns on demand; interact with Photos and re-run."
  fi
fi
