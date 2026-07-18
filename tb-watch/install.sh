#!/bin/zsh
# Install, update, or remove the tb-watch LaunchAgent.
#   ./install.sh              install or update (re-run after moving the repo)
#   ./install.sh --uninstall  stop and remove
set -euo pipefail

LABEL="com.tech-utils.tb-watch"
SCRIPT_DIR="${0:A:h}"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
UID_N=$(id -u)

if [[ "${1:-}" == "--uninstall" ]]; then
  launchctl bootout "gui/$UID_N/$LABEL" 2>/dev/null || true
  rm -f "$PLIST_DST"
  print "tb-watch uninstalled."
  exit 0
fi

mkdir -p "$HOME/Library/LaunchAgents"
sed -e "s|__REPO__|$SCRIPT_DIR|g" -e "s|__HOME__|$HOME|g" \
  "$SCRIPT_DIR/$LABEL.plist.template" > "$PLIST_DST"

launchctl bootout "gui/$UID_N/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_N" "$PLIST_DST"
sleep 1
launchctl print "gui/$UID_N/$LABEL" | grep -E "state =|pid =" || true
print "tb-watch installed. Log: $HOME/Library/Logs/tb-watch.log"
