# The NAS's SMB shares on the laptop, as on Fedora: each share of
# ravnix.nas.shares (modules/options/nas.nix) is a cifs file system that
# systemd mounts on first access and unmounts after 10 idle minutes, and
# ravnix.nas.links puts links to them in the home. Nothing is synced to the
# disk: cifs keeps file data in the page cache only.
#
# The options are Fedora's: SMB 3.1.1, the files the user's (uid= and gid=
# take the names) with modes 640 and 750, rw or ro by the share, and
# noauto, nofail, _netdev, x-systemd.automount, idle-timeout=10min and
# mount-timeout=20s, so neither the boot nor a missing NAS waits on them.
# cifs-utils comes with the file system type (system.fsPackages, from
# boot.supportedFilesystems, which NixOS fills from the cifs entries).
#
# The group is the user's primary group, which on NixOS is `users` (gid
# 100) and on Fedora was the user's own: the group bits of 640 and 750 reach
# every normal user of the host here. ravnix makes one; the maintainer
# accepted that (2026-11-16).
#
# No domain= is written: the NAS is standalone, and Fedora's fstab has
# none. An account of an Active Directory domain cannot be expressed yet.
#
# A NAS out of reach makes mount.cifs fail in milliseconds (no route, or
# the connection refused), and five such starts within 10 s would trip the
# mount unit's start limit: the automount would then fail for good
# (mount-start-limit-hit) and the folder read as empty until a reboot. Each
# mount unit therefore gets a drop-in without a start limit, so the
# automount stays armed and the share mounts again once the NAS is back
# (tests/desktop/nas-vm.nix).
#
# THE PASSWORDS. mount.cifs reads each account's password from a file,
# credentials=, as root, when the automount fires. The file is
# /run/ravnix/nas/ACCOUNT.cred: on tmpfs, root's, mode 600, in a directory
# of mode 700, so it is gone at every boot, and it is never in the store.
# Every mount requires the unit ravnix-nas-credential-ACCOUNT
# (x-systemd.requires=), which writes the file before the mount from the
# user's vault with packages/ravnix-nas-credential: as root, it runs the
# user's rbw as the user (setpriv), and takes the password through a pipe.
# So each mount, the one after an idle unmount too, reads the password
# again while the vault is unlocked, and a changed password reaches the
# next mount by itself. While the vault is locked the unit keeps the file
# an earlier mount wrote and says so, so the shares stay usable for the
# rest of the boot, as Fedora's root-only files kept them while Bitwarden
# was locked. Before the first unlock after a boot there is no file: the
# unit fails, the mount with it, a program that opens the folder gets an
# error, and the automount waits for the next access; after ai-unlock the
# next access mounts.
#
# Each mount reads the vault while it is unlocked, and every read starts
# rbw's idle lock (lock_timeout) again, as the syncs' reads do
# (modules/common/rbw.nix): opening a share every hour keeps the vault
# unlocked until the 12-hour cap locks it.
#
# The unit is sandboxed as far as its job allows: the system and the home
# read-only, its runtime directory /run/ravnix/nas the one place it writes,
# private /tmp and /dev, no network but AF_UNIX (rbw's agent socket), and
# of root's capabilities only CAP_SETUID and CAP_SETGID, for the drop to the
# user: the timeout that stops a hung rbw runs after the drop, as the user,
# and needs no CAP_KILL (tests/desktop/nas-vm.nix hangs one). Its start
# timeout is the helper's two rbw calls and 15 s, so a slow vault still ends
# in the fallback to the kept file and not in a kill.
#
# THE HELPER IS BASH, by the maintainer's explicit exception to rule 4 of
# AGENTS.md (2026-11-16): "Keep Bash, it's glue". It runs as root, which the
# Odin tools that drop to the user with setpriv do too (tools/ravnix-tap-ask,
# tools/claude-roll), and the exception holds because the helper is small
# (one read, four checks, one rename), every branch is covered by its shell
# test (tests/bin/ravnix-nas-credential.nix) and the real path by
# tests/desktop/nas-rbw-vm.nix, and it is root only until the drop: what it
# runs as root is setpriv, timeout, head and the write of the file.
#
# The server is an option of its own and not taken from ravnix.hosts: a NAS
# can serve SMB on another interface than the one its services are reached
# on (a management VLAN, say), and the registry names the latter.
#
# Why not the other routes:
#   - A user unit that pushes the password to a root helper (a sudo rule or
#     a polkit-checked socket) gives every process of the user a way to
#     write a root-only file, and needs a trigger for "the vault is now
#     unlocked" that ravnix does not have. Here root asks, only when a mount
#     needs it, and the user gains nothing.
#   - A cifs multiuser mount with `cifscreds add` keeps one password per
#     server for each user's keyring (cifs:a:ADDRESS), so the two accounts of
#     one user on one NAS cannot both be had, and the mount itself still
#     needs a root credential for its own session.
#   - A file on disk, written once by hand, as Fedora has it, keeps a
#     secret on disk for good. ravnix.backup.nas.secrets = "file" makes that
#     exception for a run that must be unattended; a mount opened by a
#     person is not one.
{
  config,
  lib,
  pkgs,
  utils,
  ...
}:
let
  cfg = config.ravnix.nas;
  user = config.ravnix.user.username;
  group = config.users.users.${user}.group;
  rbw = config.home-manager.users.${user}.programs.rbw.package;
  helper = pkgs.ravnix.ravnix-nas-credential.override { inherit rbw; };

  dir = "/run/ravnix/nas";
  credFile = account: "${dir}/${account}.cred";
  unit = account: "ravnix-nas-credential-${account}";

  optionsOf = share: [
    "credentials=${credFile share.account}"
    (if share.readOnly then "ro" else "rw")
    "vers=3.1.1"
    "uid=${user}"
    "gid=${group}"
    "file_mode=0640"
    "dir_mode=0750"
    "noauto"
    "nofail"
    "_netdev"
    "x-systemd.automount"
    "x-systemd.idle-timeout=10min"
    "x-systemd.mount-timeout=20s"
    "x-systemd.requires=${unit share.account}.service"
  ];

  # The accounts a share is mounted as: the others need no unit.
  used = lib.unique (map (s: s.account) cfg.shares);
