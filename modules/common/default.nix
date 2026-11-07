# What both hosts share, for home-manager: the shell, the prompt, git and the
# command-line tools, as the Fedora laptop has them (design spec, "modules/
# common"). Claude Code and Neovim are modules of their own beside this one.
#
# It reads ravnix.user, ravnix.secrets, ravnix.services, ravnix.dev and
# ravnix.theme, so homeModules.options and homeModules.theme must be imported
# beside it. nixosModules.common does all three, and gives home-manager the
# user's values; use homeModules.common by itself only outside a ravnix host.
{ config, lib, ... }:
{
  imports = [
    ./options.nix
    ./bash.nix
    ./git.nix
    ./cli.nix
    ./atuin.nix
    ./starship.nix
  ];

  # Outside a host, home-manager is told who it is working for once, here.
  home.username = lib.mkDefault config.ravnix.user.username;
  home.homeDirectory = lib.mkDefault "/home/${config.ravnix.user.username}";
}
