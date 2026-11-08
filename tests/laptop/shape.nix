# The laptop shape and the IdeaPad Pro 5 16AHP9 module, evaluated as the
# private flake will build huginn, with the template's values: the desktop
# module it brings, the disk layout as NixOS mounts it, the swap (zram
# alone), the boot loader, the disk the shape names, the rule that hides the
# other internal disks from udisks, and the graphics, the kernel parameters
# and the initrd of the hardware, with its power parts: the NVIDIA suspend
# settings, which no VM can run (tests/hardware/power.nix runs the rest),
# and the CPU policy, the battery safety net and the charge mode as huginn
# composes them. The whole system must evaluate, its assertions and the
# NVIDIA driver's licence included, without building anything.
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
  # the keys deduplicate it: of every module that is not disabled, and of
  # none below a disabled one, which the module system never reaches.
  keys =
    s:
    let
      walk = lib.concatMap (m: lib.optionals (!m.disabled) ([ m.key ] ++ walk m.imports));
    in
    walk s.graph;
  # How many copies of the common module a system loads, counted by what
  # each copy adds: homeModules.common, by its key, in
  # home-manager.sharedModules.
  copies = s: lib.count (m: builtins.isAttrs m && (m.key or null) == "ravnix/homeModules.common") s.config.home-manager.sharedModules;
  # huginn with common's inner module loaded once more without its key, as
  # a common whose key stopped working would be: the count has to see it.
  unkeyed = build [
    self.nixosModules.laptop
    self.nixosModules.hardware-ideapad-pro-5-16ahp9
    (import ../../modules/common/nixos.nix { inherit self; })
  ];
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

  # The power parts of the hardware module (its power.nix, battery.nix,
  # nvidia.nix and panel.nix).
  imported = file: lib.any (k: lib.hasSuffix "/modules/hardware/ideapad-pro-5-16ahp9/${file}" (toString k)) (keys huginn);
  tuned = c.services.tuned;
  upower = c.services.upower;
  zram = s: s.config.zramSwap;
  zramAsFedora =
    s:
    (zram s).enable
    && (zram s).memoryPercent == 100
    && (zram s).memoryMax == 8 * 1024 * 1024 * 1024
    && (zram s).algorithm == "lzo-rle"
    && (zram s).priority == 100;
  laptopProfiles = {
    laptop-ac = {
      main = {
        summary = "Laptop on AC, balanced: tuned balanced with EPP performance (ravnix)";
        include = "balanced";
      };
      cpu.energy_performance_preference = "performance";
    };
    laptop-battery = {
      main = {
        summary = "Laptop on battery, balanced: balanced-battery with EPP balance_performance (ravnix)";
        include = "balanced-battery";
      };
      cpu = {
        energy_performance_preference = "balance_performance";
        boost = 1;
      };
    };
    laptop-performance-battery = {
      main = {
        summary = "Laptop on battery, performance: EPP performance under the powersave governor (ravnix)";
        include = "balanced";
      };
      cpu = {
        governor = "powersave";
        energy_performance_preference = "performance";
        boost = 1;
      };
      acpi.platform_profile = "performance";
    };
  };
  service = name: c.systemd.services.${name} or { };
  rapl = lib.findFirst (p: (p.name or "") == "rapl-readable-udev-rules") null c.services.udev.packages;
  chargeRule = lib.filter (
    r:
    r.users or [ ] == [ c.ravnix.user.username ]
    && (r.runAs or null) == "root"
    && lib.any (
      cmd:
      lib.hasSuffix "/bin/charge-mode-apply" (cmd.command or "") && (cmd.options or [ ]) == [ "NOPASSWD" ]
    ) (r.commands or [ ])
  ) c.security.sudo.extraRules;
  modprobe = c.boot.extraModprobeConfig;
  sleepUnits = [
    "systemd-suspend"
    "systemd-hibernate"
    "systemd-hybrid-sleep"
    "systemd-suspend-then-hibernate"
  ];

  failures =
    # The whole system, and the shape alone and imported twice.
    check (evaluates huginn) "huginn (the shape and the hardware module) does not evaluate"
    ++ check (evaluates bare) "the shape without a hardware module does not evaluate"
    ++ check (evaluates twice) "the shape and the hardware module imported twice do not evaluate"

    # The desktop comes with the shape. It brings the common module, which
    # the shape imports too; the key loads it once, so it adds its home
    # modules once. An unkeyed second copy would add them again.
    ++ check (has (keys huginn) "ravnix/nixosModules.desktop") "the shape does not bring nixosModules.desktop"
    ++ check (has (keys bare) "ravnix/nixosModules.desktop") "the shape without a hardware module does not bring nixosModules.desktop"
    ++ check (copies huginn == 1) "huginn loads the common module ${toString (copies huginn)} times, not once"
    ++ check (
      copies unkeyed == 2
    ) "a second, unkeyed copy of the common module counts ${toString (copies unkeyed)}, not 2: the count above cannot fail"

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
    # zram, as Fedora has it: the smaller of the RAM and 8 GiB, lzo-rle,
    # priority 100; with or without a hardware module.
    ++ check (zramAsFedora huginn) "huginn's zram is not on, or not min(RAM, 8 GiB) with lzo-rle at priority 100"
    ++ check (zramAsFedora bare) "the shape without a hardware module has no zram as Fedora's"

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
    ++ check (lib.count (p: p == "amdgpu.abmlevel=2") params == 1) "amdgpu.abmlevel=2 is not on the command line once"
    ++ check (!lib.any (p: lib.hasPrefix "amdgpu.abmlevel=" p && p != "amdgpu.abmlevel=2") params) "another amdgpu.abmlevel is on the command line"
    ++ check (has params "rd.driver.blacklist=nouveau") "no rd.driver.blacklist=nouveau"
    ++ check (has c.boot.blacklistedKernelModules "nouveau") "nouveau is not blacklisted"
    ++ check (!has initrdModules "nouveau") "nouveau is in the initrd"
    ++ check (has c.boot.kernelModules "kvm-amd") "no kvm-amd"

    # The power parts: each file of the hardware module is imported.
    ++ lib.concatMap (f: check (imported f) "the hardware module does not import its ${f}") [
      "power.nix"
      "battery.nix"
      "nvidia.nix"
      "panel.nix"
    ]

    # The CPU policy: tuned alone, with Fedora's three laptop profiles and
    # its power-profiles mapping.
    ++ check (tuned.enable && tuned.ppdSupport) "tuned and tuned-ppd are not on"
    ++ check (!c.services.power-profiles-daemon.enable && !c.services.tlp.enable && !c.services.auto-cpufreq.enable) "a second owner of the CPU policy is on"
    ++ check (lib.getAttrs (lib.attrNames laptopProfiles) tuned.profiles == laptopProfiles) "the laptop profiles are not Fedora's"
    ++ check (tuned.ppdSettings.main.default == "balanced" && tuned.ppdSettings.main.battery_detection) "tuned-ppd does not start balanced with battery detection"
    ++ check (
      tuned.ppdSettings.profiles == {
        power-saver = "powersave";
        balanced = "laptop-ac";
        performance = "throughput-performance";
      }
    ) "tuned-ppd's AC mapping is ${builtins.toJSON tuned.ppdSettings.profiles}"
    ++ check (
      tuned.ppdSettings.battery == {
        balanced = "laptop-battery";
        performance = "laptop-performance-battery";
      }
    ) "tuned-ppd's battery mapping is ${builtins.toJSON tuned.ppdSettings.battery}"
    ++ check (!tuned.settings.dynamic_tuning) "tuned's dynamic tuning is on, which wakes it every 10 s"
    ++ check (has c.environment.systemPackages c.services.tuned.package) "tuned-adm is not installed"
    ++ check (lib.elem "sway-session.target" (c.systemd.user.services.energy-watch.wantedBy or [ ])) "energy-watch does not start with the Sway session"
    ++ check (
      rapl != null && (rapl.destination or null) == "/lib/udev/rules.d/99-rapl-readable.rules"
    ) "no udev rule makes the RAPL counters readable"

    # The battery safety net, both layers.
    ++ check (upower.enable && upower.criticalPowerAction == "PowerOff") "UPower's critical action is not PowerOff"
    ++ check (
      upower.usePercentageForPolicy
      && upower.percentageAction == 2
      && upower.percentageCritical == 5
      && upower.percentageLow == 20
      && !upower.allowRiskyCriticalPowerAction
    ) "UPower does not act at 2 % by the percentage"
    ++ check (
      has (c.systemd.timers.battery-emergency-poweroff.wantedBy or [ ]) "timers.target"
      && (c.systemd.timers.battery-emergency-poweroff.timerConfig or { }) == {
        OnBootSec = "2min";
        OnUnitActiveSec = "2min";
        AccuracySec = "30s";
      }
    ) "battery-emergency-poweroff.timer does not run every 2 minutes from boot"
    ++ check (
      ((service "battery-emergency-poweroff").unitConfig.ConditionPathExists or null)
      == "/sys/class/power_supply/BAT0"
      && lib.hasSuffix "/bin/battery-emergency-poweroff" (
        (service "battery-emergency-poweroff").serviceConfig.ExecStart or ""
      )
    ) "battery-emergency-poweroff.service does not watch BAT0 with no argument"

    # The charge mode.
    ++ check (has ((service "charge-mode-restore").wantedBy or [ ]) "multi-user.target") "charge-mode-restore does not run at boot"
    ++ check (lib.length chargeRule == 1) "the user has not exactly one sudo rule, NOPASSWD as root, for charge-mode-apply"
    ++ check (
      (c.systemd.tmpfiles.settings."10-charge-mode"."/var/lib/charge-mode".f.argument or null) == "Long_Life\n"
    ) "a new install does not start from Long_Life"

    # The dGPU around a suspend (nvidia.nix): no nvidia-powerd or
    # nvidia-persistenced, the video memory saved by the kernel notifier
    # into /var/lib/systemd/sleep, and the sessions not frozen.
    ++ check (!nvidia.dynamicBoost.enable && !(c.systemd.services ? nvidia-powerd)) "nvidia-powerd is on, and holds the dGPU awake"
    ++ check (!nvidia.nvidiaPersistenced && !(c.systemd.services ? nvidia-persistenced)) "nvidia-persistenced is on, which disables RTD3"
    ++ check nvidia.powerManagement.kernelSuspendNotifier "the driver's kernel suspend notifier is off"
    ++ lib.concatMap (p: check (lib.hasInfix p modprobe) "the NVIDIA module options lack ${p}") [
      "NVreg_UseKernelSuspendNotifiers=1"
      "NVreg_PreserveVideoMemoryAllocations=1"
      "NVreg_TemporaryFilePath=/var/lib/systemd/sleep"
    ]
    ++ check (
      !(c.systemd.services ? nvidia-suspend)
      && !(c.systemd.services ? nvidia-resume)
      && !(c.systemd.services ? nvidia-hibernate)
    ) "the legacy nvidia-suspend services are on beside the kernel notifier"
    ++ check (
      lib.getAttrs [ "mode" "user" "group" ] (
        c.systemd.tmpfiles.settings."10-nvidia-sleep"."/var/lib/systemd/sleep".d or {
          mode = null;
          user = null;
          group = null;
        }
      ) == {
        mode = "0700";
        user = "root";
        group = "root";
      }
    ) "/var/lib/systemd/sleep is not made root's alone"
    ++ lib.concatMap (
      u:
      check (
        ((service u).environment.SYSTEMD_SLEEP_FREEZE_USER_SESSIONS or null) == "false"
      ) "${u} freezes the user sessions"
    ) sleepUnits

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
