# magic-trackpad-battery: the true battery level of Apple Magic devices, from
# the HID report the kernel driver does not read over Bluetooth. Carried over
# from Fedora's bin-magic-trackpad-battery and still Python, unchanged but for
# a comment (AGENTS.md, rule 4). Stdlib only. It needs a uaccess udev rule for
# the hidraw node, which modules/desktop/peripherals.nix owns.
{ writers }:
writers.writePython3Bin "magic-trackpad-battery"
  {
    # The original fails flake8 on these and is left as it was:
    #   E501  lines past 79 characters (21 of them)
    #   E302/E305  one blank line where PEP 8 wants two (7 places)
    #   E401  two imports on one line
    flakeIgnore = [
      "E501"
      "E302"
      "E305"
      "E401"
    ];
  }
  (builtins.readFile ./magic-trackpad-battery.py)
