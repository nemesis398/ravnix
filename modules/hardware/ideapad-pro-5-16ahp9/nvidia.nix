# The RTX 4050 around a suspend: what keeps it asleep at idle and what lets
# a lid-close suspend complete. ./default.nix sets up the driver, PRIME
# offload and its runtime power management (RTD3).
#
# Why this matters: on the Fedora laptop suspend never succeeded until
# 2026-07-15, and a failing suspend is a battery that runs flat with the
# lid closed: s2idle aborted within a second, logind tried again every
# 30 seconds, 379 times one night, and the battery was at 0 % by morning,
# twice (./battery.nix has the safety net that came of it). Two Fedora
# workarounds fixed it; each is decided below for driver 615 on kernel 7.2
# under NixOS, from its documented root cause.
#
# 1. nvidia-powerd stays off (Fedora's nvidia-dgpu-suspend-fix). Kept.
#    RPM Fusion enables nvidia-powerd (Dynamic Boost), which on this laptop
#    failed every 2 seconds ("Failed to get AC Line status") and held the
#    dGPU awake; at lid close the driver's suspend notifier could not
#    suspend the live GPU and s2idle aborted. NixOS runs nvidia-powerd only
#    with hardware.nvidia.dynamicBoost.enable, which is off by default; it
#    is set off here so the reason stays with it. The same holds for
#    nvidia-persistenced, which in UVM persistence mode disables RTD3.
#    The script's second half, a udev settle before SDDM's Sway greeter
#    against a cold-boot "Wayland socket watcher timed out", is dropped:
#    huginn has no SDDM, and greetd's tuigreet draws on a console, so no
#    compositor races udev at boot.
#
# 2. The VRAM spill goes to /var/lib/systemd/sleep (Fedora's
#    nvidia-suspend-vram-fix). Kept, for a reason that changed. With the
#    open modules, driver 595 and later save and restore the video memory
#    in their kernel suspend notifier (NVreg_UseKernelSuspendNotifiers=1,
#    with NVreg_PreserveVideoMemoryAllocations=1; NixOS sets both through
#    powerManagement.enable and kernelSuspendNotifier, and runs none of the
#    legacy nvidia-suspend services then), inside systemd-sleep's process.
#    On Fedora the spill file sat in /var/tmp, which SELinux forbids
#    systemd-sleep to write: the write failed, the GSP crashed (Xid 120,
#    then 154) and every suspend aborted (rfbz#7428). NixOS has no SELinux,
#    so that cause is gone. The path stays for the other rule Fedora's
#    notes give: the spill must never land on a tmpfs. Unset, the driver
#    spills to /tmp, which is on disk on huginn today but would be RAM the
#    day boot.tmp.useTmpfs is turned on, and a spill that does not fit
#    fails the suspend the same way. /var/lib/systemd/sleep is on the
#    btrfs root, root's alone (0700), and the path the baseline ran with.
#
#    With it, RPM Fusion's packaging turns off systemd's freezing of the
#    user sessions during a suspend (SYSTEMD_SLEEP_FREEZE_USER_SESSIONS=
#    false on systemd-suspend and its kin), and Fedora's notes say to leave
#    it. Its stated reason is an Xorg server that, frozen, cannot answer a
#    VT switch during the suspend. huginn runs no Xorg (Xwayland holds no
#    VT), and NixOS installs no nvidia-sleep.sh, the script that switched
#    VTs, so the need is likely gone, but nothing here proves it. Kept all
#    the same: the baseline's working suspend had it, NixOS does not set
#    it, and a suspend that hangs is the drain above. Task 3.7 tries a
#    suspend without it (the module's header).
{ lib, ... }:
{
  hardware.nvidia = {
    dynamicBoost.enable = false;
    nvidiaPersistenced = false;
    # The default for the open modules of 595 and later, said here because
    # the spill below depends on it.
    powerManagement.kernelSuspendNotifier = true;
    moduleParams.nvidia.NVreg_TemporaryFilePath = "/var/lib/systemd/sleep";
  };

  systemd.tmpfiles.settings."10-nvidia-sleep"."/var/lib/systemd/sleep".d = {
    mode = "0700";
    user = "root";
    group = "root";
  };

  systemd.services =
    lib.genAttrs
      [
        "systemd-suspend"
        "systemd-hibernate"
        "systemd-hybrid-sleep"
        "systemd-suspend-then-hibernate"
      ]
      (_: {
        environment.SYSTEMD_SLEEP_FREEZE_USER_SESSIONS = "false";
      });
}
