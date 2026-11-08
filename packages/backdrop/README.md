# backdrop

The wallpaper and the lock image of the desktop, and the lock command that
uses the second. `backdrop` is Python (cairo, Pango and librsvg through
PyGObject), carried over from the Fedora laptop and reworked; it stays Python
until the Odin port of the `bin-*` scripts (Phase 13). Both commands keep the
names they have on Fedora, because every kanshi profile and the lock binding
call them by name.

| Command | Does |
| --- | --- |
| `backdrop wallpaper` | draws the wallpaper of every active output, hands it to sway (`swaymsg output NAME bg PATH fill`), and makes sure each output has its lock image cached |
| `backdrop lock-args` | prints swaylock's `-i OUTPUT:PATH` arguments, one per line, rendering a lock image first when its cache key changed; also names the outputs seen before that are not connected now, so a monitor docked while locked gets its image |
| `backdrop render KIND OUT.png WxH SCALE` | one image to a file (`KIND` is `wall` or `lock`), for looking at a layout without touching the session; `WxH` is the physical size |
| `lock-screen` | `swaylock -f` over the images `lock-args` names, then, once unlocked, `backdrop wallpaper` once more |

`modules/desktop/backdrop.nix` installs the package into the user's profile and
writes the config. kanshi runs `backdrop wallpaper` at login, on every sway
reload and on every dock or undock.

## What is drawn

Sizes are logical pixels times the output scale, and the images are drawn at the
physical resolution (the lock ring's radius is logical too).

| Image | Holds |
| --- | --- |
| wallpaper | Base, or the user's own picture scaled until it covers the output and cropped at the middle. On it: the ravnix mark in the middle and the phyllon mark in the top left corner, at the same size and both in the accent; the NixOS logo in Blue and Sapphire with the system facts, drawn through fastfetch, in the top right; and the user's tool logos, if any, in Surface1 and Surface2 alternately, spread evenly around the rest |
| lock image | Base, or the same picture, and the ravnix mark alone, sized to sit inside the 110 px lock ring (its inner edge is at 105 px). It never runs fastfetch and never draws a logo, so nothing about the machine can be read on a locked screen |

The ravnix mark is the wordmark `ravnix` in the theme's font, bold, until Task
12.2 ships the mark. From then on `assets/ravnix-mark.svg` is drawn instead,
in one color whatever its own fills say, in the square the phyllon mark has. Both
marks reach 95 px from their center.

## The config

One JSON file, `$BACKDROP_CONFIG` or `~/.config/backdrop/config.json`, which the
module writes from the theme and from `ravnix.desktop.backdrop.image` and
`.tools`. No color is written in the script: the palette, the accent and the
font come from it.

| Key | Is |
| --- | --- |
| `palette` | the Catppuccin Mocha colors by name |
| `accent` | the name of the accent in the palette |
| `font` | the family of the facts and the wordmark |
| `image` | the user's picture (an absolute path) or `null` |
| `tools` | SVG logos, in order, or `[]` |

A config that cannot be read, is not valid, or lacks a color fails the command
with one line that says what. `lock-screen` then locks on plain Base.

## Seams

| Seam | For |
| --- | --- |
| `BACKDROP_CONFIG` | the config file |
| `BACKDROP_ASSETS` | the directory of the marks (the package sets it; from a checkout it is `assets/`) |
| `BACKDROP_FACTS` | a file holding what fastfetch prints, drawn instead of running fastfetch |
| `BACKDROP_FASTFETCH_SECONDS` | how long fastfetch gets, 10 by default |
| `XDG_CACHE_HOME` | where `backdrop/` keeps the images |

Without `BACKDROP_FACTS`, `backdrop` runs the user's `fastfetch` (its config is
the one home-manager writes), with the logo's six color slots set to Blue and
Sapphire. It needs no network.

## What goes wrong, and what happens

Whatever is wrong with the picture, a logo, a mark or the facts, the wallpaper
is still drawn and the problem is one line on stderr, which is the journal under
sway. Only a broken config, bad arguments, a sway that refuses, or a cache that
cannot be written fail the command.

| Problem | Result |
| --- | --- |
| the picture is missing, unreadable, not an image, truncated, not an absolute path, or larger than 64 megapixels | the default, one line |
| a tool logo is missing, is not an SVG or draws nothing | that logo is skipped, one line |
| no room for the logos (a tiny output) | the logos that fit, one line |
| fastfetch is missing, fails or takes more than 10 s | no facts, one line |
| the facts are hostile (control codes, binary, huge) | cut to 80 lines of 240 columns and drawn |
| fastfetch prints more than 1 MiB | it is killed with its children as soon as it has, the first MiB is drawn (cut as above), one line |
| a facts line is wider than the room right of the panel | the whole panel's font shrinks to fit, never below 6 px |
| `backdrop` fails or takes more than 2 s inside `lock-screen` | swaylock starts on plain Base |
| swaylock rejects the images | swaylock is started once more without them |

## Tests

`tests/` holds pytest tests, run by `nix flake check` as the check
`desktop-backdrop`: they render the images and look at the pixels, run
`lock-screen` over stand-ins for swaylock and swaymsg (`tests/stubs`), and run the
real fastfetch with the config ravnix writes, in the build sandbox, so with no
network. `desktop-backdrop-module` checks what the module writes.

The facts the tests draw (`tests/fastfetch.ansi`) are a capture of the real
fastfetch with ravnix's config, the personal values replaced by invented ones
and the colors by names that `conftest.py` fills in from the theme. The one
test that runs the real fastfetch also checks that the Palette row starts in
the value column. `tests/pytest.ini` filters the one deprecation warning of the
run: PyGObject itself raises it while it loads its GLib override.

From a checkout:

```sh
nix build .#checks.x86_64-linux.desktop-backdrop -L
```

## Findings that are not fixed

- The ring's radius and thickness (110 and 10 px) are written here and in the
  swaylock config of the sway module. Nothing checks that the two agree.
- Two logos can overlap when there are many: the spread picks the point farthest
  from the logos placed so far among 400 tries, and never refuses a point that is
  near one. 31 logos on the laptop's panel do not.
- A narrow or portrait output gets the same layout in fractions of its size, so
  the marks and the facts can touch below about 700 px of width. The lock image
  is not affected.
- Wide and combining characters are counted by their East Asian width, so a
  glyph that the font draws wider or narrower than that (an emoji, a Nerd Font
  icon from a fallback font) shifts the rest of its line.
- A picture with bright areas under the facts is hard to read: the facts are drawn
  as they are, without a backing, because the style has none. The picture is the
  user's choice.
- The lock image is made from the first frame of an animated picture, and its
  rotation follows the EXIF orientation.
- `lock-screen` sends the output of the redraw after an unlock to nowhere, as
  swayidle's before-sleep must not be held by it; a problem on that redraw is
  only visible at the next `backdrop wallpaper`.
- fastfetch's `colors` module with the block symbol prints two lines, and the
  second starts left of the first: that is how the Palette row of ravnix's fastfetch
  config looks on the wallpaper, and in a terminal. A single line (the circle
  symbol) would not have it.
- ravnix's fastfetch config sets only the logo's color slots 1 and 2, so in a
  terminal the other four stay in the terminal's blue and cyan (Blue and Teal).
  `backdrop` sets all six for the wallpaper itself.
