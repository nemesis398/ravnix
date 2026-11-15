# magic-trackpad-battery (tools/magic-trackpad-battery): the built program,
# with the real ioctl, on a machine with no device and on a fake sysfs. The
# logic is in the tool's own Odin tests (magic-trackpad-battery-tests).
{
  self,
  pkgs,
  system,
  ...
}:
pkgs.runCommand "bin-magic-trackpad-battery"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
    ];
    MAGIC_TRACKPAD_BATTERY_UNDER_TEST = "${self.packages.${system}.magic-trackpad-battery}/bin/magic-trackpad-battery";
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    bash ${./magic-trackpad-battery/cli.test.sh}
    touch "$out"
  ''
