#!/bin/bash
# studio-light: keep a Mac Studio or Mac mini's front light off during the hours you choose.
#
#   bash studio-light.sh setup             first-time setup, run from the unzipped folder
#   studio-light                           show status (after setup)
#   sudo studio-light hours 23:00 08:00    change the off hours ("always" keeps it off)
#   sudo studio-light uninstall            put the light back to normal and remove everything
#
# Setup builds a small C tool from led.c, finds out with you which SMC setting turns
# your Mac's light fully off, then installs a launchd job that checks once a minute
# that the light is right, so sleep, wake and restarts can't undo it.
# No network, no menu-bar app, nothing setuid; only the keys you confirm are touched.

set -eu

PREFIX="${STUDIO_LIGHT_PREFIX:-}"   # tests install into a scratch folder instead of /
APP_DIR="$PREFIX/Library/Application Support/studio-light"
BIN="$APP_DIR/studio-light-led"
SCRIPT="$APP_DIR/studio-light"
CONF="$APP_DIR/config"
LINK="$PREFIX/usr/local/bin/studio-light"
LABEL="local.studio-light"
PLIST="$PREFIX/Library/LaunchDaemons/$LABEL.plist"
LOG="$PREFIX/var/log/studio-light.log"
ERRFILE="$PREFIX/var/run/studio-light.err"
KNOWN_KEYS="LSLN LS0C LS0S LS0P"
HERE=$(cd "$(dirname "$0")" && pwd)
SELF="$HERE/$(basename "$0")"

die() { echo "studio-light: $*" >&2; exit 1; }

# "HH:MM" -> minutes after midnight; fails on anything else.
to_min() {
  case "$1" in
    [0-9]:[0-5][0-9] | [01][0-9]:[0-5][0-9] | 2[0-3]:[0-5][0-9]) echo $(( 10#${1%%:*} * 60 + 10#${1##*:} )) ;;
    *) return 1 ;;
  esac
}

# Off hours run from $2 up to $3 (minutes), wrapping past midnight; equal means always.
in_off_hours() {
  if [ "$2" -eq "$3" ]; then return 0; fi
  if [ "$2" -lt "$3" ]; then [ "$1" -ge "$2" ] && [ "$1" -lt "$3" ]; else [ "$1" -ge "$2" ] || [ "$1" -lt "$3" ]; fi
}

conf_get() { awk -v k="$1" '$1 == k { print $2; exit }' "$CONF"; }
conf_keys() { awk '$1 ~ /^LS/ { print $1, $2, $3 }' "$CONF"; }

describe() {  # describe OFF ON
  if [ "$1" = "$2" ]; then echo "always off"; else echo "off from $1 to $2 every day"; fi
}

config_text() {  # config_text OFF ON, key lines ("KEY NIGHT DAY") on stdin
  echo '# studio-light: the front light is off from "off" until "on" (24-hour, local time).'
  echo '# Equal times mean always off. Change with: sudo studio-light hours 23:00 08:00'
  echo "off $1"
  echo "on $2"
  echo '# key, value it reads in the off hours, the Mac'"'"'s own value otherwise'
  cat
}

plist_text() {
  cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
    <string>apply</string>
    <string>$CONF</string>
  </array>
  <key>StartInterval</key><integer>60</integer>
  <key>RunAtLoad</key><true/>
  <key>ProcessType</key><string>Background</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
}

owner_mode() {  # "uid octal-mode" of a path
  if [ "$(uname -s)" = Darwin ]; then stat -f '%u %Lp' "$1"; else stat -c '%u %a' "$1"; fi
}

# root_only DIR: DIR and every folder above it are owned by root and writable by no one
# else, so nothing running as you could swap in a file that root would later run.
root_only() {
  local d=$1 top=${PREFIX:-/} uid mode
  while :; do
    read -r uid mode <<EOF
$(owner_mode "$d" 2>/dev/null)
EOF
    [ "${uid:-}" = 0 ] || return 1
    case "$mode" in *[2367] | *[2367]?) return 1 ;; esac
    if [ "$d" = "$top" ] || [ "$d" = / ]; then return 0; fi
    d=$(dirname "$d")
  done
}

# ------------------------------------------------------------------ status

