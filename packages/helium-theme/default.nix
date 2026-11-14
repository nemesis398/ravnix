# Helium's own theme, the frame of the browser in the roles of the theme
# module: an unpacked Chromium theme (a directory with a manifest.json), which
# packages/helium loads at every start with --load-extension (`themeExtension`).
# Before this, the same manifest was written to ~/.local/share/helium/themes/
# ravnix and loaded by hand once ("Load unpacked" at helium://extensions).
#
# The strip that frames the work (the frame, the address bar and the buttons)
# is Mantle (style rule 1), the toolbar Base, and the accent is on the icons
# and the address.
#
#   theme   { palette, roles } of config.ravnix.theme. The desktop module
#           passes the host's; the default is the theme module's own default,
#           Mocha with the Mauve accent.
{
  lib,
  writeTextDir,
  theme ? null,
}:
let
  inherit (if theme == null then import ../../lib/default-theme.nix { inherit lib; } else theme)
    roles
    ;

  rgb =
    hex:
    let
      h = lib.removePrefix "#" hex;
      byte = i: lib.fromHexString (builtins.substring i 2 h);
    in
    [
      (byte 0)
      (byte 2)
      (byte 4)
    ];

  manifest = builtins.toJSON {
    manifest_version = 3;
    name = "Ravnix";
    description = "Catppuccin Mocha in the accent of ravnix";
    version = "1.0.0";
    theme.colors = lib.mapAttrs (_: rgb) {
      frame = roles.dock;
      frame_inactive = roles.dock;
      frame_incognito = roles.selected;
      frame_incognito_inactive = roles.selected;
      bookmark_text = roles.text;
      tab_background_text = roles.label;
      tab_background_text_inactive = roles.secondary;
      tab_background_text_incognito = roles.label;
      tab_background_text_incognito_inactive = roles.secondary;
      tab_text = roles.text;
      toolbar = roles.canvas;
      toolbar_button_icon = roles.accent;
      omnibox_text = roles.accent;
      omnibox_background = roles.dock;
      ntp_background = roles.canvas;
      ntp_link = roles.accent;
      ntp_text = roles.text;
      button_background = roles.dock;
    };
  };
in
(writeTextDir "manifest.json" manifest).overrideAttrs (old: {
  name = "helium-theme";
  meta = (old.meta or { }) // {
    description = "Helium's frame in the ravnix theme, an unpacked Chromium theme";
    platforms = lib.platforms.all;
  };
})
