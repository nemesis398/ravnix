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
#               restarts the service. The same file is linked to
#               ~/.config/sway-radial/theme.json, where the program looks when
#               the variable is not set (a run by hand). The program draws no
#               color of its own.
#
# The apps it opens are Sway's, not the service's. A menu entry is started with
# `swaymsg exec` (a `desktop` item as `gtk-launch ID`, with the gtk-launch the
# package names), so Sway is the parent: the app is outside sway-radial.service's
# cgroup and survives a restart of the unit, which every rebuild that changes
# the unit, a new accent or a new menu does, and it gets the session's
# environment (the PATH with /run/wrappers/bin) and none of the program's own
# variables. The unit therefore sets no PATH; the one it has (NixOS's
# environment.d file) is the session's, and the wrapper adds swaymsg behind it.
# XDG_DATA_DIRS is set, because a user unit starts without it and the program
# itself reads it: it draws an item whose .desktop file it cannot find dim.
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
#     "The round ring stays" brings two things with it, and they are part of
#     this one exception, not new ones. The ring has no outer 1 px accent frame,
#     which rule 2 gives to a floating menu: it is wedges drawn on a layer
#     surface, and the accent marks the lit sector. And the layer surface around
#     the ring is clear: it covers the whole output and has nothing drawn on it
#     outside the ring, or the ring would hide the screen. That is the absence
#     of a surface, not a translucent one (the program's stylesheet says
#     `background-color: transparent` for it). scripts/check-style.sh does not
#     read Python, so the gate does not see either of the two.
{ config, lib, ... }:
let
  chosen = config.ravnix.desktop.radial.menu;
in
{
  # A path of the flake is copied into the store and a path in the store is
  # there already. A string that names any other file cannot be read: a flake
  # evaluates purely, so home-manager's copy of it stops with "access to
  # absolute path is forbidden", which does not say which option is wrong. (And
  # an impure evaluation would only copy a snapshot, not link the live file.)
  assertions = [
    {
      assertion = chosen == null || builtins.isPath chosen || lib.hasPrefix "${builtins.storeDir}/" (toString chosen);
      message = ''
        ravnix.desktop.radial.menu is ${toString chosen}, a file outside the Nix store named by a string.
        Set it to a path of your flake instead (./radial/menu.toml) or to a path in the store.
        A flake evaluates purely and cannot read that file, and a copy would be a snapshot, so a
        change of the menu is a rebuild.
      '';
    }
  ];

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
        # The same file the unit names in SWAY_RADIAL_THEME, where the program
        # looks without the variable, so that a run by hand (`sway-radial -v`)
        # draws in the theme too.
        xdg.configFile."sway-radial/theme.json".source = themeFile;

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
