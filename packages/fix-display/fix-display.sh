#!/usr/bin/env bash
# fix-display: bring the Sway session back when the panel stays dark after a
# resume or a TTY visit. Run it from a TTY: Ctrl+Alt+F3, log in, `fix-display`.
# It also works from a herdr pane on that TTY, over SSH, or from an agent.
#
# What is broken: the session is alive, keyboard and swaylock included, but
# Sway's own output restore fails ("Requested backend configuration failed",
# then "Search for valid config failed") and every output stays off. There is
# nothing to draw the lock screen on. Cause, found 2026-10-20: wlroots kept the
# panel on another CRTC than the one the kernel console lit it on while Sway
# was paused, and the kernel refuses that move. panel-crtc (same package)
# explains it and keeps it from happening; this script is the fallback.
# Background: panel-crtc has the mechanism, "A dark panel after a resume".
#
# Steps, cheapest first, stopping at the first that lights an output:
#   1. switch to Sway's VT, which re-activates the session and its outputs
#   2. power on and enable all outputs, then have kanshi re-apply its profile
#   3. from a text VT, turn every CRTC off (panel-crtc --free-console), then
#      switch back, so Sway's restore starts from nothing. This is the cure
#      for the CRTC mismatch; re-plugging the dock was the old one.
# Before step 1 it saves the amdgpu display state and the kernel log, because
# every step changes that state and it is what a bug report needs. On success
# it moves the panel to the console's CRTC (panel-crtc --fix) so the next
# resume works. If nothing works it offers a clean reboot.
#
# On success it ends the TTY login it was started from, so no shell stays open
# behind the lock.
#
# Usage: fix-display           asks for sudo once
#        fix-display --status  read-only report: session, VT, lid, outputs

# The root reads below (driver state, kernel log) redirect into files that
# stay the user's, which is what SC2024 warns about and exactly what is wanted.
# shellcheck disable=SC2024
set -uo pipefail

STATE_ROOT="$HOME/.local/state/fix-display"
# panel-crtc is in this package, so it is on the PATH; sudo gets its full path.
PANEL_CRTC=$(type -P panel-crtc) || { printf 'fix-display: panel-crtc is not installed\n' >&2; exit 1; }

say()  { printf '%s\n' "$*"; }
die()  { printf 'fix-display: %s\n' "$*" >&2; exit 1; }

# Sway's IPC socket, for this user's sway only. The login greeter may run a sway
# of its own under another uid.
sway_pid=$(pgrep -u "$UID" -x sway | head -1)
if [[ -n $sway_pid ]]; then
  export SWAYSOCK="/run/user/$UID/sway-ipc.$UID.$sway_pid.sock"
fi

# Never trust XDG_SESSION_ID or XDG_SESSION_TYPE here. A TTY login drops into
# herdr, and a herdr pane inherits them from the herdr server, which was
# started inside Sway: on 2026-10-20 a pane on tty3 said session 3, wayland.
# So sessions are looked up in logind, by type and VT.
session_where() {  # session_where TYPE [VT]: this user's session of that type
  local s
  for s in $(loginctl show-user "$USER" -p Sessions --value); do
    [[ $(loginctl show-session "$s" -p Type --value) == "$1" &&
       $(loginctl show-session "$s" -p Class --value) == user ]] || continue
    [[ -z ${2:-} || $(loginctl show-session "$s" -p VTNr --value) == "$2" ]] || continue
    echo "$s"; return
  done
}

fg_vt() { local t; t=$(cat /sys/class/tty/tty0/active); echo "${t#tty}"; }

# The panel's connector on the amdgpu card. Card numbers and the eDP index
# both change between boots, so match on the driver, not on a name.
panel_connector() {
  local c
  for c in /sys/class/drm/card*-eDP-*; do
    [[ $(readlink -f "$c/device/device/driver") == */amdgpu ]] && { echo "$c"; return; }
  done
}

lid_state() { awk '{print $2}' /proc/acpi/button/lid/*/state 2>/dev/null | head -1; }

# Sway can hang inside the driver (the DMUB failure of 2026-10-07), so every
# IPC call gets a timeout. Exit 124 from here means: Sway does not answer.
outputs_json() { timeout 3 swaymsg -r -t get_outputs; }

# True when at least one output is on. That is all swaylock needs.
lit() {
  outputs_json 2>/dev/null | jq -e 'any(.[]; .active and (.power // true))' >/dev/null
}

wait_lit() {
  local i
  for ((i = 0; i < $1; i++)); do lit && return 0; sleep 1; done
  return 1
}

status() {
  local sid c
  sid=$(session_where wayland)
  say "sway pid:      ${sway_pid:-none}"
  say "sway session:  ${sid:-none}${sid:+ on VT $(loginctl show-session "$sid" -p VTNr --value)}"
  say "foreground VT: $(fg_vt)"
  say "lid:           $(lid_state)"
  c=$(panel_connector)
  say "panel:         ${c##*/} $(cat "$c/status" 2>/dev/null)"
  for c in /sys/class/drm/card*-*; do
    [[ $(cat "$c/status" 2>/dev/null) == connected ]] && say "connected:     ${c##*/}"
  done
  # wlroots names the CRTC it kept when it fails to turn it off on a pause.
  say "wlroots kept:  $(journalctl -b -q --no-pager -o cat _COMM=sway --grep 'eDP-[0-9]+: Failed to disable CRTC' 2>/dev/null | tail -1 | sed 's/.*\] //')"
  say "panel-crtc:    $("$PANEL_CRTC" 2>&1)"
  if [[ -n $sway_pid ]]; then
    say "sway outputs:"
    outputs_json | jq -r '.[] | "  \(.name)  active=\(.active)  power=\(.power // .dpms)  \(.make) \(.model)"' \
      || say "  (no answer from sway within 3 s)"
  fi
}

