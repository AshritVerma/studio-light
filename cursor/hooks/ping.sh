#!/bin/bash
# Notifies (banner + sound) when a Cursor agent finishes — unless ~/.cursor/ping-off exists.
# Toggle with: cursor-ping [on|off|toggle|status|test]
input="$(cat)"
[ -e "$HOME/.cursor/ping-off" ] && { echo '{}'; exit 0; }
status="$(printf '%s' "$input" | /usr/bin/sed -n 's/.*"status"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' | head -1)"
case "$status" in
  error)   msg="Agent hit an error" ;;
  aborted) msg="Agent stopped" ;;
  *)       msg="Agent finished" ;;
esac
SOUND="$(cat "$HOME/.cursor/ping-sound" 2>/dev/null || echo Glass)"
( /usr/bin/osascript -e "display notification \"$msg\" with title \"Cursor\"" >/dev/null 2>&1 & )
( /usr/bin/afplay "/System/Library/Sounds/${SOUND}.aiff" >/dev/null 2>&1 & )
echo '{}'
exit 0
