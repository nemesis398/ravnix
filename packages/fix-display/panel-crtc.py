"""panel-crtc - keep the laptop panel on the CRTC the kernel console uses.

This is what keeps the panel from staying dark after a resume (2026-10-20).
The notes on this laptop have the history under "A dark panel after a resume".

The mechanism, read from wlroots 0.19.3 and still the same on its master:

  1. Whenever Sway's session pauses (every suspend, because the kernel
     switches to VT 63, and every visit to a TTY), wlroots destroys its
     outputs and tries to turn their CRTCs off. It has already lost DRM
     master, so that fails ("Failed to disable CRTC 381" in the journal), and
     because it failed, wlroots keeps the old CRTC assigned to the connector.
  2. While Sway is paused the kernel console lights the panel itself, on the
     first CRTC the panel can use. Measured on tty3: CRTC 376, index 0.
  3. When Sway comes back it restores the panel on the CRTC it kept. If that
     is the console's CRTC, nothing moves and it works. If it is another one,
     the commit moves the panel away and leaves the console's CRTC on with no
     connector. The kernel refuses that, and every fallback Sway tries
     ("Search for valid config failed"), all-off included, because each one
     keeps that CRTC lit.

The panel lands on the other CRTC after it has shared the GPU with the
ultrawide, which then held index 0. Undocking does not move it back. Over 12
boots up to 2026-10-20, every resume with the panel on index 0 lit it again
(119 of 119), and every resume without the ultrawide while the panel sat on
index 1 stayed dark. Plugging the dock back in cures it only because the
ultrawide takes over index 0 in the same commit.

So the fix is to keep the panel on the console's CRTC. Powering an output off
in Sway frees its CRTC, because that commit succeeds, and powering the panel
on again lets wlroots pick the lowest free CRTC. The ultrawide has to be
powered off too if it holds that CRTC, or the panel gets index 1 again.

Usage:
  panel-crtc                  report where the panel is (read-only, any user);
                              exits 1 when it is on the wrong CRTC
  panel-crtc --fix            move the panel to the console's CRTC if it is
                              anywhere else; does nothing, and so no blink,
                              when it is already there
  panel-crtc --free-console   as root, from a TTY while Sway is paused: turn
                              every CRTC off so Sway's restore starts from
                              nothing. This is the cure once the panel is dark;
                              fix-display runs it.

--fix runs from every kanshi profile and from swayidle's before-sleep (in
keep-awake), which holds the suspend for up to 5 s while it works.
"""

import ctypes
import fcntl
import glob
import json
import os
import re
import subprocess
import sys
import syslog
import time

DRM_MODE_CONNECTOR_EDP = 14
TYPE_NAMES = {3: "DVI-D", 10: "DP", 11: "HDMI-A", 14: "eDP"}


class ModeInfo(ctypes.Structure):
    _fields_ = [("clock", ctypes.c_uint32)] + \
        [(n, ctypes.c_uint16) for n in ("hdisplay", "hsync_start", "hsync_end", "htotal", "hskew",
                                        "vdisplay", "vsync_start", "vsync_end", "vtotal", "vscan")] + \
        [(n, ctypes.c_uint32) for n in ("vrefresh", "flags", "type")] + \
        [("name", ctypes.c_char * 32)]


class CardRes(ctypes.Structure):
    _fields_ = [(n, ctypes.c_uint64) for n in ("fb_id_ptr", "crtc_id_ptr", "connector_id_ptr", "encoder_id_ptr")] + \
        [(n, ctypes.c_uint32) for n in ("count_fbs", "count_crtcs", "count_connectors", "count_encoders",
                                        "min_width", "max_width", "min_height", "max_height")]


class GetConnector(ctypes.Structure):
    _fields_ = [(n, ctypes.c_uint64) for n in ("encoders_ptr", "modes_ptr", "props_ptr", "prop_values_ptr")] + \
        [(n, ctypes.c_uint32) for n in ("count_modes", "count_props", "count_encoders", "encoder_id",
                                        "connector_id", "connector_type", "connector_type_id", "connection",
                                        "mm_width", "mm_height", "subpixel", "pad")]


class GetEncoder(ctypes.Structure):
    _fields_ = [(n, ctypes.c_uint32) for n in ("encoder_id", "encoder_type", "crtc_id", "possible_crtcs", "possible_clones")]


class ModeCrtc(ctypes.Structure):
    _fields_ = [("set_connectors_ptr", ctypes.c_uint64)] + \
        [(n, ctypes.c_uint32) for n in ("count_connectors", "crtc_id", "fb_id", "x", "y", "gamma_size", "mode_valid")] + \
        [("mode", ModeInfo)]


def iowr(nr, struct):
    return (3 << 30) | (ctypes.sizeof(struct) << 16) | (ord("d") << 8) | nr


GETRESOURCES, SETCRTC = iowr(0xA0, CardRes), iowr(0xA2, ModeCrtc)
GETENCODER, GETCONNECTOR = iowr(0xA6, GetEncoder), iowr(0xA7, GetConnector)


def log(msg):
    # The journal gets it as panel-crtc; kanshi and swayidle would log stderr
    # a second time, so print only to a person.
    syslog.syslog(msg)
    if sys.stderr.isatty():
        print(f"panel-crtc: {msg}", file=sys.stderr)


