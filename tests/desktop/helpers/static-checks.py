#!/usr/bin/env python3
"""The static half of the desktop-sway check: what the generated files say.

    static-checks.py ARGS.json

ARGS.json names the generated files of two evaluations of the desktop module,
one with the default accent and one with Teal, the palette and the roles, and
the expected values of the options. Every failed expectation is printed on
stderr, one line each, and the exit status is 1 if there was any.

The rows of the style spec's table that belong to this module are checked
here, each named in its message, so that a regression says which row broke.
"""
import ast
import json
import re
import sys
from pathlib import Path

failures = []


def fail(message):
    failures.append(message)


def read(path):
    return Path(path).read_text()


def expect(condition, message):
    if not condition:
        fail(message)


def strip_jsonc(text):
    """Waybar's own parser takes comments and trailing commas; json does not."""
    out = []
    in_string = False
    escaped = False
    i = 0
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
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))


def jsonc(path, label):
    try:
        return json.loads(strip_jsonc(read(path)))
    except ValueError as e:
        fail(f"{label} is not JSON with comments and trailing commas: {e}")
        return {}


def colors_of(text):
    """The hex colors a file writes: #rrggbb[aa], and bare values of color keys."""
    found = set(m.lower() for m in re.findall(r"#([0-9a-fA-F]{6})(?:[0-9a-fA-F]{2})?\b", text))
    for m in re.finditer(r"^[a-z-]*(?:color|background|text|prompt|input|placeholder|counter|match|selection|selection-text|selection-match|border)=([0-9a-fA-F]{6})(?:[0-9a-fA-F]{2})?$", text, re.M):
        found.add(m.group(1).lower())
    return found


