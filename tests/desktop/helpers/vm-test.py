# The VM half of the desktop-sway check. tests/desktop/sway.nix puts USER and
# PASSWORD in front of this file.
import json
import shlex
import struct
import zlib
from collections import Counter

UID = 1000
RUN = f"/run/user/{UID}"


def as_user(command, check=True):
    """Run a command as the user, in the environment of the session."""
    env = f"XDG_RUNTIME_DIR={RUN} WAYLAND_DISPLAY=wayland-1"
    full = f"su - {USER} -c {shlex.quote(env + ' ' + command)}"
    return machine.succeed(full) if check else machine.execute(full)


def swaymsg_command(*args):
    sock = machine.succeed(f"ls {RUN}/sway-ipc.{UID}.*.sock | head -n1").strip()
    return "swaymsg -s " + shlex.quote(sock) + " " + " ".join(shlex.quote(a) for a in args)


def swaymsg(*args):
    return json.loads(as_user(swaymsg_command(*args)))


def workspace_y():
    focused = [w for w in swaymsg("-t", "get_workspaces") if w["focused"]]
    assert len(focused) == 1, f"expected one focused workspace, got {focused}"
    return focused[0]["rect"]["y"]


def diagnose(what):
    """What the machine looks like when a wait gave up, for the log of the check."""
    print(f"--- {what}: the processes ---")
    print(machine.execute("ps -eo pid,user,args --width 220 | grep -v ' \\[' | head -90")[1])
    print(f"--- {what}: the journal ---")
    print(machine.execute("journalctl -b --no-pager -o cat | tail -200")[1])
    print(f"--- {what}: the first console ---")
    print(machine.get_tty_text("1"))
    machine.screenshot("failure")


def wait_for(description, condition, timeout=60, left=None):
    """Wait until condition() holds. left, when given, says what was still
    there when the time ran out, and the failure carries it."""

    def check(last_chance):
        if condition():
            return True
        assert not (last_chance and left), f"gave up waiting for {description} after {timeout} s: {left()}"
        return False

    try:
        with machine.nested(f"waiting for {description}"):
            retry(check, timeout)
    except Exception:
        diagnose(description)
        raise


