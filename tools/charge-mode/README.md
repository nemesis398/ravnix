# charge-mode

The battery's charge ceiling on the IdeaPad Pro 5 16AHP9, read and set from
the desktop without a password. The firmware has no percentage threshold,
only `BAT0/charge_types` with three modes: `Fast`, `Standard` and
`Long_Life`, which parks the cell and refills it to 80 %. Three programs:

| Program | Runs as | What it does |
| --- | --- | --- |
| `charge-mode` | the user | prints, cycles or sets the mode, and the boot default; Waybar's battery click and the energy menu call it |
| `charge-mode-apply` | root, through one sudo rule | the one writer of `charge_types`: it writes only a mode the kernel lists, to two fixed paths, and saves it in `/var/lib/charge-mode` |
| `charge-mode-restore` | root, at boot | puts the saved mode back (`charge-mode-restore.service`) |

```
charge-mode              print the active mode
charge-mode cycle        Long_Life -> Standard -> Fast -> Long_Life
charge-mode set <mode>   set one explicitly, right now
charge-mode default      print the mode re-asserted at boot
charge-mode default <m>  set the boot mode, leaving the live one alone
charge-mode modes        list what the firmware currently offers

charge-mode-apply [--save-only] MODE
charge-mode-restore
```

Every `charge-mode` command does nothing and exits 0 on a machine without
`charge_types`. Exit statuses: `charge-mode` 0, 1 when the helper did not
run or refused, 2 for bad usage; `charge-mode-apply` 0, 1 when the system is
not as it should be (no attribute, a symlink, a failed write), 2 when it
refuses its arguments; `charge-mode-restore` 0 also when there is nothing to
restore or the attribute never appears, else the helper's status.

Odin, ported from the Bash scripts carried over from Fedora's
`bin-charge-mode` (AGENTS.md, rule 4). The headers of `charge_mode.odin`,
`user.odin` and `apply.odin` hold the measurements and the reasons.
Installed by the IdeaPad module's `battery.nix`, with the sudo rule (one
command, `NOPASSWD`, as root, by its store path), the boot unit, and the
saved mode `Long_Life` on a new install.

## Personal values

None. The sudo rule's user is `ravnix.user.username`.

## The privilege split

One Odin package, built three times by `default.nix` with
`-define:CHARGE_MODE_ROLE=user|apply|restore`. Odin builds only what `main`
reaches, so each binary holds its own role's code and nothing else: the root
helper has no sudo, no notification, no Waybar refresh and no PATH lookup
(the shell test greps its binary for the names). It is a program of its own,
at a store path of its own, which is the path the sudo rule names; the user's
command and the restore have that path built in.

- `charge-mode` never writes sysfs or the saved mode. It runs
  `sudo -n HELPER [--save-only] MODE` with `LC_ALL=C`, sudo found on the
  caller's PATH (the setuid wrapper in `/run/wrappers/bin`), and passes any
  mode on for the helper to judge.
- `charge-mode-apply` checks everything before it writes anything: the
  attribute is a regular file, not a symlink, of at most 4096 bytes; its
  arguments are `MODE` or `--save-only MODE` and nothing more; the mode is a
  whole word of the kernel's list; the directory of the saved mode is a real
  directory, not a symlink, owned by root (or the caller) and writable by
  its owner alone; the saved mode is absent or a regular file. Then it writes
  the mode to `charge_types` (opened without `O_CREAT`, with `O_NOFOLLOW`,
  one write) and saves it through a temporary file, `fsync` and a rename,
  as 0644, then syncs the directory, so the rename survives a power cut. It
  runs nothing.
- `charge-mode-restore` reads the saved mode (no symlink, at most 4096
  bytes, no NUL), waits up to 20 times half a second for `charge_types`, and
  execs the helper by its store path with the mode, unchecked.

The tests point the programs at a fake battery and state through
`CHARGE_MODE_ATTR`, `CHARGE_MODE_STATE`, `CHARGE_MODE_HELPER` and (for
`charge-mode`) `CHARGE_MODE_NOTIFY_SEND`. A program honours them only when
neither its real nor its effective uid is 0, its real and effective uid and
gid are the same (no setuid or setgid exec, to root or anyone else), and it
holds no effective capability: under sudo, and as the boot unit, the fixed
paths hold whatever the environment says. The VM test `hardware-power` checks that as root,
directly and through sudo.

## Changes from the Bash scripts

What a caller sees is the same: the program names, the commands, the output,
the messages, the exit statuses and the boot unit. `pkgs.ravnix.charge-mode`
is the package, with `passthru.apply` and `passthru.restore`, so
`battery.nix`, the energy menu (which runs `charge-mode` by its store path)
and Waybar's `charge-mode cycle` need no change. On purpose:

- the helper refuses extra arguments (exit 2). The Bash one used the first
  and ignored the rest, so `charge-mode-apply Fast --save-only` wrote the
  live mode;
- the helper checks the state directory and the saved mode before it writes
  the attribute. The Bash one wrote `charge_types` and then failed to save
  when `/var/lib` was missing; with a directory at `/var/lib/charge-mode` its
  `mv` moved the mode into it and exited 0; it followed a symlinked
  attribute or state directory and wrote to the target;
