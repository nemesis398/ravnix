#!/usr/bin/env bash
# charge-mode-apply: the ONLY privileged writer of BAT0/charge_types.
#
# This is the security boundary for the one-command sudo rule without a
# password that the hardware module gives the user
# (modules/hardware/ideapad-pro-5-16ahp9/battery.nix): the mode is checked
# against the list the KERNEL currently offers, so no argument can make this
# write anything else, and the two paths it touches are fixed. It finds its
# tools in the store only, never on the caller's PATH. Writing charge_types
# also flips VPC2004:00/conservation_mode, which is the same EC feature
# under its deprecated name (kernel, 2026-08-23). Do not write that
# attribute.
set -eu
ATTR=/sys/class/power_supply/BAT0/charge_types
STATE=/var/lib/charge-mode

[ -e "$ATTR" ] || { echo "charge-mode-apply: no $ATTR" >&2; exit 1; }

# --save-only changes the BOOT DEFAULT without touching the live mode, for the
# "parked at 97% now, something else after a reboot" case. It runs through the
# same validation, so the state file can never be seeded with a value that the
# restore would then refuse.
save_only=0
if [ "${1:-}" = "--save-only" ]; then
  save_only=1
  shift
fi

mode=${1:-}
[ -n "$mode" ] || { echo "charge-mode-apply: no mode given" >&2; exit 2; }

ok=0
# The words of the list, split on purpose; the brackets mark the active one.
# shellcheck disable=SC2013
for v in $(tr ' ' '\n' < "$ATTR" | tr -d '[]'); do
  [ "$v" = "$mode" ] && ok=1
done
if [ "$ok" -ne 1 ]; then
  echo "charge-mode-apply: '$mode' is not offered by this firmware" >&2
  echo "  offered: $(tr -d '[]' < "$ATTR")" >&2
  exit 2
fi

if [ "$save_only" -eq 0 ]; then
  printf '%s' "$mode" > "$ATTR"
fi
# Saved through a rename, so two writes at once leave one whole mode and never
# a torn file that the restore would refuse.
tmp=$(mktemp "$STATE.XXXXXX")
trap 'rm -f -- "$tmp"' EXIT
printf '%s\n' "$mode" > "$tmp"
chmod 0644 "$tmp"
mv -f -- "$tmp" "$STATE"
