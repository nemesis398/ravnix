#!/usr/bin/env bash
# Tests for bt-game-codec (packages/bt-game-codec), run by the check
# bin-bt-game-codec. pactl is a stand-in: the contract is which card gets which
# profile and what is remembered between `on` and `off`, and a real pactl would
# switch the headphones of whoever runs the tests. The stand-in is in front of
# the script's own pactl (see tests/bin/helpers/stub-first.nix).
#
# BT_GAME_CODEC_UNDER_TEST=<file> tests another copy; by default it is the
# bt-game-codec on the PATH.

# The checks are eval'd, so their $ expand at check time.
# shellcheck disable=SC2016

set -uo pipefail

SUT=$(readlink -f "${BT_GAME_CODEC_UNDER_TEST:-$(type -P bt-game-codec)}")
BASH_BIN=$(type -P bash)
SB=$(mktemp -d "${TMPDIR:-/tmp}/bt-game-codec-test.XXXXXX")
trap 'rm -rf "$SB"' EXIT

pass=0 fail=0
ok()  { printf '  \e[32m✓\e[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \e[31m✗\e[0m %s\n%s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$SB/bin" "$SB/run"
# The cards come from $CARDS, one "name profile has_sbc" line each; every
# set-card-profile is logged, and fails for a card named in $SET_FAILS.
cat >"$SB/bin/pactl" <<'STUB'
#!/usr/bin/env bash
[[ -n ${PACTL_DEAD:-} ]] && exit 1
if [[ $1 == list && $2 == cards && ${3:-} == short ]]; then
    while read -r name _ _; do [[ -n $name ]] && printf '1\t%s\tmodule-bluez5-device.c\n' "$name"; done <<<"$CARDS"
elif [[ $1 == list && $2 == cards ]]; then
    while read -r name profile sbc; do
        [[ -n $name ]] || continue
        printf 'Card #1\n\tName: %s\n\tProfiles:\n' "$name"
        [[ $sbc == yes ]] && printf '\t\ta2dp-sink-sbc: High Fidelity Playback (A2DP Sink, codec SBC)\n'
        printf '\tActive Profile: %s\n' "$profile"
    done <<<"$CARDS"
elif [[ $1 == set-card-profile ]]; then
    printf 'set %s %s\n' "$2" "$3" >>"$LOG"
    [[ " ${SET_FAILS:-} " == *" $2 "* ]] && exit 1
    exit 0
fi
STUB
sed -i "1s|.*|#!$BASH_BIN|" "$SB/bin/pactl"
chmod +x "$SB/bin/pactl"

# run ENV... -- ARGS: sets $out, $rc, $log.
run() {
    local envs=()
    while [[ $1 != -- ]]; do envs+=("$1"); shift; done
    shift
    : >"$SB/log"
    out=$(env -i HOME="$SB" PATH="$SB/nopath" STUB_PATH="$SB/bin" XDG_RUNTIME_DIR="$SB/run" LOG="$SB/log" \
        CARDS="$CARDS" "${envs[@]}" "$BASH_BIN" "$SUT" "$@" 2>&1)
    rc=$?
    log=$(<"$SB/log")
}
check() { if eval "$2"; then ok "$1"; else bad "$1" "    rc: $rc
    out: $out
    log: $log
    state: $(cat "$SB/run/bt-game-codec.cards" 2>/dev/null)"; fi; }
mkdir -p "$SB/nopath"

echo "bt-game-codec"

CARDS=$'bluez_card.AA_AA a2dp-sink yes\nbluez_card.BB_BB a2dp-sink-sbc yes\nbluez_card.CC_CC a2dp-sink no\nbluez_card.DD_DD headset-head-unit yes\nalsa_card.pci-0000 HiFi yes'
run -- on
check "on: a bluez card on AAC that offers SBC is switched to SBC" '[[ $log == *"set bluez_card.AA_AA a2dp-sink-sbc"* ]]'
check "on: a card already on SBC, one without SBC, one on another profile and a non-bluez card are left alone" \
    '[[ $(wc -l <<<"$log") == 1 ]]'
check "on: the switched card is remembered, and only that one" '[[ $(<"$SB/run/bt-game-codec.cards") == "bluez_card.AA_AA" ]]'
check "on: it exits 0 and says nothing" '[[ $rc == 0 && -z $out ]]'

CARDS=$'bluez_card.AA_AA a2dp-sink-sbc yes\nbluez_card.EE_EE a2dp-sink yes'
run -- off
check "off: the remembered card goes back to AAC, if it is still connected" \
    '[[ $log == "set bluez_card.AA_AA a2dp-sink" && $rc == 0 ]]'
check "off: the memory is gone afterwards" '[[ ! -e "$SB/run/bt-game-codec.cards" ]]'

run -- off
check "off with nothing remembered does nothing and exits 0" '[[ $rc == 0 && -z $log && -z $out ]]'

CARDS=$'bluez_card.AA_AA a2dp-sink yes\nbluez_card.EE_EE a2dp-sink yes'
run -- on
CARDS=$'bluez_card.EE_EE a2dp-sink-sbc yes'
run -- off
check "off: a remembered card that has gone is skipped, the one still there is restored" \
    '[[ $log == "set bluez_card.EE_EE a2dp-sink" ]]'

CARDS=$'bluez_card.AA_AA a2dp-sink yes\nbluez_card.EE_EE a2dp-sink yes'
run SET_FAILS=bluez_card.AA_AA -- on
check "on: a card that refuses the switch is not remembered, the other is" \
    '[[ $(<"$SB/run/bt-game-codec.cards") == "bluez_card.EE_EE" && $rc == 0 ]]'

CARDS=$'bluez_card.AA_AA a2dp-sink yes'
run PACTL_DEAD=1 -- on
check "no sound server: exit 0, nothing remembered, a Prism launch is not stopped" \
    '[[ $rc == 0 && ! -s "$SB/run/bt-game-codec.cards" ]]'
run PACTL_DEAD=1 -- off
check "no sound server on off: exit 0 as well" '[[ $rc == 0 ]]'

run -- sideways
check "an unknown mode prints the usage on stderr and exits 0" '[[ $rc == 0 && $out == "usage: bt-game-codec on|off" ]]'
run --
check "no mode is the same" '[[ $rc == 0 && $out == "usage: bt-game-codec on|off" ]]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