def png_pixels(path):
    """The pixels of a PNG as (r, g, b) tuples: a palette of 1 to 8 bits, or 8 bit RGB or RGBA."""
    data = open(path, "rb").read()
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG"
    pos, chunks, idat = 8, {}, b""
    palette: list = []
    while pos < len(data):
        length, kind = struct.unpack(">I4s", data[pos : pos + 8])
        body = data[pos + 8 : pos + 8 + length]
        pos += 12 + length
        if kind == b"IDAT":
            idat += body
        elif kind == b"PLTE":
            palette = [tuple(body[i : i + 3]) for i in range(0, len(body), 3)]
        else:
            chunks[kind] = body
    width, height, depth, ctype, _c, _f, interlace = struct.unpack(">IIBBBBB", chunks[b"IHDR"])
    assert interlace == 0, "interlaced PNG"
    assert (ctype == 3 and palette) or (ctype in (2, 6) and depth == 8), f"unsupported PNG: type {ctype}, depth {depth}"
    channels = {2: 3, 3: 1, 6: 4}[ctype]
    stride = (width * channels * depth + 7) // 8
    bpp = max(1, channels * depth // 8)  # bytes per pixel for the filters
    raw = zlib.decompress(idat)
    prev = bytearray(stride)
    for y in range(height):
        base = y * (stride + 1)
        ft, line = raw[base], bytearray(raw[base + 1 : base + 1 + stride])
        for i in range(stride):
            a = line[i - bpp] if i >= bpp else 0
            b = prev[i]
            c = prev[i - bpp] if i >= bpp else 0
            if ft == 1:
                line[i] = (line[i] + a) & 255
            elif ft == 2:
                line[i] = (line[i] + b) & 255
            elif ft == 3:
                line[i] = (line[i] + (a + b) // 2) & 255
            elif ft == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if pa <= pb and pa <= pc else (b if pb <= pc else c)
                line[i] = (line[i] + pred) & 255
        prev = line
        for x in range(width):
            if ctype == 3:
                bit = x * depth
                index = (line[bit // 8] >> (8 - depth - bit % 8)) & ((1 << depth) - 1)
                yield palette[index]
            else:
                yield tuple(line[x * channels : x * channels + 3])


def rgb(hexcolor):
    h = hexcolor.lstrip("#")
    return tuple(int(h[i : i + 2], 16) for i in (0, 2, 4))


start_all()
machine.wait_for_unit("multi-user.target")
machine.wait_for_unit("greetd.service")

# ── the greeter ───────────────────────────────────────────────────────────────
machine.wait_until_tty_matches("1", "Username")
machine.sleep(2)
machine.screenshot("greeter")
counts = Counter(png_pixels(machine.out_dir / "greeter.png"))
total = sum(counts.values())
base = rgb(BASE)
accent = rgb(ACCENT)
assert counts[base] > total * 0.8, f"the greeter is not drawn on Base: {counts.most_common(4)}"
assert counts[accent] > 200, f"nothing on the greeter is the accent (frame and prompt): {counts.most_common(6)}"

# ── logging in through it ─────────────────────────────────────────────────────
machine.send_chars(USER + "\n")
machine.wait_until_tty_matches("1", "Password")
machine.send_chars(PASSWORD + "\n")
wait_for("Sway", lambda: machine.execute(f"pgrep -u {USER} -x sway")[0] == 0, 120)
machine.wait_for_file(f"{RUN}/wayland-1")

# ── the session comes up ──────────────────────────────────────────────────────
# Waybar is a wrapper on NixOS: its process is called .waybar-wrapped, and the
# command line is what says waybar.
WAYBAR = "'^waybar -c '"


def waybars():
    return int(machine.succeed(f"pgrep -u {USER} -fc {WAYBAR} || true").strip() or 0)


wait_for("Waybar", lambda: waybars() == 1)
wait_for("dunst", lambda: as_user("systemctl --user is-active dunst", check=False)[0] == 0)
wait_for("kanshi", lambda: machine.execute(f"pgrep -u {USER} -x kanshi")[0] == 0)
wait_for(
    "the clipboard watchers",
    lambda: machine.execute(f"pgrep -u {USER} -fc 'wl-paste --type (text|image) --watch cliphist store' | grep -qx 2")[0] == 0,
)
wait_for("swayidle", lambda: machine.execute(f"pgrep -u {USER} -x swayidle")[0] == 0)
# (the process name is cut at 15 characters, so the command line is matched)
wait_for("the policy kit agent", lambda: machine.execute(f"pgrep -u {USER} -f lxqt-policykit-agent")[0] == 0)
wait_for("sway-session.target", lambda: as_user("systemctl --user is-active sway-session.target", check=False)[0] == 0)

# The commands that energy, the keys and the bar call by name resolve for a
# process Sway starts (swaymsg exec runs them with Sway's own environment).
swaymsg("exec", "command -v keep-awake waybar-launch waybar-mode ghostty-float sway-volume gtk-launch > /tmp/session-path.txt 2>&1")
wait_for(
    "the session's PATH to be asked",
    lambda: machine.execute("test $(wc -l < /tmp/session-path.txt) -ge 6")[0] == 0,
    20,
)
found = machine.succeed("cat /tmp/session-path.txt")
for command in ("keep-awake", "waybar-launch", "waybar-mode", "ghostty-float", "sway-volume", "gtk-launch"):
    assert f"/bin/{command}" in found, f"{command} is not on the PATH of the Sway session: {found}"

# The GPU the module names is the one the link points at, and Sway started
# under it: the udev rule matched the PCI address (not a card number), and the
# variable is in the compositor's environment.
card = machine.succeed("readlink -f /dev/dri/primary-gpu").strip()
assert card.startswith("/dev/dri/card"), f"/dev/dri/primary-gpu does not resolve to a card: {card}"
parent = machine.succeed(f"readlink -f /sys/class/drm/{card.rsplit('/', 1)[1]}/device").strip()
assert parent.endswith("/" + GPU_ADDRESS), f"the link {card} is the card of {parent}, not of {GPU_ADDRESS}"
sway_env = machine.succeed(f"tr '\\0' '\\n' < /proc/$(pgrep -u {USER} -x sway | head -n1)/environ")
assert "WLR_DRM_DEVICES=/dev/dri/primary-gpu" in sway_env.splitlines(), "Sway did not start with WLR_DRM_DEVICES=/dev/dri/primary-gpu"

# home-manager's session variables reach the processes Sway starts, which is
# what the launcher and the keys are. greetd runs the session through the
# user's shell, and home-manager's bash profile reads the file, so here they
# arrive with or without the Sway wrapper's help; the wrapper reads the file
# too, for a user whose shell does not, and that is checked further down in an
# empty environment. Qt finds its platform theme through one of them, the
# cursor through two more; another is a variable this test gave home-manager.
hm_file = f"/etc/profiles/per-user/{USER}/etc/profile.d/hm-session-vars.sh"


def hm_var(name):
    value = machine.succeed(f"sed -n 's/^export {name}=\"\\(.*\\)\"$/\\1/p' {hm_file}").strip()
    assert value, f"{hm_file} sets no {name}"
    return value


hm_qt = hm_var("QT_QPA_PLATFORMTHEME")
# The cursor is home-manager's alone (the session sets no XCURSOR_* of its
# own), and Sway's own seat takes the same theme and size from the same place.
hm_cursor = f"{hm_var('XCURSOR_THEME')} {hm_var('XCURSOR_SIZE')}"
machine.succeed(f"grep -qx 'seat \\* xcursor_theme {hm_cursor}' /home/{USER}/.config/sway/config")
swaymsg("exec", 'echo "qt=$QT_QPA_PLATFORMTHEME cursor=$XCURSOR_THEME $XCURSOR_SIZE test=$RAVNIX_TEST_HM_VAR" > /tmp/hm-vars.txt')
wait_for("the variables of a process Sway started", lambda: machine.execute("test -s /tmp/hm-vars.txt")[0] == 0, 20)
seen = machine.succeed("cat /tmp/hm-vars.txt").strip()
expected = f"qt={hm_qt} cursor={hm_cursor} test=from-home-manager"
assert seen == expected, f"a process started by Sway sees '{seen}', not the variables of home-manager ('{expected}')"

# The login shell can bring those variables along by itself (home-manager's
# bash writes them into the profile), which would hide a wrapper that does not
# read them. So the wrapper's own session commands are also run in an empty
# environment, as greetd would run them for a shell that sources nothing.
bare = machine.succeed("dirname $(readlink -f $(command -v sway))").strip() + "/.sway-wrapped"
machine.succeed(f"sed -n '/XDG_CURRENT_DESKTOP=/,/_SWAY_WRAPPER_ALREADY_EXECUTED=1/p' {bare} > /tmp/session-commands.sh")
machine.succeed("test $(wc -l < /tmp/session-commands.sh) -gt 3")
machine.succeed(
    "printf '%s\\n' '. /tmp/session-commands.sh' 'echo \"qt=$QT_QPA_PLATFORMTHEME cursor=$XCURSOR_THEME $XCURSOR_SIZE test=$RAVNIX_TEST_HM_VAR\"' > /tmp/probe.sh"
)
bare_seen = machine.succeed(f"su {USER} -c 'env -i HOME=/home/{USER} USER={USER} PATH=/run/current-system/sw/bin bash -e /tmp/probe.sh'").strip()
assert bare_seen == expected, f"the Sway wrapper's session commands leave '{bare_seen}' in an empty environment, not the variables of home-manager ('{expected}')"

# Waybar has been up long enough to have failed on a bad config or stylesheet.
machine.sleep(5)
assert waybars() == 1, "Waybar is not running once"

# Sway accepts its own config again, every line (a reload runs them all).
reply = swaymsg("reload")
assert all(r["success"] for r in reply), f"sway reload refused something: {reply}"
wait_for("one Waybar after the reload", lambda: waybars() == 1)
machine.sleep(3)

# ── the bar is 32 px in every mode ────────────────────────────────────────────
assert workspace_y() == 32, f"the full bar is not 32 px high: workspace starts at {workspace_y()}"
machine.screenshot("bar-full")


def cycle(expected_y, label):
    swaymsg("exec", "waybar-mode")
    wait_for(label, lambda: workspace_y() == expected_y, 30)


cycle(32, "the focus bar, 32 px high")
wait_for("one Waybar in focus mode", lambda: waybars() == 1)
machine.screenshot("bar-focus")
cycle(0, "no bar")
wait_for("no Waybar in mode none", lambda: waybars() == 0)
cycle(32, "the full bar again")
wait_for("one Waybar again", lambda: waybars() == 1)

# ── the bar's colors on a real screen ─────────────────────────────────────────
swaymsg("exec", "grim /tmp/screen.png")
machine.wait_for_file("/tmp/screen.png")
machine.copy_from_machine("/tmp/screen.png", "")
pixels = Counter(png_pixels(machine.out_dir / "screen.png"))
mantle = rgb(MANTLE)
assert pixels[mantle] > 5000, "the bar is not drawn on Mantle"

# ── a notification ────────────────────────────────────────────────────────────
as_user("notify-send -a test 'Desktop test' 'A notification'")
wait_for("a notification on screen", lambda: as_user("dunstctl count displayed").strip() == "1", 20)
machine.screenshot("notification")
as_user("dunstctl close-all")

# ── the login layout is over ───────────────────────────────────────────────────
# The layout starts the session's apps through gtk-launch (Helium and the music
# web app among them), which works since gtk-launch is on the PATH. Their
# windows are not what the next stage looks at: it counts colors on the screen,
# and a browser page under the ring has the wash and the accent in it and would
# change the numbers it is compared with. So the layout is waited for, and its
# windows are closed. Closing is not the end: Helium is killed too, and what
# is left is waited out until, for three seconds in a row, no window is on the
# tree and no Helium runs, so that no window of the layout maps after the
# baseline of the next stage.
wait_for("the login layout to be done", lambda: machine.execute(f"pgrep -u {USER} -f sway-session-layout")[0] != 0, 120)


def windows():
    """The views on the tree, as (con_id, app_id or X11 class, pid)."""
    found = []

    def walk(node):
        if node.get("pid") and node.get("type") in ("con", "floating_con"):
            app = node.get("app_id") or (node.get("window_properties") or {}).get("class")
            found.append((node["id"], app, node["pid"]))
        for child in node.get("nodes", []) + node.get("floating_nodes", []):
            walk(child)

    walk(swaymsg("-t", "get_tree"))
    return found


def helium_runs():
    return machine.execute(f"pgrep -u {USER} -f '/share/helium/helium'")[0] == 0


def close(window):
    """Close one view. A view can be gone by the time its kill arrives: the
    pkill in layout_gone ends Helium's while their list is read. Sway then
    answers "No matching node." and swaymsg exits 2 (sway/commands.c,
    swaymsg/main.c), which is what the kill was for, so that one answer is let
    pass and the next read of the tree decides. Any other failure stops the
    stage at once with what swaymsg said; a view that stays open is caught by
    the bounded wait below."""
    status, out = as_user(swaymsg_command(f"[con_id={window}]", "kill"), check=False)
    if status == 0:
        return
    try:
        errors = [r.get("error") for r in json.loads(out)]
    except (ValueError, AttributeError, TypeError):
        errors = []
    assert status == 2 and errors == ["No matching node."], (
        f"swaymsg could not close the window {window}: exit {status}, {out.strip()!r}"
    )


# What the last look found, for the message when the wait gives up.
last_look: dict = {"windows": [], "helium": False}


def layout_gone():
    machine.execute(f"pkill -u {USER} -f '/share/helium/helium'")
    for window, _app, _pid in windows():
        close(window)
    for _ in range(3):
        machine.sleep(1)
        last_look["windows"], last_look["helium"] = windows(), helium_runs()
        if last_look["windows"] or last_look["helium"]:
            return False
    return True


wait_for(
    "the apps of the layout to be gone, and no window to map late",
    layout_gone,
    90,
    left=lambda: (
        f"windows still on the tree (con_id, app, pid): {last_look['windows'] or 'none'}; "
        f"Helium {'still runs' if last_look['helium'] else 'is gone'}"
    ),
)
# close() takes Sway's answer for a view that is gone as done. That answer is
# pinned here once, on an id that no view has, so that a Sway that words it
# otherwise fails this line every time and not, now and then, the race above.
close(2**31 - 1)

# ── the radial menu ───────────────────────────────────────────────────────────
# sway-radial is a user service of the session. It reads the trackpad, which the
# VM has none of: it says so in the journal and carries on. SIGUSR1 opens the
# ring for the pointer, as the mouse's button does through sway-mouse, and a
# screenshot shows what it draws: the lit sector in the accent, the others in
# the wash, the hub in Crust, all opaque and drawn at once; and the same signal
# again takes it away at once.
wait_for("sway-radial", lambda: as_user("systemctl --user is-active sway-radial", check=False)[0] == 0, 60)


def grab(name):
    as_user(f"grim /tmp/{name}.png")
    machine.copy_from_machine(f"/tmp/{name}.png", "")
    return Counter(png_pixels(machine.out_dir / f"{name}.png"))


def radial_signal():
    as_user("systemctl --user kill --kill-whom=main --signal=SIGUSR1 sway-radial.service")


wash, deepest = rgb(WASH), rgb(DEEPEST)
closed = grab("radial-closed")
radial_signal()
wait_for(
    "the ring on screen",
    lambda: (lambda c: c[accent] - closed[accent] > 3000 and c[wash] - closed[wash] > 20000)(grab("radial-open")),
    60,
)
machine.screenshot("radial-open")
opened = grab("radial-shot")
assert opened[deepest] - closed[deepest] > 3000, "the hub of the ring is not drawn in Crust"
# Opaque: the ring is drawn in the colors of the roles and in no blend of them.
# A translucent wedge would show the screen through it and be a color of its own.
assert opened[wash] - closed[wash] > 20000, "the wedges are not the wash"
radial_signal()
wait_for(
    "the ring to be gone at once",
    lambda: (lambda c: c[wash] - closed[wash] < 200 and c[accent] - closed[accent] < 200)(grab("radial-gone")),
    20,
)

# ── an app opened from the ring ───────────────────────────────────────────────
# The menu of the VM (tests/desktop/fixtures/sway-radial/vm-menu.toml) has an
# application on its north sector: radial-probe, whose Exec is `sleep 4711`. A
# click on that sector is the whole path: the pointer, the overlay, the daemon's
# run_item, `swaymsg exec`, gtk-launch. The app has to be Sway's and not the
# service's: it runs, outside sway-radial.service's cgroup, with the session's
# PATH and none of the program's wrapper variables, and it is still there after
# the service has been restarted, which is what every rebuild that changes the
# unit does.
as_user(
    "mkdir -p ~/.local/share/applications && printf '%s\\n' '[Desktop Entry]' 'Type=Application' "
    "'Name=Radial probe' 'Exec=sleep 4711' > ~/.local/share/applications/radial-probe.desktop"
)


def radial_main_pid():
    return as_user("systemctl --user show -p MainPID --value sway-radial.service").strip()


def environ_of(pid):
    raw = machine.succeed(f"tr '\\0' '\\n' < /proc/{pid}/environ")
    return dict(line.split("=", 1) for line in raw.splitlines() if "=" in line)


daemon_pid = radial_main_pid()
assert daemon_pid not in ("", "0"), "sway-radial.service has no main process"
radial_signal()
wait_for("the ring to click on", lambda: grab("radial-click")[accent] - closed[accent] > 3000, 60)
rect = swaymsg("-t", "get_outputs")[0]["rect"]
click_x, click_y = rect["x"] + rect["width"] // 2, rect["y"] + rect["height"] // 2 - 120  # north, between hub and rim
for command in (("cursor", "set", str(click_x), str(click_y)), ("cursor", "press", "button1"), ("cursor", "release", "button1")):
    answer = swaymsg("seat", "seat0", *command)
    assert all(entry.get("success") for entry in answer), (command, answer)
    machine.sleep(1)
wait_for("the app of the ring", lambda: machine.execute(f"pgrep -u {USER} -f '/sleep 4711$'")[0] == 0, 30)
app_pid = machine.succeed(f"pgrep -u {USER} -f '/sleep 4711$'").split()[0]

app_cgroup = machine.succeed(f"cat /proc/{app_pid}/cgroup")
assert "sway-radial" not in app_cgroup, f"the app of the ring is in the cgroup of the service: {app_cgroup}"
daemon_cgroup = machine.succeed(f"cat /proc/{daemon_pid}/cgroup")
assert "sway-radial.service" in daemon_cgroup, f"the daemon is not in its own unit: {daemon_cgroup}"
app_env = environ_of(app_pid)
for name in ("GI_TYPELIB_PATH", "PYTHONPATH", "PYTHONDONTWRITEBYTECODE", "SWAY_RADIAL_GTK_LAUNCH", "SWAY_RADIAL_THEME"):
    assert name not in app_env, f"the app of the ring has the program's {name}={app_env[name]}"
# Exactly Sway's PATH, which is not the daemon's (the user manager's, with the
# wrapper's swaymsg behind it, and without ~/.local/bin): an app that the daemon
# started itself would have the daemon's.
sway_path = next(line[len("PATH=") :] for line in sway_env.splitlines() if line.startswith("PATH="))
assert app_env.get("PATH") == sway_path, f"the app of the ring has not the session's PATH: {app_env.get('PATH')} against Sway's {sway_path}"

as_user("systemctl --user restart sway-radial.service")
wait_for(
    "sway-radial to be back",
    lambda: radial_main_pid() not in ("", "0", daemon_pid) and as_user("systemctl --user is-active sway-radial", check=False)[0] == 0,
    60,
)
assert machine.execute(f"kill -0 {app_pid}")[0] == 0, "the app of the ring did not survive a restart of the service"
assert machine.succeed(f"tr '\\0' ' ' < /proc/{app_pid}/cmdline").strip().endswith("sleep 4711")
machine.succeed(f"pkill -u {USER} -f '/sleep 4711$'; rm -f /home/{USER}/.local/share/applications/radial-probe.desktop")

# ── the locked screen ─────────────────────────────────────────────────────────
swaymsg("exec", "swaylock -f")
# (swaylock is a wrapper too: the process is called .swaylock-wrapped)
wait_for("swaylock", lambda: machine.execute(f"pgrep -u {USER} -f '^swaylock'")[0] == 0, 30)
machine.sleep(2)
machine.screenshot("locked")
machine.send_chars(PASSWORD + "\n")
wait_for("the unlock", lambda: machine.execute(f"pgrep -u {USER} -f '^swaylock'")[0] != 0, 30)

# ── PipeWire survives Xwayland going away ─────────────────────────────────────
# Xwayland ends ten seconds after its last client; PipeWire's X11 bell module
# used to crash on it (sway.nix explains). Give Xwayland the time, then look.
as_user("pgrep -x Xwayland || true")
machine.sleep(15)
machine.succeed('test -z "$(coredumpctl list --no-pager --no-legend 2>/dev/null)"')

# ── nothing failed ────────────────────────────────────────────────────────────
machine.succeed("systemctl --failed --no-legend | wc -l | grep -qx 0")
failed_user = as_user("systemctl --user --failed --no-legend")
assert failed_user.strip() == "", f"user units failed: {failed_user}"
machine.screenshot("final")
