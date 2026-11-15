{ config, lib, pkgs, ... }:
let
  roles = config.ravnix.theme.roles;
  pin = "82bca82b2b27e3d044c7cd5c22a471c8c60df72e";
  digest = "sha256:0f1e2d3c4b5a69788796a5b4c3d2e1f00f1e2d3c4b5a69788796a5b4c3d2e1f0";
in
{
  programs.fuzzel = {
    enable = true;
    settings = {
      main = {
        width = 50;
        lines = 12;
        font = "JetBrainsMono Nerd Font:size=11";
      };
      colors = {
        background = roles.canvas;
        text = roles.text;
        selection = roles.selected;
        match = roles.accent;
      };
      border = {
        width = 1;
        radius = 0;
      };
    };
  };

  # Opaque, square, still: the bar takes its values from the theme module.
  services.dunst.settings.global = {
    frame_width = 1;
    corner_radius = 0;
    separator_height = 1;
    notification_limit = 5;
  };

  gtk.gtk3.extraConfig.gtk-enable-animations = false;
  home.packages = [ pkgs.fuzzel ];
  home.sessionVariables.REV = pin;
  home.sessionVariables.DIGEST = digest;
}
