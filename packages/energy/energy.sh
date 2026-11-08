#!/usr/bin/env bash
# energy: the laptop's energy settings in one place, and the watcher that
# applies them. Built 2026-10-03 from the battery round's decisions on the
# Fedora laptop.
#
# THE MENU (`energy menu`, middle click on waybar's power-profile icon) is a
# fuzzel dropdown in the style of waybar-netmenu. Each row is one setting with
# its current value; picking a row opens that setting's choices:
#   Power profile    power-saver / balanced / performance (tuned-ppd)
#   Refresh rate     auto / 120 Hz / 60 Hz. Auto = 60 Hz on power-saver and
#                    120 Hz on the other two profiles.
#   Keep-awake       on / off (the waybar cup; it also switches itself off on
#                    every unplug, so it can't be forgotten on battery again,
#                    as it was for 8 days in late September)
#   Idle suspend     on / off: suspend after 30 min idle, on battery only
#   Charge mode      Long_Life / Standard / Fast (charge-mode)
#   Focus bar        on / off: on battery, switch waybar to its focus layout
#
# THE WATCHER (`energy watch`, energy-watch.service) listens on the system bus
# for UPower's OnBattery and tuned-ppd's ActiveProfile and acts on changes:
# the refresh rate follows the profile in auto mode, and an unplug turns
# keep-awake off and, if Focus bar is on, switches waybar to focus (plugging
# in switches it back, but only if the watcher was the one that switched).
# gdbus blocks on the bus socket, so an idle watcher costs no wakeups.
#
# WHY KANSHI CALLS `energy refresh`. kanshi pins 2560x1600@120Hz in all its
# profiles and re-applies on every dock and undock, so each profile ends with
# `exec energy refresh`, which puts the auto choice back.
#
# The tools of the session come from its PATH: fuzzel (with the session's
# theme), swaymsg, keep-awake and waybar-launch. The rest comes with the
# package, charge-mode by its store path. A missing keep-awake or
# waybar-launch is said in the journal and a notification, never skipped
# without a word.
#
# Settings persist in ~/.local/state/energy (machine-local, survives reboots).
#
# Usage:
#   energy menu | watch | refresh | idle-suspend
#   energy get <key> | set <key> <value>
#     keys: refresh (auto|120|60), idle_suspend (on|off), focus_bar (on|off)
set -uo pipefail

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/energy"
RUN="${XDG_RUNTIME_DIR:-/tmp}"
CHARGE_MODE=@chargeMode@
IDLE_SUSPEND_MIN=30   # keep-awake's swayidle runs `energy idle-suspend` then

declare -A DEFAULT=([refresh]=auto [idle_suspend]=on [focus_bar]=off)

notify() { command -v notify-send >/dev/null 2>&1 && notify-send -a "Energy" "$@"; }

# A tool of the desktop session (keep-awake, waybar-launch) that is not on
# the PATH: says so in the journal and as a notification, naming the tool
# and what stays as it is, so nothing claims a change that did not happen.
need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  echo "energy: $1 is not on the PATH, so $2" >&2
  notify -u critical "$1 not found" "$2."
  return 1
}
# keep-awake set STATE, and when it fails, the same kind of message.
keep_awake() {
  local rc
  keep-awake set "$1" && return 0
  rc=$?
  echo "energy: keep-awake set $1 failed (exit $rc), so keep-awake may still be $2" >&2
  notify -u critical "keep-awake failed" "keep-awake set $1 failed (exit $rc), so keep-awake may still be $2."
  return "$rc"
}

get() { cat "$STATE_DIR/$1" 2>/dev/null || printf '%s\n' "${DEFAULT[$1]}"; }
# Saved through a rename, so two sets at once leave one whole value, and a
# get never reads a file halfway written.
set_key() {
  local tmp
  case "$1:$2" in
    refresh:auto|refresh:120|refresh:60|idle_suspend:on|idle_suspend:off|focus_bar:on|focus_bar:off) ;;
    *) echo "energy: '$2' is not a value for '$1'" >&2; return 2 ;;
  esac
  mkdir -p "$STATE_DIR" && tmp=$(mktemp "$STATE_DIR/.$1.XXXXXX") || return 1
  if ! { printf '%s\n' "$2" >"$tmp" && mv -f -- "$tmp" "$STATE_DIR/$1"; }; then
    rm -f -- "$tmp"
    return 1
  fi
}

