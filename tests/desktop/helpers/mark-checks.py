#!/usr/bin/env python3
"""The check desktop-mark: the raven mark in the bar and on the login screen.

    mark-checks.py ARGS.json

ARGS.json names the shipped mark and its art, the art mark-art.py makes from
the mark now, the palette, and the generated files of two evaluations of the
desktop module, one with the default accent and one with Teal. Every failed
expectation is one line on stderr, and the exit status is 1 if there was any.

The backdrop package's own check (desktop-backdrop) covers the wallpaper and
the lock image.
"""
import json
import re
import shlex
import sys
from pathlib import Path

import gi

gi.require_version("GdkPixbuf", "2.0")
from gi.repository import GdkPixbuf  # noqa: E402

failures = []

# The cells the art may use: those the console's font holds (mark-art.py).
CELLS = set(" ▀▄█")
# tuigreet's box is 80 columns by default: a frame and a padding of one on
# each side leave 76 for the greeting.
GREETING_WIDTH = 76
# The eye of the upper raven in the mark's own units (viewBox 14 14 132 132).
EYE, VIEW_X, VIEW_SIZE = (44, 52), 14, 132


def fail(message):
    failures.append(message)


def expect(condition, message):
    if not condition:
        fail(message)


def read(path):
    return Path(path).read_text()


def jsonc(path, label):
    """Waybar's own parser takes comments and trailing commas; json does not."""
    out, in_string, escaped, i, text = [], False, False, 0, read(path)
    while i < len(text):
        c = text[i]
        if in_string:
            out.append(c)
            if escaped:
                escaped = False
            elif c == "\\":
                escaped = True
            elif c == '"':
                in_string = False
        elif c == '"':
            in_string = True
            out.append(c)
        elif text.startswith("//", i):
            while i < len(text) and text[i] != "\n":
                i += 1
            continue
        else:
            out.append(c)
        i += 1
    try:
        return json.loads(re.sub(r",(\s*[}\]])", r"\1", "".join(out)))
    except ValueError as e:
        fail(f"{label} is not JSON with comments and trailing commas: {e}")
        return {}


def colors_of(text):
    return {m.lower() for m in re.findall(r"#[0-9a-fA-F]{6}\b", text)}


def rgb(hex_):
    return tuple(int(hex_[i : i + 2], 16) for i in (1, 3, 5))


def pixels(path, size):
    """(width, height, [(r, g, b, a)] by rows) of the image loaded the way
    Waybar's image module loads it: GdkPixbuf, at size by size."""
    pb = GdkPixbuf.Pixbuf.new_from_file_at_size(path, size, size)
    if not pb.get_has_alpha() or pb.get_n_channels() != 4:
        fail(f"{path} loads without an alpha channel")
        return 0, 0, []
    w, h, stride, data = pb.get_width(), pb.get_height(), pb.get_rowstride(), pb.get_pixels()
    rows = [[tuple(data[y * stride + 4 * x : y * stride + 4 * x + 4]) for x in range(w)] for y in range(h)]
    return w, h, rows


