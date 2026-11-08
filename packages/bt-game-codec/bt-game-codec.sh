#!/usr/bin/env bash
# bt-game-codec: switch Bluetooth headphones to SBC while a game runs, and back.
#
# Why: AAC over A2DP adds roughly 200 ms of latency. Video players hide that by
# delaying the picture, games cannot, so Minecraft's sounds arrive late on the
# soundcore Space Q45 (2026-11-06). SBC buffers less, at a little audio quality.
#
#   bt-game-codec on    every connected bluez card on AAC (`a2dp-sink`) that
#                       offers `a2dp-sink-sbc` switches to SBC; the card names
#                       are remembered in $XDG_RUNTIME_DIR
#   bt-game-codec off   the remembered cards go back to AAC, if still connected
#
# Run from Prism's pre-launch and post-exit commands of the Minecraft instance.
# It always exits 0: Prism aborts the launch when a pre-launch command fails,
# and headphones that are off or on another codec are not a reason to stop.

set -u
state=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/bt-game-codec.cards

profile_of() {
    pactl list cards 2>/dev/null | awk -v c="$1" '
        $1 == "Name:" { n = $2 }
        n == c && /Active Profile:/ { print $3; exit }'
}

case ${1:-} in
on)
    : >"$state"
    for card in $(pactl list cards short 2>/dev/null | awk '$2 ~ /^bluez_card\./ { print $2 }'); do
        [[ $(profile_of "$card") == a2dp-sink ]] || continue
        pactl list cards 2>/dev/null | awk -v c="$card" '$1=="Name:"{n=$2} n==c' |
            grep -q 'a2dp-sink-sbc:' || continue
        pactl set-card-profile "$card" a2dp-sink-sbc && printf '%s\n' "$card" >>"$state"
    done
    ;;
off)
    [[ -r $state ]] || exit 0
    # No check of the current profile here: after a switch, pactl reports the
    # old profile for a variable time (over 1 s measured), so a check right
    # after `on` skipped the card. Setting AAC on an AAC card is harmless.
    while read -r card; do
        pactl list cards short 2>/dev/null | awk -v c="$card" '$2 == c { f = 1 } END { exit !f }' &&
            pactl set-card-profile "$card" a2dp-sink
    done <"$state"
    rm -f -- "$state"
    ;;
*)
    printf 'usage: bt-game-codec on|off\n' >&2
    ;;
esac
exit 0
