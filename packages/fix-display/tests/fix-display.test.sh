#!/usr/bin/env bash
# Tests for fix-display and panel-crtc (packages/fix-display), run by the check
# bin-fix-display. The scripts have no tests in Fedora; these are new. A rescue
# needs a laptop with a dark panel, a TTY and sudo, so this tests what can be
# tested without one: fix-display with stand-ins for pgrep, loginctl and swaymsg
# (in front of the script's own tools, see tests/bin/helpers/stub-first.nix) for
# --status, the argument it refuses and the preconditions that end it before it
# touches anything; and panel-crtc as a module, with a fake DRM state, for its
# report, its fix (which outputs it powers off and on, and in which order) and
# its refusals. The ioctl numbers and structure sizes are pinned to the ones
# libdrm gives.
#
# FIX_DISPLAY_UNDER_TEST=<file>  tests another copy of fix-display;
# PANEL_CRTC_UNDER_TEST=<file>   another copy of panel-crtc. By default they are
# the ones on the PATH.

# The checks are eval'd, so their $ expand at check time.
# shellcheck disable=SC2016

set -uo pipefail

SUT=$(readlink -f "${FIX_DISPLAY_UNDER_TEST:-$(type -P fix-display)}")
PANEL=$(readlink -f "${PANEL_CRTC_UNDER_TEST:-$(type -P panel-crtc)}")
BASH_BIN=$(type -P bash)
SB=$(mktemp -d "${TMPDIR:-/tmp}/fix-display-test.XXXXXX")
trap 'rm -r -- "$SB"' EXIT

pass=0 fail=0
ok()  { printf '  \e[32m✓\e[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \e[31m✗\e[0m %s\n%s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$SB/bin" "$SB/home" "$SB/run"
stub() { # stub NAME: the script on stdin, made executable, naming this bash
    cat >"$SB/bin/$1"
    sed -i "1s|.*|#!$BASH_BIN|" "$SB/bin/$1"
    chmod +x "$SB/bin/$1"
}
# pgrep: a sway of this user when SWAY_PID is set, none otherwise. The real one
# would find the sway of whoever runs this test.
stub pgrep <<'STUB'
#!/usr/bin/env bash
[[ -n ${SWAY_PID:-} ]] || exit 1
[[ $* == *sway* ]] && { echo "$SWAY_PID"; exit 0; }
exit 1
STUB
# loginctl: one wayland session (number 7) of class user, on the VT that is in
# front, so that "Sway's VT is in front" holds wherever this runs.
stub loginctl <<'STUB'
#!/usr/bin/env bash
[[ -z ${NO_SESSION:-} ]] || exit 0
case "$*" in
  "show-user "*) echo 7 ;;
  "show-session 7 -p Type --value") echo wayland ;;
  "show-session 7 -p Class --value") echo user ;;
  "show-session 7 -p VTNr --value") sed 's/^tty//' /sys/class/tty/tty0/active 2>/dev/null ;;
esac
STUB
# swaymsg: logs the socket it is given, answers get_outputs from OUTPUTS.
stub swaymsg <<'STUB'
#!/usr/bin/env bash
printf 'swaymsg %s SWAYSOCK=%s\n' "$*" "${SWAYSOCK:-}" >>"$LOG"
[[ -z ${SWAY_HANGS:-} ]] || exit 124
[[ $* == *get_outputs* ]] && printf '%s\n' "${OUTPUTS:-[]}"
exit 0
STUB
# sudo must never be reached by these cases.
stub sudo <<'STUB'
#!/usr/bin/env bash
printf 'sudo %s\n' "$*" >>"$LOG"
exit 1
STUB

