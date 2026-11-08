# charge-mode

The battery's charge ceiling on the IdeaPad Pro 5 16AHP9, read and set from
the desktop without a password. The firmware has no percentage threshold,
only `BAT0/charge_types` with three modes: `Fast`, `Standard` and
`Long_Life`, which parks the cell and refills it to 80 %. Three commands:

| Command | Runs as | What it does |
| --- | --- | --- |
| `charge-mode` | the user | prints, cycles or sets the mode, and the boot default; Waybar's battery click and the energy menu call it |
| `charge-mode-apply` | root, through one sudo rule | the one writer of `charge_types`: it writes only a mode the kernel lists, to two fixed paths, and saves it in `/var/lib/charge-mode` |
| `charge-mode-restore` | root, at boot | puts the saved mode back (`charge-mode-restore.service`) |

Bash, carried over from Fedora's `bin-charge-mode` and the helpers that
`scripts/laptop-charge-mode` wrote there (AGENTS.md, rule 4). The headers
hold the measurements and the reasons.

Installed by the IdeaPad module's `battery.nix`, with the sudo rule (one
command, `NOPASSWD`, as root, by its store path), the boot unit, and the
saved mode `Long_Life` on a new install.

## Personal values

None. The sudo rule's user is `ravnix.user.username`.

## Changes from the original

- the helper is this package's `charge-mode-apply`, by its store path, in
  `charge-mode`, in `charge-mode-restore` and in the sudo rule, instead of
  `/usr/local/sbin`;
- `charge-mode-apply` and `charge-mode-restore` see the store's tools only
  (`inheritPath = false`), so a caller's PATH cannot hand root another `tr`;
  `charge-mode` keeps the caller's PATH behind its own tools, for the setuid
  `sudo` in `/run/wrappers/bin`;
- the helper saves the mode through a temporary file and a rename. The
  original's plain redirect let two writes at once tear the file: in 43 of
  1000 rounds of two concurrent `--save-only` writes the file read
  `Fast\nard`, a mode the next boot's restore would refuse. The test
  `test_two_applies_at_once_leave_one_mode` found it, and runs 200 rounds;
- the helpers are bash, not `/bin/sh`; their code is otherwise the same;
- the hints that named the Fedora installer name the hardware module; the
  installer itself (a snapper snapshot, SELinux contexts, the sudoers file
  checked with visudo) has no counterpart, since the module declares it all
  and NixOS checks the sudoers file with visudo when it builds it.

## Tests

`tests/charge-mode.test.sh`, the check `bin-charge-mode`, 41 cases. Each
script runs as a copy whose battery and state paths point into the sandbox,
and a case fails if the copy still names a real one; sudo, notify-send,
pkill and sleep are stubs. Covered: the bracketed mode anywhere in the list,
none bracketed, an empty attribute, the modes the firmware offers (not a
fixed list), no `charge_types` for every command; cycle from each mode and
from none, set, set without a mode, a refused sudo, a missing helper, the
boot default read and written, help, unknown commands, no notify-send; the
user's command and the real helper together; the helper's refusals (wrong
case, brackets, spaces, globs, a leading dash, `;`, `..`, 100 000
characters), no mode, no attribute, a failed write that saves nothing, extra
arguments, 200 rounds of two at once; the restore with no, an empty or an unreadable saved
mode, a late attribute, one that never appears (20 half-second waits), and
a saved mode passed on for the helper to judge; the package's three
commands, their PATHs and the helper they call. The VM test `hardware-power`
checks the sudo rule, the boot unit and the saved mode on a running system.

## Findings that are not fixed

Kept as Fedora has them:

- `charge-mode set MODE` passes any mode on to the helper and lets it refuse;
  the helper's message is what the user sees.
- `charge-mode-restore` waits up to 10 seconds at boot for `charge_types`
  when it never appears (another laptop, or a kernel that renamed it), and
  then exits 0 with one journal line.
- The tmpfiles entry writes `Long_Life` only when `/var/lib/charge-mode` does
  not exist; an empty file stays empty, and the restore then does nothing.
