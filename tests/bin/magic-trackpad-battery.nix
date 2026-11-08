# magic-trackpad-battery (packages/magic-trackpad-battery): the script's
# functions against a fake sysfs and a fake ioctl, and the command itself on a
# machine with no device. The script has no tests in Fedora; these are new.
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
      pkgs.python3
    ];
    MAGIC_TRACKPAD_BATTERY_UNDER_TEST = "${self.packages.${system}.magic-trackpad-battery}/bin/magic-trackpad-battery";
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    bash ${../../packages/magic-trackpad-battery/tests/magic-trackpad-battery.test.sh}
    touch "$out"
  ''
