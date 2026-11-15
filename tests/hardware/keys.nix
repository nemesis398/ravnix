# The IdeaPad Pro 5 16AHP9's F4 (mic mute) and F8 (airplane) keys, as the
# hwdb of huginn's configuration maps them. Each press reaches the
# "Ideapad extra buttons" device twice: through the EC's VPC event (scancode
# 0x08 for F4, 0x0d for F8) and, a few ms later, through WMI (0x13e, 0x13f).
# Measured with evtest's MSC_SCAN on this laptop. Without a remap F4 toggles
# the mic twice and F8 makes the kernel's rfkill-input block and unblock every
# radio within ~250 ms, so neither key seems to do anything.
#
# The check compiles huginn's hwdb.bin and asks systemd-hwdb what this laptop's
# key device gets: the two WMI copies dropped (reserved, which the input core
# never reports), the VPC airplane scancode still rfkill (systemd's own entry
# for every IdeaPad), and nothing of ours on another Lenovo.
{
  self,
  inputs,
  lib,
  pkgs,
  system,
  ...
}:
let
  huginn = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      ../../templates/default/me.nix
      { system.stateVersion = "26.05"; }
      self.nixosModules.laptop
      self.nixosModules.hardware-ideapad-pro-5-16ahp9
    ];
  };
  hwdb = huginn.config.environment.etc."udev/hwdb.bin".source;
  # The device's modalias as udev builds it: the input name, then the DMI
  # modalias (synthetic values but for the vendor and the product).
  device = product: "evdev:name:Ideapad extra buttons:dmi:bvnLENOVO:bvrX:bd01/01/2025:br1.0:svnLENOVO:pn${product}:pvrX:rvnLENOVO:rnX:";
in
pkgs.runCommand "hardware-keys" { nativeBuildInputs = [ pkgs.systemd ]; } ''
  set -u
  mkdir -p root/etc/udev
  ln -s ${hwdb} root/etc/udev/hwdb.bin
  fail=0
  query() { systemd-hwdb --root=$PWD/root query "$1"; }
  laptop=$(query '${device "83D5"}')
  other=$(query '${device "21XX"}')
  echo "83D5: $laptop"
  echo "21XX: $other"
  for want in KEYBOARD_KEY_13e=reserved KEYBOARD_KEY_13f=reserved KEYBOARD_KEY_0d=rfkill; do
    grep -qxF "$want" <<<"$laptop" || { echo "FAIL: the 83D5's key device lacks $want" >&2; fail=1; }
  done
  if grep -qE '^KEYBOARD_KEY_13[ef]=' <<<"$other"; then
    echo "FAIL: another Lenovo's key device gets a WMI remap: $other" >&2
    fail=1
  fi
  grep -qxF KEYBOARD_KEY_0d=rfkill <<<"$other" || { echo "FAIL: the query does not see systemd's own IdeaPad entry" >&2; fail=1; }
  [ $fail = 0 ]
  echo "the F4 and F8 WMI copies are dropped on the 83D5 only" > $out
''
