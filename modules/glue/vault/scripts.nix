# The vault glue's command (../vault.nix): vault-commit, the one entry point
# the vault skills commit through, on both hosts. A data file of the glue
# module, which lib/import-dir.nix does not import (there is no default.nix
# here): vault.nix builds it with the host's ravnix-link and vault, and
# tests/glue/vault-scripts.nix with a stand-in for ravnix-link. The command
# is the Bash beside this file, with every @name@ filled in as a shell word,
# packaged by writeShellApplication, so shellcheck runs over it at build
# time.
#
#   import ./vault/scripts.nix {
#     inherit lib pkgs;
#     vault = "/home/alice/notes";   # ravnix.link.vault, or null
#     link = ...;                    # the host's ravnix-link, a path
#   }
#   => <derivation>
{
  lib,
  pkgs,
  vault ? null,
  link ? "ravnix-link",
  git ? lib.getExe pkgs.git,
  jq ? lib.getExe pkgs.jq,
  flock ? lib.getExe' pkgs.util-linux "flock",
}:
let
  word = value: lib.escapeShellArg (toString value);
  fill =
    values: file:
    lib.replaceStrings (map (n: "@${n}@") (lib.attrNames values)) (lib.attrValues values) (
      builtins.readFile file
    );
in
pkgs.writeShellApplication {
  name = "vault-commit";
  runtimeInputs = [ pkgs.coreutils ];
  text = fill {
    jq = word jq;
    git = word git;
    flock = word flock;
    link = word link;
    vault = word (if vault == null then "" else vault);
  } ./vault-commit.bash;
  meta.mainProgram = "vault-commit";
}
