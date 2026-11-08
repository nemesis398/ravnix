# energy

The laptop's energy settings in one fuzzel menu, and the watcher that
applies them: power profile, refresh rate, keep-awake, idle suspend on
battery, charge mode and the focus bar on battery. `energy menu` is Waybar's
middle click on the power-profile icon; `energy watch` is the user unit
`energy-watch.service`, which follows UPower's `OnBattery` and tuned-ppd's
`ActiveProfile` on the system bus; kanshi's profiles run `energy refresh`,
keep-awake's swayidle `energy idle-suspend`. Bash, carried over from
Fedora's `bin-energy` (AGENTS.md, rule 4); the script's header has the
reasons for each setting.

Installed, with its unit, by the IdeaPad module's `power.nix`
(`modules/hardware/ideapad-pro-5-16ahp9/`).

## Personal values

None. The settings live in `$XDG_STATE_HOME/energy`, else
`~/.local/state/energy`.

## Changes from the original

- the commands it ran from `~/.local/bin` come from elsewhere: `charge-mode`
  by its store path (`packages/charge-mode`), `keep-awake` and
  `waybar-launch` from the session's PATH, where the desktop's scripts are;
- `fuzzel` and `swaymsg` come from the session's PATH too, so the menu wears
  the session's fuzzel theme and talks to the running Sway; the package
  brings the rest (busctl, systemctl, gdbus, jq, awk, pgrep, setsid,
  notify-send, coreutils);
- three `local NAME="...$(...)"` lines are split into a declaration and an
  assignment, for shellcheck's SC2155, which writeShellApplication runs at
  build time; nothing else in the code changed;
- the header names no person and no path under a home directory.

The unit is Fedora's: started by `sway-session.target`, part of and after
`graphical-session.target`, `Restart=always` after 5 s. It sets no PATH
(`enableDefaultPath = false` too), so it keeps the user manager's, from
`/etc/environment.d`: `/run/wrappers/bin` first, then the user's and the
system's profiles, for keep-awake and waybar-launch. A PATH of the unit's
own would replace that one whole, and a Waybar the watcher relaunches would
then find no setuid sudo for `charge-mode`.

## Tests

`tests/energy.test.sh`, the check `bin-energy`, 55 cases. A copy of the
script whose charger file (`ADP0/online`) and `charge-mode` point into the
sandbox runs against stubs for everything it talks to, so no real setting
changes: busctl answers for the profile, swaymsg for the outputs, fuzzel picks
rows by pattern, gdbus plays a list of bus events and waits after each until
the watcher has acted. Covered: the three keys' defaults, every value and the
refused ones, the state directory and its fallback; the refresh rate for each
profile and fixed value, the rounding of 59.95 Hz, eDP-1 or eDP-2, inactive
panels, no Sway, malformed outputs, no profile daemon; idle suspend on and
off, on the charger, during a backup, a download or restic, with no or a
garbled charger file; the watcher's unplug (keep-awake off, the focus bar
switched on and only then switched back), noise on the bus, a second unplug
event, starting on battery, dead monitors; every menu row and choice, Escape
at each level, no fuzzel, no charge-mode; and the package's script and PATH.
The VM test `hardware-power` sets the tuned profiles through the real menu,
in an active session, and runs the watcher through charger changes.

## Findings that are not fixed

Kept as Fedora has them, for the port to Odin (Phase 13):

- `energy get KEY` for a key that is not one of the three dies with bash's
  `DEFAULT[KEY]: unbound variable` and exit 1, not a clear message.
- An empty state file reads as an empty value, not as the default: an empty
  `refresh` counts as auto, an empty `idle_suspend` as off.
- `on_battery` reads `ADP0/online`, while the watcher wakes on UPower's
  `OnBattery`. On a laptop whose charger is not ADP0 the watcher never sees
  an unplug. (On this IdeaPad it is ADP0.)
- `idle-suspend` waits for `borg-backup.service`, the Fedora unit's name. A
  backup unit of another name does not hold the suspend back; check it when
  the backup module lands.
- Switching the profile needs an active session (tuned-ppd's polkit rule):
  `energy menu` from an `su` shell or a user unit is refused with
  `Unauthorized`, and the menu exits 1. From the Sway session it works.
- `energy set` writes the state with a plain redirect, so two sets of one
  key at the same instant can tear the file, as `charge-mode-apply` could
  before its fix. A torn value reads as none of the three: `refresh` then
  counts as auto, `idle_suspend` and `focus_bar` as off.
