# handy-ptt

Hold-to-talk for Handy (`handy-ptt down|up [clean]`), carried over from the
Fedora setup. The Sway configuration binds it to the dictation keys.
`tests/desktop/handy.nix` runs it with the real `pgrep` (a recording shim that
checks the `-u` argument) against stand-ins for Handy built the way nixpkgs
builds it (a compiled program behind a `makeBinaryWrapper` wrapper with
`--inherit-argv0`, and an unwrapped one), and against stand-ins for `pactl` and
`notify-send`: both directions, both modes, the mode memory, a dropped press, a
quick tap, a mode file with garbage in it, a Handy started by its bare name, an
unwrapped Handy, a look-alike process that carries Handy's path in its command
line, and a runtime directory that is missing or unset. The test also asserts
the parts of the real Handy (`packages/handy`, 0.10.0) that the stand-in copies
(the ELF wrapper, the `.handy-wrapped` file, `--inherit-argv0`, the
`handy-0.10.0` store path), that `handy --help` lists `--start-hidden` and
`--toggle-post-process`, and, in Handy's source, that a second Handy forwards
`--toggle-post-process` to the running one, that SIGUSR2 is the plain toggle,
and that 0.10.0's transcription worker is named `Handy-worker`, which a decoy
shows `handy-ptt` does not take for Handy. A bump or a change there fails the
check.

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
  wrapper inherits from the caller, and `pgrep` is asked for the user's own
  processes (`-u`): another user's Handy on the same machine is not the one to
  signal.
- a mode file that cannot be written no longer prints an error or stops the
  take: `down` toggles all the same, and `up` takes its own argument.

## Findings that are not fixed

- The script runs without `errexit`, `nounset` and `pipefail`, on purpose: it is
  a POSIX shell script that handles failure itself, and `pactl ... | grep -q`
  fails under `pipefail` whenever `grep` stops reading early.
- It finds the take by Handy's capture stream, whose PulseAudio client is
  named `cpal-pulseaudio-PID`. A Handy that names it differently makes every
  `up` a no-op and every `down` a toggle on every press. The test asserts the
  name in the built Handy and in its vendored `handy-cpal` source (with the
  process id); Handy 0.9.8 had no such client, so this driver needs 0.10.0.
  The stream itself is only modeled by the `pactl` stand-in. The same goes for
  the process name
  `.handy-wrapped`: the test builds the wrapper the way nixpkgs does and checks
  the real package's layout, but only the real Handy on huginn shows that it
  runs under that name.
- Two presses at the same moment race on the mode file. Sway runs one binding
  at a time, so the keys do not trigger it.
- `/run/user/UID` is the fallback when `XDG_RUNTIME_DIR` is unset; where that
  directory is missing too, the mode file cannot be written, so `up` cannot
  follow the mode `down` used and takes its own argument (the test asserts it).
  A graphical session has the runtime directory, so this is an edge.