def main():
    args = json.load(open(sys.argv[1]))
    palette = args["palette"]
    palette_hex = {v.lstrip("#").lower() for v in palette.values()}
    roles = args["roles"]

    for variant, v in args["variants"].items():
        accent = roles[variant]["accent"]
        accent_hex = accent.lstrip("#").lower()
        label = lambda what: f"{variant}: {what}"  # noqa: E731

        sway = read(v["sway"])
        laptop = read(v["swayLaptop"])
        swaynag = read(v["swaynag"])
        swaylock = read(v["swaylock"])
        css_raw = read(v["waybarStyle"])
        css = re.sub(r"/\*.*?\*/", "", css_raw, flags=re.S)
        modules = read(v["waybarModules"])
        config = jsonc(v["waybarConfig"], label("waybar/config.jsonc"))
        focus = jsonc(v["waybarFocus"], label("waybar/config-focus.jsonc"))
        modules_json = jsonc(v["waybarModules"], label("waybar/modules.jsonc"))
        scripts = {name: read(path) for name, path in v["scripts"].items()}
        kanshi = read(v["kanshi"])
        fuzzel = read(v["fuzzel"])
        dunst = read(v["dunst"])

        # Every color of every generated file is one of the palette, and the
        # accent is the one of the option.
        everything = {
            "sway/config": sway,
            "sway/config.d/50-laptop.conf": laptop,
            "swaynag/config": swaynag,
            "swaylock/config": swaylock,
            "waybar/style.css": css,
            "waybar/modules.jsonc": modules,
            "kanshi/config": kanshi,
            "fuzzel/fuzzel.ini": fuzzel,
            "dunst/dunstrc": dunst,
        }
        for name, text in scripts.items():
            everything[f"bin/{name}"] = text
        for name, text in everything.items():
            for color in colors_of(text) - palette_hex:
                fail(label(f"{name} writes #{color}, which is no color of the palette"))

        # ── Sway ─────────────────────────────────────────────────────────
        for name, hex_ in palette.items():
            expect(re.search(rf"^set \${name} {re.escape(hex_)}$", sway, re.M), label(f"sway/config does not set ${name} to {hex_}"))
        expect(re.search(rf"^set \$accent {re.escape(accent)}$", sway, re.M), label(f"sway/config does not set $accent to {accent}"))
        # The cursor: home-manager's, which is the one source (its theme and size
        # reach the processes through hm-session-vars.sh, and Sway's own seat
        # setting is the same pair).
        cursor = v["cursor"]
        expect(
            re.search(rf"^seat \* xcursor_theme {re.escape(cursor['name'])} {cursor['size']}$", sway, re.M),
            label(f"sway/config does not take `seat * xcursor_theme` from home.pointerCursor ({cursor['name']} {cursor['size']})"),
        )
        expect(cursor["name"] == f"catppuccin-mocha-{variant}-cursors", label(f"home.pointerCursor.name is {cursor['name']}, not the Catppuccin cursor of the accent"))
        expect(re.search(r"^default_floating_border pixel 1$", sway, re.M), label("row Borders: sway/config lacks `default_floating_border pixel 1`"))
        expect(re.search(r"^default_border none$", sway, re.M), label("row Borders: tiled windows have a border"))
        expect(re.search(r"^client\.focused\s+\$accent\s+\$accent\s", sway, re.M), label("row Accent: the focused floating window is not framed in $accent"))
        expect(not re.search(r"^\s*opacity|\bopacity\s", re.sub(r"^\s*#.*$", "", sway, flags=re.M)), label("row Transparency: sway/config sets an opacity"))
        expect(not re.search(r"^\s*(corner_radius|blur|shadows)\s+(?!off|disable)", sway, re.M), label("row Corners: sway/config rounds, blurs or shadows"))
        # Colors only in the palette block: every other line uses a variable.
        for n, line in enumerate(sway.splitlines(), 1):
            if re.search(r"#[0-9a-fA-F]{6}\b", line) and not re.match(r"(set \$\w+ #|\s*#)", line):
                fail(label(f"sway/config line {n} writes a hex color outside the palette block: {line.strip()}"))
        expect(not re.search(r"^\s*(?!#)\S.*\b(cardN|card[0-9])\b", sway, re.M), label("sway/config names a cardN device"))
        expect(re.search(r"^workspace 2 output \"Example Corp Monitor 0x00000000\" \"eDP-1\"$", sway, re.M), label("sway/config lacks the workspace output of ravnix.desktop.workspaceOutputs"))
        expect(re.search(r"^set \$work ghostty$", sway, re.M), label("the main terminal key is not the local terminal by default"))
        expect(re.search(r"^bindsym \$mod\+Return\s+exec \$work$", sway, re.M), label("$mod+Return does not use the seam variable $work"))
        expect(re.search(r"^bindsym \$mod\+Alt\+Return\s+exec \$plain$", sway, re.M), label("$mod+Alt+Return does not use $plain"))
        expect(re.search(r"^bindsym \$mod\+Shift\+a\s+exec \$ask$", sway, re.M), label("$mod+Shift+a does not run the AI popup"))
        expect(re.search(r"^include /etc/sway/config\.d/\*$", sway, re.M), label("sway/config does not include the NixOS session integration"))
        expect(re.search(r"^include ~/\.config/sway/config\.d/\*\.conf$", sway, re.M), label("sway/config does not include config.d"))
        expect(re.search(r"^exec_always waybar-launch$", sway, re.M), label("sway/config does not start Waybar"))
        for key in ("mail", "matrix", "vaultwarden", "thunar", "pavucontrol", "blueman"):
            expect(not re.search(rf"^[^#\n]*\b{key}\b", sway, re.M | re.I), label(f"sway/config still mentions {key}, which the design drops"))
        # The four-finger pinch stays bound, and sway-radial is not needed.
        expect(re.search(r"^bindgesture pinch:4 nop$", laptop, re.M), label("50-laptop.conf lost the four-finger pinch bind"))
        expect(re.search(r"^bindgesture hold:4\s+kill$", laptop, re.M), label("50-laptop.conf lost the four-finger hold"))
        for line in (sway + laptop).splitlines():
            if "sway-radial" in line and not line.lstrip().startswith("#"):
                fail(label(f"the Sway config needs sway-radial at runtime: {line.strip()}"))
        # swaynag: themed from the roles.
        expect(f"background={roles[variant]['canvas'].lstrip('#')}" in swaynag, label("swaynag/config is not Base"))
        expect(f"border={accent_hex}" in swaynag, label("swaynag/config has no accent frame"))
        expect(f"text={roles[variant]['text'].lstrip('#')}" in swaynag, label("swaynag/config text is not Text"))
        expect("[warning]" in swaynag and f"border={palette['peach'].lstrip('#')}" in swaynag, label("swaynag warnings are not Peach"))
        expect("[error]" in swaynag and f"border={palette['red'].lstrip('#')}" in swaynag, label("swaynag errors are not Red"))
        expect("JetBrainsMono Nerd Font" in swaynag, label("swaynag/config has no font"))

        # ── Waybar ───────────────────────────────────────────────────────
        expect(config.get("height") == 32 and focus.get("height") == 32, label("row Bar height: the full and the focus bar are not both 32 px"))
        expect(config.get("spacing") == 2 and focus.get("spacing") == 2, label("row Bar height: the focus bar's spacing is not the full bar's (2)"))
        expect("sway/workspaces" in sum((config.get(k, []) for k in ("modules-left", "modules-center", "modules-right")), []), label("the full bar lacks the workspaces"))
        expect("sway/workspaces" not in sum((focus.get(k, []) for k in ("modules-left", "modules-center", "modules-right")), []), label("the focus bar has the workspaces"))
        expect(focus.get("modules-right") == [], label("the focus bar has a right cluster"))
        defined = set(modules_json)
        builtin = {"sway/workspaces", "sway/mode", "sway/window", "tray"}
        for bar_name, bar in (("config.jsonc", config), ("config-focus.jsonc", focus)):
            for key in ("modules-left", "modules-center", "modules-right"):
                for module in bar.get(key, []):
                    expect(module in defined, label(f"waybar/{bar_name} lists {module}, which modules.jsonc does not define"))
            expect(bar.get("include") == ["~/.config/waybar/modules.jsonc"], label(f"waybar/{bar_name} does not include modules.jsonc"))
        for name, module in modules_json.items():
            if isinstance(module, dict) and module.get("exec"):
                exe = module["exec"].split()[0]
                expect(exe in scripts or exe == "keep-awake", label(f"modules.jsonc runs {exe} for {name}, which this module does not provide"))
        expect(f"color='{accent}'" in modules, label("modules.jsonc has no Pango span in the accent"))
        for line in modules.splitlines():
            if "color='#" in line and f"color='{accent}'" not in line and f"color='{palette['red']}'" not in line and f"color='{palette['overlay0']}'" not in line:
                fail(label(f"modules.jsonc has a span in a color that is neither the accent, Red nor Overlay0: {line.strip()}"))
        expect(f"@define-color accent {accent};" in css, label("waybar/style.css does not define the accent"))
        for name, hex_ in palette.items():
            expect(f"@define-color {name} {hex_};" in css, label(f"waybar/style.css does not define {name}"))
        expect(not re.search(r"alpha\(|rgba\(|transparent|opacity|transition|animation|keyframes", css), label("row Transparency/Motion: waybar/style.css has alpha(), rgba(), transparent, opacity, a transition or an animation"))
        expect(not re.search(r"border-radius:\s*[1-9]", css), label("row Corners: waybar/style.css rounds a corner"))
        hover = re.findall(r"([^{}]*:hover[^{}]*)\{([^{}]*)\}", css)
        expect(len(hover) >= 2, label("waybar/style.css has no hover rules"))
        for selector, body in hover:
            if "workspaces" in selector and ("focused" in selector or "urgent" in selector):
                continue
            expect("background: @surface0;" in body, label(f"row Hover: `{selector.strip()[:50]}` is not the Surface0 wash"))
            expect("border-bottom: 2px solid @accent;" in body, label(f"row Hover: `{selector.strip()[:50]}` has no 2 px accent underline"))
        expect("padding: 0 4px;" in css and "border-bottom: 2px solid @mantle;" in css, label("the hover marker space is not reserved up front"))
        for placeholder in re.findall(r"@w\.[a-z]+@", css):
            fail(label(f"waybar/style.css still has {placeholder}"))
        floors = {}
        for selectors, body in re.findall(r"([^{}]+)\{([^{}]*)\}", css):
            floor = re.search(r"min-width:\s*(\d+)px", body)
            if floor:
                for ident in re.findall(r"#([A-Za-z0-9-]+)", selectors):
                    floors[ident] = int(floor.group(1))
        for needed in ("custom-powerdraw", "custom-peripherals", "window", "network", "custom-clock", "pulseaudio", "custom-battery", "temperature"):
            expect(needed in floors, label(f"row Fixed widths: {needed} has no min-width"))
        expect(re.search(r"\"max-length\":\s*28", modules) and "sway/window" in modules, label("row Fixed widths: the window title is not truncated"))
        expect(f"window#waybar {{\n  background: @mantle;" in css, label("row Surfaces: the bar is not Mantle"))

        # ── swaylock ─────────────────────────────────────────────────────
        expect(re.search(r"^indicator-idle-visible$", swaylock, re.M), label("row Lock screen: swaylock does not set indicator-idle-visible"))
        peach = palette["peach"].lstrip("#")
        expect(f"ring-caps-lock-color={peach}" in swaylock, label("swaylock ring-caps-lock-color is not Peach"))
        expect(f"line-caps-lock-color={peach}" in swaylock, label("swaylock line-caps-lock-color is not Peach"))
        expect(f"key-hl-color={accent_hex}" in swaylock, label("swaylock key-hl-color is not the accent"))
        expect("ignore-empty-password" not in swaylock, label("swaylock ignores an empty password, which the security key needs"))
        expect(re.search(r"^indicator-thickness=10$", swaylock, re.M), label("swaylock ring thickness changed"))
        for m in re.finditer(r"^([a-z-]+)=([0-9a-f]{8})$", swaylock, re.M):
            key, value = m.groups()
            if value[6:] != "ff":
                expect(re.fullmatch(r"inside(-[a-z-]+)?-color", key) is not None, label(f"row Transparency: swaylock {key} is translucent; only the inside of the ring may be"))

        # ── fuzzel ───────────────────────────────────────────────────────
        expect(f"border={accent_hex}ff" in fuzzel and f"match={accent_hex}ff" in fuzzel, label("fuzzel does not use the accent for its frame and matches"))
        expect(f"background={roles[variant]['canvas'].lstrip('#')}ff" in fuzzel, label("row Transparency: fuzzel's background is not opaque Base"))
        expect("radius=0" in fuzzel and "width=1" in fuzzel, label("fuzzel is not square with a 1 px frame"))

        # ── dunst ────────────────────────────────────────────────────────
        expect(f'frame_color="{accent}"' in dunst, label("dunst frame is not the accent"))
        expect(f'frame_color="{palette["peach"]}"' in dunst, label("a critical notification is not Peach"))
        expect("frame_width=1" in dunst, label("row Borders: dunst's frame is not 1 px"))
        for pin in (
            "origin=\"top-right\"", "offset=\"(10, 50)\"", "width=300", "height=\"(0, 300)\"",
            "padding=8", "horizontal_padding=8", "text_icon_padding=0", "gap_size=0",
            "separator_height=1", "corner_radius=0", "transparency=0", "notification_limit=20",
            "progress_bar_height=10", "progress_bar_min_width=150", "progress_bar_max_width=300",
        ):
            expect(re.search(rf"^{re.escape(pin)}$", dunst, re.M), label(f"dunst geometry is not pinned: {pin}"))

        # ── kanshi ───────────────────────────────────────────────────────
        names = re.findall(r"^profile (\S+) \{$", kanshi, re.M)
        expect(names == args["kanshiProfiles"] + ["ravnix-fallback"], label(f"kanshi profiles are {names}, expected {args['kanshiProfiles']} and the fallback last"))
        expect("...output * enable" in kanshi, label("kanshi has no wildcard fallback"))
        expect(len(re.findall(r"^\s+exec /nix/store/\S+-kanshi-exec$", kanshi, re.M)) == len(names), label("a kanshi profile lacks the exec hook"))
        expect(not re.search(r"\b(eDP-[0-9]|card[0-9])\b.*\bcard", kanshi), label("kanshi names a cardN"))
        expect('output "Example Corp Monitor 0x00000000" mode 2560x1440@60Hz position 0,0 scale 1' in kanshi, label("kanshi lost the quoted description criteria or the scale spelling"))

    # ── things the variants share ─────────────────────────────────────────
    t = args["teal"]
    for name, path in args["variants"]["teal"]["scripts"].items():
        text = read(path)
        if "<span" in text:
            expect(f"color='{t['accent']}'" in text and f"color='{args['roles']['mauve']['accent']}'" not in text, f"teal: bin/{name} does not tint its icon with the accent of the option")

    g = args["greeter"]
    expect("tuigreet" in g["command"], "greetd does not run tuigreet")
    expect(g["plymouth"] is False, "Plymouth is on")
    expect(g["user"] == "greeter", "greeter user")
    expect(len(g["colors"]) == 16, "console.colors has not 16 entries")
    r = args["roles"]["mauve"]
    p = palette
    expected = [r["canvas"], p["red"], p["green"], p["yellow"], p["blue"], p["pink"], p["teal"], r["text"], r["muted"], p["red"], p["green"], p["yellow"], p["blue"], r["accent"], p["teal"], r["label"]]
    expect(g["colors"] == [e.lstrip("#") for e in expected], f"console.colors is not the palette the theme names: {g['colors']}")
    theme = re.search(r"--theme '([^']+)'", g["command"])
    expect(theme is not None, "tuigreet has no --theme")
    if theme:
        pairs = dict(kv.split("=") for kv in theme.group(1).split(";"))
        for key in ("container", "text", "time", "border", "title", "greet", "prompt", "input", "action", "button"):
            expect(key in pairs, f"the tuigreet theme lacks {key}")
        for key, value in pairs.items():
            expect(value.isdigit() and 0 <= int(value) <= 15, f"the tuigreet theme names {key} by {value}, not by a palette index")
        expect(pairs.get("border") == "13" and pairs.get("prompt") == "13", "tuigreet's frame and prompt are not the accent (index 13)")
        expect(pairs.get("container") == "0", "tuigreet's screen is not Base (index 0)")

    # The address of the Open WebUI reaches sway-ask as Python literals. A value
    # with quotes and a backslash (the option's type takes them) must stay
    # inside them: the script parses, the constants are the values, and
    # nothing calls os.system.
    inj = args["askInjection"]
    try:
        tree = ast.parse(read(inj["script"]))
    except SyntaxError as e:
        fail(f"sway-ask does not parse with a quote and a backslash in ask.url: {e}")
    else:
        constants = {}
        for node in tree.body:
            if isinstance(node, ast.Assign) and len(node.targets) == 1 and isinstance(node.targets[0], ast.Name) and node.targets[0].id in ("BASE_URL", "MODEL", "RBW_ITEM", "WEBAPP_PREFIX"):
                if isinstance(node.value, ast.Constant) and isinstance(node.value.value, str):
                    constants[node.targets[0].id] = node.value.value
                else:
                    fail(f"sway-ask: {node.targets[0].id} is not one plain string literal")
        expect(constants.get("BASE_URL") == inj["url"], f"sway-ask: BASE_URL is {constants.get('BASE_URL')!r}, not the address {inj['url']!r}")
        expect(constants.get("WEBAPP_PREFIX") == f"chrome-{inj['host']}__", f"sway-ask: WEBAPP_PREFIX is {constants.get('WEBAPP_PREFIX')!r}")
        expect(not any(isinstance(n, ast.Attribute) and n.attr == "system" for n in ast.walk(tree)), "sway-ask runs os.system: the address ended its string and added a statement")

    # A user who changes the cursor in home-manager gets it in Sway's seat too.
    big = args["bigCursor"]
    expect(
        re.search(rf"^seat \* xcursor_theme {re.escape(big['name'])} {big['size']}$", read(big["sway"]), re.M),
        f"home.pointerCursor is {big['name']} {big['size']}, and sway/config does not follow it",
    )
    # The session sets no cursor variable of its own: home-manager's file does.
    for name, session in (("the default host", args["noGpuSession"]), ("huginn", args["huginn"]["session"])):
        expect(not re.search(r"^\s*(export\s+)?XCURSOR_\w+=", session, re.M), f"{name}: the session's own commands set XCURSOR_*, a second source next to home-manager's")

    # The GPU seam, in the host that sets it.
    gpu = args["gpu"]
    expect("WLR_DRM_DEVICES=/dev/dri/primary-gpu" in gpu["session"], "gpu.primary does not set WLR_DRM_DEVICES to the stable path")
    expect(not re.search(r"card[0-9]|by-path", gpu["session"] + gpu["udev"]), "the GPU is named by cardN or by path")
    expect('KERNELS=="0000:36:00.0"' in gpu["udev"] and "SYMLINK+=\"dri/primary-gpu\"" in gpu["udev"], "the udev rule does not match the PCI address and link it")
    expect("WLR_DRM_DEVICES" not in args["noGpuSession"], "WLR_DRM_DEVICES is set without gpu.primary")
    # wlroots (and Aquamarine) split these variables at every colon, so a value
    # with one is torn apart, no GPU is found and the screen stays black.
    expect(re.search(r"^export WLR_DRM_DEVICES=\S+$", gpu["session"], re.M), "WLR_DRM_DEVICES is not exported as one word")
    for var in ("WLR_DRM_DEVICES", "AQ_DRM_DEVICES"):
        for value in re.findall(rf"{var}=(\S*)", gpu["session"]):
            expect(":" not in value, f"{var}={value} has a colon, which wlroots splits the list at")
            expect(value.startswith("/dev/dri/") and "by-path" not in value, f"{var}={value} is not a colon-free udev link below /dev/dri")

    # huginn: the laptop shape and the 16AHP9 module, and nobody sets the
    # address. The iGPU's PRIME bus id (PCI:54:0:0) becomes the link, so Sway
    # renders on the 780M alone and the RTX 4050 can power off.
    huginn = args["huginn"]
    expect(huginn["primary"] == "0000:36:00.0", f"huginn: gpu.primary is {huginn['primary']}, not the 780M (0000:36:00.0)")
    expect(re.search(r"^export WLR_DRM_DEVICES=/dev/dri/primary-gpu$", huginn["session"], re.M), "huginn: the session does not export WLR_DRM_DEVICES=/dev/dri/primary-gpu")
    expect(not re.search(r"WLR_DRM_DEVICES=\S*:", huginn["session"]), "huginn: WLR_DRM_DEVICES has a colon")
    expect('KERNELS=="0000:36:00.0"' in huginn["udev"] and 'SYMLINK+="dri/primary-gpu"' in huginn["udev"], "huginn: the udev rule does not link the card at 0000:36:00.0")
    expect(huginn["extraOptions"] == ["--unsupported-gpu"], f"huginn: Sway is started with {huginn['extraOptions']}, not --unsupported-gpu")
    expect(huginn["warnings"] == [], f"huginn: a GPU warning is shown: {huginn['warnings']}")

    # The commands that other tasks call by name (energy runs keep-awake and
    # waybar-launch, the keys run the rest) are in the system profile.
    for command in ("keep-awake", "waybar-launch", "waybar-mode", "ghostty-float", "sway-volume", "sway-wait-sni", "output-wake"):
        expect(command in args["installed"], f"{command} is not installed in the system profile, so not on the session's PATH")

    # Without ravnix.desktop.ask there is no popup, no launcher entry, and the key is free.
    ask = args["ask"]
    expect("sway-ask" in ask["entriesOn"], "ravnix.desktop.ask is set and the launcher has no AI Chat entry")
    expect("sway-ask" not in ask["entriesOff"], "ravnix.desktop.ask is null and the launcher still lists AI Chat")
    expect("sway-ask" not in ask["installedOff"], "ravnix.desktop.ask is null and sway-ask is still installed")
    off = read(ask["swayOff"])
    expect(not re.search(r"^\s*bindsym\s+\$mod\+Shift\+a\b", off, re.M), "ravnix.desktop.ask is null and $mod+Shift+a is still bound")
    expect("# $mod+Shift+a is free" in off, "ravnix.desktop.ask is null and the config does not say the key is free")
    expect(not re.search(r"exec\s+\$ask\b", off), "ravnix.desktop.ask is null and something still runs $ask")
    expect(not re.search(r"@[a-z][A-Za-z0-9.]*@", off), "ravnix.desktop.ask is null and a token is left in the config")

    if failures:
        for f in failures:
            print("FAIL " + f, file=sys.stderr)
        print(f"{len(failures)} expectations failed", file=sys.stderr)
        sys.exit(1)
    print("static checks passed")


main()
