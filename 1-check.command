#!/bin/bash
# studio-light: a read-only look at this Mac's front-light keys. Changes nothing.
cd "$(dirname "$0")" || exit 1
out="$PWD/scan.txt"
{
  echo "checked: $(date '+%Y-%m-%d %H:%M')"
  echo "model: $(sysctl -n hw.model 2>/dev/null)"
  echo "chip: $(sysctl -n machdep.cpu.brand_string 2>/dev/null)"
  echo "macOS: $(sw_vers -productVersion 2>/dev/null) ($(sw_vers -buildVersion 2>/dev/null))"
  if [ -d /Applications/LuxMini.app ] || [ -d "$HOME/Applications/LuxMini.app" ]; then echo "LuxMini: installed"; else echo "LuxMini: not installed"; fi
  if pgrep -x mac-led-tray >/dev/null 2>&1; then echo "LuxMini running: yes"; else echo "LuxMini running: no"; fi
  if [ -f "/Library/Application Support/studio-light/config" ]; then echo "studio-light: already set up"; else echo "studio-light: not set up"; fi
  for d in / /Library "/Library/Application Support" /Library/LaunchDaemons /usr/local /usr/local/bin; do
    echo "folder: $d -> $(stat -f '%Su:%Sg %Lp' "$d" 2>/dev/null || echo missing)"
  done
} > "$out" 2>&1
if clang=$(xcrun --find clang 2>/dev/null); then
  echo "compiler: $clang" >> "$out"
  tmp=$(mktemp -d)
  if xcrun clang -O2 -Wall -o "$tmp/studio-light-led" led.c >> "$out" 2>&1; then
    echo "light keys (name type bytes value):" >> "$out"
    "$tmp/studio-light-led" scan >> "$out" 2>&1 || echo "scan failed (exit $?)" >> "$out"
  else
    echo "build failed" >> "$out"
  fi
  rm -rf "$tmp"
else
  echo "compiler: missing (needs: xcode-select --install)" >> "$out"
fi
echo "done" >> "$out"
cat "$out"
echo
echo "Saved to $out. Nothing on this Mac was changed; you can close this window."
