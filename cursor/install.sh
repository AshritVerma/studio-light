#!/bin/bash
# Installs the Cursor sound pieces for this Mac's user (no sudo needed):
#   ~/bin/cursor-ping                  turn Cursor's agent sounds on/off/toggle
#   ~/bin/Toggle Cursor Ping.command   double-click toggle (drag it to the Dock)
#   ~/bin/cursor-ping-schedule         keeps those sounds matched to the studio-light hours
#   ~/.cursor/hooks/ping.sh            Cursor "agent finished" hook (banner + sound)
#   ~/.cursor/hooks.json               registers that hook (only if you don't have one yet)
# Then starts the schedule. Run studio-light setup first so there are hours to follow.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
STAMP=$(date +%Y%m%d-%H%M%S)

# Put SRC at DEST; if a different file is already there, keep it as DEST.bak-<time>.
put() {
  if [ -e "$2" ] && ! cmp -s "$1" "$2"; then
    cp -p "$2" "$2.bak-$STAMP"
    echo "kept your old $(basename "$2") as $(basename "$2").bak-$STAMP"
  fi
  cp "$1" "$2"
  chmod 755 "$2"
}

mkdir -p "$HOME/bin" "$HOME/.cursor/hooks"
put "$HERE/cursor-ping" "$HOME/bin/cursor-ping"
put "$HERE/cursor-ping-schedule" "$HOME/bin/cursor-ping-schedule"
put "$HERE/Toggle Cursor Ping.command" "$HOME/bin/Toggle Cursor Ping.command"
put "$HERE/hooks/ping.sh" "$HOME/.cursor/hooks/ping.sh"

HOOKS="$HOME/.cursor/hooks.json"
if [ ! -e "$HOOKS" ]; then
  cp "$HERE/hooks.json" "$HOOKS"
  echo "added ~/.cursor/hooks.json"
elif grep -q 'hooks/ping.sh' "$HOOKS"; then
  echo "your hooks.json already runs the ping hook"
else
  echo "NOTE: you already have ~/.cursor/hooks.json, so I left it alone. Add this to its \"stop\" list:"
  echo '      { "command": "./hooks/ping.sh", "timeout": 5 }'
fi

# A short `cursor-ping` command in Terminal, the same way as on the Studio.
if [ -d /opt/homebrew/bin ] && [ -w /opt/homebrew/bin ]; then
  ln -sfn "$HOME/bin/cursor-ping" /opt/homebrew/bin/cursor-ping
  ln -sfn "$HOME/bin/cursor-ping-schedule" /opt/homebrew/bin/cursor-ping-schedule
else
  echo "To type cursor-ping without ~/bin/, add this to ~/.zshrc:  export PATH=\"\$HOME/bin:\$PATH\""
fi

echo
"$HOME/bin/cursor-ping-schedule" install
