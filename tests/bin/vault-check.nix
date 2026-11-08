# vault-check, carried over from Fedora's bin-vault-check with its tests: the
# Obsidian CLI and date(1) are stubs, and the AI memory lint is a stand-in
# (packages/vault-check/tests/fixtures/lint.py), since the skill that owns the
# real one is not part of ravnix. The cases for where the vault and the
# baseline come from are new.
#
# writeShellApplication puts the package's tools before the PATH it was
# started with, so a stub of date(1) would never be reached. The script under
# test is therefore a copy of the package's whose one PATH line starts with
# $STUB_PATH; nothing else differs.
{
  self,
  pkgs,
  system,
  ...
}:
let
  package = self.packages.${system}.vault-check;
  underTest = import ./helpers/stub-first.nix { inherit pkgs; } "${package}/bin/vault-check";
in
pkgs.runCommand "bin-vault-check"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
      pkgs.python3
    ];
    VAULT_CHECK_UNDER_TEST = underTest;
    src = pkgs.lib.fileset.toSource {
      root = ../../packages/vault-check;
      fileset = ../../packages/vault-check/tests;
    };
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    cp -r "$src/tests" tests
    chmod -R u+w tests
    patchShebangs tests >/dev/null
    bash tests/vault-check.test.sh
    touch "$out"
  ''