if [[ ${1:-} == --status ]]; then status; exit 0; fi
[[ -z ${1:-} ]] || die "unknown argument: $1 (try --status)"

# --- preconditions ----------------------------------------------------------

[[ -n $sway_pid ]] || die "no Sway of yours is running. Nothing to rescue: log in again, or reboot."

sid=$(session_where wayland)
[[ -n $sid ]] || die "found Sway (pid $sway_pid) but no wayland login session for it."
sway_vt=$(loginctl show-session "$sid" -p VTNr --value)
start_vt=$(fg_vt)

if [[ $start_vt == "$sway_vt" ]] && lit; then
  die "Sway's VT is in front and an output is on: nothing to fix. Run it from a TTY (Ctrl+Alt+F3) when the panel is dark."
fi
if [[ $(lid_state) == closed ]]; then
  die "the lid is closed, so the panel is off on purpose. Open it and run this again."
fi

# The TTY login to end on success: the tty session on the VT this started on.
tty_sid=""
[[ $start_vt != "$sway_vt" ]] && tty_sid=$(session_where tty "$start_vt")
# Step 3 needs a text VT, where the console holds the display. Use the one this
# started on, or VT 63, the console the kernel itself suspends on.
text_vt=$start_vt
[[ $text_vt == "$sway_vt" ]] && text_vt=63

panel=$(panel_connector)
[[ -n $panel ]] || die "found no eDP connector on the amdgpu card under /sys/class/drm."
pci=$(basename "$(readlink -f "$panel/device/device")")

say "Sway session $sid on VT $sway_vt, started on VT $start_vt, panel ${panel##*/}, GPU $pci."
say "sudo is needed for the VT switches, the driver state and step 3."
sudo -v || die "no sudo, no rescue."

# --- evidence ---------------------------------------------------------------

run_dir="$STATE_ROOT/$(date +%F_%H%M%S)"
mkdir -p "$run_dir"
log() { printf '%s %s\n' "$(date +%T)" "$*" | tee -a "$run_dir/run.log"; }

hung=0
outputs_json > "$run_dir/outputs-before.json" 2>&1 || { [[ $? == 124 ]] && hung=1; }
sudo cat "/sys/kernel/debug/dri/$pci/state" > "$run_dir/drm-state.txt" 2>&1
sudo journalctl -k -b -q --no-pager > "$run_dir/kernel.txt" 2>&1
journalctl -b -q --no-pager _COMM=sway _COMM=kanshi > "$run_dir/sway-kanshi.txt" 2>&1
status > "$run_dir/status-before.txt" 2>&1
log "evidence saved in $run_dir"

# --- the steps --------------------------------------------------------------

finish_ok() {
  log "step $1 worked: an output is on again"
  "$PANEL_CRTC" --fix >> "$run_dir/run.log" 2>&1
  "$PANEL_CRTC" >> "$run_dir/run.log" 2>&1 \
    || log "the panel is still on the wrong CRTC: the next resume may go dark again"
  say ""
  say "Done. Your session is on VT $sway_vt; unlock it as usual."
  say "Evidence: $run_dir"
  if [[ -n $tty_sid && $tty_sid != "$sid" ]]; then
    say "The TTY login on VT $start_vt ends now."
    sleep 2
    loginctl terminate-session "$tty_sid"
  fi
  exit 0
}

if (( hung )); then
  log "Sway does not answer on its socket: it hangs inside the driver."
  log "Nothing short of a reboot has helped with that (2026-10-07)."
else
  say ""
  say "The screen goes dark for up to half a minute while the steps run."
  say "Don't touch anything; this TTY comes back by itself if they fail."
  sleep 3

  log "step 1: switch to Sway's VT $sway_vt"
  sudo chvt "$sway_vt"
  wait_lit 8 && finish_ok 1

  log "step 2: power on, enable, kanshi reload"
  timeout 3 swaymsg 'output * power on' >> "$run_dir/run.log" 2>&1
  timeout 3 swaymsg 'output * enable'   >> "$run_dir/run.log" 2>&1
  if pgrep -u "$UID" -x kanshi >/dev/null; then
    kanshictl reload >> "$run_dir/run.log" 2>&1
  else
    timeout 3 swaymsg exec kanshi >> "$run_dir/run.log" 2>&1
  fi
  wait_lit 8 && finish_ok 2

  log "step 3: VT $text_vt, every CRTC off, back to VT $sway_vt"
  sudo chvt "$text_vt"
  sleep 1
  sudo "$PANEL_CRTC" --free-console >> "$run_dir/run.log" 2>&1
  sudo chvt "$sway_vt"
  wait_lit 8 && finish_ok 3

  log "no step lit an output"
  sudo chvt "$start_vt"
fi

# --- give up cleanly ----------------------------------------------------------

outputs_json > "$run_dir/outputs-after.json" 2>&1
sudo cat "/sys/kernel/debug/dri/$pci/state" > "$run_dir/drm-state-after.txt" 2>&1
say ""
say "Could not bring the display back. Evidence: $run_dir"
say "If the dock is at hand, plug it in now: that has cured this before."
say "Otherwise reboot. Open apps get a normal shutdown, which the power button would not give them."
say ""
read -rp "[r] reboot now   [q] stay in this TTY: " answer
if [[ $answer == r ]]; then
  log "rebooting"
  systemctl reboot
fi
