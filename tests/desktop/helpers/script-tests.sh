# shellcheck shell=bash
# The helper scripts of the bar and the kanshi hook, run in the build sandbox on
# fixtures and on the inputs a machine without the hardware gives them. This is
# the build command of a derivation (tests/desktop/sway.nix), which sets
# scriptList (lines of "name /nix/store/.../bin/name") and kanshiConfig.
# Every check records its failure and goes on; stdenv's errexit would stop at the
# first command that exits non-zero on purpose.
set +e
set -u
result=$out
scriptList=${scriptList:?the derivation sets scriptList}
kanshiConfig=${kanshiConfig:?the derivation sets kanshiConfig}
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
ok() { echo "ok: $*"; }

script() { awk -v n="$1" '$1 == n { print $2 }' "$scriptList"; }
work=$PWD/work
mkdir -p "$work"
export XDG_RUNTIME_DIR=$work/run
mkdir -p "$XDG_RUNTIME_DIR"
export HOME=$work/home

# The scripts find Waybar and swaylock by command line and signal or kill them.
# In the build sandbox nothing else runs, but a check run as the developer with
# the sandbox off would reach the developer's own bar and lock screen. So the
# scripts are told to match only the stand-ins this test starts, whose names
# are unique, and decoys named like the real programs prove that nothing else
# is touched.
export WAYBAR_MATCH='^ravnix-test-waybar( |$)'
export SWAYLOCK_MATCH='^ravnix-test-swaylock( |$)'
# Stand-ins and decoys wait for a signal and have no timer, so a slow run cannot
# let one expire and read as "was killed". They end when the test kills them,
# and the exit trap kills any that a failed run left behind.
# shellcheck disable=SC2046 # the job ids are meant to split
trap 'kill $(jobs -p) 2>/dev/null; [ -z "${lockers_parent:-}" ] || pkill -P "$lockers_parent" 2>/dev/null' EXIT
decoy() { # decoy NAME: a process whose command line starts with NAME, sets decoy_pid
  ( exec -a "$1" python3 -c 'import signal
while True:
    signal.pause()' ) &
  decoy_pid=$!
}
decoy waybar
decoy_waybar=$decoy_pid
decoy swaylock
decoy_swaylock=$decoy_pid
# No test may read the machine it runs on: every script that has a /sys seam
# is given an empty one unless the test builds a fixture.
sysfs_empty=$work/sysfs-empty
mkdir -p "$sysfs_empty"
export SYSFS=$sysfs_empty

# A power supply fixture: ps NAME key=value...
ps() {
  local dir=$1 name=$2
  shift 2
  mkdir -p "$dir/$name"
  local kv
  for kv in "$@"; do printf '%s\n' "${kv#*=}" >"$dir/$name/${kv%%=*}"; done
}

json_ok() { # json_ok LABEL OUTPUT
  if printf '%s' "$2" | jq -e 'type == "object" and (.text | type == "string")' >/dev/null 2>&1; then
    ok "$1 prints a JSON object with text"
  else
    bad "$1 did not print a JSON object with a text: $2"
  fi
}

# ── every bar script, on a machine without what it reads ─────────────────────
empty=$work/empty
mkdir -p "$empty"
for name in waybar-battery waybar-peripherals waybar-powerdraw waybar-gpu waybar-gputemp waybar-clock; do
  out=$(PSDIR=$empty RAPL=$empty/none "$(script $name)" 2>&1)
  rc=$?
  [ $rc = 0 ] || bad "$name exited $rc on an empty machine: $out"
  json_ok "$name (empty machine)" "$out"
done
out=$(PSDIR=$empty "$(script waybar-battery)")
[ "$out" = '{"text":""}' ] || bad "waybar-battery shows something without a battery: $out"
out=$(PSDIR=$empty "$(script waybar-peripherals)")
[ "$out" = '{"text":""}' ] || bad "waybar-peripherals shows something without a peripheral: $out"

# ── waybar-battery ───────────────────────────────────────────────────────────
b=$work/bat
battery() { PSDIR=$b "$(script waybar-battery)"; }
accent_span="color='#"
rm -rf "$b"
ps "$b" BAT0 type=Battery capacity=80 status=Discharging
out=$(battery)
if [ "$(jq -r .class <<<"$out")" != battery ] || ! jq -r .text <<<"$out" | grep -q '80%'; then
  bad "battery at 80%: $out"
fi
jq -r .text <<<"$out" | grep -qF "$accent_span" || bad "the battery icon is not tinted with the accent: $out"
ps "$b" BAT0 type=Battery capacity=28 status=Discharging
[ "$(jq -r .class <<<"$(battery)")" = warning ] || bad "28% is no warning"
ps "$b" BAT0 type=Battery capacity=15 status=Discharging
[ "$(jq -r .class <<<"$(battery)")" = critical ] || bad "15% is no critical"
ps "$b" BAT0 type=Battery capacity=250 status=Discharging
jq -r .text <<<"$(battery)" | grep -q ' 100%' || bad "a capacity of 250 is not clamped to 100%"
ps "$b" BAT0 type=Battery capacity=abc status=Discharging
out=$(battery)
json_ok "waybar-battery (capacity abc)" "$out"
[ "$(jq -r .class <<<"$out")" = critical ] || bad "an unreadable capacity should read as empty, not as full: $out"
ps "$b" BAT0 type=Battery capacity=50 status=Charging power_now=15000000
out=$(battery)
[ "$(jq -r .class <<<"$out")" = charging ] || bad "charging has no class charging"
jq -r .tooltip <<<"$out" | grep -qF 'Charging at 15.0 W' || bad "the charge power is not in the tooltip: $out"
ps "$b" BAT0 type=Battery capacity=97 status="Not charging" charge_types="Standard [Long_Life]"
jq -r .tooltip <<<"$(battery)" | grep -qF 'Charge mode: Long_Life' || bad "the charge ceiling is not in the tooltip"
rm -rf "$b"
ps "$b" hid-1-battery type=Battery scope=Device capacity=5 status=Discharging
[ "$(battery)" = '{"text":""}' ] || bad "a peripheral's battery was taken for the system battery"
ps "$b" BAT0 type=Battery capacity=60 status=Discharging
jq -r .text <<<"$(battery)" | grep -q '60%' || bad "the system battery is not found next to a peripheral"
ok "waybar-battery states"

# ── waybar-peripherals ───────────────────────────────────────────────────────
p=$work/periph
peripherals() { PSDIR=$p MAGIC_CMD=${MAGIC_CMD:-none} "$(script waybar-peripherals)"; }
rm -rf "$p"
ps "$p" hid-a-1 type=Battery scope=Device capacity=45 status=Discharging model_name="Mouse"
[ "$(peripherals)" = '{"text":""}' ] || bad "a peripheral at 45% shows"
ps "$p" hid-b-1 type=Battery scope=Device capacity=28 status=Discharging model_name="Trackpad"
out=$(peripherals)
[ "$(jq -r .class <<<"$out")" = warning ] && [ "$(jq -r .text <<<"$out")" = "󰂃 28%" ] || bad "one peripheral at 28%: $out"
ps "$p" hid-b-2 type=Battery scope=Device capacity=22 status=Discharging model_name="Trackpad"
out=$(peripherals)
[ "$(jq -r .text <<<"$out")" = "󰂃 22%" ] || bad "the same device twice is not reduced to the lower reading: $out"
ps "$p" hid-c-1 type=Battery scope=Device capacity=12 status=Discharging model_name="Keyboard"
out=$(peripherals)
[ "$(jq -r .text <<<"$out")" = "󰂃 12% (2)" ] && [ "$(jq -r .class <<<"$out")" = critical ] || bad "two low devices: $out"
jq -r .tooltip <<<"$out" | grep -q 'Trackpad: 22%' || bad "the tooltip lacks the trackpad: $out"
ps "$p" hid-c-1 type=Battery scope=Device capacity=12 status=Charging model_name="Keyboard"
[ "$(jq -r .text <<<"$(peripherals)")" = "󰂃 22%" ] || bad "a charging peripheral still warns"
ps "$p" hid-d-1 type=Battery scope=Device capacity=zz status=Discharging model_name="Broken"
json_ok "waybar-peripherals (capacity zz)" "$(peripherals)"
ps "$p" hid-e-1 type=Battery scope=Device capacity=7 status=Discharging model_name='Quote"Back\Slash'
out=$(peripherals)
json_ok "waybar-peripherals (quote and backslash in a name)" "$out"
magic=$work/magic
printf '#!/bin/sh\nprintf "9\\tDischarging\\tMagic Mouse\\n"\n' >"$magic"
chmod +x "$magic"
out=$(MAGIC_CMD=$magic peripherals)
jq -r .tooltip <<<"$out" | grep -q 'Magic Mouse: 9%' || bad "the hardware-read device is not merged in: $out"
ok "waybar-peripherals states"

# ── waybar-powerdraw ─────────────────────────────────────────────────────────
d=$work/draw
rm -rf "$d"
ps "$d" BAT0 type=Battery capacity=60 status=Discharging power_now=12345000
out=$(PSDIR=$d RAPL=$empty/none "$(script waybar-powerdraw)")
jq -r .text <<<"$out" | grep -q ' 12W$' || bad "the battery draw is not in the bar: $out"
jq -r .text <<<"$out" | grep -qF "$accent_span" || bad "the power icon is not tinted with the accent"
rm -rf "$d"
ps "$d" BAT0 type=Battery capacity=100 status=Full
out=$(PSDIR=$d RAPL=$empty/none "$(script waybar-powerdraw)")
json_ok "waybar-powerdraw (AC)" "$out"

# ── waybar-gpu and waybar-gputemp: the classes, on a fixture of /sys ─────────
gpu_class() { jq -r .class <<<"$("$(script waybar-gpu)")"; }
gpu_text() { jq -r .text <<<"$("$(script waybar-gpu)")"; }
gpu_is() { [ "$(gpu_class)" = "$1" ] && gpu_text | grep -q "$2"; } # CLASS TEXT-PATTERN
rm -rf "$work/sys-gpu"
export SYSFS=$work/sys-gpu
# a card of another driver comes first and must be skipped
mkdir -p "$SYSFS/class/drm/card0/device" "$SYSFS/class/drm/card1/device"
printf 'DRIVER=i915\n' >"$SYSFS/class/drm/card0/device/uevent"
printf '99\n' >"$SYSFS/class/drm/card0/device/gpu_busy_percent"
printf 'DRIVER=amdgpu\n' >"$SYSFS/class/drm/card1/device/uevent"
busy() { printf '%s\n' "$1" >"$SYSFS/class/drm/card1/device/gpu_busy_percent"; }
busy 12
gpu_is gpu ' 12%$' || bad "gpu at 12%: $(gpu_class) $(gpu_text)"
busy 79
[ "$(gpu_class)" = gpu ] || bad "gpu at 79% is $(gpu_class), not plain"
busy 80
[ "$(gpu_class)" = warning ] || bad "gpu at 80% is $(gpu_class), not warning"
busy 94
[ "$(gpu_class)" = warning ] || bad "gpu at 94% is $(gpu_class), not warning"
busy 95
[ "$(gpu_class)" = critical ] || bad "gpu at 95% is $(gpu_class), not critical"
busy 100
[ "$(gpu_class)" = critical ] || bad "gpu at 100% is $(gpu_class), not critical"
busy abc
gpu_is gpu ' 0%$' || bad "an unreadable gpu load is not shown as 0%: $(gpu_text)"
busy ""
[ "$(gpu_class)" = gpu ] || bad "an empty gpu load is not plain"
rm -f "$SYSFS/class/drm/card1/device/uevent"
busy 99
gpu_text | grep -q ' 0%$' || bad "a card without a driver line was taken for the amdgpu: $(gpu_text)"
ok "waybar-gpu classes"

temp_class() { jq -r .class <<<"$("$(script waybar-gputemp)")"; }
temp_text() { jq -r .text <<<"$("$(script waybar-gputemp)")"; }
temp_is() { [ "$(temp_class)" = "$1" ] && temp_text | grep -q "$2"; } # CLASS TEXT-PATTERN
rm -rf "$work/sys-temp"
export SYSFS=$work/sys-temp
mkdir -p "$SYSFS/class/hwmon/hwmon0" "$SYSFS/class/hwmon/hwmon1" "$SYSFS/class/hwmon/hwmon2"
printf 'nvme\n' >"$SYSFS/class/hwmon/hwmon0/name"
printf '99000\n' >"$SYSFS/class/hwmon/hwmon0/temp1_input"
printf 'amdgpu\n' >"$SYSFS/class/hwmon/hwmon1/name" # an amdgpu with no edge temperature: skipped
printf 'amdgpu\n' >"$SYSFS/class/hwmon/hwmon2/name"
tempc() { printf '%s\n' "$1" >"$SYSFS/class/hwmon/hwmon2/temp1_input"; }
tempc 45000
temp_is gpu ' 45°C$' || bad "gpu temperature 45: $(temp_class) $(temp_text)"
tempc 79999
temp_is gpu ' 79°C$' || bad "gpu temperature 79.999 is not 79 and plain: $(temp_text)"
tempc 80000
[ "$(temp_class)" = warning ] || bad "gpu temperature 80 is $(temp_class), not warning"
tempc 89999
[ "$(temp_class)" = warning ] || bad "gpu temperature 89.999 is $(temp_class), not warning"
tempc 90000
[ "$(temp_class)" = critical ] || bad "gpu temperature 90 is $(temp_class), not critical"
tempc 120000
[ "$(temp_class)" = critical ] || bad "gpu temperature 120 is $(temp_class), not critical"
tempc junk
temp_is gpu ' 0°C$' || bad "an unreadable gpu temperature is not shown as 0: $(temp_text)"
ok "waybar-gputemp classes"

# ── waybar-powerdraw on the GPU side: watts of the amdgpu, and the dGPU's state
rm -rf "$work/sys-draw" "$d"
export SYSFS=$work/sys-draw
ps "$d" AC type=Mains
mkdir -p "$SYSFS/class/hwmon/hwmon0" "$SYSFS/bus/pci/drivers/nvidia" "$work/pci-nvidia/power"
printf 'amdgpu\n' >"$SYSFS/class/hwmon/hwmon0/name"
printf '15000000\n' >"$SYSFS/class/hwmon/hwmon0/power1_average"
draw() { PSDIR=$d RAPL=$empty/none "$(script waybar-powerdraw)"; }
out=$(draw)
jq -r .text <<<"$out" | grep -q ' 15W$' || bad "the amdgpu's 15 W is not the draw on AC: $out"
jq -r .tooltip <<<"$out" | grep -qF 'GPU: 15 W' || bad "the tooltip does not name the GPU: $out"
ln -s "$work/pci-nvidia" "$SYSFS/bus/pci/drivers/nvidia/0000:01:00.0"
printf 'suspended\n' >"$work/pci-nvidia/power/runtime_status"
out=$(draw)
{ jq -r .tooltip <<<"$out" | grep -qF 'iGPU: 15 W' && jq -r .tooltip <<<"$out" | grep -qF 'dGPU: suspended'; } || bad "a suspended dGPU is not reported, or the amdgpu is not the iGPU: $out"
jq -r .text <<<"$out" | grep -q 'dGPU' && bad "a suspended dGPU is marked in the bar: $out"
printf 'active\n' >"$work/pci-nvidia/power/runtime_status"
out=$(draw)
jq -r .text <<<"$out" | grep -q ' 15W+dGPU$' || bad "an active dGPU is not marked +dGPU: $out"
rm -f "$SYSFS/class/hwmon/hwmon0/power1_average"
printf '9000000\n' >"$SYSFS/class/hwmon/hwmon0/power1_input"
jq -r .text <<<"$(draw)" | grep -q ' 9W+dGPU$' || bad "power1_input is not the fallback of power1_average: $(draw)"
rm -rf "$SYSFS/class/hwmon/hwmon0"
out=$(draw)
{ jq -r .text <<<"$out" | grep -q -- '--' && jq -r .tooltip <<<"$out" | grep -qF 'No readable power sensor'; } || bad "no sensor at all is not said so: $out"
export SYSFS=$sysfs_empty
ok "waybar-powerdraw GPU side"

# ── waybar-clock ─────────────────────────────────────────────────────────────
clock=$(script waybar-clock)
rm -rf "$XDG_RUNTIME_DIR"
mkdir -p "$XDG_RUNTIME_DIR"
out=$("$clock")
jq -r .text <<<"$out" | grep -Eq '^[A-Z][a-z]{2} [0-9]{2}:[0-9]{2}$' || bad "the time view is not 'Mon 14:32': $out"
"$clock" toggle
[ "$(cat "$XDG_RUNTIME_DIR/waybar-clock-mode")" = date ] || bad "toggle did not switch to the date"
jq -r .text <<<"$("$clock")" | grep -Eq '^W[0-9]{2} [0-9]{2}\. [A-Za-z]+ [0-9]{4}$' || bad "the date view is not 'W36 30. September 2026'"
"$clock" toggle
[ "$(cat "$XDG_RUNTIME_DIR/waybar-clock-mode")" = time ] || bad "a second toggle did not switch back"
stubs=$work/stubs
mkdir -p "$stubs"
printf '#!/bin/sh\nprintf "09:00-10:00 Lunch & Learn <b>R&D</b>\\n"\n' >"$stubs/khal"
chmod +x "$stubs/khal"
rm -f "$XDG_RUNTIME_DIR/waybar-clock-agenda"
out=$(PATH=$stubs:$PATH "$clock")
tip=$(jq -r .tooltip <<<"$out")
case "$tip" in
*'Lunch &amp; Learn &lt;b&gt;R&amp;D&lt;/b&gt;'*) ok "a khal agenda is escaped for Pango" ;;
*) bad "the agenda is not escaped for Pango: $tip" ;;
esac
rm -f "$XDG_RUNTIME_DIR/waybar-clock-agenda"
tip=$(jq -r .tooltip <<<"$("$clock")")
[ -n "$tip" ] || bad "without khal the tooltip is empty"

