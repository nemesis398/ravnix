# atuin-root-login (packages/atuin-root-login): the helper that logs root in
# to the user's atuin account from a Bitwarden item. rbw, sudo and id are
# stand-ins made by the test, and atuin is a stand-in built into the helper,
# so no vault, no root and no server are involved; the test runs the real
# atuin once for the contract the helper relies on. New: the helper handles the
# account's password and recovery key, so the test hunts for them on command
# lines, in files, in output, in traces and in the environment of every
# process but atuin.
{
  self,
  pkgs,
  lib,
  system,
  ...
}:
let
  stub = pkgs.writeShellScriptBin "atuin" (builtins.readFile ../../packages/atuin-root-login/tests/atuin-stub.bash);
  syncAddress = "http://sync.test:8888";
  helper = self.packages.${system}.atuin-root-login.override {
    atuin = stub;
    inherit syncAddress;
  };
  # No atuin service placed: no sync address.
  helperNoSync = self.packages.${system}.atuin-root-login.override { atuin = stub; };
in
pkgs.runCommand "bin-atuin-root-login"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.python3
      pkgs.util-linux
    ];
    ATUIN_ROOT_LOGIN_UNDER_TEST = lib.getExe helper;
    ATUIN_ROOT_LOGIN_NO_SYNC = lib.getExe helperNoSync;
    ATUIN_ROOT_LOGIN_SYNC_ADDRESS = syncAddress;
    ATUIN_REAL = lib.getExe pkgs.atuin;
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    bash ${self}/packages/atuin-root-login/tests/atuin-root-login.test.sh
    touch "$out"
  ''
