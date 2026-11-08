# The server as a virtual machine: one disk layout and one boot for all of
# its images, and the images themselves. A host that runs as a VM imports
# this beside the server shape (flake.nix: nixosModules.server-vm):
#
#   modules = [
#     ravnix.nixosModules.server
#     ravnix.nixosModules.server-vm
#     ./muninn-vm.nix               # the hypervisor's settings, the network
#     ./me.nix
#   ];
#
# The images are NixOS's own, system.build.images of the pinned nixpkgs
# (nixos/modules/image/images.nix), built from the host's configuration:
#
#   nix build PRIVATE_FLAKE#nixosConfigurations.HOST.config.system.build.images.qemu-efi
#
#   qemu-efi     qcow2, for Proxmox and QEMU   nixpkgs' variant, as it is
#   vmware       VMDK, for VMware              nixpkgs' variant, as it is
#   virtualbox   OVA, for VirtualBox           ravnix's variant, see below
#
# and the second disk, which every one of them mounts on /home:
#
#   nix build PRIVATE_FLAKE#nixosConfigurations.HOST.config.system.build.homeVolume
#
# The layout: a GPT disk with an EFI system partition labelled ESP and an
# ext4 root labelled nixos, which grows to the disk at every boot (enlarge
# the disk in the hypervisor, reboot, done); systemd-boot, started from the
# firmware's fallback path (EFI/BOOT/BOOTX64.EFI), so the VM needs no boot
# entry in its NVRAM, and no switch ever writes one; and a second disk, an
# ext4 labelled home on the whole disk, mounted on /home and grown to that
# disk the same way. Everything is found by label, never by a device name,
# so the bus a hypervisor gives a disk (virtio, SCSI, SATA) does not matter.
# tests/server/image-boot.nix boots every image on virtio-scsi, as Proxmox
# runs them; the drivers for VMware's SCSI controllers below, and the OVA's
# SATA, have not been booted in a test.
#
# Why the host carries the layout and the image does not: an image is the
# host's configuration plus the image's own module (extendModules), but every
# deploy after the first boot, `nixos-rebuild switch`, installs the host's
# own toplevel, without that module. An image that brought its own boot
# loader, file system or initrd driver would boot once, and the first deploy
# would install the boot loader elsewhere or drop the driver, so the VM would
# not come back from its next reboot. So all of that is here, and
# tests/server/images.nix checks that each image adds nothing to it.
#
# What an image still adds is its hypervisor's guest tools: open-vm-tools in
# the VMDK, VirtualBox's guest additions in the OVA. Neither is needed to
# boot. A host that lives on VMware or VirtualBox for good sets
# virtualisation.vmware.guest.enable or virtualisation.virtualbox.guest.enable
# itself, or the first deploy turns them off. Proxmox's guest agent is on
# here for every image; on another hypervisor it finds no channel and stays
# idle.
#
# Why the OVA is ravnix's own: nixpkgs' virtualbox image boots by BIOS from an
# MBR disk with GRUB on /dev/sda and adds a swap file, a different boot from
# the other two, which the first deploy of this layout would break. Ours is
# the same EFI disk as the others, with the home volume as the second disk,
# packed by VBoxManage as nixpkgs packs its own.
{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:
let
  # The home volume: an empty ext4 labelled home on the whole of a 1 GiB
  # disk, which grows to the disk the hypervisor gives it (autoResize below),
  # as a qcow2 and as a VMDK. mke2fs reserves room by default to grow a file
  # system on line to 1024 times its first size, so to 1 TiB here.
  homeVolume =
    pkgs.runCommand "ravnix-home-volume"
      {
        nativeBuildInputs = [
          pkgs.e2fsprogs
          pkgs.qemu-utils
        ];
      }
      ''
        mkdir -p $out
        truncate -s 1G home.raw
        mkfs.ext4 -q -L home -E lazy_itable_init=1,lazy_journal_init=1 home.raw
        qemu-img convert -f raw -O qcow2 home.raw $out/home.qcow2
        qemu-img convert -f raw -O vmdk -o subformat=monolithicSparse home.raw $out/home.vmdk
      '';

  # The OVA: the same EFI disk as the qcow2 and the VMDK, with the home
  # volume, as one VirtualBox machine that starts by EFI.
  ova =
    {
      config,
      lib,
      pkgs,
      modulesPath,
      ...
    }:
    let
      name = config.networking.hostName;
    in
    {
      imports = [ (modulesPath + "/image/file-options.nix") ];
      system.nixos.tags = [ "virtualbox" ];
      image.extension = "ova";
      virtualisation.virtualbox.guest.enable = true;
      system.build.image = import (modulesPath + "/../lib/make-disk-image.nix") {
        inherit config lib pkgs;
        name = "nixos-ova-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}";
        inherit (config.image) baseName;
        format = "raw";
        partitionTableType = "efi";
        postVM = ''
          export HOME=$PWD
          export PATH=${pkgs.virtualbox}/bin:${pkgs.qemu-utils}/bin:$PATH
          VBoxManage convertfromraw "$diskImage" disk.vdi
          rm "$diskImage"
          qemu-img convert -f qcow2 -O raw ${homeVolume}/home.qcow2 home.raw
          VBoxManage convertfromraw home.raw home.vdi
          rm home.raw
          VBoxManage createvm --name ${lib.escapeShellArg name} --register --ostype Linux26_64
          VBoxManage modifyvm ${lib.escapeShellArg name} --firmware efi --memory 8192 --cpus 4 \
            --nictype1 virtio --nic1 nat --rtcuseutc on --graphicscontroller vmsvga --vram 16
          VBoxManage storagectl ${lib.escapeShellArg name} --name SATA --add sata --portcount 2 --bootable on --hostiocache on
          VBoxManage storageattach ${lib.escapeShellArg name} --storagectl SATA --port 0 --device 0 --type hdd --medium disk.vdi
          VBoxManage storageattach ${lib.escapeShellArg name} --storagectl SATA --port 1 --device 0 --type hdd --medium home.vdi
          VBoxManage export ${lib.escapeShellArg name} --output "$out/${config.image.fileName}" --options manifest
          echo "file ova $out/${config.image.fileName}" > $out/nix-support/hydra-build-products
        '';
      };
    };
in
{
  # The virtio drivers and the agent for QEMU and Proxmox; the SCSI drivers
  # of VMware's two controllers, which nixpkgs' VMDK adds to its own initrd
  # (VirtualBox's SATA is among NixOS's defaults).
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];
  boot.initrd.availableKernelModules = [
    "mptspi"
    "vmw_pvscsi"
  ];
  services.qemuGuest.enable = true;

  boot.loader = {
    systemd-boot.enable = true;
    # The images' ESP is 256 MiB (make-disk-image's default); a kernel and
    # its initrd take about 30 MiB, so five generations fit with room.
    systemd-boot.configurationLimit = lib.mkDefault 5;
    efi.canTouchEfiVariables = false;
  };
  boot.growPartition = true;
  # The kernel's messages on the serial port too, for a VM with no screen
  # (Proxmox's serial0 and `qm terminal`); the screen stays the console.
  boot.kernelParams = [
    "console=ttyS0,115200"
    "console=tty0"
  ];

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/nixos";
      fsType = "ext4";
      autoResize = true;
    };
    "/boot" = {
      device = "/dev/disk/by-label/ESP";
      fsType = "vfat";
      options = [
        "fmask=0077"
        "dmask=0077"
      ];
    };
    # Mounted by the initrd, before the activation makes the account's home
    # directory: mounted later, it would hide that directory, and the user's
    # services would start in a home that does not exist. A VM without its
    # home volume therefore stops at boot, which is better than running with
    # the work on the system disk.
    "/home" = {
      device = "/dev/disk/by-label/home";
      fsType = "ext4";
      autoResize = true;
      neededForBoot = true;
    };
  };

  system.build.homeVolume = homeVolume;
  image.modules.virtualbox = lib.mkForce ova;
}
