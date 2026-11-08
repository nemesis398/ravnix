# bt-game-codec

Switches Bluetooth headphones to SBC while a game runs, and back, to cut the
latency of AAC (`bt-game-codec on|off`). Bash, carried over unchanged from
Fedora's `bin-bt-game-codec` (AGENTS.md, rule 4). It always exits 0, so a
launch option never keeps a game from starting.

Installed on the laptop by `modules/desktop/scripts.nix`. `pactl` is the
`pulseaudio` package's, which speaks to PipeWire's pulse server too.

## Personal values

None.

## Changes from the original

None. shellcheck passes; `bashOptions = [ ]` because the script sets its own
`set -u` and errexit would change what it does.

## Left out

Nothing.

## Tests

`tests/bt-game-codec.test.sh`, the check `bin-bt-game-codec`: `pactl` is a
stand-in with a card list. Covers `on` (only a bluez card on AAC that offers
SBC is switched, and only that one is remembered; a card that refuses is not
remembered), `off` (the remembered card goes back, a vanished one is skipped,
the memory is gone afterwards), no sound server, and an unknown or missing
mode, which print the usage and still exit 0.

## Findings not fixed

None.