# ── Waybar is found by its command line, as NixOS's wrapper names the process
# .waybar-wrapped: a stand-in called waybar by argv[0] only, like the wrapper's.
fake_waybar() { # fake_waybar SIGNAL-LOG: starts it, sets fake_pid
  ( exec -a ravnix-test-waybar python3 -c 'import signal, sys
def note(*_):
    open(sys.argv[1], "a").write("x")
signal.signal(signal.SIGRTMIN + 8, note)
while True:
    signal.pause()' "$1" ) &
  fake_pid=$!
  sleep 1
}
sigfile=$work/signalled
: >"$sigfile"
fake_waybar "$sigfile"
"$clock" toggle
sleep 1
[ -s "$sigfile" ] || bad "waybar-clock toggle did not signal a Waybar whose process is not called waybar"
kill "$fake_pid" 2>/dev/null
wait "$fake_pid" 2>/dev/null
rm -rf "$XDG_RUNTIME_DIR"
mkdir -p "$XDG_RUNTIME_DIR"
printf 'none\n' >"$XDG_RUNTIME_DIR/waybar-mode"
fake_waybar "$sigfile"
launch=$(script waybar-launch)
if ! "$launch"; then bad "waybar-launch fails in mode none"; fi
if kill -0 "$fake_pid" 2>/dev/null; then
  bad "waybar-launch did not stop the running Waybar"
  kill "$fake_pid" 2>/dev/null
fi
wait "$fake_pid" 2>/dev/null
ok "Waybar is found and signalled by its command line"

# ── keep-awake's unlock handler ends a swaylock whose process is called
# .swaylock-wrapped, as on NixOS: the line is cut out of the script itself.
keep=$(script keep-awake)
handler=$(grep -m1 -o "unlock  *'[^']*'" "$keep" | sed "s/^unlock  *'//; s/'\$//")
[ -n "$handler" ] || bad "keep-awake has no unlock handler for swayidle"
( exec -a ravnix-test-swaylock python3 -c 'import signal, sys
signal.signal(signal.SIGUSR1, lambda *_: sys.exit(0))
while True:
    signal.pause()' ) &
fake_pid=$!
sleep 1
USER=$(id -un) sh -c "$handler" >/dev/null 2>&1
sleep 1
if kill -0 "$fake_pid" 2>/dev/null; then
  bad "the unlock handler of keep-awake did not end a swaylock called .swaylock-wrapped: $handler"
  kill "$fake_pid" 2>/dev/null
fi
wait "$fake_pid" 2>/dev/null
ok "keep-awake unlock handler"

# The handler as it runs on the laptop: its own pattern, with no SWAYLOCK_MATCH.
# The pkill it calls is a stand-in that adds -P, so that only the children of one
# subshell of this test can be reached, never a lock screen of the developer and
# not the decoys above. A swaylock is signalled; things that only contain the
# word are not.
children_only=$work/children-only
lockers=$work/lockers
mkdir -p "$children_only" "$lockers"
(
  for name in swaylock swaylockd xswaylock; do
    ( exec -a "$name" python3 -c 'import os, signal, sys
open(sys.argv[1], "w").write(str(os.getpid()))
while True:
    signal.pause()' "$lockers/$name.pid" ) &
  done
  wait
) &
lockers_parent=$!
printf '#!/bin/sh\nexec %s -P %s "$@"\n' "$(command -v pkill)" "$lockers_parent" >"$children_only/pkill"
chmod +x "$children_only/pkill"
sleep 1
env -u SWAYLOCK_MATCH USER="$(id -un)" PATH="$children_only:$PATH" sh -c "$handler" >/dev/null 2>&1
sleep 1
if kill -0 "$(cat "$lockers/swaylock.pid")" 2>/dev/null; then
  bad "the default pattern of keep-awake's unlock handler does not match a swaylock: $handler"
fi
kill -0 "$(cat "$lockers/swaylockd.pid")" 2>/dev/null || bad "the default pattern of keep-awake's unlock handler matches swaylockd"
kill -0 "$(cat "$lockers/xswaylock.pid")" 2>/dev/null || bad "the default pattern of keep-awake's unlock handler matches xswaylock"
pkill -P "$lockers_parent" 2>/dev/null
kill "$lockers_parent" 2>/dev/null
wait "$lockers_parent" 2>/dev/null
ok "keep-awake unlock handler, default pattern"

# ── waybar-mode cycles full, focus, none ─────────────────────────────────────
mode=$(script waybar-mode)
printf '#!/bin/sh\necho launched >>"%s/launches"\n' "$XDG_RUNTIME_DIR" >"$stubs/waybar-launch"
chmod +x "$stubs/waybar-launch"
rm -rf "$XDG_RUNTIME_DIR"
mkdir -p "$XDG_RUNTIME_DIR"
seq=""
for _ in 1 2 3 4; do
  PATH=$stubs:$PATH "$mode"
  seq="$seq $(cat "$XDG_RUNTIME_DIR/waybar-mode")"
done
[ "$seq" = " focus none full focus" ] || bad "the bar modes cycle as$seq, not focus none full focus"
[ "$(wc -l <"$XDG_RUNTIME_DIR/launches")" = 4 ] || bad "waybar-mode did not relaunch the bar every time"
printf 'garbage\n' >"$XDG_RUNTIME_DIR/waybar-mode"
PATH=$stubs:$PATH "$mode"
[ "$(cat "$XDG_RUNTIME_DIR/waybar-mode")" = full ] || bad "an unknown mode does not fall back to full"
ok "waybar-mode cycle"

# ── the kanshi hook ──────────────────────────────────────────────────────────
hook=$(grep -o '/nix/store/[^ ]*-kanshi-exec' "$kanshiConfig" | head -n1)
[ -x "$hook" ] || bad "the kanshi hook $hook is not an executable"
fakes=$work/fakes
mkdir -p "$fakes"
log=$work/hook.log
for c in energy backdrop; do
  printf '#!/bin/sh\necho "%s $*" >>"%s"\n' "$c" "$log" >"$fakes/$c"
  chmod +x "$fakes/$c"
done
: >"$log"
PATH=$fakes:$PATH "$hook" || bad "the hook fails when panel-crtc is not installed"
[ "$(cat "$log")" = "$(printf 'energy refresh\nbackdrop wallpaper')" ] || bad "the hook, without panel-crtc, ran: $(cat "$log")"
printf '#!/bin/sh\necho "panel-crtc $*" >>"%s"\n' "$log" >"$fakes/panel-crtc"
chmod +x "$fakes/panel-crtc"
: >"$log"
PATH=$fakes:$PATH "$hook"
[ "$(cat "$log")" = "$(printf 'panel-crtc --fix\nenergy refresh\nbackdrop wallpaper')" ] || bad "the hook does not run the three in order: $(cat "$log")"
: >"$log"
if ! PATH=/nonexistent "$hook" 2>/dev/null || [ -s "$log" ]; then
  bad "the hook fails or runs something with nothing installed"
fi
ok "kanshi hook"

# ── sway-volume ──────────────────────────────────────────────────────────────
vol=$(script sway-volume)
pa=$work/pa
mkdir -p "$pa"
cat >"$stubs/pactl" <<STUB
#!/bin/sh
case "\$1" in
  get-sink-volume) [ -f "$pa/broken" ] && exit 1
                   [ -f "$pa/garbage" ] && { echo "Volume: n/a"; exit 0; }
                   echo "Volume: front-left: 32768 /  \$(cat "$pa/volume")% / -18.06 dB,   front-right: 32768 /  \$(cat "$pa/volume")% / -18.06 dB" ;;
  set-sink-volume) echo "\${3%\%}" >"$pa/volume" ;;
  get-sink-mute) echo "Mute: \$(cat "$pa/mute")" ;;
