#!/bin/zsh
# Post-incident forensics for Thunderbolt storage drops.
# Pulls from the macOS unified log store, so it works even for windows where
# tb-watch was not running (the store retains default-level kernel events for
# days). Each section streams a separate `log show` pass; expect ~1 min total.
#   ./tb-forensics.sh [window]     window like 45m, 3h (default), 1d
set -uo pipefail

WINDOW="${1:-3h}"

show() { # show <predicate> <tail-count>
  /usr/bin/log show --last "$WINDOW" --info --style compact --predicate "$1" 2>/dev/null \
    | grep -vE "^(Filtering|Timestamp)" | tail -"$2"
}

print "===== NVMe fatals / timeouts / asserts (last $WINDOW) ====="
show '(eventMessage CONTAINS "FatalHandling") OR (eventMessage CONTAINS "CommandTimeout") OR (eventMessage CONTAINS "AppleNVMe Assert")' 30

print "\n===== PCIe domain teardown markers (last $WINDOW) ====="
show '(eventMessage CONTAINS "disableGated") OR (eventMessage CONTAINS "needing hardware reset") OR (eventMessage CONTAINS "dead child")' 20

print "\n===== Volume unmount order (last $WINDOW) ====="
show '(sender == "apfs" AND eventMessage CONTAINS "unmounting volume")' 20

print "\n===== PCIe hotplug interrupts (last $WINDOW) ====="
show 'eventMessage CONTAINS "hotpInt"' 15

print "\n===== Current Thunderbolt tree ====="
system_profiler SPThunderboltDataType 2>/dev/null \
  | grep -E "Device Name|Speed|Status|Route String|Firmware" | sed 's/^ *//'

print "\n===== Current external disks ====="
diskutil list external

print "\n===== Recent sleep/wake/power ====="
pmset -g log | grep -E "(Entering Sleep|Wake from|DarkWake|Using AC|Using Batt)" | tail -8
