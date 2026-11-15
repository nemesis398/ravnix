# energy

The laptop's energy settings in one fuzzel menu, and the watcher that
applies them: power profile, refresh rate, keep-awake, idle suspend on
battery, charge mode and the focus bar on battery. `energy menu` is Waybar's
middle click on the power-profile icon; `energy watch` is the user unit
`energy-watch.service`, which follows UPower's `OnBattery` and tuned-ppd's
`ActiveProfile` on the system bus; kanshi's profiles run `energy refresh`,
keep-awake's swayidle `energy idle-suspend`. Carried over from Fedora's
`bin-energy` and ported from Bash to Odin (Phase 13); `main.odin`'s header has
the reasons for each setting.

Installed, with its unit, by the IdeaPad module's `power.nix`
(`modules/hardware/ideapad-pro-5-16ahp9/`).

```
energy [menu | watch | refresh | idle-suspend | get KEY | set KEY VALUE]
  keys: refresh (auto|120|60), idle_suspend (on|off), focus_bar (on|off)
```

Exit status: `menu` and `refresh` end with the status of the last program
they ran (as the Bash version did), `watch` with 1 when its monitors end (the
unit restarts it), `get` and `set` with 0, 1 when a file cannot be written,
and 2 for a command, key or value that does not exist.

## Personal values

None. The settings live in `$XDG_STATE_HOME/energy`, else
`~/.local/state/energy`, one file per key that holds the value and a newline.

## The programs it starts

The package brings `busctl` and `systemctl` (systemd), `gdbus` (glib),
`notify-send` (libnotify), `pgrep` (procps) and `setsid` (util-linux): their
directories go in front of the session's PATH, in the binary as
`-define:TOOLS_PATH`, and a program energy starts gets that PATH too.
`charge-mode` is named by its store path (`-define:CHARGE_MODE`; `default.nix`
builds it from `packages/charge-mode` with `callPackage`, since a tool must not
read `pkgs.ravnix`). `fuzzel`, `swaymsg`, `keep-awake` and `waybar-launch`
come from the session's PATH: fuzzel so that the menu wears the session's
theme, swaymsg to talk to the running Sway, the other two from the desktop's
scripts. The bus is followed by two `gdbus monitor` children: writing a D-Bus
client is not worth it for two properties.

jq, awk, cat, mktemp and mv of the Bash version are gone: sway's list of
outputs is parsed in Odin, and a setting is saved with `open`, `fsync` and
`rename`.

### Seams

Three environment variables replace what the build or the system names. The
tests use them, and nothing else needs to:

| Variable | Replaces | Default |
| --- | --- | --- |
| `ENERGY_ONLINE_FILE` | the charger's file | `/sys/class/power_supply/ADP0/online` |
| `ENERGY_CHARGE_MODE` | the `charge-mode` program | the store path from the build |
| `ENERGY_TOOLS_PATH` | the package's directories in front of the PATH (may be empty) | the store paths from the build |

## Changes from the Bash version

- every command, exit status of the commands that exist, the state file
  format, the rows and prompts of the menu, the messages of a missing tool
  and the order in which the watcher acts are the same. The 62 cases of the
  Bash test (`tests/energy.test.sh`) pass against the Odin build, as 61: two
  that checked the script and its PATH became one that checks the package's
  store paths, and the two that pinned the findings below now expect the
  fixes;
- `energy get KEY` for a key that is none of the three says
  `'KEY' is not a key (refresh, idle_suspend, focus_bar)` and exits 2; Bash
  died with `DEFAULT[KEY]: unbound variable` and exit 1;
- a state file that holds none of the key's values (empty, torn by hand,
  longer than 64 bytes, a directory, a FIFO) reads as the key's default; Bash
  counted an empty file as an empty value, so an empty `refresh` meant auto
  and an empty `idle_suspend` meant off. White space around a value is fine;
- `energy get` and `energy set` without their arguments exit 2 with a
  message; Bash's `${2:?key}` ended the shell with 127;
- a program that only answers (swaymsg, busctl, systemctl, notify-send) is
  killed after 30 s and counts as failed (status 124), and one that prints
  more than 16 MiB too. Bash waited for ever, so a hung sway stalled the
  watcher and kanshi's `exec energy refresh`;
- sway's list of outputs is parsed once and checked: a list nested deeper than
  32 levels, an output without `current_mode`, a size that is not a whole
  positive number, or a rate beyond 10^12 mHz sets no mode. The jq of Bash
  would have run `swaymsg output eDP-1 mode nullxnull@120Hz` for an output
  without a mode;
- the menu says `energy: fuzzel is not on the PATH` on the error output
  before it exits 0; Bash printed the shell's `command not found`;
- the watcher says `energy: gdbus is not on the PATH, so there is no monitor
  of the system bus` (or why it could not start one) before it exits 1;
- the rows of a choice list go to fuzzel through a file in memory, not a pipe,
  so a fuzzel that ends before it reads cannot raise SIGPIPE.

