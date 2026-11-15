# magic-trackpad-battery: the true battery level of Apple Magic devices, from
# the HID report the kernel driver does not read over Bluetooth (README.md).
# It needs a uaccess udev rule for the hidraw node, which
# modules/desktop/peripherals.nix owns.
{ buildOdinTool, ... }:
buildOdinTool {
  name = "magic-trackpad-battery";
  src = ./.;
  tests = ./tests;
  bench = ./bench;
  # The bench reads the system in bench/root, as a status bar would ask for it.
  benchArgs = [
    "--tsv"
    "--root"
    "root"
  ];
}