def amdgpu_card():
    # The card number changes between boots, so match on the driver.
    for c in sorted(glob.glob("/sys/class/drm/card*")):
        if re.fullmatch(r"card\d+", os.path.basename(c)) and \
                os.path.realpath(c + "/device/driver").endswith("/amdgpu"):
            return "/dev/dri/" + os.path.basename(c)
    sys.exit("panel-crtc: no amdgpu card under /sys/class/drm")


def read_state(fd):
    """Return (crtc ids, [(name, type, crtc id, possible crtcs mask)]) for connectors that drive a CRTC."""
    res = CardRes()
    fcntl.ioctl(fd, GETRESOURCES, res)
    crtcs = (ctypes.c_uint32 * res.count_crtcs)()
    conns = (ctypes.c_uint32 * res.count_connectors)()
    res = CardRes(crtc_id_ptr=ctypes.addressof(crtcs), connector_id_ptr=ctypes.addressof(conns),
                  count_crtcs=len(crtcs), count_connectors=len(conns))
    fcntl.ioctl(fd, GETRESOURCES, res)
    out = []
    for cid in conns:
        # count_modes 0 would make the kernel probe the connector when this fd
        # happens to be DRM master (as root on a TTY), so ask for one mode.
        mode = ModeInfo()
        conn = GetConnector(connector_id=cid, count_modes=1, modes_ptr=ctypes.addressof(mode))
        fcntl.ioctl(fd, GETCONNECTOR, conn)
        if not conn.encoder_id:
            continue
        enc = GetEncoder(encoder_id=conn.encoder_id)
        fcntl.ioctl(fd, GETENCODER, enc)
        if enc.crtc_id:
            name = f"{TYPE_NAMES.get(conn.connector_type, f'type{conn.connector_type}')}-{conn.connector_type_id}"
            out.append((name, conn.connector_type, enc.crtc_id, enc.possible_crtcs))
    return list(crtcs), out


def panel_state():
    """Return (panel name, its crtc, the console's crtc, crtcs held by other outputs), or None if the panel is off."""
    fd = os.open(amdgpu_card(), os.O_RDWR | os.O_CLOEXEC)
    try:
        crtcs, active = read_state(fd)
    finally:
        os.close(fd)
    for name, ctype, crtc, possible in active:
        if ctype == DRM_MODE_CONNECTOR_EDP:
            console = next(crtcs[i] for i in range(len(crtcs)) if possible & (1 << i))
            others = {c for n, _, c, _ in active if n != name}
            return name, crtc, console, others
    return None


def swaymsg(*args):
    return subprocess.run(["swaymsg", *args], capture_output=True, text=True, timeout=3)


def report():
    state = panel_state()
    if state is None:
        print("the panel drives no CRTC (off, or Sway is paused and the console is off)")
        return 0
    name, crtc, console, others = state
    verdict = "ok" if crtc == console else "WRONG: the next resume or TTY visit leaves it dark"
    print(f"{name} on CRTC {crtc}, the console uses CRTC {console}: {verdict}")
    if others:
        print(f"other outputs hold CRTC {', '.join(map(str, sorted(others)))}")
    return 0 if crtc == console else 1


def fix():
    lock = open(os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), "panel-crtc.lock"), "w")
    fcntl.flock(lock, fcntl.LOCK_EX)
    state = panel_state()
    if state is None or state[1] == state[2]:
        return 0
    name, crtc, console, others = state
    outs = json.loads(swaymsg("-r", "-t", "get_outputs").stdout or "[]")
    lit = [o["name"] for o in outs if o.get("active") and o.get("power", True) and o["name"] != name]
    blockers = lit if console in others else []
    log(f"{name} is on CRTC {crtc}, the console uses {console}; powering "
        f"{' and '.join([name] + blockers)} off and on to move it")
    try:
        for o in blockers:
            swaymsg("output", o, "power", "off")
        swaymsg("output", name, "power", "off")
    finally:
        # Panel first, so it gets the lowest free CRTC; then the rest. Always
        # runs, because Sway keeps "power off" for an output across a resume.
        swaymsg("output", name, "power", "on")
        for o in blockers:
            swaymsg("output", o, "power", "on")
    for _ in range(20):
        state = panel_state()
        if state is not None and state[1] == state[2]:
            log(f"{name} is on CRTC {state[1]} now")
            return 0
        time.sleep(0.1)
    log(f"{name} did not move: {state}")
    return 1


def free_console():
    if os.geteuid() != 0:
        sys.exit("panel-crtc: --free-console needs root")
    fd = os.open(amdgpu_card(), os.O_RDWR | os.O_CLOEXEC)
    try:
        crtcs, _ = read_state(fd)
        for crtc in crtcs:
            # Needs DRM master, which this fd gets only while nobody else holds
            # it, i.e. while Sway is paused on another VT.
            try:
                fcntl.ioctl(fd, SETCRTC, ModeCrtc(crtc_id=crtc))
            except PermissionError:
                sys.exit("panel-crtc: Sway holds the display; run this from a TTY")
        log(f"turned off CRTC {', '.join(map(str, crtcs))} for Sway's restore")
    finally:
        os.close(fd)
    return 0


def main():
    syslog.openlog("panel-crtc")
    arg = sys.argv[1] if len(sys.argv) > 1 else ""
    if arg == "":
        return report()
    if arg == "--fix":
        return fix()
    if arg == "--free-console":
        return free_console()
    print(__doc__.split("Usage:")[1].split("\n\n")[0], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
