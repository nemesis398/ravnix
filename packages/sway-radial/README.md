# sway-radial

A radial menu for Sway, opened with a four-finger pinch on the trackpad,
navigated by direction while the fingers stay down, and chosen by holding still
on a sector. It exists so the machine can be driven without a keyboard: on the
couch, standing, one-handed. It deliberately does not duplicate anything the
other `bindgesture` lines of the Sway config already do.

`sway-radial` is Python (GTK 4 and gtk4-layer-shell through PyGObject, cairo,
and libinput through ctypes), carried over from the Fedora laptop where it was
written, and it stays Python until its port (Phase 13). It has its own daemon:
it reads the trackpad through a libinput context of its own, so Sway only has to
keep applications from taking the pinch (`bindgesture pinch:4 nop` in
`modules/desktop/sway/50-laptop.conf`).

`modules/desktop/sway-radial.nix` runs it as a user service of the Sway session
and writes the two files it reads. `packages/sway-radial/default.nix` builds it.

## How it is used

| Input | Does |
| --- | --- |
| four-finger pinch | opens the ring with one sector lit; closing the fingers past 85 percent arms it, and until then nothing can be chosen |
| move the fingers | lights the sector in that direction; a sector you cross on the way never opens |
| hold still on a lit sector | after `dwell_ms` (one second by default) a submenu opens, a leaf runs, or Back pops one level; an arc fills while it counts |
| spread the fingers back out | runs the lit leaf, or opens the lit submenu and keeps the ring for the pointer; with nothing under the fingers it closes |
| let go without spreading | keeps the ring on screen for the pointer (latched) |
| hold still in the middle | closes the menu without running anything, at any depth |
| `SIGUSR1` | opens the ring for the pointer, latched: click a sector; Esc or mouse button 8 goes back (Esc closes at the top ring); a second signal closes it. `sway-mouse` sends it from the MX Master's gesture button |

Back is always the south sector of a submenu. The top ring has no parent and
uses all eight directions. `--config PATH` names another menu file and `-v`
logs every gesture event.

## The two files

| File | Holds | Comes from |
| --- | --- | --- |
| `~/.config/sway-radial/menu.toml` | the menu: eight directions per ring, each a submenu or a leaf that runs a `.desktop` file (through `gtk-launch`) or a command (through `swaymsg exec`) | `ravnix.desktop.radial.menu`, else `menu.toml` in this directory |
| `$SWAY_RADIAL_THEME`, else `~/.config/sway-radial/theme.json` | the colors (eight roles of the theme module), the font and the two line widths | the unit, from `config.ravnix.theme` |

The default menu, `menu.toml` here, is built only from commands that ravnix's
Sway config runs itself and from applications the desktop module installs, and
holds nothing that belongs to one machine. A menu of your own is the place for
what does: a sink name, a display profile, an app of yours. Copy this file and
edit it; its header explains the rules and the loader names the file, the menu
and the direction of every mistake.

A menu file that is missing or wrong never leaves the program without a menu:
at start the packaged default takes over (`lib/sway-radial/menu.toml`, found
next to the package), and on a reload the menu already in use stays. A theme
file that is missing or wrong leaves a grayscale ring and one error line.

## What ravnix changed

The original is the `sway-radial` repository at its commit `4c76438`. Its
behavior is unchanged except for the following.

- **Opaque, and no fade.** The ring was drawn at alpha 0.92 and faded in and out
  over 80 ms; `docs/style.md` has no transparency and no motion, and its table
  of differences from the Fedora configs says "opaque, no fade; the round ring
  stays". Every wedge, line and the hub are opaque now, and the ring appears
  and disappears at once. The layer surface around the ring is clear: it covers
  the output and has nothing drawn on it.
- **Colors from the roles.** `theme.py` held Catppuccin Mocha with a fixed
  Mauve. It now reads `theme.json` (above), so the user's accent reaches the lit
  sector, the font is the theme's, and the line between sectors and the
  countdown arc are the theme's frame (1 px) and marker (2 px) widths; the arc
  was 3 px. No color is written in the program.
