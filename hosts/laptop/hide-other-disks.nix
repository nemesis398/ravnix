# Hides every internal disk but huginn's own from udisks: an NVMe or SATA
# disk whose serial is not ravnix.laptop.diskSerial, and each partition on
# it, gets UDISKS_IGNORE=1. The desktop then neither shows nor automounts
# the disk the laptop keeps (on the 16AHP9, the one Fedora runs from), and
# no click in a file manager mounts, unlocks or formats it. The disk guard
# keeps the install off that disk (tools/ravnix-disk-guard/README.md); this
# keeps the running system's desktop off it. root can still mount it by
# hand, and a mapping root opens on it (cryptsetup open) is a dm device,
# which the rule does not hide.
#
# Internal means the kernel's NVMe driver (nvme*) or SATA (sd* with
# ID_BUS=ata). A USB disk, an NVMe disk in a USB enclosure included, is sd*
# with ID_BUS=usb and still mounts. An NVMe disk in a Thunderbolt enclosure
# is nvme* and is hidden like an internal one, the safe side. eMMC is not
# covered, since mmcblk* is an SD card's name too; no supported model has
# eMMC. A disk udev knows no serial of is hidden.
#
# The rule compares the serial with udev's ID_SERIAL_SHORT, which for an
# NVMe disk is the SERIAL lsblk prints, and which a partition takes from its
# disk; it needs 60-persistent-storage.rules to have set it. Should the two
# ever differ, the target is hidden too, which keeps it out of the file
# manager and nothing more: systemd mounts huginn's file systems, not
# udisks. The file is 90-, after that one and after udisks' own
# 80-udisks2.rules, and only ever sets the variable. The serial cannot hold
# a character udev reads as a pattern (modules/options/laptop.nix).
#
# The shape holds the rule and not the hardware module: the install target
# is the shape's, from the private flake, the same for every model.
{ config, pkgs, ... }:
let
  serial = config.ravnix.laptop.diskSerial;
in
{
  services.udev.packages = [
    (pkgs.writeTextFile {
      name = "ravnix-hide-other-disks";
      destination = "/lib/udev/rules.d/90-ravnix-hide-other-disks.rules";
      text = ''
        # Hide every internal disk but the install target from udisks
        # (ravnix: hosts/laptop/hide-other-disks.nix).
        ACTION!="remove", SUBSYSTEM=="block", KERNEL=="nvme*", ENV{DEVTYPE}=="disk|partition", ENV{ID_SERIAL_SHORT}!="${serial}", ENV{UDISKS_IGNORE}="1"
        ACTION!="remove", SUBSYSTEM=="block", KERNEL=="sd*", ENV{ID_BUS}=="ata", ENV{DEVTYPE}=="disk|partition", ENV{ID_SERIAL_SHORT}!="${serial}", ENV{UDISKS_IGNORE}="1"
      '';
    })
  ];
}