esac
STUB
cat >"$stubs/notify-send" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$pa/notifications"
STUB
chmod +x "$stubs/pactl" "$stubs/notify-send"
volume() { # volume START ARGS...: the volume after the run
  printf '%s\n' "$1" >"$pa/volume"
  echo no >"$pa/mute"
  : >"$pa/notifications"
  shift
  PACTL=$stubs/pactl NOTIFY_SEND=$stubs/notify-send "$vol" "$@" 2>/dev/null
  cat "$pa/volume"
}
[ "$(volume 50 --increase 5)" = 55 ] || bad "sway-volume: 50 + 5 is not 55"
[ "$(volume 98 --limit 100 --increase 5)" = 100 ] || bad "sway-volume goes above the limit"
[ "$(volume 3 --decrease 5)" = 0 ] || bad "sway-volume goes below 0"
[ "$(volume 50 --limit 80 --set-volume 150)" = 80 ] || bad "sway-volume --set-volume ignores the limit"
[ "$(volume 50)" = 50 ] || bad "sway-volume changes the volume when asked only to show it"
volume 50 --increase 5 >/dev/null
grep -q 'int:value:55' "$pa/notifications" || bad "the notification does not carry the new volume: $(cat "$pa/notifications")"
grep -q 'synchronous' "$pa/notifications" || bad "the notification does not replace the one before"
echo yes >"$pa/mute"
PACTL=$stubs/pactl NOTIFY_SEND=$stubs/notify-send "$vol" >/dev/null 2>&1
grep -q 'muted' "$pa/notifications" || bad "a muted sink is not shown as muted"
for args in "--increase abc" "--increase" "--limit 5;ls" "--set-volume x[\$(touch $pa/pwned)]" "--frobnicate" "--sink"; do
  # shellcheck disable=SC2086
  PACTL=$stubs/pactl NOTIFY_SEND=$stubs/notify-send "$vol" $args >/dev/null 2>&1
  [ $? = 2 ] || bad "sway-volume $args is not refused with status 2"
