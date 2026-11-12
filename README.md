# studio-light

Keeps the front power light of a Mac Studio or Mac mini off during the hours you
choose, while the Mac stays on. Optionally, it also mutes Cursor's agent sounds
during those same hours and turns them back on in the morning.

It's a lean replacement for LuxMini: no network access, no menu-bar app, nothing setuid.

## Set it up on a Mac (about two minutes, at the Mac)

Clone or download this repo, then in Finder double-click, in order:

1. **`1-check.command`**: a read-only look at this Mac's light keys. It writes
   `scan.txt` and changes nothing.
2. **`2-setup.command`**: guided setup. Type your Mac password once. The light changes
   a few times; each time, answer `y` (off), `d` (dimmer but on) or `n` (no change).
   Usually the first test works. There's an optional 30-second sleep test, then you
   pick the hours (default 22:30 to 10:30, or `never` to keep it off).
3. **`3-cursor.command`** (optional): installs `cursor-ping` and its Cursor hook, and
   ties Cursor's sounds to the light's hours. No password needed.

Or from Terminal: `bash studio-light.sh setup`, then `bash cursor/install.sh`.

Building needs Apple's command line tools (you have them if `git` works); otherwise run
`xcode-select --install` first. If LuxMini is installed, remove it and restart first,
or the two would fight over the light.

## Afterwards

```
studio-light                          what it's doing right now
sudo studio-light hours 22:30 10:30   new hours ("always" keeps it off)
sudo studio-light uninstall           light back to normal, everything removed

cursor-ping on | off | status | test  Cursor's agent sounds (Toggle Cursor Ping.command does the same)
cursor-ping-schedule status           the sound schedule
cursor-ping-schedule uninstall        stop following the light's hours
```

A manual `cursor-ping on`/`off` holds until the light's next switch.

## How it works

**The light.** Its brightness lives in SMC keys starting with `LS` (`LSLN` on recent
Mac Studios). Setup builds `led.c`, a small C tool that talks to the SMC through IOKit,
and tries up to four settings of the known light keys until you confirm the light is
fully off. It records each key's normal value and the value it reads when off.

Everything goes in `/Library/Application Support/studio-light/` (the tool, your config
and the script, all root-owned), plus `/Library/LaunchDaemons/local.studio-light.plist`,
a launchd job that runs the tool once a minute. In the off hours it puts the light keys
at their off values whenever they aren't; in the on hours it only undoes its own change.
So sleep, wake and restarts can't leave the light on for more than a minute. A
`studio-light` link in `/usr/local/bin` is made only when that folder is root-owned.
Changes are logged to `/var/log/studio-light.log`. The tool refuses any key that doesn't
start with `LS`.

**Cursor's sounds** (`cursor/`):
- `hooks/ping.sh` is a Cursor `stop` hook (registered in `~/.cursor/hooks.json`) that
  shows a banner and plays a sound when an agent finishes, unless `~/.cursor/ping-off` exists.
- `cursor-ping` flips that file and also sets Cursor's accessibility-sound volume
  (the blips between thinking steps) to 0 or back to 70.
- `cursor-ping-schedule` is a LaunchAgent that reads studio-light's config every minute
  and runs `cursor-ping off`/`on` when the light switches, and at install, login and wake.

If setup can't find a setting that turns the light off, it changes nothing and leaves
its findings in `studio-light-report.txt` next to the script.
