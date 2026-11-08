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
- bash, not `/bin/sh`, with the store's tools only (`inheritPath = false`);
- after the warning it reads the capacity again, not only the status, and
  powers off only when that second reading is 3 % or less too: one low
  sample, as right after a resume, no longer powers a healthy battery off.
  A file gone by then aborts quietly;
- when logind refuses the poweroff, it starts `poweroff.target` with
  `systemctl start --job-mode=replace-irreversibly --no-block`, as
  systemctl itself does without logind, and logs that it did. logind
  refuses while a suspend or a shutdown is pending ("Action suspend already
  in progress, refusing requested poweroff operation"), and `systemctl
  poweroff` then exits 1 without a fallback of its own. The VM test shows
  both: the refusal, and this script powering the VM off through it. The
  original would have tried again only 2 minutes later, in the very suspend
  loop it exists for.

## Tests

`tests/battery-emergency-poweroff.test.sh`, the check
`bin-battery-emergency-poweroff`, 37 cases, with logger, wall, sleep and
systemctl as stubs: 3, 1 and 0 % power off, 4 and 50 % do not; charging,
parked ("Not charging"), full, unknown and a lower-case status do nothing;
plugging in or parking during the warning aborts, still discharging powers
off; a second capacity reading above 3 % (4 and 57), empty, non-numeric,
`2%`, huge or gone aborts, a still low one powers off, a status gone aborts;
logind refusing makes it start `poweroff.target` itself, with a failing
logger too, and a failing fallback fails the run; a failing wall or logger
still powers off; no battery, no status or capacity file, an unreadable,
empty, non-numeric, `2%` or huge capacity do nothing; two runs at once; BAT0
as the default; and the package's script and PATH. The VM test
`hardware-power` runs the package against the kernel's test_power battery:
4 % leaves it alone, plugging in during the warning aborts, at 3 %, with
UPower masked, it powers the VM off, and once more while a suspend held
back by a delay lock makes logind refuse every poweroff.

## Findings that are not fixed

- A negative capacity counts as empty and powers off. The kernel reports
  none; a broken reading of that kind is taken as the safe side.
- Between two runs 2 minutes pass, so a battery that falls from 4 % to 0 %
  within them is not caught by this layer; UPower's PowerOff at 2 % is the
  layer that acts on its own events.
