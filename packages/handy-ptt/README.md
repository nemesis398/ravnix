# handy-ptt

Hold-to-talk for Handy (`handy-ptt down|up [clean]`), carried over from the
Fedora setup. The Sway configuration binds it to the dictation keys.
`tests/desktop/handy.nix` runs it with the real `pgrep` against a stand-in for
Handy built as nixpkgs builds it (a compiled program behind a
`makeBinaryWrapper` wrapper with `--inherit-argv0`), and stand-ins for `pactl`
and `notify-send`: both directions, both modes, the mode memory, a dropped
press, a quick tap, a mode file with garbage in it, a Handy started by its bare
name, a look-alike process, and no runtime directory.

## Changed from the original

- the helper commands come from the store, not from `~/.local/bin`;
- a direction other than `down` or `up` is a usage error at once. The original
  said so only while Handy ran, and otherwise exited 0 without a word, so a typo
  in a key binding looked like Handy being off. The test found it.
- Handy is found by the name of its process, `.handy-wrapped`, not `handy`. In
  nixpkgs `bin/handy` is a binary wrapper that execs `bin/.handy-wrapped`, and
  the kernel names a process after the file it runs, so the original
  `pgrep -x handy` never found it: every `down` took Handy for stopped and
  started it again, and no take began. The first version of the test replaced
  `pgrep` and missed it. The name does not depend on `argv[0]`, which the
  wrapper inherits from the caller.
- a mode file that cannot be written no longer prints an error or stops the
  take: `down` toggles all the same, and `up` takes its own argument.

## Findings that are not fixed

- The script runs without `errexit`, `nounset` and `pipefail`, on purpose: it is
  a POSIX shell script that handles failure itself, and `pactl ... | grep -q`
  fails under `pipefail` whenever `grep` stops reading early.
- It finds the take by Handy's PipeWire stream, named `cpal-pulseaudio-PID`.
  A Handy that names its stream differently makes every `up` a no-op and every
  `down` a toggle on every press. The stand-in uses the same name; only Handy
  itself shows whether it holds. The same goes for the process name
  `.handy-wrapped`: the test builds the wrapper the way nixpkgs does, but only
  the real Handy on huginn shows that it runs under that name.
- Two presses at the same moment race on the mode file. Sway runs one binding
  at a time, so the keys do not trigger it.
- `/run/user/UID` is the fallback when `XDG_RUNTIME_DIR` is unset; where that
  directory is missing too, the mode file cannot be written, so `up` cannot
  follow the mode `down` used and takes its own argument (the test asserts it).
  A graphical session has the runtime directory, so this is an edge.
