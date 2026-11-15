# check-style, the style check (tools/check-style): the shell test that
# scripts/check-style.sh passes, run on the Odin program. It is the harness
# of the port: the same cases, the same fixtures, the program in place of the
# script (CHECK_STYLE), so the two cannot drift apart unseen while both exist.
# The Odin tests are the check check-style-tests; the script's own run of the
# file is in scripts-tests.
{
  self,
  lib,
  pkgs,
  system,
  ...
}:
let
  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../scripts/tests/lib.sh
      ../../scripts/tests/check-style.test.sh
      ../../docs/style.md
      ../../docs/mermaid-theme.json
    ];
  };
in
pkgs.runCommand "bin-check-style"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.diffutils
      pkgs.gawk
      pkgs.gnused
    ];
    CHECK_STYLE = lib.getExe self.packages.${system}.check-style;
  }
  ''
    export HOME="$TMPDIR"
    bash ${src}/scripts/tests/check-style.test.sh
    touch "$out"
  ''
