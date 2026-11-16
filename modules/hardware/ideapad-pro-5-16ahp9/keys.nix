# F4 (mic mute) and F8 (airplane), each reported once.
#
# Every press of either key reaches the "Ideapad extra buttons" device twice:
# the ideapad-laptop driver reports it for the EC's VPC event (scancode 0x08
# for F4, 0x0d for F8) and again, 3 to 5 ms later, for the WMI fn-key event
# (0x13e and 0x13f, that is 0x100 | 0x3e and 0x3f). Measured with evtest's
# MSC_SCAN on this laptop, on Fedora (kernel 7.3) and on huginn (7.2); the
# driver's two paths are the same in both. Without this:
#   F4  the session toggles the mic twice, so it stays as it was and the
#       notification shows the old state;
#   F8  the kernel's rfkill-input (RFKILL_INPUT=y) blocks every radio and
#       unblocks it again within ~250 ms, before Sway runs its binding.
# Mapping the WMI copies to `reserved` makes the input core drop them, so the
# VPC copy is the only one: one mic toggle, and one rfkill toggle that also
# works on the lock screen and at the login screen. 0x0d stays systemd's
# `rfkill` (its entry for every IdeaPad); 0x08 is KEY_MICMUTE in the driver.
# systemd does the same for F4 on the ThinkBook 14 G7 ARP, and Fedora's setup
# for this laptop carried the F8 half since 2026-10-06.
#
# If a key stops working after a kernel update, the driver may have stopped
# reporting the VPC copy itself: measure again (evtest on the device, both
# scancodes or one?) before changing this, since this entry would then eat
# the last copy. tests/hardware/keys.nix checks the compiled hwdb.
#
# The Copilot key as a plain second Super.
#
# The key is a firmware macro: Super+Shift+F23 on press (Meta, Shift, F23,
# about 1 ms apart) and the reverse on release, held as long as the key is.
# Its Shift is scancode 0x2a, the real left Shift's, so a hwdb remap would
# kill the real Shift too, and libxkbcommon has no action that clears a
# modifier. So copilot-key-super (tools/copilot-key-super) grabs the
# internal keyboard and re-emits it through the virtual keyboard
# 1:1:copilot-key-super, which Sway's config sets up, with the macro's Shift
# released before F23 reaches anyone. If it dies, the grab dies with it and
# the kernel hands the raw keyboard back, with the key back to stock;
# Sway's config has a block for the raw keyboard too.
#
# hardware.uinput, not only boot.kernelModules = [ "uinput" ]: it loads the
# module as well, and adds the uinput group and the udev rule that gives
# /dev/uinput to it (0660), so the service can run as a dynamic user in the
# input and uinput groups instead of as root. Nothing else on huginn opens
# /dev/uinput.
#
# The unit mirrors Fedora's: Restart=on-failure after 2 s, and at most 5
# starts in 60 s, since a daemon that flaps while it holds a keyboard grab
# is worse than none. The rest is hardening: no capability, no network, a
# read-only system, and of the devices only the input nodes (read) and
# /dev/uinput (write). tests/hardware/copilot-key-vm.nix runs it in a VM
# under exactly this unit; tests/hardware/copilot-key.nix checks huginn has
# it.
{ lib, pkgs, ... }:
{
  services.udev.extraHwdb = ''
    evdev:name:Ideapad extra buttons:dmi:*:svnLENOVO:pn83D5:*
     KEYBOARD_KEY_13e=reserved
     KEYBOARD_KEY_13f=reserved
  '';

  hardware.uinput.enable = true;

  systemd.services.copilot-key-super = {
    description = "Copilot key as a second Super (evdev filter)";
    wantedBy = [ "multi-user.target" ];
    startLimitBurst = 5;
    startLimitIntervalSec = 60;
    serviceConfig = {
      Type = "simple";
      ExecStart = lib.getExe pkgs.ravnix.copilot-key-super;
      Restart = "on-failure";
      RestartSec = 2;

      DynamicUser = true;
      SupplementaryGroups = [
        "input"
        "uinput"
      ];
      DevicePolicy = "closed";
      DeviceAllow = [
        "char-input r"
        "/dev/uinput w"
      ];
      CapabilityBoundingSet = [ "" ];
      AmbientCapabilities = [ "" ];
      NoNewPrivileges = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      PrivateTmp = true;
      PrivateNetwork = true;
      PrivateIPC = true;
      IPAddressDeny = "any";
      RestrictAddressFamilies = [ "none" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      ProtectClock = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectControlGroups = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      SystemCallArchitectures = "native";
      SystemCallFilter = [
        "@system-service"
        "~@privileged @resources"
      ];
      UMask = "0077";
    };
  };
}