def check_bar(name, v, args):
    accent = v["accent"].lower()
    full = jsonc(v["config"], f"{name}: waybar/config.jsonc")
    focus = jsonc(v["focus"], f"{name}: waybar/config-focus.jsonc")
    modules = jsonc(v["modules"], f"{name}: waybar/modules.jsonc")
    for label, bar in (("full", full), ("focus", focus)):
        left = bar.get("modules-left", [])
        expect(left[:1] == ["image#mark"], f"{name}: the {label} bar does not start with the mark (modules-left is {left})")
        for key in ("modules-center", "modules-right"):
            expect("image#mark" not in bar.get(key, []), f"{name}: the {label} bar has the mark in {key}")
    mark = modules.get("image#mark")
    if not isinstance(mark, dict):
        fail(f"{name}: modules.jsonc does not define image#mark")
        return
    expect(mark.get("size") == 16, f"{name}: the mark in the bar is {mark.get('size')} px, not 16")
    expect(mark.get("tooltip") is False, f"{name}: the mark in the bar has a tooltip")
    # Waybar 0.15's image module re-renders every 1 ms when no interval is
    # given (its "render once" branch cannot be reached), and "once" turns
    # into a duration that overflows when it sleeps. Either keeps Waybar and
    # Sway busy enough that a `swaymsg reload` times out. A number of seconds
    # that fits in nanoseconds is the only safe value.
    interval = mark.get("interval")
    expect(
        isinstance(interval, int) and not isinstance(interval, bool) and 3600 <= interval <= 10**9,
        f"{name}: the mark's interval is {interval!r}, not a whole number of seconds from 3600 to 10^9",
    )
    path = mark.get("path", "")
    expect(path.startswith("/nix/store/"), f"{name}: the mark's path {path!r} is not in the store")
    if not path.startswith("/nix/store/"):
        return
    svg, source = read(path), read(args["svg"])
    text = args["palette"]["text"]
    expect(
        svg == source.replace(text, v["accent"]),
        f"{name}: the bar's mark is not the shipped mark with Text ({text}) made the accent",
    )
    expect(colors_of(svg) == {accent}, f"{name}: the bar's mark has the colors {sorted(colors_of(svg))}, not the accent {accent} alone")

    # As Waybar draws it: at 16 px on a scale of 1, at 32 on a scale of 2.
    for size in (16, 32):
        w, h, rows = pixels(path, size)
        expect((w, h) == (size, size), f"{name}: the bar's mark loads at {w}x{h}, not {size}x{size}")
        # A fifth of the square mostly covered (the mark itself covers about
        # a quarter), and every fully covered pixel in the accent.
        drawn = sum(p[3] >= 128 for row in rows for p in row)
        expect(drawn > size * size // 5, f"{name}: the bar's mark at {size} px covers only {drawn} pixels")
        solid = [p for row in rows for p in row if p[3] == 255]
        others = {p[:3] for p in solid} - {rgb(accent)}
        expect(not others, f"{name}: the bar's mark at {size} px has solid pixels in {sorted(others)}, not the accent")
    # At 32 px the eye is a hole of more than two pixels across.
    _, _, rows = pixels(path, 32)
    ex, ey = ((c - VIEW_X) * 32 / VIEW_SIZE for c in EYE)
    expect(rows[int(ey)][int(ex)][3] < 128, f"{name}: the upper raven's eye is not cut out of the bar's mark")

    css = re.sub(r"/\*.*?\*/", "", read(v["style"]), flags=re.S)
    rule = re.search(r"#image\.mark\s*\{([^}]*)\}", css)
    expect(rule is not None, f"{name}: waybar/style.css has no rule for #image.mark")
    if rule:
        expect(re.search(r"min-width:\s*16px", rule.group(1)), f"{name}: #image.mark has no fixed width of 16 px")
    expect(not re.search(r"#image\.mark[^{,]*:hover", css), f"{name}: the mark in the bar has a hover, but no action")


def greetd_command(exec_start):
    """default_session.command as greetd 0.10 reads it from its config: a
    line-based parser (inish) that takes a field to the end of its line, then
    one quoted string with backslash escapes (enquote). A TOML multi-line
    string, or a quote inside the value that makes the TOML writer pick one,
    stops greetd at the start."""
    m = re.search(r"--config (/nix/store/\S+)", exec_start)
    if not m:
        fail(f"greetd is not started with --config: {exec_start}")
        return ""
    section, command = "", None
    for line in read(m.group(1)).splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("["):
            section = line.strip("[]").strip()
            continue
        if "=" not in line:
            fail(f"greetd's config has a line without an equals sign, which greetd refuses: {line[:60]!r}")
            continue
        key, value = (x.strip() for x in line.split("=", 1))
        if section == "default_session" and key == "command":
            command = value
    if command is None:
        fail("greetd's config has no default_session.command")
        return ""
    if not re.fullmatch(r'"(?:[^"\\]|\\.)*"', command):
        fail(f"greetd cannot unquote default_session.command: {command[:60]!r}")
        return ""
    return json.loads(command)


def check_greeter(name, v, art):
    command = greetd_command(v["greetd"])
    expect(command == v["greeter"], f"{name}: greetd reads a command other than the one the module sets")
    words = shlex.split(command)
    # greetd runs the command with sh -c and cannot hold the art's newlines,
    # so the first word is a wrapper that reads the art from a file and runs
    # tuigreet with it.
    wrapper = read(words[0]) if words and words[0].startswith("/nix/store/") else ""
    m = re.search(r'^exec (/nix/store/\S+/bin/tuigreet) --greeting "\$\(< (/nix/store/\S+)\)" "\$@"$', wrapper, re.M)
    expect(m is not None, f"{name}: the greeter's command does not run tuigreet with the art as --greeting")
    if m:
        greeting = read(m.group(2)).removesuffix("\n")
        width = max(len(line) for line in art)
        expect(
            greeting == "\n".join(line.ljust(width) for line in art),
            f"{name}: tuigreet's greeting is not the art of assets/ravnix-mark.txt, each line padded to {width}",
        )
    theme = words[words.index("--theme") + 1] if "--theme" in words else ""
    pairs = dict(kv.split("=", 1) for kv in theme.split(";") if "=" in kv)
    expect(pairs.get("greet") == "13", f"{name}: the greeting is color {pairs.get('greet')}, not the accent (13)")


def main():
    args = json.loads(read(sys.argv[1]))

    # The art: what mark-art.py makes of the shipped mark now, in a shape the
    # console and tuigreet show as it is.
    art = read(args["art"]).split("\n")
    expect(art[-1] == "", "assets/ravnix-mark.txt does not end in a newline")
    art = art[:-1] if art[-1] == "" else art
    fresh = read(args["fresh"]).split("\n")[:-1]
    if art != fresh:
        fail("assets/ravnix-mark.txt is not what mark-art.py makes of assets/ravnix-mark.svg; it makes:\n" + "\n".join(fresh))
    expect(10 <= len(art) <= 16, f"the art has {len(art)} rows, not 10 to 16")
    expect(0 < max(map(len, art), default=0) <= GREETING_WIDTH, f"the art is {max(map(len, art), default=0)} columns wide, not 1 to {GREETING_WIDTH}")
    for n, line in enumerate(art, 1):
        expect(set(line) <= CELLS, f"line {n} of the art has {sorted(set(line) - CELLS)}, which the console font may lack")
        # tuigreet's wrapper turns a line of spaces alone into two lines.
        expect(line.strip(" "), f"line {n} of the art is blank")
        expect(not line.endswith(" "), f"line {n} of the art ends in a space")

    for name, v in args["variants"].items():
        check_bar(name, v, args)
        check_greeter(name, v, art)
    teal, mauve = args["variants"]["teal"], args["variants"]["mauve"]
    expect(teal["accent"] != mauve["accent"], "the two variants have the same accent")

    for f in failures:
        print(f, file=sys.stderr)
    print(f"{len(failures)} failed" if failures else "the mark is in the bar and on the login screen")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
