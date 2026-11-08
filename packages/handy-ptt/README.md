# handy-ptt

Hold-to-talk for Handy (`handy-ptt down|up [clean]`), carried over from the
Fedora setup. The Sway configuration binds it to the dictation keys.
`tests/desktop/handy.nix` runs it against stand-ins for Handy, `pgrep`,
`pactl` and `notify-send`: both directions, both modes, the mode memory, a
dropped press, a quick tap, a mode file with garbage in it.

## Changed from the original

- the helper commands come from the store, not from `~/.local/bin`;
- a direction other than `down` or `up` is a usage error at once. The original
  said so only while Handy ran, and otherwise exited 0 without a word, so a typo
  in a key binding looked like Handy being off. The test found it.

## Findings that are not fixed

- The script runs without `errexit`, `nounset` and `pipefail`, on purpose: it is
  a POSIX shell script that handles failure itself, and `pactl ... | grep -q`
  fails under `pipefail` whenever `grep` stops reading early.
- It finds the take by Handy's PipeWire stream, named `cpal-pulseaudio-PID`.
  A Handy that names its stream differently makes every `up` a no-op and every
  `down` a toggle on every press. The stand-in uses the same name; only Handy
  itself shows whether it holds.
- Two presses at the same moment race on the mode file. Sway runs one binding
  at a time, so the keys do not trigger it.
- `/run/user/UID` is the fallback when `XDG_RUNTIME_DIR` is unset; where that
  directory is missing, the mode file cannot be written and `down` stops there.
