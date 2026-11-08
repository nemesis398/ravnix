# The Lenovo IdeaPad Pro 5 16AHP9 with the Ryzen 7 8845HS (Hawk Point): its
# Radeon 780M drives the panel and the desktop, and its RTX 4050 renders
# only what is started through `prime-run`, and is powered off (D3cold) the
# rest of the time. The private flake imports this beside
# nixosModules.laptop. Beside this file, and imported by it:
#
#   power.nix    the CPU policy (tuned and its three laptop profiles behind
#                the power-profiles API), the energy menu and its watcher,
#                the RAPL counters for Waybar
#   battery.nix  the battery safety net (UPower's PowerOff and the
#                emergency poweroff timer) and the charge mode
#   nvidia.nix   the dGPU around a suspend: no nvidia-powerd, where the
#                video memory is saved
#   panel.nix    the panel's ABM level, pinned
#
# Each file has the Fedora workaround it carries over and why it is still
# needed. tests/hardware/power.nix runs the power parts in a VM, and
# tests/laptop/shape.nix checks all of it on huginn's configuration.
#
# Task 3.7 checks, on the real laptop, what neither test can show. Each
# reads without changing anything, except 4 (a suspend) and 9 (a mode
# switch, set back after):
#   1. The power draw: the median watts at idle and under light load, on
#      battery, no higher than Fedora's (Task 0.1's baseline).
#   2. The dGPU asleep at idle: /sys/bus/pci/devices/0000:01:00.0/power/
#      runtime_status says `suspended` (read it before any nvidia-smi or
#      lspci, which wake the card); no nvidia-powerd or nvidia-persistenced
#      process.
#   3. The driver's parameters, in /proc/driver/nvidia/params:
#      PreserveVideoMemoryAllocations 1, UseKernelSuspendNotifiers 1,
#      TemporaryFilePath "/var/lib/systemd/sleep", DynamicPowerManagement 2
#      (Fedora runs 3, the driver's auto, which on this Ada laptop GPU means
#      the same fine-grained mode).
#   4. A suspend that completes: `rtcwake -m no -s 60; systemctl suspend`,
#      then the journal shows a real gap between "PM: suspend entry" and
#      "PM: suspend exit", no "Failed to put system to sleep", no Xid and no
#      "NVRM: PM suspend notifier failed", and the dGPU is `suspended`
#      again. Then the same once without SYSTEMD_SLEEP_FREEZE_USER_SESSIONS
#      (nvidia.nix) by a runtime drop-in: if that suspend completes too, the
#      setting may go.
#   5. The panel: /sys/module/amdgpu/parameters/abmlevel is 2, the eDP
#      connector has no amdgpu/panel_power_savings, and the panel's
#      brightness does not change when the charger goes in or out.
#      /sys/class/backlight/nvidia_wmi_ec_backlight exists.
#   6. The CPU policy of each profile, from cpufreq's
#      energy_performance_preference, scaling_governor and boost and
#      /sys/firmware/acpi/platform_profile: on the charger balanced is
#      laptop-ac (EPP performance); on battery laptop-battery (EPP
#      balance_performance, boost 1), and performance laptop-performance-
#      battery (governor powersave, EPP performance, platform profile
#      performance); tuned-adm active names each.
#   7. The safety net on BAT0: `upower -d` shows critical-action PowerOff,
#      the timer is listed by `systemctl list-timers`, and after its first
#      run `systemctl show -p ConditionResult
#      battery-emergency-poweroff.service` says yes.
#   8. The RAPL counter readable by the user: stat -c %a
#      /sys/class/powercap/intel-rapl:0/energy_uj prints 444, and Waybar
#      shows the CPU's watts.
#   9. The charge mode: `charge-mode` prints the saved mode after a boot
#      (Long_Life on a new install), and `charge-mode set Standard`, then
#      `charge-mode set Long_Life`, work without a password.
#  10. energy-watch active in the Sway session; an unplug switches
#      keep-awake off, and `energy refresh` on power-saver puts the panel at
#      60 Hz. With Focus bar on, unplug (the watcher relaunches Waybar), then
#      click Waybar's battery: the charge mode changes without an error, so
#      the relaunched Waybar found the setuid sudo.
#  11. The swap: `swapon --show` lists /dev/zram0 alone, 8 GiB, and
#      /sys/block/zram0/comp_algorithm says lzo-rle.
#  12. As on Fedora, with nothing set for it here: `iw dev <wlan> get
#      power_save` says on (NetworkManager left at its default), and the
#      s2idle drain overnight stays near 0.25 to 0.3 % per hour.
#
# nixos-hardware was checked first and is not used: it has no profile for
# this model. Its lenovo/ideapad/16ahp9 is the IdeaPad 5 2-in-1 16AHP9, a
# machine without a discrete GPU, and its common pieces would bring little
# but TLP as a default, which would preempt Task 3.4's choice of the CPU
# policy. The PRIME setup has to be written here anyway, with this laptop's
# bus IDs.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  # What this module sets on nixpkgs, in a module of its own that a NixOS VM
  # test node can do without. A node's read-only pkgs
  # (nixos/modules/misc/nixpkgs/read-only.nix) declares nixpkgs.config, makes
  # nixpkgs.hostPlatform read-only, and counts every definition of a read-only
  # option, even one under mkIf false: on such a node the definitions must be
  # absent, not switched off. The probe is the one of nixosModules.common and of
  # the desktop's apps module. A node that imports this module allows the driver
  # itself, with allowUnfreePredicate (tests/desktop/vm-node.nix).
  nixpkgsSettings =
    { lib, options, ... }:
    {
      config =
        lib.optionalAttrs
          (
            !lib.any (lib.hasSuffix "/misc/nixpkgs/read-only.nix") (
              map toString options.nixpkgs.config.declarations
            )
          )
          {
            nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

            # The NVIDIA driver is unfree, and allowed by its name and nothing
            # else. allowUnfreePackages merges with the lists of other modules,
            # unlike allowUnfreePredicate.
            nixpkgs.config.allowUnfreePackages = [ "nvidia-x11" ];
          };
    };