done
[ ! -e "$pa/pwned" ] || bad "sway-volume ran a command from an argument"
: >"$pa/broken"
# pactl cannot be read: nothing is set (a volume key during a hiccup must not
# turn the sound off or set it to the step), nothing is shown, and the status
# says so.
for args in "--increase 5" "--decrease 5" "--set-volume 30" ""; do
  printf '40\n' >"$pa/volume"
  echo no >"$pa/mute"
  : >"$pa/notifications"
  : >"$pa/broken"
  # shellcheck disable=SC2086
  PACTL=$stubs/pactl NOTIFY_SEND=$stubs/notify-send "$vol" $args >/dev/null 2>&1
  rc=$?
  rm -f "$pa/broken"
  [ $rc = 1 ] || bad "sway-volume $args exits $rc when pactl cannot be read, not 1"
  [ ! -s "$pa/notifications" ] || bad "sway-volume $args shows a volume it could not read: $(cat "$pa/notifications")"
  case $args in
    "--increase 5"|"--decrease 5"|"") [ "$(cat "$pa/volume")" = 40 ] || bad "sway-volume $args changed an unreadable volume to $(cat "$pa/volume")" ;;
  esac
done
# pactl answers, with no number in it.
printf '40\n' >"$pa/volume"
: >"$pa/notifications"
: >"$pa/garbage"
PACTL=$stubs/pactl NOTIFY_SEND=$stubs/notify-send "$vol" --increase 5 >/dev/null 2>&1
[ $? = 1 ] || bad "sway-volume takes an answer without a number for a volume"
[ "$(cat "$pa/volume")" = 40 ] || bad "sway-volume changed the volume after an answer without a number"
rm -f "$pa/garbage"
ok "sway-volume"