on_battery() { [ "$(cat /sys/class/power_supply/ADP0/online 2>/dev/null)" = 0 ]; }
# tuned-ppd's power-profiles API on the system bus, the same one waybar's
# power-profiles-daemon module uses (powerprofilesctl is not installed here).
PP=(net.hadess.PowerProfiles /net/hadess/PowerProfiles net.hadess.PowerProfiles ActiveProfile)
profile() {
  local v
  v=$(busctl --system get-property "${PP[@]}" 2>/dev/null) || { echo balanced; return; }
  v=${v#s \"}; printf '%s\n' "${v%\"}"
}
set_profile() { busctl --system set-property "${PP[@]}" s "$1"; }

# ── refresh rate ─────────────────────────────────────────────────────────────
target_hz() {
  case "$(get refresh)" in
    60)  echo 60 ;;
    120) echo 120 ;;
    *)   if [ "$(profile)" = power-saver ]; then echo 60; else echo 120; fi ;;
  esac
}

# The internal panel is eDP-1 or eDP-2, depending on the boot; only an active
# one is touched, and only when its rate differs, so a call costs no modeset.
refresh() {
  local out want
  out=$(swaymsg -t get_outputs 2>/dev/null | jq -r '[.[] | select(.active and (.name | startswith("eDP")))][0]
          | if . == null then empty else "\(.name) \(.current_mode.width) \(.current_mode.height) \((.current_mode.refresh + 500) / 1000 | floor)" end')
  [ -n "$out" ] || return 0
  read -r name w h hz <<<"$out"
  want=$(target_hz)
  [ "$hz" = "$want" ] && return 0
  swaymsg output "$name" mode "${w}x${h}@${want}Hz" >/dev/null
}

# ── idle suspend ─────────────────────────────────────────────────────────────
# Called by swayidle after IDLE_SUSPEND_MIN of idle (normal mode only; with
# keep-awake on, swayidle runs no timeouts at all). Never cuts a backup or a
# video download short: then this idle period passes without a suspend.
idle_suspend() {
  [ "$(get idle_suspend)" = on ] || return 0
  on_battery || return 0
  if systemctl is-active --quiet borg-backup.service 2>/dev/null \
     || pgrep -x dl-video >/dev/null 2>&1 || pgrep -f '^restic ' >/dev/null 2>&1; then
    return 0
  fi
  systemctl suspend
}

# ── power source changes ────────────────────────────────────────────────────
unplugged() {
  if [ "$(cat "$RUN/keep-awake" 2>/dev/null)" = 1 ] \
     && need keep-awake "keep-awake stays on after the unplug" \
     && keep_awake off on; then
    notify "Keep-awake off" "Switched off on unplug."
  fi
  if [ "$(get focus_bar)" = on ] && [ "$(cat "$RUN/waybar-mode" 2>/dev/null || echo full)" = full ] \
     && need waybar-launch "the bar stays as it is"; then
    echo focus >"$RUN/waybar-mode"; : >"$RUN/energy-focus-auto"
    setsid -f waybar-launch >/dev/null 2>&1
  fi
}

# Without waybar-launch the marker stays, so a later replug switches back.
plugged_in() {
  if [ -e "$RUN/energy-focus-auto" ]; then
    if [ "$(cat "$RUN/waybar-mode" 2>/dev/null)" = focus ]; then
      need waybar-launch "the bar stays as it is" || return 0
      echo full >"$RUN/waybar-mode"; setsid -f waybar-launch >/dev/null 2>&1
    fi
    rm -f "$RUN/energy-focus-auto"
  fi
}

watch() {
  local last now
  refresh
  if on_battery; then last=1; else last=0; fi
  { gdbus monitor --system --dest org.freedesktop.UPower --object-path /org/freedesktop/UPower &
    gdbus monitor --system --dest net.hadess.PowerProfiles --object-path /net/hadess/PowerProfiles &
    wait; } 2>/dev/null | while IFS= read -r line; do
      case "$line" in *OnBattery*|*ActiveProfile*) ;; *) continue ;; esac
      if on_battery; then now=1; else now=0; fi
      if [ "$now" != "$last" ]; then
        if [ "$now" = 1 ]; then unplugged; else plugged_in; fi
        last=$now
      fi
      refresh
    done
  exit 1   # the monitors died; systemd restarts the watcher
}

