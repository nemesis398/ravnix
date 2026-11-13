# The one dictionary of custom words (tools/ravnix-dict): puts ravnix-dict
# on the user's PATH, wrapped so that it finds the dictionary that
# ravnix.dictionary.file names without being told. RAVNIX_DICT_FILE in the
# environment, or --file, still wins, so a test or a second dictionary
# needs no other build. modules/common/default.nix imports this file.
#
# Nothing here syncs: a word reaches the tools at the next
# `ravnix-dict sync`, which the watcher of Task 7.2
# (modules/common/dictionary-watch.nix) runs when the file changes.
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
          --set-default RAVNIX_DICT_FILE ${lib.escapeShellArg config.ravnix.dictionary.file}
      '';
in
{
  home.packages = [ wrapped ];
}
