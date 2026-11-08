# dl-video

Stream-copies a remote video to a file, as a background systemd user unit
with a desktop notification when it ends, so that closing the terminal does
not stop it. Bash, carried over unchanged from Fedora's `bin-dl-video`
(AGENTS.md, rule 4).

Installed on both hosts by `modules/common/scripts.nix`: it is useful on the
server as well, where the unit and the notification both work over a session
bus. `systemd-run` and `systemctl` are the system's and are looked up on the
`PATH`, so they match the running systemd. `ffmpeg` is the headless build,
`notify-send` is `libnotify`'s.

## Personal values

None.

## Changes from the original

None. shellcheck passes; `bashOptions = [ ]` because the script sets its own
`set -euo pipefail`.

## Left out

Nothing.

## Tests

`tests/dl-video.test.sh`, the check `bin-dl-video`: `systemd-run`,
`systemctl`, `ffmpeg`, `ffprobe` and `notify-send` are stand-ins in front of
the script's own tools (`tests/bin/helpers/stub-first.nix`), so no unit starts
and no network is used. Covers the unit's name and arguments, the filename
rules, and the verdict of the worker on a finished, truncated or empty file.

## Findings not fixed

None.