in
{
  config = lib.mkIf (cfg != null && cfg.shares != [ ]) {
    fileSystems = lib.listToAttrs (
      map (share: {
        name = share.mountPoint;
        value = {
          device = "//${cfg.server}/${share.share}";
          fsType = "cifs";
          options = optionsOf share;
        };
      }) cfg.shares
    );

    # No start limit on the mounts: see the header.
    systemd.units = lib.listToAttrs (
      map (share: {
        name = "${utils.escapeSystemdPath share.mountPoint}.mount";
        value = {
          overrideStrategy = "asDropin";
          text = ''
            [Unit]
            StartLimitIntervalSec=0
          '';
        };
      }) cfg.shares
    );

    systemd.services = lib.listToAttrs (
      map (
        name:
        let
          account = cfg.accounts.${name};
          # The arguments through a script, so that systemd reads no % or $
          # of an item's name as its own.
          run = pkgs.writeShellScript (unit name) ''
            exec ${lib.getExe helper} ${
              lib.escapeShellArgs (
                [
                  user
                  (credFile name)
                  account.username
                  account.item
                ]
                ++ lib.optional (account.itemUser != null) account.itemUser
              )
            }
          '';
        in
        {
          name = unit name;
          value = {
            description = "The credentials of the NAS account ${name}, from the vault";
            # Run again for every mount: a failed run (the vault was locked)
            # must not be held against the next access.
            unitConfig.StartLimitIntervalSec = 0;
            serviceConfig = {
              Type = "oneshot";
              ExecStart = "${run}";
              UMask = "0077";
              # Two rbw calls, and the fallback after them.
              TimeoutStartSec = 2 * helper.rbwTimeout + 15;
              # The directory, root's and mode 700, kept between runs and
              # for the mounts; the one place the unit writes.
              RuntimeDirectory = "ravnix/nas";
              RuntimeDirectoryMode = "0700";
              RuntimeDirectoryPreserve = "yes";
              ProtectSystem = "strict";
              # rbw reads the user's configuration and vault copy, and
              # connects to the agent's socket in /run/user, which a
              # read-only mount does not stop.
              ProtectHome = "read-only";
              PrivateTmp = true;
              PrivateDevices = true;
              NoNewPrivileges = true;
              ProtectKernelTunables = true;
              ProtectKernelModules = true;
              ProtectKernelLogs = true;
              ProtectControlGroups = true;
              ProtectClock = true;
              ProtectHostname = true;
              RestrictSUIDSGID = true;
              RestrictRealtime = true;
              RestrictNamespaces = true;
              LockPersonality = true;
              RestrictAddressFamilies = "AF_UNIX";
              IPAddressDeny = "any";
              # setpriv's drop to the user; timeout runs after it.
              CapabilityBoundingSet = [
                "CAP_SETUID"
                "CAP_SETGID"
              ];
            };
          };
        }
      ) used
    );

    home-manager.users.${user} =
      { config, ... }:
      {
        home.file = lib.mapAttrs (_: target: {
          source = config.lib.file.mkOutOfStoreSymlink target;
        }) cfg.links;
      };
  };
}