# ── sway-volume: the microphone key ──────────────────────────────────────────
# The F4 key toggles the default source and shows the new state, as the volume
# keys do.
cat >"$stubs/pactl" <<STUB
#!/bin/sh
case "\$1" in
  get-sink-volume) echo "Volume: front-left: 32768 /  \$(cat "$pa/volume")% / -18.06 dB" ;;
  set-sink-volume) echo "\${3%\%}" >"$pa/volume" ;;
  get-sink-mute) echo "Mute: \$(cat "$pa/mute")" ;;
  set-source-mute) [ -f "$pa/mic-broken" ] && exit 1
                   [ "\$3" = toggle ] || exit 2
                   if [ "\$(cat "$pa/mic")" = yes ]; then echo no >"$pa/mic"; else echo yes >"$pa/mic"; fi ;;
  get-source-mute) [ -f "$pa/mic-broken" ] && exit 1
                   echo "Mute: \$(cat "$pa/mic")" ;;
esac
STUB
chmod +x "$stubs/pactl"
mic() { # mic START: the state after one press, and what was shown
  printf '%s\n' "$1" >"$pa/mic"
  : >"$pa/notifications"
  PACTL=$stubs/pactl NOTIFY_SEND=$stubs/notify-send "$vol" --toggle-mic >/dev/null 2>&1
  echo $? >"$pa/mic-rc"
  cat "$pa/mic"
}
[ "$(mic no)" = yes ] || bad "sway-volume --toggle-mic does not mute a live microphone"
grep -qF 'Microphone: muted' "$pa/notifications" || bad "muting the microphone shows: $(cat "$pa/notifications")"
grep -q 'synchronous:mic' "$pa/notifications" || bad "the microphone notification does not replace the one before"
[ "$(mic yes)" = no ] || bad "sway-volume --toggle-mic does not unmute a muted microphone"
grep -qF 'Microphone: on' "$pa/notifications" || bad "unmuting the microphone shows: $(cat "$pa/notifications")"
: >"$pa/mic-broken"
printf 'no\n' >"$pa/mic"
: >"$pa/notifications"
PACTL=$stubs/pactl NOTIFY_SEND=$stubs/notify-send "$vol" --toggle-mic >/dev/null 2>&1
[ $? = 1 ] || bad "sway-volume --toggle-mic does not fail when pactl does"
[ ! -s "$pa/notifications" ] || bad "sway-volume --toggle-mic shows a state it could not read: $(cat "$pa/notifications")"
rm -f "$pa/mic-broken"
ok "sway-volume --toggle-mic"