status() {
  if [ ! -f "$CONF" ]; then
    echo "studio-light isn't set up. From the unzipped folder run:  bash studio-light.sh setup"
    return 0
  fi
  local off on k night day cur
  off=$(conf_get off); on=$(conf_get on)
  echo "Schedule:  light $(describe "$off" "$on")"
  if in_off_hours "$(to_min "$(date +%H:%M)")" "$(to_min "$off")" "$(to_min "$on")"; then
    echo "Right now: off hours"
  else
    echo "Right now: on hours"
  fi
  if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    echo "Job:       loaded, checks every minute"
  else
    echo "Job:       not loaded (check with: sudo launchctl print system/$LABEL)"
  fi
  conf_keys | while read -r k night day; do
    cur=$("$BIN" read "$k" 2>/dev/null || echo "?")
    echo "Key:       $k is $cur (off hours $night, otherwise $day)"
  done
  if [ -s "$LOG" ]; then echo "Last log:  $(tail -n 1 "$LOG")"; fi
}

# ------------------------------------------------------------------ hours / uninstall

hours() {
  [ "$(id -u)" -eq 0 ] || die "run it with sudo:  sudo studio-light hours $*"
  [ -f "$CONF" ] || die "studio-light isn't set up yet"
  local off on tmp
  if [ "${1:-}" = always ] && [ $# -eq 1 ]; then
    off=00:00 on=00:00
  elif [ $# -eq 2 ] && to_min "$1" >/dev/null && to_min "$2" >/dev/null; then
    off=$1 on=$2
  else
    die "usage: sudo studio-light hours OFF ON   (24-hour, e.g. 23:00 08:00), or: hours always"
  fi
  tmp=$(mktemp)
  awk -v off="$off" -v on="$on" '$1 == "off" { print "off " off; next } $1 == "on" { print "on " on; next } { print }' "$CONF" > "$tmp"
  if ! "$BIN" check "$tmp" >/dev/null; then rm -f "$tmp"; die "the new config didn't check out; nothing changed"; fi
  install -o 0 -g 0 -m 644 "$tmp" "$CONF"
  rm -f "$tmp"
  "$BIN" apply "$CONF" >> "$LOG" 2>&1 || true
  echo "The light is now $(describe "$off" "$on")."
}

uninstall() {
  [ "$(id -u)" -eq 0 ] || die "run it with sudo:  sudo studio-light uninstall"
  local k day
  launchctl bootout "system/$LABEL" 2>/dev/null || true
  if [ -f "$CONF" ] && [ -x "$BIN" ]; then
    conf_keys | while read -r k _ day; do
      "$BIN" write "$k" "$day" >/dev/null || echo "couldn't put $k back to $day" >&2
    done
  fi
  if [ -L "$LINK" ] && [ "$(readlink "$LINK")" = "$SCRIPT" ]; then rm -f "$LINK"; fi
  rm -f "$PLIST" "$LOG" "$ERRFILE"
  rm -rf "$APP_DIR"
  echo "Removed. The light is back to normal."
}

# ------------------------------------------------------------------ setup

ask() {  # ask PROMPT "y n ..." [DEFAULT] -> prints the first letter of a valid answer
  local a
  while :; do
    printf '%s' "$1" >&2
    IFS= read -r a || die "stopped: no answer"
    a=$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]' | cut -c1)
    if [ -z "$a" ] && [ -n "${3:-}" ]; then echo "$3"; return 0; fi
    case " $2 " in *" $a "*) if [ -n "$a" ]; then echo "$a"; return 0; fi ;; esac
    echo "  Please answer ${2// / or }." >&2
  done
}

ask_time() {  # ask_time PROMPT DEFAULT [VALUE-FOR-never]
  local t
  while :; do
    printf '%s' "$1" >&2
    IFS= read -r t || die "stopped: no answer"
    t=$(printf '%s' "$t" | tr -d ' ')
    if [ -z "$t" ]; then echo "$2"; return 0; fi
    if [ "$t" = never ] && [ -n "${3:-}" ]; then echo "$3"; return 0; fi
    if to_min "$t" >/dev/null; then echo "$t"; return 0; fi
    echo "  Please type a 24-hour time like 23:00." >&2
  done
}

soon() {  # a time $1 seconds from now, in pmset's format
  date -v+"$1"S '+%m/%d/%y %H:%M:%S' 2>/dev/null || date -d "+$1 seconds" '+%m/%d/%y %H:%M:%S'
}