in
{
  imports = [
    nixpkgsSettings
    ./power.nix
    ./battery.nix
    ./nvidia.nix
    ./panel.nix
  ];

  # The kernel and the NVIDIA driver of the Fedora power baseline, the one
  # stack measured on this laptop: kernel 7.2.15 and driver 615.78.08 (the
  # open modules). Task 3.7 compares huginn against it, so the same pair
  # leaves only the configuration to differ. 7.2 is no LTS kernel: when a
  # nixpkgs bump drops linuxPackages_7_2, the evaluation fails, loudly, and
  # the kernel is moved on purpose then, with the baseline measured again.
  boot.kernelPackages = lib.mkDefault pkgs.linuxPackages_7_2;

  hardware = {
    cpu.amd.updateMicrocode = true;
    # amdgpu's firmware for the 780M, and the MT7922 Wi-Fi's.
    enableRedistributableFirmware = true;
    graphics.enable = true;
    # amdgpu in the initrd, so the passphrase prompt is drawn on the panel at
    # its own resolution.
    amdgpu.initrd.enable = true;

    nvidia = {
      # NVIDIA's new-feature branch, 615 with this kernel (see above).
      package = lib.mkDefault config.boot.kernelPackages.nvidiaPackages.latest;
      # The open kernel modules, which NVIDIA recommends for Ada GPUs such
      # as the RTX 4050, and which Fedora runs on this laptop today.
      open = true;
      modesetting.enable = true;
      # A GUI for X screens; huginn runs no X server.
      nvidiaSettings = false;
      prime = {
        # Render offload: the 780M is the display GPU, and a program runs on
        # the RTX 4050 only when started with prime-run (the name the Fedora
        # setup used), which sets __NV_PRIME_RENDER_OFFLOAD and the GLX and
        # Vulkan vendor.
        offload = {
          enable = true;
          enableOffloadCmd = true;
          offloadCmdMainProgram = "prime-run";
        };
        # From `lspci -D` on this laptop: the RTX 4050 at 0000:01:00.0 and
        # the 780M at 0000:36:00.0. NixOS takes the bus in decimal: 0x36 is 54.
        nvidiaBusId = "PCI:1:0:0";
        amdgpuBusId = "PCI:54:0:0";
      };
      powerManagement = {
        # Fine-grained runtime power management (RTD3): with nothing on it,
        # the driver powers the RTX 4050 off, and it reports `suspended`.
        # Task 3.7 measures that at idle.
        finegrained = true;
        # Keep the dGPU's memory across suspend; nvidia.nix has where the
        # driver spills it, and why.
        enable = true;
      };
    };
  };
  # Loads the NVIDIA driver; the X server stays off, Sway is Wayland.
  services.xserver.videoDrivers = [
    "modesetting"
    "nvidia"
  ];

  boot = {
    # amdgpu.abmlevel=2 is panel.nix's.
    kernelParams = [
      # As on Fedora. dracut reads it there; NixOS's initrd does not, and
      # holds no nouveau anyway. What keeps nouveau (and nova_core and
      # nvidiafb) out on NixOS is the NVIDIA module's
      # boot.blacklistedKernelModules.
      "rd.driver.blacklist=nouveau"
    ];
    kernelModules = [ "kvm-amd" ];
    initrd.availableKernelModules = [
      # The NVMe disk, and a keyboard or the YubiKey on USB or a USB4 dock
      # at the passphrase prompt.
      "nvme"
      "xhci_pci"
      "thunderbolt"
      "usbhid"
      # QEMU, which boots the installed disk from Fedora as a virtio disk.
      "virtio_pci"
      "virtio_blk"
      "virtio_scsi"
    ];
  };
}
