# helium-devtools-frontend

Helium's own DevTools frontend in the ravnix theme: dark mode in the roles and
the accent, square corners, JetBrainsMono Nerd Font. Helium's wrapper passes it
as `--custom-devtools-frontend=file://<this>/` when the package `helium` is
built with `devtoolsFrontend` set, which the desktop module does for the Helium
on the PATH (`modules/desktop/apps.nix`). The headless Helium of the Chrome
DevTools MCP server (`packages/chrome-devtools-mcp-helium`) is the plain
package and keeps the stock DevTools.

Carried over from the Fedora setup, where it works: commit `bc31106` of the
Fedora repository, `stow/helium/.local/share/helium-devtools-theme/`, tested
there with Helium 0.21.3.1 (Chromium 157).

## What is in it

| File | Holds |
| --- | --- |
| `build-frontend.py` | reads the path-to-id table of the frontend from the helium binary (32-byte records whose path pointers are `R_X86_64_RELATIVE` relocations in `.rela.dyn`, the pak id a uint16 at offset 8), extracts the files from `resources.pak` (Brotli or gzip), links the two theme files into every HTML entry point, writes `.complete` last |
| `square-shadow-roots.js` | an adopted `border-radius: 0` sheet on every shadow root, through `attachShadow` and the `adoptedStyleSheets` setter, because a document stylesheet does not reach shadow DOM |
| `stylesheet.nix` | the stylesheet, `catppuccin-mocha.css`: DevTools' design tokens only, each `!important`; the corner tokens 0 and the fonts in every mode, the `--ref-palette-*` and `--sys-color-*` tokens in dark mode |
| `oklab.nix` | the OKLab mix the tone ramps of the stylesheet are made with |

The build reads the binary and the pak from Helium's tarball as it is
(`ravnix.helium.src`), not from the package, which runs patchelf on the binary.
The frontend of Helium 0.21.3.1 is 859 files with 8 HTML entry points, as it
was on 0.21.1.1; on 0.21.1.1 the table read the same from the patched binary
too (checked once by hand).

## What changed from Fedora

- `build-frontend.py` takes the binary and the pak as arguments instead of
  `/opt/helium`, and writes into a build directory that the derivation moves to
  `$out`. The pruning of old copies in `~/.local/state` is gone, since there is
  no state directory. The theme files are still symlinks from the script's own
  directory, which is now a store path (`passthru.themeDir`). One fix: a
  resource that runs past the end of the pak now stops the build. Before, a pak
  cut at the start of a resource gave an empty file and exit status 0.
- `square-shadow-roots.js` is unchanged.
- The stylesheet is made from the theme module (`theme`, the module passes the
  host's) instead of written in hex: colors are `rgb(r g b)`, the accent is
  `roles.accent` where Fedora had Mauve as the accent, and the ramps are mixed
  at evaluation. Mauve stays where it is a hue of its own (the purple ramp, the
  keyword color, the purple accents). `--sys-color-inverse-primary` was
  Catppuccin Latte's Mauve on Fedora, which is no color of the theme; it is
  tone 40 of the primary ramp, DevTools' own value in dark mode. With the
  default accent every other declaration is Fedora's, color for color.
- `helium-launch`, which built the copy at the first start after an update, is
  not carried over: the frontend is built once, with the package.

## Tests

- `tests/desktop/helium-devtools-stylesheet.nix`: the stylesheet of a host with
  the default accent against the Fedora file, declaration by declaration; no
  hex color, the six corner tokens 0, the font, the style check finding only
  the three translucent tokens; Teal gives another stylesheet whose accent
  tokens are Teal and whose purple ramp is still Mauve.
- `tests/desktop/helium-devtools.nix`: the frontend of a host (859 files, both
  theme files, all 8 entry points, `.complete`, every stock corner token
  overridden); the parser on a truncated, empty, missing or foreign binary and
  on an empty, truncated or cut pak fails and leaves nothing behind; the Helium
  on the PATH passes the flag once and is the only one, every launcher runs it,
  and the MCP server's Helium does not; and, headless over the DevTools
  protocol, the host's DevTools are dark, square in all shadow roots, in the
  accent and the font, the MCP server's are stock, and a Teal frontend is Teal.

## Findings that are not fixed

- Light mode stays stock: the stylesheet colors dark mode only, as on Fedora.
  DevTools follows the system's dark preference, which the desktop sets.
- Three legacy tokens stay translucent (`--color-background-opacity-50` and
  `-80`, `--app-color-strokestyle`), as their stock values are, because DevTools
  draws them over its own canvases. `modules/desktop/apps.nix` lists them as an
  exception to the style.
- A Helium update that moves the table's layout (the record size, the anchor
  path) fails the build loudly; the parser then needs a look, not the package.
- The DevTools page reports `devtools://devtools/bundled/devtools_app.html`
  whichever frontend it serves, so the URL does not show which one loaded.