- the helper refuses an attribute that is a symlink, not a file, or longer
  than 4096 bytes, and a state directory that others may write;
- a refused mode is shown with every byte outside printable ASCII as `\xNN`
  and cut after 64 bytes with its length, so the refusal is two lines
  whatever the argument held; the Bash helper echoed 100 000 bytes back, and
  a newline or an escape sequence as it was;
- the restore refuses a symlinked or non-file saved mode (exit 1), one over
  4096 bytes (exit 2) and one with a NUL (exit 2; the Bash `$(cat)` dropped
  the NUL and restored `Fa\0st` as `Fast`);
- the restore waits with `nanosleep`, not `sleep`; a missing helper exits
  127, as the shell's `exec` did;
- the Waybar refresh scans `/proc` and sends `SIGRTMIN+10` (44, glibc's
  `SIGRTMIN` is 34) through `pidfd_send_signal` to each process named
  `waybar` or `.waybar-wrapped` whose effective uid is the caller's, as
  `pkill -u "$EUID" -x 'waybar|\.waybar-wrapped'` matched; each process is
  pinned by a pidfd before it is looked at, so a reused pid gets no signal;
- sudo is looked up on PATH like `command -v` did, but empty and relative
  entries are skipped, so nothing runs from the working directory;
- notify-send is the package's own by its store path, as the Bash
  package's PATH put it first;
- `charge-mode` reads `charge_types` and the saved mode up to 64 KiB; a
  longer one counts as unreadable (`unknown`, `(nothing saved)`). `cat` read
  any length.

## Tests

`tests/` (the check `charge-mode-tests`, 33 tests): the bracketed mode and
the offered words, which words count as offered (part of a word, brackets,
spaces, tabs, line ends, NUL, globs, a leading dash, `..`), the cycle, the
shown argument, reading a missing, symlinked, dangling, directory, FIFO,
exactly-4096 and over-4096 file, the seams' rule, the fixed paths; the
helper writing and saving (0644), `--save-only` on a read-only attribute,
every refusal with both files left as they were, one mode only, a symlinked,
missing, directory or oversized attribute, a failed write, a symlinked or
directory saved mode, a state directory that others may write, that is a
symlink, missing or a file, a leftover temporary file, 200 rounds of two
writes at once in threads; the restore passing the mode on, nothing to do,
the refusals, a late attribute and giving up; the user's command without
`charge_types`, reading, the saved mode, usage and refusals, a missing
helper, no sudo, sudo's words and their hints, the PATH lookup, the locale,
and which processes count as the user's Waybar in a fake `/proc`.

`tests/bin/charge-mode/charge-mode.test.sh` (the check `bin-charge-mode`, 61
cases) runs the built programs, with sudo and notify-send as stubs: the
cases of the Bash scripts' test, which passed against the Bash scripts and
the Odin programs alike before the scripts were deleted, among them the
Waybar refresh against real processes named `.waybar-wrapped`, `waybar`,
`waybar-launch`, `waybar-powerdraw` and one that only calls itself waybar in
its argv, and 200 rounds of two helpers at once; then the helper's refusals
of control characters, a huge mode, a symlinked or non-file or huge
attribute, a symlinked or missing or others-writable state directory, a
symlinked or directory saved mode, the directory synced after the rename
(under strace); and the package: three different ELF
programs, the helper path built into the other two, no `sudo`,
`notify-send` or `waybar` in the root programs, and both root programs
working with an empty environment. The VM test `hardware-power` checks the
sudo rule, the boot unit, the saved mode, and that root ignores the seams.

## Bench

`bench/baseline.json`: `charge-mode show` as on a machine without
`charge_types`, which is the start of every run and what every command does
there (the runtime's start, the seams, one `access`). The bench's
environment is fixed and cannot carry the seams, and the root programs take
no path option, so the bench cannot point a program at a fake battery; the
sandbox has no `/sys`. The work on a real attribute is a few hundred bytes
of parsing and is covered by the tests, not the count.

## Findings that are not fixed

- `charge-mode set MODE` passes any mode on to the helper and lets it refuse;
  the helper's message is what the user sees. Kept as Fedora has it.
- `charge-mode-restore` waits up to 10 seconds at boot for `charge_types`
  when it never appears (another laptop, or a kernel that renamed it), and
  then exits 0 with one journal line.
- The tmpfiles entry writes `Long_Life` only when `/var/lib/charge-mode` does
  not exist; an empty file stays empty, and the restore then does nothing.
- The helper's check that the state directory belongs to root or the caller
  has no test: a test cannot make a directory of another uid without root.
  The check of its write bits has one.
- The helper refuses a state directory that is a symlink, so a system whose
  `/var/lib` is a symlink (rather than a bind mount) cannot save a mode.
- A sudo or notify-send that never exits holds `charge-mode` as long, as it
  did the Bash script; `sudo -n` asks nothing, and notify-send gives up
  after D-Bus's timeout.
- The seams' rule reads the effective capabilities with `capget`; a kernel
  that refused the call would count as privileged, so the tests would see
  the fixed paths and fail, which is the safe side.