nwords() { echo $#; }

keep_sudo() {
  if [ -n "${SUDO_KEEPER:-}" ]; then return 0; fi
  echo "Your Mac password is needed to change the light (asked once)."
  sudo -v || die "no password given; nothing was changed"
  ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
  SUDO_KEEPER=$!
}

stock_of() { echo "$SCAN" | awk -v k="$1" '$1 == k { print $4; exit }'; }
zeros() { printf '%s' "$1" | tr '0-9a-fA-F' '0'; }

set_keys() {  # set_keys "KEY KEY ..." -> those keys to zero, every other touched key back to stock;
  local k      # APPLIED lists the keys the SMC actually accepted
  APPLIED=""
  for k in $TOUCHED; do
    case " $1 " in
      *" $k "*) ;;
      *) sudo "$BIN" write "$k" "$(stock_of "$k")" >/dev/null 2>&1 || echo "  (couldn't put $k back)" >&2 ;;
    esac
  done
  for k in $1; do
    if sudo "$BIN" write "$k" "$(zeros "$(stock_of "$k")")" >/dev/null 2>&1; then
      APPLIED="${APPLIED:+$APPLIED }$k"
      case " $TOUCHED " in *" $k "*) ;; *) TOUCHED="$TOUCHED $k" ;; esac
    else
      echo "  ($k can't be changed on this Mac; skipping it)" >&2
    fi
  done
}

restore_stock() {
  local k
  for k in ${TOUCHED:-}; do sudo -n "$BIN" write "$k" "$(stock_of "$k")" >/dev/null 2>&1; done
}

# Runs on any exit from setup. Order matters: put things back first, print last,
# and never stop early (a closed Terminal window makes even echo fail).
cleanup() {
  local rc=$?
  set +e
  if [ -z "${COMMITTED:-}" ]; then
    if [ -n "${TOUCHED:-}" ]; then restore_stock; fi
    if [ -n "${WAS_INSTALLED:-}" ]; then
      sudo -n launchctl bootstrap system "$PLIST" >/dev/null 2>&1
    elif [ -n "${STAGED:-}" ]; then
      sudo -n rm -rf "$APP_DIR" >/dev/null 2>&1
    fi
  fi
  if [ -n "${SUDO_KEEPER:-}" ]; then kill "$SUDO_KEEPER" 2>/dev/null; fi
  if [ -n "${WORK:-}" ]; then rm -rf "$WORK"; fi
  if [ -z "${COMMITTED:-}" ] && [ -n "${TOUCHED:-}" ]; then echo "The light is back to how it was." >&2; fi
  return "$rc"
}

