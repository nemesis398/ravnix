# The NAS mounts of huginn (modules/desktop/nas.nix, modules/options/nas.nix),
# read from an evaluated host with made-up shares and never built:
#
#   - each share is a cifs file system of //SERVER/SHARE with Fedora's
#     options: credentials= of its account's file under /run/ravnix/nas,
#     rw, or ro for a read-only share, SMB 3.1.1, the user's uid and gid,
#     modes 640 and 750, noauto, nofail, _netdev, the automount with its 10
#     minute idle timeout and 20 second mount timeout, and the unit that
#     writes the file as a requirement; each share's mount unit has no
#     start limit (a drop-in), so quick failures never stop its automount;
#   - each account a share uses has that unit, a oneshot with no start
#     limit, which runs the helper with the user, the file, the SMB user and
#     the item (and rbw's item user, unless it is null); an account no share
#     uses has none; the directory is root's, mode 700, on /run, and the
#     unit's runtime directory; the unit is sandboxed (read-only system and
#     home, the directory alone writable, no network but AF_UNIX, the
#     capabilities of the drop to the user alone), and
#     its start timeout leaves room for the helper's two rbw calls and the
#     fallback after them;
#   - no secret is in the store: no option, unit or fstab line holds a
#     password or an environment, and the credentials file is not a store
#     path;
#   - cifs-utils is a file system package, and the links are home-manager's;
#   - with ravnix.nas null, or with no shares, there is no cifs file system,
#     no unit, no directory and no link;
#   - the options refuse two shares on one mount point, a share of an account
#     that is not there, a link outside the home, an account name that cannot
#     be a unit's, and a share name, mount point or user name with a space or
#     a newline; the template's values pass, and the template mounts nothing
#     (ravnix.nas is null there, as other per-site features are).
#
# tests/desktop/nas-vm.nix mounts shares of a real Samba server.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };
  moduleFile = ../../modules/desktop/nas.nix;
  user = (import ../../templates/default/me.nix).ravnix.user.username;

  nas = {
    server = "nas.example";
    accounts = {
      share-owner = {
        username = "owner-a";
        item = "NAS - owner a";
      };
      other = {
        username = "owner-b";
        item = "NAS 100% $HOME";
        itemUser = null;
      };
      unused = {
        username = "owner-c";
        item = "NAS - owner c";
      };
    };
    shares = [
      {
        share = "share-a";
        account = "share-owner";
        mountPoint = "/mnt/nas/a/share-a";
      }
      {
        share = "share-ro";
        account = "share-owner";
        mountPoint = "/mnt/nas/a/share-ro";
        readOnly = true;
      }
      {
        share = "share-b";
        account = "other";
        mountPoint = "/mnt/nas/b";
      }
    ];
    links = {
      NAS-a = "/mnt/nas/a";
      "Folders/NAS-b" = "/mnt/nas/b";
    };
  };

  host =
    extra:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = hostModules ++ [
        self.nixosModules.common
        moduleFile
      ]
      ++ extra;
    };
  with' = value: [ { ravnix.nas = lib.mkForce value; } ];
  config = (host (with' nas)).config;
  failedOf = extra: map (a: a.message) (lib.filter (a: !a.assertion) (host extra).config.assertions);
  refusedBy = value: needle: lib.any (m: lib.hasInfix needle m) (failedOf (with' value));
  # Whether evaluating the value fails its type.
  typeRefused =
    value: !(builtins.tryEval (builtins.deepSeq (host (with' value)).config.ravnix.nas true)).success;

  cifsOf = c: lib.filterAttrs (_: fs: fs.fsType == "cifs") c.fileSystems;
  unitsOf = c: lib.filter (lib.hasPrefix "ravnix-nas-") (lib.attrNames c.systemd.services);
  linksOf = c: lib.attrNames c.home-manager.users.${user}.home.file;

  fedora = share: account: mode: [
    "credentials=/run/ravnix/nas/${account}.cred"
    mode
    "vers=3.1.1"
    "uid=${user}"
    "gid=${config.users.users.${user}.group}"
    "file_mode=0640"
    "dir_mode=0750"
    "noauto"
    "nofail"
    "_netdev"
    "x-systemd.automount"
    "x-systemd.idle-timeout=10min"
    "x-systemd.mount-timeout=20s"
    "x-systemd.requires=ravnix-nas-credential-${account}.service"
  ];
  fs = config.fileSystems;
  unitA = config.systemd.services.ravnix-nas-credential-share-owner;
  unitB = config.systemd.services.ravnix-nas-credential-other;
  fstab = config.environment.etc.fstab.text;
  allOptions = lib.concatMap (f: f.options) (lib.attrValues (cifsOf config));

  helper = self.packages.${system}.ravnix-nas-credential;
  # A time span of systemd's in seconds: a number, or a string "Ns".
  seconds = v: if builtins.isInt v then v else lib.toInt (lib.removeSuffix "s" v);
  # The mount units of the shares, as systemd names them.
  mountUnits = [
    "mnt-nas-a-share\\x2da"
    "mnt-nas-a-share\\x2dro"
    "mnt-nas-b"
  ];

  emptyHosts = [
    (host (with' null)).config
    (host (with' (nas // { shares = [ ]; }))).config
  ];

  expect = ok: message: lib.optional (!ok) message;
  failures =
    expect (lib.elem moduleFile
      (import ../../modules/desktop/default.nix { inherit lib; }).imports
    ) "modules/desktop/default.nix does not import nas.nix"
    ++ expect (lib.attrNames (cifsOf config) == [
      "/mnt/nas/a/share-a"
      "/mnt/nas/a/share-ro"
      "/mnt/nas/b"
    ]) "the cifs file systems are ${toString (lib.attrNames (cifsOf config))}"
    ++ expect (fs."/mnt/nas/a/share-a".device == "//nas.example/share-a") "share-a's device is ${fs."/mnt/nas/a/share-a".device}"
    ++ expect (fs."/mnt/nas/b".device == "//nas.example/share-b") "share-b's device is ${fs."/mnt/nas/b".device}"
    ++ expect (
      fs."/mnt/nas/a/share-a".options == fedora "share-a" "share-owner" "rw"
    ) "share-a's options are ${toString fs."/mnt/nas/a/share-a".options}"
    ++ expect (
      fs."/mnt/nas/a/share-ro".options == fedora "share-ro" "share-owner" "ro"
    ) "the read-only share's options are ${toString fs."/mnt/nas/a/share-ro".options}"
    ++ expect (
      !lib.elem "rw" fs."/mnt/nas/a/share-ro".options
    ) "the read-only share is mounted rw as well"
    ++ expect (
      fs."/mnt/nas/b".options == fedora "share-b" "other" "rw"
    ) "share-b's options are ${toString fs."/mnt/nas/b".options}"
    # The units: one per account a share uses.
    ++ expect (unitsOf config == [
      "ravnix-nas-credential-other"
      "ravnix-nas-credential-share-owner"
    ]) "the units are ${toString (unitsOf config)}"
    ++ expect (unitA.serviceConfig.Type == "oneshot") "the credentials unit is no oneshot"
    ++ expect (unitA.unitConfig.StartLimitIntervalSec == 0) "a failed credentials run holds back the next mount"
    ++ lib.concatMap (
      u:
      let
        # What the unit does not set reads as unset, so a missing setting
        # fails its expectation instead of the evaluation.
        sc =
          lib.genAttrs [
            "RuntimeDirectory"
            "RuntimeDirectoryMode"
            "RuntimeDirectoryPreserve"
            "ProtectSystem"
            "ProtectHome"
            "RestrictAddressFamilies"
            "IPAddressDeny"
          ] (_: null)
          // lib.genAttrs [
            "PrivateTmp"
            "PrivateDevices"
            "NoNewPrivileges"
            "ProtectKernelTunables"
            "ProtectKernelModules"
            "ProtectControlGroups"
            "RestrictSUIDSGID"
            "LockPersonality"
          ] (_: false)
          // {
            CapabilityBoundingSet = [ ];
          }
          // u.serviceConfig;
      in
      expect (
        sc.RuntimeDirectory == "ravnix/nas" && sc.RuntimeDirectoryMode == "0700" && sc.RuntimeDirectoryPreserve == "yes"
      ) "the credentials directory is not the unit's, root's with mode 700 and kept"
      ++ expect (
        sc.ProtectSystem == "strict"
        && sc.ProtectHome == "read-only"
        && sc.PrivateTmp
        && sc.PrivateDevices
        && sc.NoNewPrivileges
        && sc.ProtectKernelTunables
        && sc.ProtectKernelModules
        && sc.ProtectControlGroups
        && sc.RestrictSUIDSGID
        && sc.LockPersonality
      ) "the credentials unit is not sandboxed: ${builtins.toJSON sc}"
      ++ expect (sc.RestrictAddressFamilies == "AF_UNIX" && sc.IPAddressDeny == "any") "the credentials unit can reach the network"
      ++ expect (
        lib.sort lib.lessThan sc.CapabilityBoundingSet == [
          "CAP_SETGID"
          "CAP_SETUID"
        ]
      ) "the credentials unit's capabilities are ${toString sc.CapabilityBoundingSet}"
      ++ expect (!(sc ? ReadWritePaths)) "the credentials unit writes more than its runtime directory"
      # Two rbw calls of rbwTimeout each, and ten seconds for the fallback.
      ++ expect (
        seconds sc.TimeoutStartSec >= 2 * helper.rbwTimeout + 10
      ) "the credentials unit's start timeout ${toString sc.TimeoutStartSec} s leaves no room after two rbw calls of ${toString helper.rbwTimeout} s"
    ) [
      unitA
      unitB
    ]
    # The mount units: no start limit, so a NAS out of reach does not kill
    # the automount after five quick failures.
    ++ lib.concatMap (
      name:
      let
        unit = config.systemd.units."${name}.mount" or null;
      in
      expect (
        unit != null && unit.overrideStrategy == "asDropin" && lib.hasInfix "StartLimitIntervalSec=0" unit.text
      ) "the mount unit ${name} has no drop-in without a start limit"
    ) mountUnits
    ++ expect ((import ../../templates/default/me.nix).ravnix.nas == null) "the template mounts shares"
    # No secret: nothing names a password, no unit has an environment, and
    # the file is on /run, not in the store.
    ++ expect (
      !lib.any (o: lib.hasInfix "password" o || lib.hasPrefix "username=" o || lib.hasPrefix "pass" o) allOptions
    ) "a mount option holds a credential"
    ++ expect (
      !lib.hasInfix "password=" fstab && lib.hasInfix "credentials=/run/ravnix/nas/share-owner.cred" fstab
    ) "the fstab holds a password, or not the credentials file"
    ++ expect (!lib.any (o: lib.hasInfix builtins.storeDir o) allOptions) "a mount option names a store path"
    ++ expect (
      lib.all (
        u:
        # PATH is the one NixOS gives every unit.
        lib.attrNames (u.environment or { }) == [ "PATH" ]
        && !(u.serviceConfig ? Environment)
        && !(u.serviceConfig ? EnvironmentFile)
        && !(u.serviceConfig ? LoadCredential)
      ) [
        unitA
        unitB
      ]
    ) "a credentials unit has an environment"
    ++ expect (config.boot.supportedFilesystems.cifs or false) "cifs is not a supported file system"
    ++ expect (lib.elem "cifs-utils" (map lib.getName config.system.fsPackages)) "cifs-utils is not a file system package"
    ++ expect (lib.all (n: lib.elem n (linksOf config)) [
      "Folders/NAS-b"
      "NAS-a"
    ]) "the home's links are not home-manager's: ${toString (linksOf config)}"
    # Nothing without shares.
    ++ lib.concatMap (
      c:
      expect (cifsOf c == { }) "with no shares there is a cifs file system"
      ++ expect (unitsOf c == [ ]) "with no shares there is a credentials unit"
      ++ expect (!lib.any (n: lib.hasPrefix "mnt-" n) (lib.attrNames c.systemd.units)) "with no shares there is a mount drop-in"
      ++ expect (!lib.any (n: lib.hasPrefix "NAS" n || lib.hasPrefix "Folders" n) (linksOf c)) "with no shares there is a link"
    ) emptyHosts
    # What the options refuse.
    ++ expect (refusedBy (
      nas
      // {
        shares = nas.shares ++ [
          {
            share = "share-c";
            account = "other";
            mountPoint = "/mnt/nas/b";
          }
        ];
      }
    ) "/mnt/nas/b") "two shares on one mount point are not refused"
    ++ expect (refusedBy (
      nas
      // {
        shares = [
          {
            share = "share-a";
            account = "nobody";
            mountPoint = "/mnt/x";
          }
        ];
      }
    ) "nobody") "a share of an account that is not there is not refused"
    ++ expect (refusedBy (nas // { links."../out" = "/mnt/nas"; }) "links") "a link outside the home is not refused"
    ++ expect (refusedBy (nas // { links."/abs" = "/mnt/nas"; }) "links") "an absolute link is not refused"
    ++ expect (refusedBy (
      nas
      // {
        accounts = nas.accounts // {
          Upper = {
            username = "x";
            item = "y";
          };
        };
      }
    ) "Upper") "an account name with a capital is not refused"
    ++ lib.concatMap
      (
        bad:
        expect (typeRefused (
          nas
          // {
            shares = [
              (
                {
                  share = "share-a";
                  account = "other";
                  mountPoint = "/mnt/x";
                }
                // bad
              )
            ];
          }
        )) "the share ${builtins.toJSON bad} is not refused"
      )
      [
        { share = "two words"; }
        { share = "-dash"; }
        { mountPoint = "/mnt/two words"; }
        { mountPoint = "/mnt/a,b"; }
        { mountPoint = "/mnt/x/"; }
        { mountPoint = "relative"; }
      ]
    ++ expect (typeRefused (
      nas
      // {
        accounts.other = {
          username = "a\npassword=b";
          item = "y";
        };
      }
    )) "a user name with a newline is not refused"
    ++ expect (typeRefused (
      nas
      // {
        accounts.other = {
          username = "a";
          item = "line\nbreak";
        };
      }
    )) "an item with a newline is not refused"
    ++ expect (typeRefused (nas // { server = "-oops"; })) "a server that starts with a dash is not refused"
    # The control: the values above pass the types.
    ++ expect (!typeRefused nas) "the test's own values fail a type"
    ++ expect (failedOf [ ] == [ ]) "the template's values fail an assertion: ${toString (failedOf [ ])}";

  # The units' scripts, to be read once built: the arguments the helper gets.
  scripts = pkgs.linkFarm "nas-unit-scripts" {
    a = unitA.serviceConfig.ExecStart;
    b = unitB.serviceConfig.ExecStart;
  };
in
pkgs.runCommand "desktop-nas"
  {
    nativeBuildInputs = [ pkgs.gnugrep ];
    failures = lib.concatStringsSep "\n" failures;
    passAsFile = [ "failures" ];
  }
  ''
    if [ -s "$failuresPath" ]; then
      cat "$failuresPath"
      exit 1
    fi
    fail() { echo "FAIL: $*"; exit 1; }
    # The arguments, quoted for the shell: the user, the file, the SMB user,
    # the item, and rbw's item user where there is one.
    grep -qF "/bin/ravnix-nas-credential ${user} /run/ravnix/nas/share-owner.cred owner-a 'NAS - owner a' owner-a" ${scripts}/a \
      || fail "the unit of share-owner runs: $(cat ${scripts}/a)"
    grep -qF "/bin/ravnix-nas-credential ${user} /run/ravnix/nas/other.cred owner-b 'NAS 100% \$HOME'" ${scripts}/b \
      || fail "the unit of other runs: $(cat ${scripts}/b)"
    grep -qF "'NAS 100% \$HOME' " ${scripts}/b && fail "the unit of other passes an item user: $(cat ${scripts}/b)"
    grep -qi 'password' ${scripts}/a ${scripts}/b && fail "a unit's script names a password"
    touch "$out"
  ''
