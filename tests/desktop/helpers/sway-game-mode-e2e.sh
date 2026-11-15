#!/usr/bin/env bash
# The cases of sway-game-mode against a real, headless Sway and real windows
# (tests/desktop/sway-game-mode.nix runs this). The environment names the
# programs: SWAY_GAME_MODE, SWAY, SWAYMSG, FOOT, JQ. Each case prints PASS or
# FAIL; the script exits 1 when any failed.
#
# The seat's hide_cursor values cannot be asked of Sway, so the watcher's
# own log stands in: it says "sway refused" for every command that Sway
# answers with success false, and no such line may appear.
set -u
GAME=com.mojang.minecraft
fail=0

mode() { "$SWAYMSG" -t get_binding_state | "$JQ" -r .name; }
pass() { echo "PASS $1"; }
bad() { echo "FAIL $1"; fail=1; }

expect_mode() { # name want
  for _ in $(seq 50); do
    if [ "$(mode)" = "$2" ]; then pass "$1 (mode $2)"; return; fi
    sleep 0.1
  done
  bad "$1: wanted mode $2, got $(mode)"
}

stays_mode() { # name want
  sleep 1
  if [ "$(mode)" = "$2" ]; then pass "$1 (mode stays $2)"; else bad "$1: wanted mode $2, got $(mode)"; fi
}

focus() { "$SWAYMSG" "[app_id=\"$1\"]" focus > /dev/null; }

window() { # app_id
  "$FOOT" --app-id "$1" sleep 600 &
  for _ in $(seq 50); do
    # shellcheck disable=SC2016  # a jq program
    if "$SWAYMSG" -t get_tree | "$JQ" -e --arg a "$1" '.. | select(.app_id? == $a)' > /dev/null; then return; fi
    sleep 0.1
  done
  bad "the window $1 never appeared"
}

"$SWAYMSG" mode default > /dev/null
"$SWAY_GAME_MODE" 2> watcher.log &
watcher=$!
sleep 0.5

window other
expect_mode "start with a window that is no game" default

window "$GAME"
expect_mode "a game gains focus" game
focus other
expect_mode "focus goes to another window" default
focus "$GAME"
expect_mode "focus comes back to the game" game
"$SWAYMSG" workspace number 7 > /dev/null
expect_mode "an empty workspace" default
"$SWAYMSG" workspace number 1 > /dev/null
focus "$GAME"
expect_mode "back on the game's workspace" game

# resize and passthrough keep their mode, whichever way the focus moves.
for m in resize passthrough; do
  "$SWAYMSG" mode default > /dev/null
  focus other
  sleep 0.3
  "$SWAYMSG" mode $m > /dev/null
  focus "$GAME"
  stays_mode "a game gains focus in $m" $m
  focus other
  stays_mode "focus leaves the game in $m" $m
done
"$SWAYMSG" mode default > /dev/null

focus "$GAME"
expect_mode "the game again" game
"$SWAYMSG" reload > /dev/null
expect_mode "after a reload the game is entered again" game

# SIGTERM leaves the game and exits 0.
kill -TERM $watcher
wait $watcher
code=$?
if [ "$code" = 0 ]; then pass "SIGTERM exits 0"; else bad "SIGTERM exited $code"; fi
expect_mode "SIGTERM leaves game" default

# A crash leaves "game" behind; --leave is the ExecStopPost that clears it.
"$SWAY_GAME_MODE" 2> watcher2.log &
watcher=$!
sleep 0.5
expect_mode "a second watcher enters game" game
kill -KILL $watcher
wait $watcher 2> /dev/null
stays_mode "a killed watcher leaves game behind" game
"$SWAY_GAME_MODE" --leave 2> leave.log
code=$?
if [ "$code" = 0 ]; then pass "--leave exits 0"; else bad "--leave exited $code"; fi
expect_mode "--leave returns to default" default
"$SWAY_GAME_MODE" --leave 2> /dev/null
if [ "$(mode)" = default ]; then pass "--leave in default changes nothing"; else bad "--leave in default"; fi

# A watcher started while a game has focus enters game at once, and ends
# with status 1 when Sway goes away.
"$SWAY_GAME_MODE" 2> watcher3.log &
watcher=$!
expect_mode "a watcher started with a game in focus" game
"$SWAYMSG" exit > /dev/null 2>&1 || true
wait $watcher
code=$?
if [ "$code" = 1 ]; then pass "Sway going away ends the watcher with 1"; else bad "the watcher exited $code when Sway went away"; fi

if cat watcher.log watcher2.log leave.log watcher3.log | grep -q "sway refused"; then
  bad "Sway refused a command:"
  cat watcher.log watcher2.log leave.log watcher3.log
fi
exit $fail
