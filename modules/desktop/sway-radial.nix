# The radial menu behind the four-finger pinch on the trackpad: the
# `sway-radial` program (packages/sway-radial) in the user's profile, as a user
# service of the Sway session, and the two files it reads.
#
# It reads the trackpad itself, through its own libinput context, so the Sway
# config only has to keep applications from taking the pinch: `bindgesture
# pinch:4 nop` (sway/50-laptop.conf) does that, and without the service it is
# harmless, since sway-mouse starts fuzzel when the service is not running.
# The udev rule that lets the user read the pad's evdev node is the
# peripherals module's (peripherals.nix, the uaccess tag); without it libinput
# skips the pad and says nothing, and the menu never opens.
#
#   the menu    ~/.config/sway-radial/menu.toml, the file of
#               ravnix.desktop.radial.menu (modules/options/radial.nix), or
#               ravnix's own menu when the option is null. The program watches
#               the file; a change of it restarts the service as well, so a
#               rebuild is enough.
#   the theme   the roles, the font and the line widths of the theme module as
#               JSON, which the unit names in SWAY_RADIAL_THEME. The file is a
#               store path in the unit, so a new accent changes the unit and
#               restarts the service. The program draws no color of its own.
#
# The unit's PATH and XDG_DATA_DIRS are the user's profile and the system's:
# a user unit starts with neither, and the menu starts programs by name
# (`desktop` items through gtk-launch, which looks the .desktop file up on
# XDG_DATA_DIRS, and the program draws an item whose file it cannot find dim).
# WAYLAND_DISPLAY and SWAYSOCK come from the Sway session (NixOS's
# sway-session integration imports them into the user manager).
#
# EXCEPTION (docs/style.md, rule 9), one, kept from the original program on
# purpose and written down here so it is not found by accident:
#   - The ring is round. The style has square corners everywhere, and a radial
#     menu cannot have them: its sectors are wedges of a circle. This is the
#     exception the style spec lists (the row "sway-radial" of *Where the
#     Fedora configs differ*, "the round ring stays"). The ring is opaque and
#     nothing fades: the program was patched from alpha 0.92 and an 80 ms fade.
#     The countdown does not move either: holding still on a sector for the
#     dwell time draws a 2 px arc along its edge, whole, at once, and the arc
#     goes when the dwell fires or is cancelled.
# The layer surface that carries the ring covers the whole output and has
# nothing drawn on it outside the ring; it has to be clear, or the ring would
# hide the screen. That is the absence of a surface and not a translucent one.
{ ... }:
{
  home-manager.sharedModules = [
    (
      {
        config,
        lib,
        pkgs,
        ...
      }:
      let
        cfg = config.ravnix.desktop.radial;
        inherit (config.ravnix) theme;
        package = pkgs.ravnix.sway-radial;
        profile = config.home.profileDirectory;

        # ravnix's own menu when the user brings none; the file of the package
        # is a store path, like the user's.
        menu = if cfg.menu == null then "${package}/lib/sway-radial/menu.toml" else cfg.menu;

        # What theme.py reads (packages/sway-radial/src/sway_radial/theme.py):
        # the roles (it uses eight of them), the font and the two line widths.
        themeFile = pkgs.writeText "sway-radial-theme.json" (
          builtins.toJSON { inherit (theme) roles font lineWidth; }
        );
      in
      {
        home.packages = [ package ];

        xdg.configFile."sway-radial/menu.toml".source = menu;

        systemd.user.services.sway-radial = {
          Unit = {
            Description = "Radial menu for the four-finger pinch";
            PartOf = [ "graphical-session.target" ];
            After = [ "graphical-session.target" ];
            # The file is a link into the store, so a new menu is a new link
            # and the program's watch may or may not see it; a restart does.
            X-Restart-Triggers = [ "${menu}" ];
          };
          Service = {
            Type = "simple";
            ExecStart = lib.getExe package;
            Environment = [
              "SWAY_RADIAL_THEME=${themeFile}"
              "PATH=${profile}/bin:/run/current-system/sw/bin"
              "XDG_DATA_DIRS=${profile}/share:/run/current-system/sw/share"
            ];
            Restart = "on-failure";
            RestartSec = 2;
          };
          Install.WantedBy = [ "sway-session.target" ];
        };
      }
    )
  ];
}
