# The laptop shape and the IdeaPad Pro 5 16AHP9 module, evaluated as the
# private flake will build huginn, with the template's values: the disk
# layout as NixOS mounts it, the boot loader, the disk the shape names, and
# the graphics, the kernel parameters and the initrd of the hardware. The
# whole system must evaluate, its assertions and the NVIDIA driver's licence
# included, without building anything.
{
  self,
  inputs,
  lib,
  pkgs,
  system,
  ...
}:
let
  me = ../../templates/default/me.nix;
  build =
    modules:
    inputs.nixpkgs.lib.nixosSystem {
      modules = [
        me
        { system.stateVersion = "26.05"; }
      ]
      ++ modules;
    };
  huginn = build [
    self.nixosModules.laptop
    self.nixosModules.hardware-ideapad-pro-5-16ahp9
  ];
  c = huginn.config;
  # The shape without a hardware module, as a second laptop model would use it.
  bare = build [
    self.nixosModules.laptop
    { nixpkgs.hostPlatform = system; }
  ];
  # The shape, the hardware module and both again: each has a key.
  twice = build [
    self.nixosModules.laptop
    self.nixosModules.hardware-ideapad-pro-5-16ahp9
    self.nixosModules.laptop
    self.nixosModules.hardware-ideapad-pro-5-16ahp9
  ];

  evaluates = s: (builtins.tryEval (builtins.unsafeDiscardStringContext s.config.system.build.toplevel.drvPath)).success;
  fs = c.fileSystems;
  has = list: x: lib.elem x list;
  check = cond: msg: lib.optional (!cond) msg;

  subvolume =
    mount: name:
    check (
      fs ? ${mount}
      && fs.${mount}.device == "/dev/mapper/cryptroot"
      && fs.${mount}.fsType == "btrfs"
      && has fs.${mount}.options "subvol=${name}"
      && has fs.${mount}.options "compress=zstd"
    ) "${mount} is not the btrfs subvolume ${name} in cryptroot with compress=zstd";

  initrdModules = c.boot.initrd.availableKernelModules ++ c.boot.initrd.kernelModules;
  params = c.boot.kernelParams;
  nvidia = c.hardware.nvidia;

  failures =
    # The whole system, and the shape alone and imported twice.
    check (evaluates huginn) "huginn (the shape and the hardware module) does not evaluate"
    ++ check (evaluates bare) "the shape without a hardware module does not evaluate"
    ++ check (evaluates twice) "the shape and the hardware module imported twice do not evaluate"

    # The disk the shape names: by model and serial, from the private flake.
    ++ check (lib.attrNames c.disko.devices.disk == [ "huginn" ]) "the shape describes other disks than huginn's one"
    ++ check (
      c.disko.devices.disk.huginn.device == "/dev/disk/by-id/nvme-Example_SSD_1TB_EXAMPLE0SERIAL"
    ) "the shape's disk is ${c.disko.devices.disk.huginn.device}, not the by-id path of the template's model and serial"

    # The layout, as NixOS mounts it.
    ++ subvolume "/" "@"
    ++ subvolume "/home" "@home"
    ++ subvolume "/nix" "@nix"
    ++ subvolume "/var/log" "@log"
    ++ check (
      fs ? "/boot" && fs."/boot".fsType == "vfat" && fs."/boot".device == "/dev/disk/by-partlabel/disk-huginn-ESP"
    ) "/boot is not the vfat ESP"
    ++ check (
      c.boot.initrd.luks.devices ? cryptroot
      && c.boot.initrd.luks.devices.cryptroot.device == "/dev/disk/by-partlabel/disk-huginn-luks"
    ) "the initrd does not open cryptroot from the LUKS partition"
    ++ check (c.boot.initrd.luks.devices.cryptroot.allowDiscards or false) "cryptroot does not pass discards to the SSD"
    ++ check (c.swapDevices == [ ]) "huginn has a swap device; zram is its only swap"

    # The boot loader: systemd-boot on the ESP, and no write to the
    # firmware's boot entries; the install adds its entry on purpose.
    ++ check c.boot.loader.systemd-boot.enable "the boot loader is not systemd-boot"
    ++ check (!c.boot.loader.grub.enable) "GRUB is enabled"
    ++ check (!c.boot.loader.efi.canTouchEfiVariables) "a switch would write the firmware's boot entries"

    # The hardware: the 780M drives the panel, the RTX 4050 renders on
    # demand and sleeps otherwise.
    ++ check (c.nixpkgs.hostPlatform.system == "x86_64-linux") "the hardware module does not name the platform"
    ++ check c.hardware.cpu.amd.updateMicrocode "no AMD microcode updates"
    ++ check c.hardware.enableRedistributableFirmware "no firmware for the 780M and the Wi-Fi"
    ++ check c.hardware.amdgpu.initrd.enable "amdgpu is not in the initrd, so the passphrase prompt is not on the panel"
    ++ check c.hardware.graphics.enable "no graphics stack"
    ++ check (has c.services.xserver.videoDrivers "nvidia") "the NVIDIA driver is not enabled"
    ++ check nvidia.enabled "the NVIDIA driver is not enabled"
    ++ check (nvidia.open == true) "not the open NVIDIA kernel modules, which Ada GPUs take"
    ++ check nvidia.modesetting.enable "no NVIDIA modesetting"
    ++ check nvidia.prime.offload.enable "no PRIME offload"
    ++ check (!nvidia.prime.sync.enable && !nvidia.prime.reverseSync.enable) "PRIME sync keeps the dGPU awake"
    ++ check nvidia.prime.offload.enableOffloadCmd "no offload command"
    ++ check (nvidia.prime.offload.offloadCmdMainProgram == "prime-run") "the offload command is not prime-run, as on Fedora"
    ++ check (nvidia.prime.amdgpuBusId == "PCI:54:0:0") "the 780M is not at PCI:54:0:0 (0000:36:00.0)"
    ++ check (nvidia.prime.nvidiaBusId == "PCI:1:0:0") "the RTX 4050 is not at PCI:1:0:0 (0000:01:00.0)"
    ++ check nvidia.powerManagement.enable "no NVIDIA power management"
    ++ check nvidia.powerManagement.finegrained "no fine-grained runtime power management for the dGPU"
    ++ check (lib.hasInfix "NVreg_DynamicPowerManagement=0x02" c.boot.extraModprobeConfig) "the dGPU's runtime D3 is not on"
    ++ check (has params "amdgpu.abmlevel=2") "no amdgpu.abmlevel=2"
    ++ check (has params "rd.driver.blacklist=nouveau") "no rd.driver.blacklist=nouveau"
    ++ check (has c.boot.blacklistedKernelModules "nouveau") "nouveau is not blacklisted"
    ++ check (!has initrdModules "nouveau") "nouveau is in the initrd"
    ++ check (has c.boot.kernelModules "kvm-amd") "no kvm-amd"

    # The initrd finds the Samsung on the laptop and in QEMU, where the disk
    # is passed through as a virtio device.
    ++ lib.concatMap (m: check (has initrdModules m) "the initrd lacks ${m}") [
      "nvme"
      "xhci_pci"
      "thunderbolt"
      "usbhid"
      "virtio_pci"
      "virtio_blk"
      "virtio_scsi"
    ];
in
pkgs.runCommand "laptop-shape" { } (
  if failures == [ ] then
    ''
      touch $out
    ''
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
