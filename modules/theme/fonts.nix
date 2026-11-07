# JetBrainsMono Nerd Font for the user's applications: the package, and the
# monospace default of fontconfig. Only the monospace default: sans-serif and
# serif stay the system's, because a web page set in one mono family is
# unreadable, and the GTK and Qt applications name the family themselves
# (gtk-qt.nix). It applies when something graphical is on, so a host that
# draws nothing gets no 200 MB of font.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  graphical = lib.any (enabled: enabled) [
    config.gtk.enable
    config.qt.enable
    config.programs.ghostty.enable
    config.programs.fuzzel.enable
    config.programs.waybar.enable
    config.programs.swaylock.enable
    config.services.dunst.enable
    config.wayland.windowManager.sway.enable
  ];
in
{
  config = lib.mkIf graphical {
    home.packages = [ pkgs.nerd-fonts.jetbrains-mono ];
    fonts.fontconfig = {
      enable = true;
      defaultFonts.monospace = [ config.ravnix.theme.font ];
    };
  };
}
