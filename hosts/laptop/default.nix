# The laptop shape, huginn: what every ravnix laptop is, whatever its model.
# The common module (shell, user, home-manager), the disk layout of
# ./disko.nix, the boot, ./hide-other-disks.nix, which keeps the other
# internal disks out of udisks, and ./zram.nix, the only swap. flake.nix
# adds nixosModules.desktop beside this file in nixosModules.laptop. A
# laptop's hardware is a module of its own under modules/hardware/, which
# the private flake imports beside this one, so a second model is a new
# directory there and not a new shape:
#
#   modules = [
#     ravnix.nixosModules.laptop
#     ravnix.nixosModules.hardware-ideapad-pro-5-16ahp9
#     ./me.nix
#   ];
#
# It is a function of the flake, `import ./hosts/laptop { inherit self
# inputs; }` (flake.nix, where it gets a key), for the modules it brings.
{ self, inputs }:
{ config, lib, ... }:
let
  inherit (config.ravnix.laptop) diskModel diskSerial;

  # udev's link for an NVMe disk: nvme-<model>_<serial>, where each run of
  # white space is one "_" and every character but letters, digits and
  # #+-.:=@_ is "_" too (udev's string_escape=replace, for ASCII). It names
  # the disk by the model and the serial the private flake gives, never by a
  # kernel name. Only disko's own scripts in the system
  # (config.system.build.diskoScript and its kin) read it; the install runs
  # disko on the path the disk guard prints, which is this one
  # (tests/laptop/disko.nix checks that on a VM's NVMe disks).
  udevName =
    s:
    lib.concatMapStrings (c: if builtins.match "[0-9A-Za-z#+.:=@_-]" c != null then c else "_") (
      lib.stringToCharacters (
        lib.concatStringsSep "_" (
          lib.filter (w: builtins.isString w && w != "") (builtins.split "[[:space:]]+" s)
        )
      )
    );
  byId = "/dev/disk/by-id/nvme-${udevName diskModel}_${udevName diskSerial}";
in
{
  imports = [
    inputs.disko.nixosModules.disko
    self.nixosModules.common
    ./hide-other-disks.nix
    ./zram.nix
  ];

  # The file systems, the swap on disk (none; zram is the swap) and the
  # initrd's LUKS device come from the layout, by GPT label and mapper name,
  # not by the device.
  disko.devices = (import ./disko.nix { device = byId; }).disko.devices;

  boot = {
    # systemd-boot on the ESP, listing the generations to roll back to.
    # efi.canTouchEfiVariables stays false, NixOS's default, so neither the
    # install nor a switch writes the firmware's boot entries; the install
    # adds huginn's entry on purpose, and Fedora's stays as it is.
    loader.systemd-boot.enable = true;
  };
}