- **The menu is a file of the user's.** The original `menu.toml` was the author's
  own menu and held their paths, their sink names and their apps. It is not
  here. The default menu is a generic one, and a user's goes through the option.
- **The three libraries opened by name** (libinput, libudev, gtk4-layer-shell)
  are opened by store path in the installed copy (`default.nix` patches the
  three strings), instead of through a `LD_LIBRARY_PATH` that every program the
  menu starts would inherit.
- **Three findings fixed**, found by the new tests of malformed menu files: a
  menu file that is not UTF-8 text, and one nested a few hundred levels deep,
  raised an exception out of the loader and stopped the daemon at start instead
  of falling back to the packaged menu; and a menu with an empty top ring was
  accepted, which opens eight empty sectors and does nothing.
- **Comments and tests** no longer name the author, a host, a tree of dotfiles
  or a directory of a machine.

## Style exceptions

Both are listed in the module that installs it (`modules/desktop/sway-radial.nix`),
as `docs/style.md` rule 9 asks: the ring is round, as the style spec says it
stays, and the countdown arc moves while the fingers hold still, because it is a
gauge of the time that has passed and the only sign that holding is doing
something.

## Left out of the vendored tree

The source repository holds more than the package needs. Not copied: `docs/plans/`
(the implementation plan, with the author's notes), `docs/reference/libinput-abi.md`
(how the ABI numbers were read on the Fedora laptop; `tests/test_libinput_abi.py`
now compares them with `libinput.h` itself), `deploy` (copied the program into a
Stow package), `sway-radial.service` (the Fedora unit; the module writes the
new one), the repository's own `check-public.sh`, `README.md` (this file
replaces it), and `.gitignore`.

## Tests

`pytest` runs from this directory with `src` on the `PYTHONPATH`, and in the Nix
sandbox as the check `desktop-sway-radial` (`tests/desktop/sway-radial.nix`),
against the installed copy:

```sh
nix build .#checks.x86_64-linux.desktop-sway-radial
```

| Marker | Deselected by default because | Run it |
| --- | --- | --- |
| `font` | needs JetBrainsMono Nerd Font; measures every label and icon of the menu (the check sets this up) | `pytest -m font` |
| `hardware` | needs the real trackpad and the udev rule | `pytest -m hardware tests/smoke` |
| `compositor` | needs a running Sway session | `pytest -m compositor tests/smoke` |
| `machine` | needs the applications of the menu installed | `pytest -m machine` |

The check runs everything except `hardware`, `compositor` and `machine`.
`SWAY_RADIAL_TEST_MENU=/path/menu.toml` points the menu tests (the default-menu
tests and the font tests) at a menu of your own. Three more variables are the
Nix check's: `SWAY_RADIAL_TEST_PROGRAMS` and `SWAY_RADIAL_TEST_DESKTOP_IDS` (the
commands and `.desktop` ids the menu may name) and `SWAY_RADIAL_TEST_LIBINPUT_H`
(libinput's header); a test that needs one is skipped without it.

## Findings that are not fixed

- A `desktop` item whose `.desktop` id does not resolve is drawn dim and still
  runs `gtk-launch`, which fails with a log line. That is by design (hiding it
  would move every other item), but a typo in an id is easy to miss; the
  `machine` test `test_every_desktop_id_resolves_on_this_machine` finds it on
  the machine that has the apps.
- The menu is read once per change and parsed whole. A file of millions of lines
  is read before it is refused or accepted (a megabyte of comments loads in well
  under a second).
- `Daemon.run`, the layer surface and the input region need a compositor and
  GTK's main loop, so the sandbox check does not cover them. The VM stage of
  `desktop-sway` starts the service, opens the ring with `SIGUSR1` and looks at
  the pixels; the `compositor` tests (`tests/smoke`) read the layer-shell
  configuration back on a live session.
