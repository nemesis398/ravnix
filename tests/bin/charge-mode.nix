# charge-mode, the battery's charge ceiling (tools/charge-mode): the user's
# command, its root helper charge-mode-apply and the boot restore, each the
# package's program with its battery and state paths pointed into the
# sandbox, and sudo and notify-send as stubs (the Waybar refresh against
# real processes named as Waybar's are); then the package's three programs
# and the helper they call. The Odin tests are the check charge-mode-tests;
# the VM test hardware-power checks the sudo rule and the boot unit on a
# running system.
{
  self,
  pkgs,
  system,
  ...
}:
pkgs.runCommand "bin-charge-mode"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.diffutils
      pkgs.gnugrep
      pkgs.gnused
      # pgrep, which tells whether a Waybar of the user runs outside the
      # sandbox, where the case with real processes skips.
      pkgs.procps
    ];
    PACKAGE = self.packages.${system}.charge-mode;
    TEST_LIB = ../../scripts/tests/lib.sh;
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    bash ${./charge-mode/charge-mode.test.sh}
    touch "$out"
  ''
