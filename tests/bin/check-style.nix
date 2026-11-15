# check-style, the style check (tools/check-style): the shell test of the
# program, tests/bin/check-style/check-style.test.sh, the cases of the Bash
# script it replaced, on the built program (CHECK_STYLE). The Odin tests are
# the check check-style-tests; the gate's style step, which runs the program
# from a cached build, is tested by scripts/tests/check.test.sh in
# scripts-tests.
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
      ./check-style/check-style.test.sh
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
    bash ${src}/tests/bin/check-style/check-style.test.sh
    touch "$out"
  ''