# ── sway-brightness ──────────────────────────────────────────────────────────
# nixpkgs' brightnessctl is 0.5.1: no --percentage. The script reads get and max
# and does its own arithmetic, so the stand-in answers only what 0.5.1 answers.
bright=$(script sway-brightness)
bl=$work/bl
mkdir -p "$bl"
cat >"$stubs/brightnessctl" <<STUB
#!/bin/sh
[ -f "$bl/broken" ] && exit 1
printf '%s\n' "\$*" >>"$bl/calls"
case "\$*" in
  get) cat "$bl/raw" ;;
  max) cat "$bl/max" ;;
  "-q set "[0-9]*) echo "\$3" >"$bl/raw" ;;
  *) echo "brightnessctl: unsupported in 0.5.1: \$*" >&2; exit 2 ;;
esac
STUB
chmod +x "$stubs/brightnessctl"
pct_of() { echo $(( ($1 * 200 + $2) / (2 * $2) )); } # round(raw * 100 / max)
bpress() { # bpress MAX RAW up|down: runs the key, leaves the raw value in $bl/raw
  printf '%s\n' "$1" >"$bl/max"
  printf '%s\n' "$2" >"$bl/raw"
  : >"$bl/calls"
  : >"$bl/notifications"
  BRIGHTNESSCTL=$stubs/brightnessctl NOTIFY_SEND=$bl/notify "$bright" "$3" >/dev/null 2>&1
}
cat >"$bl/notify" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$bl/notifications"
STUB
chmod +x "$bl/notify"
# walk MAX START DIRECTION: the percentages, one per press, until it stops moving.
walk() {
  local max=$1 raw=$2 dir=$3 seq="" prev
  printf '%s\n' "$max" >"$bl/max"
  printf '%s\n' "$raw" >"$bl/raw"
  for _ in $(seq 1 60); do
    prev=$(cat "$bl/raw")
    BRIGHTNESSCTL=$stubs/brightnessctl NOTIFY_SEND=$bl/notify "$bright" "$dir" >/dev/null 2>&1
    [ "$(cat "$bl/raw")" = "$prev" ] && break
    seq="$seq $(pct_of "$(cat "$bl/raw")" "$max")"
  done
  echo "${seq# }"
}
up_expect="1 2 3 4 5 10 15 20 25 30 35 40 45 50 55 60 65 70 75 80 85 90 95 100"
down_expect="95 90 85 80 75 70 65 60 55 50 45 40 35 30 25 20 15 10 5 4 3 2 1 0"
for max in 100 255 400 19200; do
  [ "$(walk "$max" 0 up)" = "$up_expect" ] || bad "sway-brightness up from 0 (max $max): $(walk "$max" 0 up)"
  [ "$(walk "$max" "$max" down)" = "$down_expect" ] || bad "sway-brightness down from 100% (max $max): $(walk "$max" "$max" down)"
done
# Between the steps: a value off the grid snaps to it and never skips below 5.
bpress 255 18 down   # 7 %
[ "$(pct_of "$(cat "$bl/raw")" 255)" = 5 ] || bad "sway-brightness down from 7% reads $(pct_of "$(cat "$bl/raw")" 255)%, not 5%"
bpress 255 18 up
[ "$(pct_of "$(cat "$bl/raw")" 255)" = 10 ] || bad "sway-brightness up from 7% reads $(pct_of "$(cat "$bl/raw")" 255)%, not 10%"
bpress 255 31 down   # 12 %
[ "$(pct_of "$(cat "$bl/raw")" 255)" = 10 ] || bad "sway-brightness down from 12% reads $(pct_of "$(cat "$bl/raw")" 255)%, not 10%"
bpress 255 255 up
[ "$(cat "$bl/raw")" = 255 ] || bad "sway-brightness goes above 100%: $(cat "$bl/raw")"
bpress 255 0 down
[ "$(cat "$bl/raw")" = 0 ] || bad "sway-brightness goes below 0: $(cat "$bl/raw")"
# The value shown is the value that was set (read back, not assumed).
bpress 255 0 up
grep -qF 'Brightness: 1%' "$bl/notifications" || bad "up from 0 shows: $(cat "$bl/notifications")"
grep -q 'int:value:1 ' "$bl/notifications" || bad "up from 0 does not carry the value: $(cat "$bl/notifications")"
grep -q 'synchronous:brightness' "$bl/notifications" || bad "the brightness notification does not replace the one before"
bpress 255 255 down
grep -qF 'Brightness: 95%' "$bl/notifications" || bad "down from 100 shows: $(cat "$bl/notifications")"
grep -q 'int:value:95 ' "$bl/notifications" || bad "down from 100 does not carry the value: $(cat "$bl/notifications")"
# Coarse hardware: every press still moves, never past the ends, and the key
# works on a backlight with a handful of levels.
for max in 7 20 50; do
  seq=$(walk "$max" 0 up)
  [ -n "$seq" ] && [ "$(cat "$bl/raw")" = "$max" ] || bad "sway-brightness up (max $max) does not reach the top: $seq, raw $(cat "$bl/raw")"
  seq=$(walk "$max" "$max" down)
  [ -n "$seq" ] && [ "$(cat "$bl/raw")" = 0 ] || bad "sway-brightness down (max $max) does not reach 0: $seq, raw $(cat "$bl/raw")"
