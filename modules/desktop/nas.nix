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

    systemd.tmpfiles.settings."10-ravnix-nas".${dir}.d = {
      mode = "0700";
      user = "root";
      group = "root";
    };

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
              # Longer than the helper's 20 s for rbw.
              TimeoutStartSec = "40s";
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
