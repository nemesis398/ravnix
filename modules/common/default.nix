# What both hosts share, for home-manager: the shell, the prompt, git and the
# command-line tools, as the Fedora laptop has them (design spec, "modules/
# common"). Neovim (./nvim.nix) is a module of its own that this one imports.
# Claude Code is another beside it (./claude-code.nix and ./claude-skills.nix),
# which the flake's homeModules.common adds to this one: the `claude` function
# of the shell starts its build (./bash.nix). ./chrome-devtools-mcp.nix gives
# Claude Code its browser tools, a headless Helium, on both hosts.
# ./dictionary.nix puts ravnix-dict on the PATH, with the user's dictionary.
#
# It reads ravnix.user, ravnix.secrets, ravnix.services, ravnix.dev,
# ravnix.shell, ravnix.editor, ravnix.dictionary and ravnix.theme, so
# homeModules.options and homeModules.theme must be imported beside it.
# nixosModules.common does all three, and gives home-manager the user's
# values; use homeModules.common by itself only outside a ravnix host.
{ config, lib, ... }:
{
  imports = [
    ./bash.nix
    ./git.nix
    ./cli.nix
    ./rbw.nix
    ./tokens.nix
    ./atuin.nix
    ./starship.nix
    ./nvim.nix
    ./scripts.nix
    ./chrome-devtools-mcp.nix
    ./dictionary.nix
  ];

  # Outside a host, home-manager is told who it is working for once, here.
  home.username = lib.mkDefault config.ravnix.user.username;
  home.homeDirectory = lib.mkDefault "/home/${config.ravnix.user.username}";
}
