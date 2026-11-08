# The laptop shape and the IdeaPad Pro 5 16AHP9 module, evaluated as the
# private flake will build huginn, with the template's values: the desktop
# module it brings, the disk layout as NixOS mounts it, the boot loader, the disk the shape names, the
# rule that hides the other internal disks from udisks, and the graphics,
# the kernel parameters and the initrd of the hardware. The
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
  # The key of every module in a system's module tree, as imported, before
  # the keys deduplicate it.
  keys =
    s:
    let
      walk = lib.concatMap (m: lib.optional (!m.disabled) m.key ++ walk m.imports);
    in
    walk s.graph;
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

  # The rule that hides the laptop's other internal disks from udisks, and
  # its text for the template's serial.
  hider = cfg: lib.findFirst (p: (p.name or "") == "ravnix-hide-other-disks") null cfg.services.udev.packages;
  hide = hider c;
  rules = lib.filter (l: l != "" && !lib.hasPrefix "#" l) (lib.splitString "\n" (hide.text or ""));
  hidden = [
    ''ACTION!="remove", SUBSYSTEM=="block", KERNEL=="nvme*", ENV{DEVTYPE}=="disk|partition", ENV{ID_SERIAL_SHORT}!="EXAMPLE0SERIAL", ENV{UDISKS_IGNORE}="1"''
    ''ACTION!="remove", SUBSYSTEM=="block", KERNEL=="sd*", ENV{ID_BUS}=="ata", ENV{ID_USB_VENDOR_ID}!="?*", ENV{ID_PATH}!="*-usb-*", ENV{DEVTYPE}=="disk|partition", ENV{ID_SERIAL_SHORT}!="EXAMPLE0SERIAL", ENV{UDISKS_IGNORE}="1"''
  ];
  # The shape with another serial: udev reads *?[ and | in a match as a
  # pattern, so a serial holding one must not evaluate.
  withSerial =
    serial:
    build [
      self.nixosModules.laptop
      {
        nixpkgs.hostPlatform = system;
        ravnix.laptop.diskSerial = lib.mkForce serial;
      }
    ];
  patterns = [
    "EXAMPLE*"
    "EXAMPLE?"
    "EXAMPLE[0]"
    "EXAMPLE|KEEP0SERIAL"
    "EXAMPLE SERIAL"
    "EXAMPLE\"SERIAL"
    "EXAMPLE\\SERIAL"
    "EXAMPLE\nSERIAL"
  ];

  initrdModules = c.boot.initrd.availableKernelModules ++ c.boot.initrd.kernelModules;
  params = c.boot.kernelParams;
  nvidia = c.hardware.nvidia;

  failures =
    # The whole system, and the shape alone and imported twice.
    check (evaluates huginn) "huginn (the shape and the hardware module) does not evaluate"
    ++ check (evaluates bare) "the shape without a hardware module does not evaluate"
    ++ check (evaluates twice) "the shape and the hardware module imported twice do not evaluate"

    # The desktop comes with the shape, and the common module it brings as
    # well is loaded once: the key deduplicates it, so its options have one
    # declaration each.
    ++ check (has (keys huginn) "ravnix/nixosModules.desktop") "the shape does not bring nixosModules.desktop"
    ++ check (has (keys bare) "ravnix/nixosModules.desktop") "the shape without a hardware module does not bring nixosModules.desktop"
    ++ check (
      lib.length huginn.options.ravnix.user.name.declarations == 1
    ) "the common module's options are declared more than once"

    # The disk the shape names: by model and serial, from the private flake.
    ++ check (lib.attrNames c.disko.devices.disk == [ "huginn" ]) "the shape describes other disks than huginn's one"
    ++ check (
      c.disko.devices.disk.huginn.device == "/dev/disk/by-id/nvme-Example_SSD_1TB_EXAMPLE0SERIAL"
    ) "the shape's disk is ${c.disko.devices.disk.huginn.device}, not the by-id path of the template's model and serial"

    # The other internal disks, hidden from udisks by the serial, in a rule
    # file after 60-persistent-storage, which sets ID_SERIAL_SHORT, and
    # 80-udisks2; with or without a hardware module.
    ++ check (hide != null) "no udev rule hides the laptop's other internal disks from udisks"
    ++ check (
      (hide.destination or null) == "/lib/udev/rules.d/90-ravnix-hide-other-disks.rules"
    ) "the rule hiding the other disks is ${builtins.toJSON (hide.destination or null)}, not lib/udev/rules.d/90-ravnix-hide-other-disks.rules"
    ++ check (rules == hidden) "the rules hiding the other disks are ${builtins.toJSON rules}, not ${builtins.toJSON hidden}"
    ++ check (hider bare.config != null) "the shape without a hardware module hides no disk"
    ++ map (s: "the shape evaluates with the serial ${builtins.toJSON s}, which the rule would read as a pattern") (
      lib.filter (s: evaluates (withSerial s)) patterns
    )

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
    # The kernel and driver of the Fedora power baseline: 7.2 and 615.
    ++ check (
      lib.versions.majorMinor c.boot.kernelPackages.kernel.version == "7.2"
    ) "the kernel is ${c.boot.kernelPackages.kernel.version}, not the 7.2 of the Fedora power baseline"
    ++ check (
      lib.versions.major nvidia.package.version == "615"
    ) "the NVIDIA driver is ${nvidia.package.version}, not the 615 of the Fedora power baseline"
    ++ check (lib.any (p: lib.hasPrefix "nvidia-open-615." (p.name or "")) c.boot.extraModulePackages) "the kernel does not get the open NVIDIA modules of 615"
    ++ check (has params "amdgpu.abmlevel=2") "no amdgpu.abmlevel=2"
    ++ check (has params "rd.driver.blacklist=nouveau") "no rd.driver.blacklist=nouveau"
    ++ check (has c.boot.blacklistedKernelModules "nouveau") "nouveau is not blacklisted"
    ++ check (!has initrdModules "nouveau") "nouveau is in the initrd"
    ++ check (has c.boot.kernelModules "kvm-amd") "no kvm-amd"

    # The initrd finds the NVMe disk on the laptop and in QEMU, where the disk
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
