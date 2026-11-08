#!/usr/bin/env bash
# charge-mode: read and cycle the laptop battery's charge ceiling.
#
# WHAT THE HARDWARE ACTUALLY OFFERS. This IdeaPad has NO
# charge_control_end_threshold anywhere under /sys/class/power_supply, so an
# arbitrary cap ("stop at 95%") is NOT EXPRESSIBLE on it. What exists is
# /sys/class/power_supply/BAT0/charge_types with exactly three discrete modes:
# Fast / Standard / Long_Life. Writing it also flips
# /sys/bus/platform/devices/VPC2004:00/conservation_mode, because the two are
# faces of one EC feature. The kernel says so itself (2026-08-23):
#   ideapad_acpi VPC2004:00: conservation_mode attribute has been deprecated,
#   see charge_types.
# so this script drives charge_types and never the deprecated attribute.
#
# WHAT Long_Life DOES, MEASURED 2026-09-18 starting from 97%: the EC PARKS the
# cell, it does NOT force-discharge to its threshold. status went to
# "Not charging", power_now tapered 2.74 W -> 1.47 -> 0.65 -> 0.19 -> 0 over
# ~50 s as the charge path closed, energy_now froze at 75.55 Wh and held for
# 4 min with ADP0/online=1. power_now=0 on AC with the machine running is the
# proof that the PSU is carrying the whole load and the battery is neither
# taking nor giving anything, which is what "run off the power supply, not
# through the battery" actually means. There was never a knob for that half; it
# is simply what the hardware does once charging stops. (There is no
# charge_behaviour attribute on this machine, i.e. no ThinkPad-style
# inhibit-charge / force-discharge interface to set.)
#
# THE REFILL CEILING IS 80%, measured from upower history (2026-09-28, and
# twice on 2026-10-02): below it Long_Life refills to 80% and stops there;
# above it, it parks where it stands. It could not be measured on AC because
# parking leaves no discharge to observe, so it was read off the first real
# battery runs instead. Long_Life is also the boot default since 2026-10-03.
#
# WHY A ROOT HELPER AND NOT `sudo tee`. charge_types is root-writable only.
# The hardware module (modules/hardware/ideapad-pro-5-16ahp9/battery.nix)
# gives the user one sudo rule, without a password, for exactly one command:
# charge-mode-apply, from this package, which validates its argument against
# the live charge_types list, so the grant cannot be bent into an arbitrary
# root write. sudo is the setuid wrapper on the caller's PATH.
#
# Usage:
#   charge-mode              # print the active mode
#   charge-mode cycle        # Long_Life -> Standard -> Fast -> Long_Life
#   charge-mode set <mode>   # set one explicitly, right now
#   charge-mode default [m]  # print, or set, the mode re-asserted at boot
#   charge-mode modes        # list what the firmware currently offers
#
set -uo pipefail

BAT=/sys/class/power_supply/BAT0
ATTR=$BAT/charge_types
HELPER=@apply@
STATE=/var/lib/charge-mode
SIG=10   # matches "signal": 10 on custom/battery in modules.jsonc -> SIGRTMIN+10

# Inert where the attribute does not exist, rather than failing loudly: same
# auto-detect-not-hardcode rule as waybar-battery and the waybar-gpu* helpers.
if [ ! -r "$ATTR" ]; then
  echo "charge-mode: no $ATTR on this machine; nothing to do" >&2
  exit 0
fi

# The active mode is the bracketed one. Returns "unknown" rather than echoing
# the whole line back when nothing is bracketed, so a caller can never mistake
# the raw attribute text for a mode name.
current() {
  local line
  line=$(cat "$ATTR" 2>/dev/null || true)
  case "$line" in
    *\[*\]*) line=${line#*[}; printf '%s\n' "${line%%]*}" ;;
    *)       printf 'unknown\n' ;;
  esac
}

# The legal set comes from the firmware, not from a hardcoded list here, so a
# kernel or firmware change cannot leave this script writing a rejected value.
modes() { tr ' ' '\n' < "$ATTR" | tr -d '[]' | sed '/^$/d'; }

next_mode() {
  case "$1" in
    Long_Life) printf 'Standard\n'  ;;
    Standard)  printf 'Fast\n'      ;;
    Fast)      printf 'Long_Life\n' ;;
    *)         printf 'Long_Life\n' ;;  # unknown -> the conservative end
  esac
}

describe() {
  case "$1" in
    Long_Life) printf 'Parks the cell; the PSU carries the machine. Refills only to the EC ceiling.\n' ;;
    Standard)  printf 'Charges to 100%% at the normal rate.\n' ;;
    Fast)      printf 'Charges to 100%% rapidly. Hardest of the three on the cell.\n' ;;
    *)         printf '\n' ;;
  esac
}

# $2 = "save-only" to change the BOOT DEFAULT and leave the live mode alone.
# The two are deliberately separable: the cell can stay parked now and still
# come up in a different mode after a reboot.
apply() {
  local mode=$1 only=${2:-}
  if [ ! -x "$HELPER" ]; then
    echo "charge-mode: $HELPER is missing." >&2
    echo "             It comes with the charge-mode package; rebuild the host." >&2
    exit 1
  fi
  if [ "$only" = "save-only" ]; then
    if ! sudo -n "$HELPER" --save-only "$mode"; then
      echo "charge-mode: the helper refused, or the sudoers rule is absent." >&2
      echo "             The rule comes with the hardware module's battery.nix." >&2
      exit 1
    fi
    command -v notify-send >/dev/null 2>&1 &&
      notify-send -a charge-mode "Charge mode at boot: $mode" \
        "The live mode is unchanged ($(current))."
    printf '%s\n' "$mode"
    return 0
  fi
  if ! sudo -n "$HELPER" "$mode"; then
    echo "charge-mode: the helper refused, or the sudoers rule is absent." >&2
    echo "             The rule comes with the hardware module's battery.nix." >&2
    exit 1
  fi
  command -v notify-send >/dev/null 2>&1 &&
    notify-send -a charge-mode "Charge mode: $mode" "$(describe "$mode")"
  # -x matches the process name exactly. Never `pkill -f` here: that matches the
  # whole command line and takes out unrelated processes that merely mention it.
  pkill -RTMIN+"$SIG" -x waybar 2>/dev/null || true
  printf '%s\n' "$mode"
}

case "${1:-}" in
  ""|show|status)
    current ;;
  cycle)
    apply "$(next_mode "$(current)")" ;;
  set)
    mode=${2:-}
    if [ -z "$mode" ]; then
      echo "charge-mode: 'set' needs a mode. Offered now: $(modes | tr '\n' ' ')" >&2
      exit 2
    fi
    apply "$mode" ;;
  default)
    if [ -z "${2:-}" ]; then
      cat "$STATE" 2>/dev/null || echo "(nothing saved)"
    else
      apply "$2" save-only
    fi ;;
  modes)
    modes ;;
  -h|--help|help)
    printf '%s\n' \
      "charge-mode              print the active mode" \
      "charge-mode cycle        Long_Life -> Standard -> Fast -> Long_Life" \
      "charge-mode set <mode>   set one explicitly, right now" \
      "charge-mode default      print the mode re-asserted at boot" \
      "charge-mode default <m>  set the boot mode, leaving the live one alone" \
      "charge-mode modes        list what the firmware currently offers" ;;
  *)
    echo "charge-mode: unknown command '$1' (try --help)" >&2
    exit 2 ;;
esac
