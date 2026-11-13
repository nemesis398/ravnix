# The disk layout of the laptop shape, for disko: the whole disk, a 1 GiB
# ESP, then LUKS2 (cryptroot) holding btrfs with the subvolumes @, @home,
# @nix and @log, compressed with zstd. No swap partition and no swap file:
# zram is huginn's only swap.
#
# It takes the disk as `device`, the /dev/disk/by-id path that
# ravnix-disk-guard printed, and refuses anything else: a kernel name such
# as /dev/nvme0n1 can be the other disk after the next boot (AGENTS.md,
# rule 2). The install takes the disk lock first, so that no QEMU passthrough
# (scripts/try-huginn.sh, which the guard cannot see) holds the disk while a
# command writes it, and then runs, in that one shell and after the guard
# exited 0:
#
#   sudo flock -n /run/lock/ravnix-huginn-disk.lock bash    # exits 1 if the lock is held
#   dev=$(ravnix-disk-guard --model "$MODEL" --serial "$SERIAL" --print-device) || exit
#   disko --mode destroy,format,mount --argstr device "$dev" hosts/laptop/disko.nix
#
# The same shell then runs nixos-install and systemd-cryptenroll, and every
# rerun of any of them starts with the same flock line: all of them write
# the disk. The path is /run/lock/ravnix-huginn-disk.lock and no other,
# because try-huginn takes exactly that one and refuses while it is held.
#
# disko then lists the one disk it is about to wipe and asks before it does,
# and asks for the LUKS passphrase twice; no key file ever holds it. The
# FIDO2 slot is enrolled afterwards with systemd-cryptenroll.
#
# The partitions are found by their GPT labels, disk-huginn-ESP and
# disk-huginn-luks, which name the shape and not the device, so the system
# boots the same on the laptop and in QEMU, where the disk is passed through
# under another name. hosts/laptop/default.nix imports this file for the
# file systems and the initrd; tests/laptop/ checks the script and runs it in
# a VM.
{
  device ? throw "hosts/laptop/disko.nix needs device: the /dev/disk/by-id path that ravnix-disk-guard printed",
  ...
}:
let
  prefix = "/dev/disk/by-id/";
  link = builtins.substring (builtins.stringLength prefix) (builtins.stringLength device) device;
  # One name in the characters udev writes a by-id link in, so neither a
  # path nor a shell character reaches the script. udev also keeps UTF-8
  # and \x escapes, which an NVMe model or serial, ASCII by the NVMe
  # specification, never needs.
  isById =
    builtins.substring 0 (builtins.stringLength prefix) device == prefix
    && builtins.match "[0-9A-Za-z#+.:=@_-]+" link != null
    && link != "."
    && link != "..";
  disk =
    if isById then
      device
    else
      throw "hosts/laptop/disko.nix takes the disk as a /dev/disk/by-id path, the one ravnix-disk-guard printed, not ${builtins.toJSON device}";

  # Each subvolume compressed with zstd, as on Fedora.
  subvolume = mountpoint: {
    inherit mountpoint;
    mountOptions = [ "compress=zstd" ];
  };
in
{
  disko.devices.disk.huginn = {
    type = "disk";
    device = disk;
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "1G";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        luks = {
          size = "100%";
          content = {
            type = "luks";
            name = "cryptroot";
            extraFormatArgs = [
              "--type"
              "luks2"
            ];
            # TRIM through to the SSD, as Fedora's crypttab has it.
            settings.allowDiscards = true;
            content = {
              type = "btrfs";
              extraArgs = [ "-f" ];
              subvolumes = {
                "@" = subvolume "/";
                "@home" = subvolume "/home";
                "@nix" = subvolume "/nix";
                "@log" = subvolume "/var/log";
              };
            };
          };
        };
      };
    };
  };
}
