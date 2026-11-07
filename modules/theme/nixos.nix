# The theme for a NixOS host: the ravnix.theme.* options, so the system
# modules read the same roles, line widths and font as the user's
# home-manager configuration, and the font as the system's monospace default.
# The font package itself comes with a desktop only (programs.sway.enable):
# the server shape draws nothing, and the family is 200 MB.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  imports = [ ./options.nix ];

  config = {
    fonts.fontconfig.defaultFonts.monospace = [ config.ravnix.theme.font ];
    fonts.packages = lib.mkIf config.programs.sway.enable [ pkgs.nerd-fonts.jetbrains-mono ];
  };
}
