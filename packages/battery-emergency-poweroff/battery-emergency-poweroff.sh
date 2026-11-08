#!/usr/bin/env bash
# battery-emergency-poweroff: the last layer of the battery safety net. The
# timer battery-emergency-poweroff.timer runs it as root every 2 minutes,
# apart from upowerd, D-Bus and logind's battery handling: when the battery
# discharges at 3 % or less, it warns for 10 seconds and powers off.
# Plugging in the charger in those 10 seconds aborts, because the battery
# then stops discharging, and so does a capacity above 3 % at the second
# reading. When logind refuses the poweroff, it blocks sleep for the rest of
# the boot and asks systemd directly.
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

# Blocks every sleep unit for the rest of the boot, before the direct
# poweroff below: a drop-in that refuses a start by request (logind's
# StartUnit is one) and a condition that never holds (a start as a
# dependency). It goes under /run because NixOS's units live in
# /etc/systemd/system, and a runtime mask in /run would not override them.
# A failure here never stops the poweroff.
block_sleep() {
    local unit
    for unit in sleep.target suspend.target hibernate.target hybrid-sleep.target \
        suspend-then-hibernate.target systemd-suspend.service systemd-hibernate.service \
        systemd-hybrid-sleep.service systemd-suspend-then-hibernate.service; do
        mkdir -p "/run/systemd/system/$unit.d" 2>/dev/null &&
            printf '[Unit]\nRefuseManualStart=yes\nConditionPathExists=!/\n' \
                >"/run/systemd/system/$unit.d/50-battery-emergency-poweroff.conf" 2>/dev/null
    done
    systemctl daemon-reload
}

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
    # Read both again: plugging in the charger during the warning aborts,
    # and so does a capacity that is above 3 % again or no number, so one
    # low sample, as right after a resume, never powers a healthy battery
    # off.
    status=$(cat "$BAT/status" 2>/dev/null)
    cap=$(cat "$BAT/capacity" 2>/dev/null)
    if [ "$status" = "Discharging" ] && [ "$cap" -le 3 ] 2>/dev/null; then
        systemctl poweroff && exit 0
        # logind refuses while a suspend or a shutdown is under way ("Action
        # suspend already in progress"), and systemctl then gives up instead
        # of asking systemd: the failing suspend loop this net exists for is
        # such a time. So ask systemd directly, as systemctl does without
        # logind. The suspend that logind holds back stays armed: it fires
        # when its delay lock goes or its delay runs out, also during the
        # shutdown. replace-irreversibly does not disarm it; it only keeps a
        # later request from cancelling the poweroff's own jobs. On NixOS
        # that late suspend is refused today all the same, because its
        # transaction pulls in sleep-actions.service, whose default
        # dependencies collide with those jobs (the VM test saw
        # "Transaction for suspend.target/start is destructive"). The block
        # first makes the refusal rest on nothing else: logind's start of a
        # sleep target fails at once.
        logger -t battery-emergency-poweroff "logind refused the poweroff; blocking sleep, then starting poweroff.target directly"
        block_sleep
        exec systemctl start --job-mode=replace-irreversibly --no-block poweroff.target
    fi
fi
exit 0
