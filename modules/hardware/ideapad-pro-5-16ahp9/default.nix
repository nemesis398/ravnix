# The Lenovo IdeaPad Pro 5 16AHP9 with the Ryzen 7 7840HS: its Radeon 780M
# drives the panel and the desktop, and its RTX 4050 renders only what is
# started through `prime-run`, and is powered off (D3cold) the rest of the
# time. The private flake imports this beside nixosModules.laptop.
# Task 3.4 adds the power, battery, panel and NVIDIA suspend modules of this
# directory.
#
# nixos-hardware was checked first and is not used: it has no profile for
# this model. Its lenovo/ideapad/16ahp9 is the IdeaPad 5 2-in-1 16AHP9, a
# machine without a discrete GPU, and its common pieces would bring little
# but TLP as a default, which would preempt Task 3.4's choice of the CPU
# policy. The PRIME setup has to be written here anyway, with this laptop's
# bus IDs.
{ lib, ... }:
{
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  # The NVIDIA driver is unfree, and allowed by its name and nothing else.
  # allowUnfreePackages merges with the lists of other modules, unlike
  # allowUnfreePredicate.
  nixpkgs.config.allowUnfreePackages = [ "nvidia-x11" ];

  hardware = {
    cpu.amd.updateMicrocode = true;
    # amdgpu's firmware for the 780M, and the MT7922 Wi-Fi's.
    enableRedistributableFirmware = true;
    graphics.enable = true;
    # amdgpu in the initrd, so the passphrase prompt is drawn on the panel at
    # its own resolution.
    amdgpu.initrd.enable = true;

    nvidia = {
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
        # Keep the dGPU's memory across suspend. Task 3.4 settles where the
        # driver spills it.
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
    kernelParams = [
      # Panel brightness management at level 2, as on Fedora.
      "amdgpu.abmlevel=2"
      # As on Fedora. dracut reads it there; NixOS's initrd does not, and
      # holds no nouveau anyway. What keeps nouveau (and nova_core and
      # nvidiafb) out on NixOS is the NVIDIA module's
      # boot.blacklistedKernelModules.
      "rd.driver.blacklist=nouveau"
    ];
    kernelModules = [ "kvm-amd" ];
    initrd.availableKernelModules = [
      # The Samsung NVMe, and a keyboard or the YubiKey on USB or a USB4 dock
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
