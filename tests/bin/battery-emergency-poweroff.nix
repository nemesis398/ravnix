# battery-emergency-poweroff, the last layer of the battery safety net
# (packages/battery-emergency-poweroff): its tests run the script against a
# battery directory in the sandbox, with logger, wall, sleep and systemctl
# as stubs, so nothing powers off; then they check that the package runs
# that script with a PATH of store paths only. The VM test hardware-power
# runs the package itself against a fake battery and sees the VM power off.
{
  self,
  pkgs,
  system,
  ...
}:
pkgs.runCommand "bin-battery-emergency-poweroff"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.diffutils
      pkgs.gawk
      pkgs.gnugrep
    ];
    SOURCE = ../../packages/battery-emergency-poweroff/battery-emergency-poweroff.sh;
    PACKAGE = "${self.packages.${system}.battery-emergency-poweroff}/bin/battery-emergency-poweroff";
    TEST_LIB = ../../scripts/tests/lib.sh;
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    bash ${../../packages/battery-emergency-poweroff/tests/battery-emergency-poweroff.test.sh}
    touch "$out"
  ''