# ── the menu ─────────────────────────────────────────────────────────────────
pick() { fuzzel --dmenu --prompt "$1" --width 42 --lines "${2:-8}"; }
mark() { if [ "$1" = "$2" ]; then printf '󰄬 %s\n' "$3"; else printf '   %s\n' "$3"; fi; }

menu() {
  local prof ka cm choice sub
  prof=$(profile)
  ka=off; [ "$(cat "$RUN/keep-awake" 2>/dev/null)" = 1 ] && ka=on
  cm=$("$CHARGE_MODE" 2>/dev/null || echo unknown)
  local r_prof="󰾅  Power profile: $prof"
  local r_ref
  r_ref="󰍹  Refresh rate: $(get refresh)$( [ "$(get refresh)" = auto ] && printf ' (%s Hz now)' "$(target_hz)")"
  local r_ka="󰅶  Keep-awake: $ka"
  local r_is
  r_is="󰒲  Idle suspend on battery: $(get idle_suspend)"
  local r_cm="󰂄  Charge mode: $cm"
  local r_fb
  r_fb="󰕮  Focus bar on battery: $(get focus_bar)"
  choice=$(printf '%s\n' "$r_prof" "$r_ref" "$r_ka" "$r_is" "$r_cm" "$r_fb" | pick "  Energy   " 6) || exit 0
  case "$choice" in
    "$r_prof")
      sub=$({ mark "$prof" power-saver "power-saver"; mark "$prof" balanced "balanced"; mark "$prof" performance "performance"; } \
            | pick "  Power profile   " 3) || exit 0
      set_profile "$(echo "$sub" | awk '{print $NF}')" ;;   # the watcher follows with the refresh rate
    "$r_ref")
      sub=$({ mark "$(get refresh)" auto "auto  (60 Hz on power-saver, else 120 Hz)"; mark "$(get refresh)" 120 "120 Hz always"; mark "$(get refresh)" 60 "60 Hz always"; } \
            | pick "  Refresh rate   " 3) || exit 0
      case "$sub" in *auto*) set_key refresh auto ;; *120*) set_key refresh 120 ;; *60*) set_key refresh 60 ;; esac
      refresh ;;
    "$r_ka")
      sub=$({ mark "$ka" on "on   (no idle lock or screen-off)"; mark "$ka" off "off  (normal idle)"; } | pick "  Keep-awake   " 2) || exit 0
      need keep-awake "keep-awake is unchanged" || exit 1
      case "$sub" in *on\ *) keep_awake on off ;; *off*) keep_awake off on ;; esac ;;
    "$r_is")
      sub=$({ mark "$(get idle_suspend)" on "on   (suspend after $IDLE_SUSPEND_MIN min idle, on battery)"; mark "$(get idle_suspend)" off "off"; } \
            | pick "  Idle suspend   " 2) || exit 0
      case "$sub" in *on\ *) set_key idle_suspend on ;; *off*) set_key idle_suspend off ;; esac ;;
    "$r_cm")
      sub=$({ mark "$cm" Long_Life "Long_Life  (parks the cell, refills to 80%)"; mark "$cm" Standard "Standard   (charges to 100%)"; mark "$cm" Fast "Fast       (100%, hardest on the cell)"; } \
            | pick "  Charge mode   " 3) || exit 0
      "$CHARGE_MODE" set "$(echo "$sub" | awk '{for (i=1;i<=NF;i++) if ($i ~ /^(Long_Life|Standard|Fast)$/) print $i}')" >/dev/null ;;
    "$r_fb")
      sub=$({ mark "$(get focus_bar)" on "on   (focus layout while on battery)"; mark "$(get focus_bar)" off "off"; } | pick "  Focus bar   " 2) || exit 0
      case "$sub" in *on\ *) set_key focus_bar on ;; *off*) set_key focus_bar off ;; esac ;;
  esac
}

case "${1:-menu}" in
  menu)          menu ;;
  watch)         watch ;;
  refresh)       refresh ;;
  idle-suspend)  idle_suspend ;;
  get)           get "${2:?key}" ;;
  set)           set_key "${2:?key}" "${3:?value}" ;;
  *) echo "usage: energy [menu|watch|refresh|idle-suspend|get KEY|set KEY VALUE]" >&2; exit 2 ;;
esac
