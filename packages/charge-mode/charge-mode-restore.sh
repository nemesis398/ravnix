#!/usr/bin/env bash
# charge-mode-restore: re-assert the saved charge mode at boot, through
# charge-mode-apply, which validates it. charge-mode-restore.service runs it
# (modules/hardware/ideapad-pro-5-16ahp9/battery.nix).
#
# Waits briefly for the attribute: ideapad_laptop is a module, and if it has not
# bound yet this would otherwise skip in silence and leave the mode unrestored.
# Bounded so a machine that will never have it does not hang the boot.
set -eu
ATTR=/sys/class/power_supply/BAT0/charge_types
STATE=/var/lib/charge-mode

[ -r "$STATE" ] || exit 0
mode=$(cat "$STATE" 2>/dev/null || true)
[ -n "$mode" ] || exit 0

i=0
while [ ! -e "$ATTR" ] && [ "$i" -lt 20 ]; do
  sleep 0.5
  i=$((i + 1))
done
[ -e "$ATTR" ] || { echo "charge-mode-restore: $ATTR never appeared" >&2; exit 0; }

exec @apply@ "$mode"
