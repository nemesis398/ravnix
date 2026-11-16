# ravnix-nas-credential (packages/ravnix-nas-credential), the root helper that
# writes a NAS share's credentials file from the login's vault: its shell test
# (packages/ravnix-nas-credential/tests), on scripts/tests/lib.sh, against a
# copy whose PATH starts with the test's stand-ins for setpriv, rbw, timeout
# and mv (helpers/stub-first.nix). strace traces every program the script
# starts, for the test that the secret is on no command line. The VM test of
# the mounts (tests/desktop/nas-vm.nix) runs the real setpriv as root, and
# tests/desktop/nas-rbw-vm.nix the real rbw against a real agent.
{
  self,
  pkgs,
  system,
  ...
}:
let
  package = self.packages.${system}.ravnix-nas-credential;
  underTest = import ./helpers/stub-first.nix { inherit pkgs; } "${package}/bin/ravnix-nas-credential";
in
pkgs.runCommand "bin-ravnix-nas-credential"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.strace
      # setsid, for the run that is killed mid-write.
      pkgs.util-linux
    ];
    NAS_CREDENTIAL_UNDER_TEST = underTest;
    TEST_LIB = ../../scripts/tests/lib.sh;
    RBW_TIMEOUT = toString package.rbwTimeout;
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    bash ${../../packages/ravnix-nas-credential/tests/ravnix-nas-credential.test.sh}
    touch "$out"
  ''