setup() {
  local k s c ans cnt night day slept linkdir cmd
  [ "$(id -u)" -ne 0 ] || die "run setup without sudo; it asks for your password when it needs it"
  if [ -z "$PREFIX" ] && [ "$(uname -s)" != Darwin ]; then die "run this on the Mac"; fi
  [ -f "$HERE/led.c" ] || die "led.c has to be next to this script; run setup from the unzipped folder"
  if [ -d "$PREFIX/Applications/LuxMini.app" ] || [ -d "$HOME/Applications/LuxMini.app" ] ||
     pgrep -x mac-led-tray >/dev/null 2>&1; then
    die "LuxMini is installed and would fight this over the light. Quit it, move it to the Trash, restart the Mac, then run setup again."
  fi
  root_only "$(dirname "$APP_DIR")" ||
    die "$(dirname "$APP_DIR") can be changed without admin rights on this Mac, so a root job there wouldn't be safe. Nothing was changed."
  root_only "$(dirname "$PLIST")" ||
    die "$(dirname "$PLIST") can be changed without admin rights on this Mac. Nothing was changed."
  if ! xcrun --find clang >/dev/null 2>&1; then
    die "this needs Apple's command line tools. Run:  xcode-select --install   then run setup again"
  fi
  trap cleanup EXIT
  trap 'exit 130' INT TERM
  trap 'exit 129' HUP

  WORK=$(mktemp -d)
  echo "Building the light tool..."
  xcrun clang -O2 -Wall -o "$WORK/studio-light-led" "$HERE/led.c" || die "the build failed"

  REPORT="$HERE/studio-light-report.txt"
  {
    echo "studio-light setup $(date '+%Y-%m-%d %H:%M')"
    echo "model: $(sysctl -n hw.model 2>/dev/null || echo unknown)"
    echo "macOS: $(sw_vers -productVersion 2>/dev/null || echo unknown)"
  } > "$REPORT"

  keep_sudo
  # From here on, the only copy of the tool that runs as root is a root-owned one.
  if [ -f "$CONF" ]; then
    WAS_INSTALLED=1
    echo "studio-light is already set up; pausing it while we test."
    sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
  else
    STAGED=1   # a fresh setup that stops early removes what it staged
  fi
  sudo mkdir -p "$APP_DIR"
  sudo chown 0:0 "$APP_DIR"
  sudo chmod 755 "$APP_DIR"
  sudo install -o 0 -g 0 -m 755 "$WORK/studio-light-led" "$BIN"
  sudo xattr -c "$BIN" 2>/dev/null || true

  # A re-run first puts the light back to the Mac's own values, so what we read below is
  # really stock. If any key won't go back, stop rather than save a wrong value.
  if [ -n "${WAS_INSTALLED:-}" ]; then
    conf_keys | while read -r k _ day; do
      if ! sudo "$BIN" write "$k" "$day" >/dev/null 2>&1 || [ "$("$BIN" read "$k" 2>/dev/null)" != "$day" ]; then
        echo "couldn't put $k back to $day" >&2
        exit 1
      fi
    done || die "couldn't put the light back to normal before testing; nothing else was changed"
  fi

  SCAN=$("$BIN" scan) || die "couldn't read this Mac's SMC"
  { echo "light keys:"; echo "$SCAN"; } >> "$REPORT"

  # The values we read now become the daytime values, so make sure nothing has the light turned down.
  s=$(stock_of LSLN)
  if [ -n "$s" ] && [ "$(zeros "$s")" = "$s" ]; then
    die "the light's main key reads $s, as if something already turned it off. Remove any other LED app, restart the Mac, then run setup again."
  fi
  if [ -n "$s" ] && [ "$s" != ffff ]; then
    if [ "$(ask "The light's key reads $s instead of the usual ffff. Is the light at its normal brightness right now? [y/n] " "y n")" != y ]; then
      die "restart the Mac so the light is back to normal, then run setup again"
    fi
  fi

  # Tests to try, most likely first: LSLN is the light's brightness on recent Mac Studios,
  # and the LS0x keys look like a second stage on some models. Nothing else is touched.
  USABLE=" "
  for k in $KNOWN_KEYS; do
    s=$(stock_of "$k")
    case "$s" in "" | unreadable) continue ;; esac
    if [ "$(zeros "$s")" = "$s" ]; then echo "skipped $k: reads all zeros" >> "$REPORT"; continue; fi
    USABLE="$USABLE$k "
  done
  CANDS=()
  add_cand() {
    local c="" k e
    for k in "$@"; do case "$USABLE" in *" $k "*) c="$c $k" ;; esac; done
    c=${c# }
    [ -n "$c" ] || return 0
    for e in ${CANDS[@]+"${CANDS[@]}"}; do [ "$e" = "$c" ] && return 0; done
    CANDS+=("$c")
  }
  add_cand LSLN
  add_cand LSLN LS0C
  add_cand LSLN LS0S LS0P
  add_cand LSLN LS0C LS0S LS0P
  [ ${#CANDS[@]} -gt 0 ] ||
    die "none of the light keys this knows ($KNOWN_KEYS) are on this Mac, so nothing was changed. Details are in $REPORT"

  echo
  echo "Next I'll change the light up to ${#CANDS[@]} times. After each change, look at the"
  echo "small light on the front of the Mac and say what you see."
  printf 'Press Return when you can see the light... ' >&2
  IFS= read -r _ || die "stopped: no answer"

  TOUCHED="" CHOSEN="" DIMMEST="" DIM_COUNT=0 TESTED="" n=0
  for c in "${CANDS[@]}"; do
    set_keys "$c"
    # Skip a test that, after dropping keys the SMC wouldn't change, repeats an earlier one.
    case "|$TESTED|" in *"|$APPLIED|"*) continue ;; esac
    TESTED="$TESTED|$APPLIED"
    n=$((n + 1))
    sleep 1
    ans=$(ask "Test $n: is the light completely off?  y = off, d = dimmer but on, n = no change: " "y d n")
    echo "test $n ($APPLIED): $ans" >> "$REPORT"
    if [ "$ans" = y ]; then CHOSEN=$APPLIED; break; fi
    if [ "$ans" = d ]; then
      # shellcheck disable=SC2086
      cnt=$(nwords $APPLIED)
      if [ "$cnt" -ge "$DIM_COUNT" ]; then DIMMEST=$APPLIED DIM_COUNT=$cnt; fi
    fi
  done

  if [ -z "$CHOSEN" ]; then
    if [ -n "$DIMMEST" ] && [ "$(ask "None turned it fully off. Use the dimmest one during the off hours instead? [y/n] " "y n")" = y ]; then
      CHOSEN=$DIMMEST
      set_keys "$CHOSEN"
    else
      die "nothing turned the light off, so nothing was installed. What we tried is in $REPORT"
    fi
  fi

  # What each key reads back now is what the job will expect during the off hours.
  KEYS=""
  for k in $CHOSEN; do
    night=$("$BIN" read "$k") || die "couldn't read $k back"
    day=$(stock_of "$k")
    if [ "$night" != "$day" ]; then KEYS="$KEYS$k $night $day
"; fi
  done
  [ -n "$KEYS" ] || die "that setting didn't change any key, so nothing was installed"
  echo "Using: $CHOSEN"

  if [ "$(ask "Check that it stays off while the Mac sleeps? It sleeps about 30 seconds, then wakes itself. [Y/n] " "y n" y)" = y ]; then
    sudo pmset schedule wake "$(soon 40)" >/dev/null 2>&1 || true
    echo "Sleeping now: watch the light. If the screen isn't back within a minute, press a key."
    sleep 3
    pmset sleepnow >/dev/null 2>&1 || true
    sleep 10
    slept=$(ask "Did the light stay off the whole time? [y/n] " "y n")
    echo "sleep test: $slept" >> "$REPORT"
    if [ "$slept" = n ]; then
      echo "Noted in $REPORT. While the Mac is awake the light is still kept off (checked every minute)."
    fi
  fi

  echo
  OFF=$(ask_time "Turn the light off at what time? [22:30] " 22:30)
  ON=$(ask_time "Turn it back on at what time? Type never to keep it off. [10:30] " 10:30 "$OFF")

  echo "Installing..."
  printf '%s' "$KEYS" | config_text "$OFF" "$ON" > "$WORK/config"
  "$BIN" check "$WORK/config" >/dev/null || die "the new config didn't check out, so nothing was installed"
  plist_text > "$WORK/plist"
  sudo install -o 0 -g 0 -m 644 "$WORK/config" "$CONF"
  sudo install -o 0 -g 0 -m 755 "$SELF" "$SCRIPT"
  sudo install -o 0 -g 0 -m 644 "$WORK/plist" "$PLIST"
  # install copies extended attributes; drop the download quarantine so the command runs.
  sudo xattr -c "$SCRIPT" "$CONF" "$PLIST" 2>/dev/null || true

  # A short command in /usr/local/bin, but only where nothing running as you could replace it.
  cmd="sudo \"$SCRIPT\""
  linkdir=$(dirname "$LINK")
  if [ ! -e "$LINK" ] && [ ! -L "$LINK" ] || [ "$(readlink "$LINK" 2>/dev/null)" = "$SCRIPT" ]; then
    if [ ! -d "$linkdir" ] && root_only "$(dirname "$linkdir")"; then
      sudo mkdir -p "$linkdir" && sudo chown 0:0 "$linkdir" && sudo chmod 755 "$linkdir"
    fi
    if [ -d "$linkdir" ] && root_only "$linkdir"; then
      sudo ln -sfn "$SCRIPT" "$LINK"
      cmd="sudo studio-light"
    fi
  fi

  sudo launchctl bootout "system/$LABEL" 2>/dev/null || true
  sudo launchctl bootstrap system "$PLIST" || die "launchd didn't accept the job"
  COMMITTED=1
  sudo "$BIN" apply "$CONF" >/dev/null 2>&1 || true   # launchd also runs it at load; this just doesn't wait
  echo "setup done: $CHOSEN, $(describe "$OFF" "$ON")" >> "$REPORT"

  echo
  echo "Done. The light is $(describe "$OFF" "$ON")."
  echo "  ${cmd#sudo }                 see what it's doing"
  echo "  $cmd hours 22:00 07:00       change the hours (\"always\" keeps it off)"
  echo "  $cmd uninstall               put the light back and remove everything"
  echo "macOS may show a \"Background Items Added\" notice; that's this job."
}

case "${1:-status}" in
  setup) setup ;;
  status) status ;;
  hours) shift; hours "$@" ;;
  uninstall) uninstall ;;
  help | -h | --help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0" ;;
  *) sed -n '2,/^$/s/^# \{0,1\}//p' "$0" >&2; exit 64 ;;
esac
