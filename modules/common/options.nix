# The ravnix.shell.* options: what the shell reads from the user's own flake.
# They use nothing of NixOS or home-manager, so nixosModules.common and
# homeModules.common both import this file, and a user sets them once in
# me.nix for both.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  cfg = config.ravnix.shell;

  # The names go into generated shell code, so they must be names a shell
  # accepts for a variable.
  identifier = "[A-Za-z_][A-Za-z0-9_]*";
in
{
  options.ravnix.shell = {
    secretEnv = mkOption {
      type = types.attrsOf types.str;
      default = { };
      example = {
        SERVICE_API_TOKEN = "Service - API token";
      };
      description = ''
        Environment variables a shell fills from your Bitwarden through rbw:
        the variable's name, and the name of the item whose password is its
        value. `ai-unlock` unlocks the vault and loads them into the shell
        it runs in, and every shell opened while the vault is still
        unlocked loads them on its own, without ever asking for a
        password. Only the item names are in your flake; the values come
        from rbw at the moment they are read and are never written down.
      '';
    };

    autoAttach = mkOption {
      type = types.lines;
      default = "";
      example = ''
        [[ -z $SSH_CONNECTION ]] && exec some-multiplexer attach
      '';
      description = ''
        Shell code that runs first in every interactive bash, before
        anything else is set up. It is the seam for the module that drops a
        new terminal into a persistent session (an `exec` belongs here, so
        a shell that is about to be replaced does not pay for the rest of
        its start). Empty when no such module is in use.
      '';
    };
  };

  # One assertion per name, so each wrong one is named in a message of its own.
  config.assertions = map (name: {
    assertion = builtins.match identifier name != null;
    message = "ravnix.shell.secretEnv has the name \"${name}\", which is not a shell variable name ([A-Za-z_][A-Za-z0-9_]*).";
  }) (lib.attrNames cfg.secretEnv);
}
