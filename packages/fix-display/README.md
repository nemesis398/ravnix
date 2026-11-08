# fix-display and panel-crtc

`fix-display` brings the Sway session back when the panel stays dark after a
resume or a TTY visit: it saves evidence, then tries three steps, cheapest
first, and offers a clean reboot if none lights an output. `panel-crtc`
(Python, the same package) explains the cause and prevents it: it keeps the
panel on the CRTC the kernel console uses. Bash and Python, carried over from
Fedora's `bin-fix-display` (AGENTS.md, rule 4). The comments in both hold the
history and the mechanism.

Installed on the laptop by `modules/desktop/scripts.nix`. The tools of the
session are looked up on the `PATH`: `swaymsg`, `kanshi`, `kanshictl`,
`loginctl`, `journalctl` and `sudo` (which has to be the setuid wrapper).
`panel-crtc` is in the package, so `fix-display` finds it there and hands
`sudo` its full path.

## Personal values

None.

## Changes from the original

- `fix-display` finds `panel-crtc` on the `PATH` where Fedora used a fixed
  path under the home directory, and says so if it is missing;
- comments that named the user, the login manager (SDDM) and a vault note
  are neutral;
- `panel-crtc` loses its shebang (the package adds one) and the line that
  named its stow package;
- shellcheck SC2024 (a redirect after `sudo` is not run by `sudo`) is off for
  the whole script by `excludeShellChecks`: the reads as root redirect into
  files of the user's on purpose. The directive in the script cannot do it,
  because `writeShellApplication` puts its own lines before it;
- flake8 ignores E501 (lines past 79 characters, 24 of them) for
  `panel-crtc`; the original fails it and is left as it was.

## Left out

Nothing.

## Tests

`tests/fix-display.test.sh`, the check `bin-fix-display`. `fix-display` runs
with stand-ins for `pgrep`, `loginctl`, `swaymsg` and `sudo`: the argument it
refuses, `--status` with and without a Sway (the socket it talks to, the
outputs, a Sway that does not answer) and the preconditions that stop it
before it touches anything. `panel-crtc` is loaded as a module against a fake
DRM state: the sizes of its structures and the numbers of its ioctls, the
report, which outputs `--fix` powers off and on and in which order, that the
power-on runs even if Sway times out, and the refusals that need no GPU.

## Findings not fixed

- A real rescue needs a dark panel, a TTY and `sudo`, so the three steps
  themselves are unverified on NixOS. `/sys/kernel/debug/dri/*/state` needs
  debugfs, which NixOS mounts by default.
- `fix-display` exits with a `cat` error from `/sys/class/tty/tty0/active`
  where there is no console, as in a container.
