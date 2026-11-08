#!/usr/bin/env bash
# battery-emergency-poweroff: the last layer of the battery safety net. The
# timer battery-emergency-poweroff.timer runs it as root every 2 minutes,
# apart from upowerd, D-Bus and logind's battery handling: when the battery
# discharges at 3 % or less, it warns for 10 seconds and powers off.
# Plugging in the charger in those 10 seconds aborts, because the battery
# then stops discharging.
#
# Why it exists: on the Fedora laptop the battery ran to 0 % twice while a
# broken suspend looped all night with the lid closed (2026-07-13 and
# 2026-07-14). upowerd was alive both nights and took no action through
# 3 h 12 min of discharge, so a net that rested on upowerd alone would rest
# on the part that failed. UPower's own critical action is the first layer
# (modules/hardware/ideapad-pro-5-16ahp9/battery.nix); this is the second.
# The thresholds are the Fedora ones: 3 %, a 10 second warning, every
# 2 minutes.
#
# Usage: battery-emergency-poweroff [BATTERY]
#   BATTERY is the battery's sysfs directory, /sys/class/power_supply/BAT0
#   unless given. The unit gives none; the tests name another.
BAT=${1:-/sys/class/power_supply/BAT0}
if [ ! -r "$BAT/status" ] || [ ! -r "$BAT/capacity" ]; then
    exit 0
fi
status=$(cat "$BAT/status")
cap=$(cat "$BAT/capacity")
# A capacity that is no number fails the test and counts as not low.
if [ "$status" = "Discharging" ] && [ "$cap" -le 3 ] 2>/dev/null; then
    logger -t battery-emergency-poweroff "battery at ${cap}% and discharging, powering off in 10s"
    wall "Battery at ${cap}%: EMERGENCY POWEROFF in 10 seconds. Plug in AC now to abort." 2>/dev/null || true
    sleep 10
    # Plugging in the charger during the warning aborts.
    if [ "$(cat "$BAT/status")" = "Discharging" ]; then
        exec systemctl poweroff
    fi
fi
exit 0
