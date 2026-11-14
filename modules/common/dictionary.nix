# The one dictionary of custom words (tools/ravnix-dict): puts ravnix-dict
# on the user's PATH, wrapped so that it finds the dictionary that
# ravnix.dictionary.file names, and the adapters this host syncs
# (ravnix.dictionary.adapters) with the places of their tools, without being
# told. The environment, or --file, still wins, so a test or a second
# dictionary needs no other build. modules/common/default.nix imports this
# file.
#
# A word reaches the tools at the next `ravnix-dict sync`, which the watcher
# (./dictionary-watch.nix) runs when a list changes. Both run this wrapper,
# which the internal ravnix.dictionary.package names.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  ravnixPackages = import ../../lib/ravnix-packages.nix { inherit lib; } {
    packagesDir = ../../packages;
    toolsDir = ../../tools;
  };
  # pkgs.ravnix comes from the overlay of nixosModules.common; on its own,
  # homeModules.common gets the same package from the same overlay here
  # (modules/common/scripts.nix does the same).
  ravnix = pkgs.ravnix or (pkgs.extend ravnixPackages.overlay).ravnix;
  tool = ravnix.ravnix-dict;
  cfg = config.ravnix.dictionary;
  # In the order sync reads them (ADAPTER_NAMES in tools/ravnix-dict).
  names = lib.filter (n: cfg.adapters.${n}) [
    "handy"
    "languagetool"
    "prose"
  ];

  # systemctl starts Handy again after a write, and rbw gives LanguageTool's
  # key; they come after the user's own PATH, for the watcher's service,
  # whose PATH is the user manager's.
  wrapped =
    pkgs.runCommand "ravnix-dict"
      {
        nativeBuildInputs = [ pkgs.makeWrapper ];
        meta = tool.meta // {
          mainProgram = "ravnix-dict";
        };
      }
      ''
        makeWrapper ${lib.getExe tool} "$out/bin/ravnix-dict" \
          --set-default RAVNIX_DICT_FILE ${lib.escapeShellArg cfg.file} \
          --set-default RAVNIX_DICT_ADAPTERS ${lib.escapeShellArg (lib.concatStringsSep "," names)} \
          --set-default RAVNIX_DICT_HANDY_SETTINGS ${lib.escapeShellArg cfg.paths.handy} \
          --set-default RAVNIX_DICT_PROSE_FILE ${lib.escapeShellArg cfg.paths.prose} \
          --suffix PATH : ${
            lib.makeBinPath [
              pkgs.systemd
              config.programs.rbw.package
            ]
          }
      '';
in
{
  # What the wrapper and the watcher share; set here, read by
  # ./dictionary-watch.nix. Declared in this home-manager module and not in
  # modules/options: nothing outside home-manager sets or reads them.
  options.ravnix.dictionary = {
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      internal = true;
      description = "ravnix-dict, wrapped with this host's dictionary and adapters.";
    };
    paths = {
      handy = lib.mkOption {
        type = lib.types.str;
        internal = true;
        default = "${config.xdg.dataHome}/com.pais.handy/settings_store.json";
        description = "Handy's settings store, which holds its custom words.";
      };
      prose = lib.mkOption {
        type = lib.types.str;
        internal = true;
        default = "${config.xdg.configHome}/prose/dictionary.txt";
        description = "The prose skill's dictionary of the user.";
      };
    };
  };

  config = {
    ravnix.dictionary.package = wrapped;
    home.packages = [ wrapped ];
  };
}
