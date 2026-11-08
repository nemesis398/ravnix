# charge-mode, the battery's charge ceiling (packages/charge-mode): the
# user's command, its root helper charge-mode-apply and the boot restore,
# each run as a copy whose battery and state paths point into the sandbox,
# with sudo, notify-send, pkill and sleep as stubs (and once the real pkill,
# against processes named as Waybar's are); then the package's three
# commands, their PATHs and the helper they call. The VM test hardware-power
# checks the sudo rule and the boot unit on a running system.
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
      pkgs.gawk
      pkgs.gnugrep
      pkgs.gnused
      # The real pkill, for the Waybar refresh against real processes.
      pkgs.procps
    ];
    SOURCES = ../../packages/charge-mode;
    PACKAGE = self.packages.${system}.charge-mode;
    TEST_LIB = ../../scripts/tests/lib.sh;
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    bash ${../../packages/charge-mode/tests/charge-mode.test.sh}
    touch "$out"
  ''
