# Hides every internal disk but huginn's own from udisks: an NVMe or SATA
# disk whose serial is not ravnix.laptop.diskSerial, and each partition on
# it, gets UDISKS_IGNORE=1. The desktop then neither shows nor automounts
# the disk the laptop keeps (on the 16AHP9, the one Fedora runs from), and
# no click in a file manager mounts, unlocks or formats it. The disk guard
# keeps the install off that disk (tools/ravnix-disk-guard/README.md); this
# keeps the running system's desktop off it. UDISKS_IGNORE is a hint to
# user interfaces, not a lock: udisks still lists the disk, and udisksctl
# mounts or unlocks it behind polkit's admin password for system devices,
# which no ravnix module may relax. root can still mount it by hand, and a
# mapping root opens on it (cryptsetup open) is a dm device, which the rule
# does not hide.
#
# Internal means the kernel's NVMe driver (nvme*) or SATA (sd* with
# ID_BUS=ata) not on USB. A USB disk is never hidden. ID_BUS=ata alone does
# not say so: systemd's 60-persistent-storage.rules runs ata_id on every
# non-removable USB disk, and a SATA disk in a USB enclosure whose bridge
# passes ATA commands through comes out ID_BUS=ata like an internal one. So
# the SATA line also needs both marks of USB to be missing: ID_USB_VENDOR_ID,
# which usb_id sets on every sd* disk below USB, and an ID_PATH through
# "-usb-", which path_id writes; a partition takes both over from its disk.
# An NVMe disk in a Thunderbolt or USB4 enclosure tunnels PCIe and is nvme*,
# so it is hidden like an internal one, the safe side, though its user may
# call it a USB disk. eMMC is not covered, since mmcblk* is an SD card's
# name too; no supported model has eMMC. A disk udev knows no serial of is
# hidden.
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
        ACTION!="remove", SUBSYSTEM=="block", KERNEL=="sd*", ENV{ID_BUS}=="ata", ENV{ID_USB_VENDOR_ID}!="?*", ENV{ID_PATH}!="*-usb-*", ENV{DEVTYPE}=="disk|partition", ENV{ID_SERIAL_SHORT}!="${serial}", ENV{UDISKS_IGNORE}="1"
      '';
    })
  ];
}