done
bpress 1 0 up
[ "$(cat "$bl/raw")" = 1 ] || bad "sway-brightness cannot light a backlight with one level"
# It uses nothing but get, max and an absolute set.
bpress 255 100 up
if grep -Eq -- '--percentage|-P|-m|%' "$bl/calls"; then bad "sway-brightness calls brightnessctl with an option 0.5.1 lacks: $(cat "$bl/calls")"; fi
# A dead or odd backlight tool: nothing set, nothing shown, status 1.
for broken in dead zero garbage; do
  rm -f "$bl/broken"
  printf '255\n' >"$bl/max"; printf '100\n' >"$bl/raw"; : >"$bl/calls"; : >"$bl/notifications"
  case $broken in
    dead) : >"$bl/broken" ;;
    zero) printf '0\n' >"$bl/max" ;;
    garbage) printf 'n/a\n' >"$bl/raw" ;;
  esac
  BRIGHTNESSCTL=$stubs/brightnessctl NOTIFY_SEND=$bl/notify "$bright" up >/dev/null 2>&1
  [ $? = 1 ] || bad "sway-brightness ($broken) does not exit 1"
  [ ! -s "$bl/notifications" ] || bad "sway-brightness ($broken) shows something: $(cat "$bl/notifications")"
  ! grep -q 'set' "$bl/calls" 2>/dev/null || bad "sway-brightness ($broken) sets a value"
done
rm -f "$bl/broken"
BRIGHTNESSCTL=/nonexistent NOTIFY_SEND=$bl/notify "$bright" up >/dev/null 2>&1
[ $? = 1 ] || bad "sway-brightness without brightnessctl does not exit 1"
for args in "" "sideways" "up down" "5%+"; do
  # shellcheck disable=SC2086
  BRIGHTNESSCTL=$stubs/brightnessctl NOTIFY_SEND=$bl/notify "$bright" $args >/dev/null 2>&1
  [ $? = 2 ] || bad "sway-brightness '$args' is not refused with status 2"
done
# Without a notification daemon the brightness still changes.
printf '255\n' >"$bl/max"; printf '100\n' >"$bl/raw"
BRIGHTNESSCTL=$stubs/brightnessctl NOTIFY_SEND=/nonexistent "$bright" up >/dev/null 2>&1
[ "$(pct_of "$(cat "$bl/raw")" 255)" = 40 ] || bad "sway-brightness does not change the brightness when the notification fails"
ok "sway-brightness"

# ── sway-mirror ──────────────────────────────────────────────────────────────
mirror=$(script sway-mirror)
mi=$work/mi
mkdir -p "$mi"
cat >"$mi/swaymsg" <<STUB
#!/bin/sh
case "\$*" in
  "-t get_outputs") cat "$mi/outputs.json" ;;
  *) printf '%s\n' "\$*" >>"$mi/swaymsg.log" ;;
esac
STUB
cat >"$mi/pgrep" <<STUB
#!/bin/sh
[ -f "$mi/running" ]
STUB
cat >"$mi/pkill" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$mi/pkill.log"
rm -f "$mi/running"
STUB
cat >"$mi/notify" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$mi/notifications"
STUB
chmod +x "$mi"/swaymsg "$mi"/pgrep "$mi"/pkill "$mi"/notify
mirror_run() { # mirror_run OUTPUTS-JSON [running]: runs the key on that machine
  printf '%s\n' "$1" >"$mi/outputs.json"
  rm -f "$mi/running"
  [ "${2:-}" = running ] && : >"$mi/running"
  : >"$mi/swaymsg.log"; : >"$mi/pkill.log"; : >"$mi/notifications"
  SWAYMSG=$mi/swaymsg PGREP=$mi/pgrep PKILL=$mi/pkill NOTIFY_SEND=$mi/notify "$mirror" >/dev/null 2>&1
  mrc=$?
}
one='[{"name":"eDP-1","active":true},{"name":"DP-3","active":true}]'
mirror_run "$one"
grep -qxF -- '-q exec wl-mirror --fullscreen-output DP-3 eDP-1' "$mi/swaymsg.log" || bad "sway-mirror does not start wl-mirror from the panel on the external output: $(cat "$mi/swaymsg.log")"
grep -qF 'DP-3' "$mi/notifications" || bad "sway-mirror does not say where the screen is shown: $(cat "$mi/notifications")"
mirror_run "$one" running
[ -s "$mi/pkill.log" ] && [ ! -s "$mi/swaymsg.log" ] || bad "sway-mirror does not end a running mirror, or starts another"
grep -qF 'off' "$mi/notifications" || bad "sway-mirror does not say it is off: $(cat "$mi/notifications")"
mirror_run '[{"name":"eDP-1","active":true}]'
[ "$mrc" = 0 ] && [ ! -s "$mi/swaymsg.log" ] || bad "sway-mirror acts without an external display"
grep -qiF 'no external display' "$mi/notifications" || bad "sway-mirror says nothing without an external display: $(cat "$mi/notifications")"
mirror_run '[{"name":"eDP-1","active":true},{"name":"DP-3","active":false}]'
[ ! -s "$mi/swaymsg.log" ] || bad "sway-mirror mirrors onto an inactive output"
mirror_run '[{"name":"DP-3","active":true}]'
[ ! -s "$mi/swaymsg.log" ] || bad "sway-mirror mirrors with no laptop panel"
mirror_run '[{"name":"eDP-1","active":true},{"name":"DP-3; exec touch '"$mi"'/pwned","active":true}]'
[ ! -s "$mi/swaymsg.log" ] && [ ! -e "$mi/pwned" ] || bad "sway-mirror puts an output name with a command in it into a Sway command: $(cat "$mi/swaymsg.log")"
mirror_run 'not json'
[ "$mrc" = 1 ] && [ ! -s "$mi/swaymsg.log" ] || bad "sway-mirror does not fail on an answer that is no JSON"
# A running mirror ends even when the display is gone.
mirror_run '[{"name":"eDP-1","active":true}]' running
[ -s "$mi/pkill.log" ] || bad "sway-mirror leaves a mirror running after the display was unplugged"
ok "sway-mirror"