The unit is Fedora's, unchanged: started by `sway-session.target`, part of
and after `graphical-session.target`, `Restart=always` after 5 s. It sets no
PATH (`enableDefaultPath = false` too), so it keeps the user manager's, from
`/etc/environment.d`: `/run/wrappers/bin` first, then the user's and the
system's profiles, for keep-awake and waybar-launch. energy puts its own
directories in front of that PATH for the programs it starts and leaves its
own environment alone, so `/proc/PID/environ` still shows the manager's. A
PATH of the unit's own would replace the manager's whole, and a Waybar the
watcher relaunches would then find no setuid sudo for `charge-mode`.

## Tests

`tests/*.odin`, the check `energy-tests`, 85 cases. Each builds a world in a
temporary directory: the charger's file, the state and runtime directories, and
a bin directory in which every program energy runs (busctl, swaymsg, fuzzel,
gdbus, keep-awake, ...) is a link to `tests/testdata/fake`, which logs its call
and does what its `.case` file says. energy finds them on a PATH that holds
nothing else (and `sleep`), so a test can never reach the desktop it runs on.
Covered: the three keys' defaults, every value and the refused ones, a state
file that is empty, garbled, huge, a directory or a FIFO, two sets at once
for 200 rounds on two threads with 2000 reads beside them, an unwritable state
directory and no state directory at all; the refresh rate for each profile
and fixed value, the rounding of 59.95 Hz, eDP-1 or eDP-2, inactive panels, no
Sway, a dozen kinds of malformed list, a list of 200 000 brackets and one of
20 000 outputs, absurd rates, no profile daemon, a failing modeset, a hung
sway and a flood of output; idle suspend on and off, on the charger, during a
backup, a download or restic, with no or a garbled charger file, with no
systemctl; the watcher's unplug (keep-awake off, the focus bar switched on and
only then switched back), noise on the bus, a second unplug event, starting on
battery, dead monitors, no gdbus, a line with no newline, a line of 2 MiB, no
keep-awake, a failing one, no waybar-launch on an unplug and on a replug, no
notify-send; every menu row and choice, Escape at each level, a fuzzel that
answers with something else, no fuzzel, no charge-mode, a refused profile,
no or a failing keep-awake; the lookup of programs (directories, files that
cannot run, empty PATH entries, too long names), a program killed by a
signal, one that closes its output and runs on, one that leaves a daemon on
its pipe, and 400 KB of rows to a program that never reads them.

`tests/energy.test.sh`, the check `bin-energy`, is the Bash suite that the
port had to pass, run against the built program with the three seams: 61
cases. The VM test `hardware-power` sets the tuned profiles through the real
menu, in an active session, runs the watcher through charger changes, and
checks that its PATH starts with the setuid wrappers.

## Bench

The callgrind bench runs `energy get refresh`: a bench has no PATH
(`tools/README.md`, Known gaps), so it cannot start a program, and the
state directory it sees is `$HOME/.local/state/energy`, which does not exist.
It counts the start of the program, the reading of a setting and the default;
the work of the menu, the watcher and the refresh is not in the baseline.

## Findings that are not fixed

- `on_battery` reads `ADP0/online`, while the watcher wakes on UPower's
  `OnBattery`. On a laptop whose charger is not ADP0 the watcher never sees
  an unplug. (On this IdeaPad it is ADP0; `ENERGY_ONLINE_FILE` is a seam, not
  a setting.)
- `idle-suspend` waits for `borg-backup.service`, the Fedora unit's name. A
  backup unit of another name does not hold the suspend back. ravnix's own,
  `ravnix-backup` (modules/common/backup.nix), runs restic by the name
  `restic` from its PATH, so the `^restic ` check holds the suspend while it
  runs; the wait for its preparation (rbw, before restic starts) does not.
  (The `pgrep -f '^restic '` pattern needs the space: a `restic` with no
  argument does not match.)
- Switching the profile needs an active session (tuned-ppd's polkit rule):
  `energy menu` from an `su` shell or a user unit is refused with
  `Unauthorized`, and the menu exits 1. From the Sway session it works.
- `setsid -f waybar-launch` returns before `waybar-launch` runs, so a
  `waybar-launch` that is there but fails is not seen; its own log has it.
- The watcher goes on while one of its two monitors is dead (the profile
  monitor ends at once when tuned-ppd is not running) and ends only when
  both are. Fedora's did the same.
- A write of `waybar-mode` or of the marker that fails is said on the error
  output and the watcher goes on, so a bar can be relaunched in the layout it
  already had.
- A crash between creating a temporary file and the rename leaves
  `.KEY.PID.N` in the state directory. Nothing reads it, nothing removes it.
- `energy watch` stops its two `gdbus` children when they end, not when it is
  killed: under systemd the unit's control group takes them along, and started
  by hand they end at the next bus event, when their pipe is gone.
- The watcher acts on the line it has read before it reads the next, so a
  `keep-awake` or `notify-send` that takes its 30 s delays the events behind
  it. The limit ends it; there is no queue.
- The bench cannot cover the programs energy starts (see Bench).