# run [ENV=VAL ...] -- ARGS: sets $out (stdout), $err, $rc, and $LOG's lines.
run() {
    local envs=()
    while [[ $1 != -- ]]; do envs+=("$1"); shift; done
    shift
    : >"$SB/log"
    out=$(env -i HOME="$SB/home" USER=nobody PATH="$PATH" STUB_PATH="$SB/bin" LOG="$SB/log" "${envs[@]}" "$BASH_BIN" "$SUT" "$@" 2>"$SB/err" </dev/null)
    rc=$?
    err=$(<"$SB/err")
    log=$(<"$SB/log")
}
check() { if eval "$2"; then ok "$1"; else bad "$1" "    rc: $rc
    out: ${out:0:700}
    err: ${err:0:500}
    log: ${log:0:500}"; fi; }

echo "fix-display"

run -- --bogus
check "an unknown argument exits 1 and points at --status" \
    '[[ $rc == 1 && $err == "fix-display: unknown argument: --bogus (try --status)" ]]'
run -- --status extra
check "--status ignores what follows it" '[[ $rc == 0 && $out == "sway pid:"* ]]'

run -- 
check "with no Sway of the user's it stops before anything else and touches no sudo" \
    '[[ $rc == 1 && $err == "fix-display: no Sway of yours is running. Nothing to rescue: log in again, or reboot." && -z $log ]]'

run NO_SESSION=1 -- --status
check "--status with no Sway says so and lists no outputs" \
    '[[ $rc == 0 && $out == *"sway pid:      none"* && $out == *"sway session:  none"* && $out != *"sway outputs:"* ]]'
check "--status always reports the foreground VT, the lid, the panel and panel-crtc" \
    '[[ $out == *"foreground VT:"* && $out == *"lid:"* && $out == *"panel:"* && $out == *"panel-crtc:"* && $out == *"wlroots kept:"* ]]'

OUT='[{"name":"eDP-1","active":true,"power":true,"make":"Maker","model":"Panel"},{"name":"DP-3","active":false,"dpms":false,"make":"Other","model":"Big"}]'
run SWAY_PID=4242 OUTPUTS="$OUT" -- --status
check "--status with a Sway names its pid and its session, and talks to its socket" \
    '[[ $rc == 0 && $out == *"sway pid:      4242"* && $out == *"sway session:  7 on VT"* && $log == *"SWAYSOCK=/run/user/$(id -u)/sway-ipc.$(id -u).4242.sock"* ]]'
check "--status lists the outputs with their state and their make and model" \
    '[[ $out == *"  eDP-1  active=true  power=true  Maker Panel"* && $out == *"  DP-3  active=false  power=false  Other Big"* ]]'
run SWAY_PID=4242 SWAY_HANGS=1 -- --status
check "a Sway that does not answer is reported, not waited for" \
    '[[ $rc == 0 && $out == *"(no answer from sway within 3 s)"* ]]'

run SWAY_PID=4242 NO_SESSION=1 -- 
check "a Sway without a wayland login session of the user is a stop, before anything is touched" \
    '[[ $rc == 1 && $err == "fix-display: found Sway (pid 4242) but no wayland login session for it." && $log != *sudo* ]]'

LIT='[{"name":"eDP-1","active":true,"power":true,"make":"M","model":"P"}]'
run SWAY_PID=4242 OUTPUTS="$LIT" -- 
# Without a console (the build sandbox) both VTs are empty, which is equal; with
# one, the stand-in answers with the VT that is in front.
check "with Sway's VT in front and an output on there is nothing to fix, and sudo is never asked" \
    '[[ $rc == 1 && $err == *"nothing to fix"* && $log != *sudo* ]]'

echo "panel-crtc"

# panel_state() is replaced by a fake that answers from a table, and swaymsg
# by a recorder, so that fix() can be followed through its decisions.
# Not exec'd, so that the trap above removes the sandbox when it ends.
env -i PATH="$PATH" HOME="$SB/home" SB="$SB" PANEL="$PANEL" PASS="$pass" FAIL="$fail" XDG_RUNTIME_DIR="$SB/run" python3 -I - <<'PY'
import contextlib
import ctypes
import importlib.machinery
import importlib.util
import io
import os
import subprocess
import sys

sb = os.environ["SB"]
loader = importlib.machinery.SourceFileLoader("pc", os.environ["PANEL"])
spec = importlib.util.spec_from_loader("pc", loader)
pc = importlib.util.module_from_spec(spec)
loader.exec_module(pc)

passed, failed = int(os.environ["PASS"]), int(os.environ["FAIL"])


def check(name, cond, detail=""):
    global passed, failed
    if cond:
        print(f"  \033[32m✓\033[0m {name}")
        passed += 1
    else:
        print(f"  \033[31m✗\033[0m {name}\n    {detail}")
        failed += 1


# ── the kernel interface ───────────────────────────────────────────────────
# The numbers of DRM_IOCTL_MODE_GETRESOURCES, _SETCRTC, _GETENCODER and
# _GETCONNECTOR in drm.h, from the structure sizes: 64, 104, 20 and 80 bytes.
check("the structures have the sizes the kernel's have",
      (ctypes.sizeof(pc.CardRes), ctypes.sizeof(pc.ModeCrtc),
       ctypes.sizeof(pc.GetEncoder), ctypes.sizeof(pc.GetConnector), ctypes.sizeof(pc.ModeInfo))
      == (64, 104, 20, 80, 68),
      str((ctypes.sizeof(pc.CardRes), ctypes.sizeof(pc.ModeCrtc), ctypes.sizeof(pc.GetEncoder),
           ctypes.sizeof(pc.GetConnector), ctypes.sizeof(pc.ModeInfo))))
check("the ioctl numbers are the ones drm.h gives",
      (pc.GETRESOURCES, pc.SETCRTC, pc.GETENCODER, pc.GETCONNECTOR)
      == (0xC04064A0, 0xC06864A2, 0xC01464A6, 0xC05064A7),
      str([hex(n) for n in (pc.GETRESOURCES, pc.SETCRTC, pc.GETENCODER, pc.GETCONNECTOR)]))

# ── refusals that need no GPU ──────────────────────────────────────────────
def run_cli(argv, env=None):
    p = subprocess.run([os.environ["PANEL"], *argv], capture_output=True, text=True,
                       env=env or {"PATH": os.environ["PATH"], "HOME": sb, "XDG_RUNTIME_DIR": sb + "/run"})
    return p.returncode, p.stdout, p.stderr


rc, so, se = run_cli(["--bogus"])
check("an argument it does not know prints the usage on stderr and exits 2",
      rc == 2 and "panel-crtc " in se and "--free-console" in se and "--fix" in se, f"{rc} {se!r}")
rc, so, se = run_cli(["--free-console"])
check("--free-console as an ordinary user is refused before any device is opened",
      rc == 1 and se.strip() == "panel-crtc: --free-console needs root", f"{rc} {se!r}")
rc, so, se = run_cli([])
check("without an amdgpu card the report says so (exit 1), not a traceback",
      (rc == 1 and "no amdgpu card" in se and "Traceback" not in se) or "on CRTC" in so or "drives no CRTC" in so,
      f"{rc} {so!r} {se!r}")

# ── the report ─────────────────────────────────────────────────────────────
def say(fn):
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        rc = fn()
    return rc, buf.getvalue()


pc.panel_state = lambda: ("eDP-1", 376, 376, {377})
rc, text = say(pc.report)
check("the panel on the console's CRTC is ok, exit 0",
      rc == 0 and text.startswith("eDP-1 on CRTC 376, the console uses CRTC 376: ok") and "other outputs hold CRTC 377" in text, repr(text))
pc.panel_state = lambda: ("eDP-1", 377, 376, set())
rc, text = say(pc.report)
check("the panel on another CRTC is WRONG, exit 1, and no line for outputs that hold none",
      rc == 1 and "WRONG" in text and "other outputs" not in text, repr(text))
pc.panel_state = lambda: None
rc, text = say(pc.report)
check("a panel that drives no CRTC is reported, exit 0", rc == 0 and "the panel drives no CRTC" in text, repr(text))

# ── the fix ────────────────────────────────────────────────────────────────
calls = []


class Done:
    stdout = "[]"


def fake_swaymsg(*args):
    calls.append(args)
    r = Done()
    if args[:3] == ("-r", "-t", "get_outputs"):
        r.stdout = OUTPUTS
    return r


OUTPUTS = "[]"
pc.swaymsg = fake_swaymsg
pc.time.sleep = lambda s: None
pc.log = lambda m: None


def states(*seq):
    it = iter(seq)
    last = [None]

    def f():
        try:
            last[0] = next(it)
        except StopIteration:
            pass
        return last[0]
    return f


# Already on the console's CRTC: nothing is touched, no blink.
calls.clear()
pc.panel_state = states(("eDP-1", 376, 376, {377}))
rc = pc.fix()
check("--fix with the panel on the console's CRTC does nothing and does not touch Sway",
      rc == 0 and calls == [], str(calls))

# Panel off the console's CRTC, nobody holds the console's: panel off, panel on.
calls.clear()
pc.panel_state = states(("eDP-1", 377, 376, {378}), ("eDP-1", 376, 376, set()))
OUTPUTS = '[{"name":"DP-3","active":true,"power":true},{"name":"eDP-1","active":true,"power":true}]'
rc = pc.fix()
check("--fix moves the panel by powering it off and on when no other output holds the console's CRTC",
      rc == 0 and calls == [("-r", "-t", "get_outputs"), ("output", "eDP-1", "power", "off"),
                            ("output", "eDP-1", "power", "on")], str(calls))

# Another output holds the console's CRTC: it goes off first and on last.
calls.clear()
pc.panel_state = states(("eDP-1", 377, 376, {376}), ("eDP-1", 376, 376, {377}))
rc = pc.fix()
check("--fix powers the blocking output off first and on last, the panel first of the two on",
      rc == 0 and calls[1:] == [("output", "DP-3", "power", "off"), ("output", "eDP-1", "power", "off"),
                                ("output", "eDP-1", "power", "on"), ("output", "DP-3", "power", "on")], str(calls))

# An output that is off already is not one to switch back on.
calls.clear()
OUTPUTS = '[{"name":"DP-3","active":true,"power":false},{"name":"eDP-1","active":true}]'
pc.panel_state = states(("eDP-1", 377, 376, {376}), ("eDP-1", 376, 376, set()))
rc = pc.fix()
check("--fix leaves an output that was powered off alone",
      rc == 0 and not any("DP-3" in c for c in calls), str(calls))

# The panel does not move: after twenty tries it reports failure.
calls.clear()
OUTPUTS = "[]"
pc.panel_state = lambda: ("eDP-1", 377, 376, set())
rc = pc.fix()
check("--fix that cannot move the panel exits 1, and the panel is powered on again at the end",
      rc == 1 and calls[-1] == ("output", "eDP-1", "power", "on"), str(calls))

# Sway stops answering in the middle: the power-on still runs (try/finally).
calls.clear()


def failing(*args):
    calls.append(args)
    if args[:3] == ("-r", "-t", "get_outputs"):
        return Done()
    if args == ("output", "eDP-1", "power", "off"):
        raise subprocess.TimeoutExpired("swaymsg", 3)
    return Done()


pc.swaymsg = failing
pc.panel_state = lambda: ("eDP-1", 377, 376, set())
try:
    pc.fix()
    raised = False
except subprocess.TimeoutExpired:
    raised = True
check("a Sway that times out while the panel is off still gets the power-on before the error goes on",
      raised and calls[-1] == ("output", "eDP-1", "power", "on"), str(calls))

print()
print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
exit $?