# ── sway-airplane ────────────────────────────────────────────────────────────
air=$(script sway-airplane)
ar=$work/ar
mkdir -p "$ar"
# A stand-in rfkill: ar/soft holds the soft state of the two radios (blocked or
# unblocked), ar/hard the hardware state of the Wi-Fi one.
cat >"$ar/rfkill" <<STUB
#!/bin/sh
[ -f "$ar/dead" ] && { echo "rfkill: cannot open /dev/rfkill" >&2; exit 1; }
printf '%s\n' "\$*" >>"$ar/calls"
case "\$*" in
  "-J") cat <<JSON
{"rfkilldevices": [
  {"id": 0, "type": "wlan", "device": "phy0", "soft": "\$(cat "$ar/soft")", "hard": "\$(cat "$ar/hard")"},
  {"id": 1, "type": "bluetooth", "device": "hci0", "soft": "\$(cat "$ar/soft")", "hard": "unblocked"}
]}
JSON
  ;;
  "block all") [ -f "$ar/refuse" ] || echo blocked >"$ar/soft" ;;
  "unblock all") [ -f "$ar/refuse" ] || echo unblocked >"$ar/soft" ;;
  *) exit 2 ;;
esac
STUB
cat >"$ar/notify" <<STUB
#!/bin/sh
printf '%s\n' "\$*" >>"$ar/notifications"
STUB
chmod +x "$ar/rfkill" "$ar/notify"
air_run() { # air_run SOFT [HARD]: one press
  rm -f "$ar/dead" "$ar/refuse"
  printf '%s\n' "$1" >"$ar/soft"
  printf '%s\n' "${2:-unblocked}" >"$ar/hard"
  : >"$ar/calls"; : >"$ar/notifications"
  RFKILL=$ar/rfkill NOTIFY_SEND=$ar/notify "$air" >/dev/null 2>&1
}
air_run unblocked
[ "$(cat "$ar/soft")" = blocked ] || bad "sway-airplane does not switch the radios off"
grep -qF 'Airplane mode: on' "$ar/notifications" || bad "switching airplane mode on shows: $(cat "$ar/notifications")"
grep -q 'synchronous:airplane' "$ar/notifications" || bad "the airplane notification does not replace the one before"
air_run blocked
[ "$(cat "$ar/soft")" = unblocked ] || bad "sway-airplane does not switch the radios back on"
grep -qF 'Airplane mode: off' "$ar/notifications" || bad "switching airplane mode off shows: $(cat "$ar/notifications")"
# A radio the hardware switch holds stays blocked: the notification says what is.
air_run blocked blocked
grep -qF 'Airplane mode: off' "$ar/notifications" || bad "with the Wi-Fi hard-blocked the state read after the change is wrong: $(cat "$ar/notifications")"
# The change did not take: say so, do not claim it.
air_run unblocked
printf 'unblocked\n' >"$ar/soft"; : >"$ar/refuse"; : >"$ar/notifications"
RFKILL=$ar/rfkill NOTIFY_SEND=$ar/notify "$air" >/dev/null 2>&1
airc=$?
[ "$airc" = 1 ] || bad "sway-airplane exits $airc when rfkill did not change"
! grep -qF 'Airplane mode: on' "$ar/notifications" || bad "sway-airplane claims airplane mode though rfkill did not change: $(cat "$ar/notifications")"
grep -qF 'Airplane mode' "$ar/notifications" || bad "sway-airplane is silent when rfkill refuses the change"
# No access to /dev/rfkill: a notification, status 1.
: >"$ar/dead"; : >"$ar/notifications"
RFKILL=$ar/rfkill NOTIFY_SEND=$ar/notify "$air" >/dev/null 2>&1
[ $? = 1 ] && [ -s "$ar/notifications" ] || bad "sway-airplane is silent or exits 0 when rfkill cannot be used"
rm -f "$ar/dead"
# A machine without radios.
cat >"$ar/rfkill-none" <<STUB
#!/bin/sh
case "\$*" in -J) echo '{"rfkilldevices": []}' ;; *) printf '%s\n' "\$*" >>"$ar/calls-none" ;; esac
STUB
chmod +x "$ar/rfkill-none"
: >"$ar/notifications"; rm -f "$ar/calls-none"
RFKILL=$ar/rfkill-none NOTIFY_SEND=$ar/notify "$air" >/dev/null 2>&1
airc=$?
[ "$airc" = 1 ] && [ ! -e "$ar/calls-none" ] || bad "sway-airplane exits $airc or acts on a machine without radios"
grep -qiF 'no radio' "$ar/notifications" || bad "sway-airplane does not say a machine has no radios: $(cat "$ar/notifications")"
RFKILL=$ar/rfkill NOTIFY_SEND=$ar/notify "$air" frobnicate >/dev/null 2>&1
[ $? = 2 ] || bad "sway-airplane takes an argument"
ok "sway-airplane"

# ── sway-wait-sni ────────────────────────────────────────────────────────────
sni=$(script sway-wait-sni)
printf '#!/bin/sh\nexit 0\n' >"$stubs/busctl"
chmod +x "$stubs/busctl"
BUSCTL=$stubs/busctl "$sni" 2 || bad "sway-wait-sni does not return when the watcher is there"
printf '#!/bin/sh\nexit 1\n' >"$stubs/busctl"
start=$(date +%s)
if BUSCTL=$stubs/busctl "$sni" 1 2>/dev/null; then bad "sway-wait-sni returns 0 without a watcher"; fi
[ $(( $(date +%s) - start )) -le 4 ] || bad "sway-wait-sni waited far longer than its timeout"
for arg in abc -1 "1;2"; do
  BUSCTL=$stubs/busctl "$sni" "$arg" >/dev/null 2>&1
  [ $? = 2 ] || bad "sway-wait-sni $arg is not refused with status 2"
done
rm -f "$stubs/busctl"
ok "sway-wait-sni"

# The decoys, called waybar and swaylock like the real programs, were in reach of
# every kill and signal above and must have survived them all.
kill -0 "$decoy_waybar" 2>/dev/null || bad "a process called waybar was killed or signalled: the scripts do not stay with WAYBAR_MATCH"
kill -0 "$decoy_swaylock" 2>/dev/null || bad "a process called swaylock was killed or signalled: the scripts do not stay with SWAYLOCK_MATCH"
kill "$decoy_waybar" "$decoy_swaylock" 2>/dev/null
wait "$decoy_waybar" "$decoy_swaylock" 2>/dev/null
ok "the scripts touched only the processes the test started"

[ $fail = 0 ] || exit 1
echo "script tests passed" >"$result"
