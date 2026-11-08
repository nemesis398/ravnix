# The server's VM images (hosts/server/images.nix), evaluated and never
# built: the qcow2 for Proxmox and QEMU, the VMDK for VMware and the OVA for
# VirtualBox, each one of NixOS's system.build.images.
#
# An image is the host's configuration plus the image's own module, and every
# deploy after the first boot (nixos-rebuild switch) installs the host's own
# toplevel, without that module. So whatever decides whether the VM comes
# back after its next reboot must already be the host's: the file systems,
# the swap, the boot loader, the drivers the initrd needs to find the disks,
# and a disk with an EFI system partition for that boot loader. This test
# checks each image against the host on exactly those, names the file each
# one builds, and checks the layout's own promises: root and the ESP by
# label, /home on a volume of its own, by label and mounted by the initrd
# (so the account's home directory is made on it, not under it), no write to
# the firmware's boot entries, and a second disk that is ext4 labelled home.
{
  self,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  host = inputs.nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      self.nixosModules.server
      self.nixosModules.server-vm
      ../../templates/default/me.nix
      {
        system.stateVersion = "26.11";
        warnings = lib.mkForce [ ];
        ravnix.editor.languages = lib.mkForce [ "nix" ];
      }
    ];
  };
  c = host.config;

  # The image variant and the file it builds.
  images = {
    qemu-efi = "qcow2";
    vmware = "vmdk";
    virtualbox = "ova";
  };

  # What a switch to the host's toplevel must not change.
  boot = cfg: {
    fileSystems = lib.mapAttrs (_: fs: {
      inherit (fs)
        device
        fsType
        autoResize
        neededForBoot
        ;
      options = lib.sort lib.lessThan (lib.unique fs.options);
    }) cfg.fileSystems;
    swap = map (s: s.device) cfg.swapDevices;
    systemd-boot = cfg.boot.loader.systemd-boot.enable;
    grub = cfg.boot.loader.grub.enable;
    canTouchEfiVariables = cfg.boot.loader.efi.canTouchEfiVariables;
    growPartition = cfg.boot.growPartition;
  };
  initrdModules = cfg: lib.unique (cfg.boot.initrd.availableKernelModules ++ cfg.boot.initrd.kernelModules);
  # Modules of a hypervisor's guest tools, which come with the package that
  # image adds and are no driver for a disk: VirtualBox's shared folders.
  guestToolModules = [ "vboxsf" ];

  imageFailures = lib.concatLists (
    lib.mapAttrsToList (
      name: extension:
      let
        image = c.system.build.images.${name};
        ic = image.passthru.config;
        mine = boot c;
        theirs = boot ic;
        differs = lib.filter (k: mine.${k} != theirs.${k}) (lib.attrNames mine);
        missing = lib.subtractLists (initrdModules c ++ guestToolModules) (initrdModules ic);
      in
      lib.optional (!lib.hasSuffix ".${extension}" image.passthru.filePath)
        "the ${name} image builds ${image.passthru.filePath}, not a .${extension}"
      ++ map (
        k:
        "the ${name} image differs from the host in ${k}, so the first deploy changes it: host ${builtins.toJSON mine.${k}}, image ${builtins.toJSON theirs.${k}}"
      ) differs
      ++ lib.optional (missing != [ ])
        "the ${name} image's initrd needs ${toString missing}, which the host's lacks, so the VM finds no disk after a deploy"
      ++ lib.optional (
        !(lib.hasInfix "mkpart ESP" (image.preVM or "") && !lib.hasInfix "mklabel msdos" (image.preVM or ""))
      ) "the ${name} image's disk has no EFI system partition, which the host's boot loader is installed to"
    ) images
  );

  fs = c.fileSystems;
  layoutFailures =
    lib.optional (fs."/".device != "/dev/disk/by-label/nixos" || !fs."/".autoResize)
      "root is not the file system labelled nixos, grown to its disk"
    ++ lib.optional (
      fs."/boot".device != "/dev/disk/by-label/ESP" || fs."/boot".fsType != "vfat"
    ) "/boot is not the EFI system partition labelled ESP"
    ++ lib.optional (!(fs ? "/home")) "/home has no volume of its own"
    ++ lib.optional (
      fs ? "/home"
      && (fs."/home".device != "/dev/disk/by-label/home" || fs."/home".fsType != "ext4" || !fs."/home".autoResize)
    ) "/home is not the ext4 volume labelled home, grown to its disk"
    ++ lib.optional (
      fs ? "/home" && !fs."/home".neededForBoot
    ) "/home is mounted after the activation makes the account's home, which then lies under the mount"
    ++ lib.optional c.boot.loader.efi.canTouchEfiVariables "a switch writes the firmware's boot entries"
    ++ lib.optional (!c.boot.loader.systemd-boot.enable) "the boot loader is not systemd-boot"
    ++ lib.optional (
      c.boot.loader.systemd-boot.configurationLimit == null
    ) "systemd-boot keeps every generation on an ESP of 256 MiB"
    ++ lib.optional (!c.services.qemuGuest.enable) "Proxmox's guest agent does not run"
    ++ lib.optional (!(c.system.build ? homeVolume)) "there is no image of the home volume";

  failures = imageFailures ++ layoutFailures;
  homeVolume = c.system.build.homeVolume or null;
in
pkgs.runCommand "server-images"
  {
    nativeBuildInputs = [
      pkgs.qemu-utils
      pkgs.util-linux
    ];
  }
  (
    if failures != [ ] then
      ''
        printf '%s\n' ${lib.escapeShellArgs failures} >&2
        exit 1
      ''
    else
      ''
        # The home volume is small, so this one is built and looked at: an
        # empty ext4 labelled home in a qcow2 and a VMDK, the volume that the
        # host mounts on /home.
        for f in home.qcow2 home.vmdk; do
          [ -e ${homeVolume}/$f ] || { echo "the home volume has no $f" >&2; exit 1; }
        done
        qemu-img convert -O raw ${homeVolume}/home.qcow2 home.raw
        [ "$(blkid -o value -s TYPE home.raw)" = ext4 ] || { echo "the home volume is not ext4" >&2; exit 1; }
        [ "$(blkid -o value -s LABEL home.raw)" = home ] || { echo "the home volume is not labelled home" >&2; exit 1; }
        touch $out
      ''
  )
