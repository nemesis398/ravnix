# The laptop shape, huginn: what every ravnix laptop is, whatever its model.
# The common module (shell, user, home-manager), the disk layout of
# ./disko.nix, the boot, ./hide-other-disks.nix, which keeps the other
# internal disks out of udisks, ./zram.nix, the only swap, and
# ./atuin-root.nix, root's shell history in the user's atuin timeline. flake.nix
# adds nixosModules.desktop and nixosModules.glue beside this file in
# nixosModules.laptop; the glue takes its laptop end from ravnix.shape, set
# here. A laptop's hardware is a module of its own under modules/hardware/,
# which the private flake imports beside this one, so a second model is a
# new directory there and not a new shape:
#
#   modules = [
#     ravnix.nixosModules.laptop
#     ravnix.nixosModules.hardware-ideapad-pro-5-16ahp9
#     ./me.nix
#   ];
#
# It is a function of the flake, `import ./hosts/laptop { inherit self
# inputs; }` (flake.nix, where it gets a key), for the modules it brings.
#
# The SSH agent is rbw's (modules/common/rbw.nix), as on the server, not
# Bitwarden's desktop agent: its keys are the vault's SSH key items, and it
# asks for the master password only in a terminal. While the vault is
# locked, ssh and commit signing from a graphical program fail at once with
# no window to type into; run ai-unlock in a terminal, and again 12 hours
# later by the clock, when it locks itself. The git hosts of
# ravnix.laptop.gitKeys take the security key over ssh and no agent at all,
# one touch for ten minutes (modules/desktop/git-hosts.nix); an HTTPS remote
# of GitHub takes gh's token instead.
# Every login shell points SSH_AUTH_SOCK at rbw's agent, so one forwarded
# into it with `ssh -A` is not used.
{ self, inputs }:
{ config, lib, ... }:
let
  inherit (config.ravnix.laptop) diskModel diskSerial;

  # udev's link for an NVMe disk: nvme-<model>_<serial>, where each run of
  # white space is one "_" and every character but letters, digits and
  # #+-.:=@_ is "_" too (udev's string_escape=replace, for ASCII). It names
  # the disk by the model and the serial the private flake gives, never by a
  # kernel name. Only disko's own scripts in the system
  # (config.system.build.diskoScript and its kin) read it; the install runs
  # disko on the path the disk guard prints, which is this one
  # (tests/laptop/disko.nix checks that on a VM's NVMe disks).
  udevName =
    s:
    lib.concatMapStrings (c: if builtins.match "[0-9A-Za-z#+.:=@_-]" c != null then c else "_") (
      lib.stringToCharacters (
        lib.concatStringsSep "_" (
          lib.filter (w: builtins.isString w && w != "") (builtins.split "[[:space:]]+" s)
        )
      )
    );
  byId = "/dev/disk/by-id/nvme-${udevName diskModel}_${udevName diskSerial}";
in
{
  # The shape is a module a function returns, so without this its
  # definitions would carry the file of the caller, nixpkgs' flake.nix, and an
  # error such as the conflict of two shapes would name that file.
  _file = ./default.nix;

  imports = [
    inputs.disko.nixosModules.disko
    self.nixosModules.common
    ./hide-other-disks.nix
    ./zram.nix
    ./atuin-root.nix
    # The Claude Code update, whose laptop end follows the lock the server
    # pushes (the module says how).
    (import ../../modules/workbench/claude-update.nix { inherit self; })
  ];

  ravnix.shape = "laptop";

  # nix run, nix shell and the flake commands, as on the server. Without
  # these two, nix refuses them with "experimental Nix feature 'nix-command'
  # is disabled".
  nix.settings.experimental-features = [
    "nix-command"
    "flakes"
  ];

  # The file systems, the swap on disk (none; zram is the swap) and the
  # initrd's LUKS device come from the layout, by GPT label and mapper name,
  # not by the device.
  disko.devices = (import ./disko.nix { device = byId; }).disko.devices;

  boot = {
    # systemd-boot on the ESP, listing the generations to roll back to.
    # efi.canTouchEfiVariables stays false, NixOS's default, so neither the
    # install nor a switch writes the firmware's boot entries; the install
    # adds huginn's entry on purpose, and Fedora's stays as it is.
    loader.systemd-boot.enable = true;
  };

  # systemd-oomd on the root slice and the user slices, as Fedora has it:
  # when memory pressure stays high, it kills the control group that causes
  # it, a runaway build for instance, before the machine thrashes in zram.
  # NixOS runs the daemon by default but watches no slice.
  systemd.oomd = {
    enableRootSlice = true;
    enableUserSlices = true;
  };

  # irqbalance spreads the hardware interrupts over the cores, as the Fedora
  # laptop does. NixOS leaves it off.
  services.irqbalance.enable = true;

  # fwupd, firmware updates from the LVFS, as on Fedora. It sits here and not
  # in a hardware module: the update tool and its daemon do not depend on the
  # model, and a second laptop model should get it with the shape.
  #
  # KNOWN, ACCEPTED EXCEPTION to rule 2 of AGENTS.md (the maintainer decided on
  # 2026-11-16 to keep fwupd fully on, and not to disable any plugin):
  #
  #   - fwupd's UEFI plugins (uefi-dbx at startup, uefi-capsule when it
  #     registers its devices, and so on every fwupd-refresh) look for the ESP.
  #     When there is more than one, as here with the other disk's, they
  #     mount each one through udisks before they compare it with
  #     EspLocation (fu_context_get_default_esp in libfwupdplugin/fu-context.c
  #     takes a fu_volume_locker on every volume, and fu-volume-locker.c
  #     mounts an unmounted one with udisks' Filesystem.Mount and no options,
  #     which is read-write). Linux sets the FAT dirty bit on a read-write
  #     mount, so the other disk's ESP is written to. hide-other-disks.nix
  #     only sets UDISKS_IGNORE, a hint that udisks still lists past.
  #     NixOS sets EspLocation to /boot, so a capsule goes to huginn's ESP.
  #   - `fwupdmgr update` without a device updates every device that has an
  #     update, and that includes the other disk's NVMe firmware. Name the
  #     device (`fwupdmgr update DEVICE-ID`) and do not update that disk.
  #
  # The hardware module's checklist has the check on the real laptop.
  services.fwupd.enable = true;

  # smartd watches the SMART status of the disks, as on Fedora. It names no
  # device: NixOS's default is DEVICESCAN, which finds them, as Fedora's
  # does, so a disk swapped or added later is watched too.
  services.smartd.enable = true;

  # sudo keeps EDITOR and VISUAL, which its env_reset drops: `sudo systemctl
  # edit`, `sudo crontab -e` and visudo then open the user's editor
  # (modules/common/bash.nix sets both, and SUDO_EDITOR for sudoedit) and not
  # nano, the editor this sudo falls back on. A user's choice of editor can
  # run any program as root through these commands; on the laptop the user is
  # the administrator who can have root anyway. The server keeps its sudo as
  # hosts/server/deploy.nix has it and does not get this.
  security.sudo.extraConfig = ''
    Defaults env_keep += "EDITOR VISUAL"
  '';
}
