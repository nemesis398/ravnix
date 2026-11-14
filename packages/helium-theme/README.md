# helium-theme

Helium's frame in the theme of the system: an unpacked Chromium theme (a
directory with a `manifest.json`) in the colors of `ravnix.theme.roles`. The
strip that frames the work (the frame, the address bar, the buttons) is
Mantle, the toolbar Base, and the accent is on the icons and the address.

`packages/helium` loads it at every start with `--load-extension`
(`themeExtension`), and `modules/desktop/apps.nix` passes the host's. Before
this package the same manifest was written to
`~/.local/share/helium/themes/ravnix` and had to be loaded by hand once. The
directory is a store path, so another accent is another path and another
extension id, and nothing is left to reload.

The web content is not part of this: Catppuccin userstyles in Stylus do that,
and their import is `lib/stylus-import.nix`.

`tests/desktop/helium-theme.nix` checks the colors against the roles, that the
accent follows, and that a headless Helium takes the theme.
