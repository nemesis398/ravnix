# battery-emergency-poweroff

The second layer of the battery safety net: when the battery discharges at
3 % or less, it warns for 10 seconds (journal and `wall`) and powers off;
plugging in during the warning aborts it. `battery-emergency-poweroff.timer`
runs it as root every 2 minutes, apart from upowerd, D-Bus and logind's
battery handling, because on the Fedora laptop upowerd took no action
through two nights of discharge to 0 %. UPower's `CriticalPowerAction =
PowerOff` is the first layer. Both come from the IdeaPad module's
`battery.nix`; neither is ever dropped. Bash, carried over from the helper
that Fedora's `scripts/battery-critical-safety-net` wrote (AGENTS.md, rule
4).

## Personal values

None.

## Changes from the original

- an optional argument names the battery's sysfs directory; without one it
  is `/sys/class/power_supply/BAT0`, as before, and the unit gives none. The
  tests and the VM test name a fake battery with it;
- a capacity that is no number no longer prints bash's "integer expression
  expected"; it still counts as not low;
- the `cond && cond || exit 0` guard and the last `[ ... ] && exec` are `if`
  blocks, the same logic;
- the warning text has a colon and a comma where the original had dashes;
- bash, not `/bin/sh`, with the store's tools only (`inheritPath = false`).

## Tests

`tests/battery-emergency-poweroff.test.sh`, the check
`bin-battery-emergency-poweroff`, 28 cases, with logger, wall, sleep and
systemctl as stubs: 3, 1 and 0 % power off, 4 and 50 % do not; charging,
parked ("Not charging"), full, unknown and a lower-case status do nothing;
plugging in or parking during the warning aborts, still discharging powers
off; a failing wall or logger still powers off; no battery, no status or
capacity file, an unreadable, empty, non-numeric, `2%` or huge capacity do
nothing; two runs at once; BAT0 as the default; and the package's script and
PATH. The VM test `hardware-power` runs the package against the kernel's
test_power battery: 4 % leaves it alone, plugging in during the warning
aborts, and at 3 %, with UPower masked, it powers the VM off.

## Findings that are not fixed

- A negative capacity counts as empty and powers off. The kernel reports
  none; a broken reading of that kind is taken as the safe side.
- Between two runs 2 minutes pass, so a battery that falls from 4 % to 0 %
  within them is not caught by this layer; UPower's PowerOff at 2 % is the
  layer that acts on its own events.
