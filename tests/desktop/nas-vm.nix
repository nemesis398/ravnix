# The NAS mounts on a running laptop (modules/desktop/nas.nix), against a
# real Samba server in a second VM with two accounts, whose passwords hold
# spaces, `#`, `,` and `=`. The module alone, with home-manager for the
# links; rbw is a stand-in that answers from files and logs who ran it.
#
#   - the automounts are armed at boot and nothing is mounted;
#   - with the vault locked, opening a share fails, no credentials file is
#     made, rbw is asked only whether it is unlocked, and the automount
#     stays armed for the next access;
#   - after the unlock the next access mounts: the file is root's, mode 600,
#     in a directory of mode 700; rbw ran as the user, with the user's
#     runtime directory; files are the user's, modes 640 and 750, and reach
#     the server as the account's; the read-only share refuses a write; the
#     second account's share is mounted as that account;
#   - mounted again with the vault locked (as after an idle unmount), a share
#     takes the password read before; after a change of the password on the
#     server and in the vault, the next mount takes the new one by itself;
#   - with the NAS out of reach, eight quick failed accesses leave the
#     automount armed (the mount units have no start limit), and the share
#     mounts again once the NAS is back;
#   - a hung rbw is stopped by the helper's limit, though the unit holds no
#     CAP_KILL, and the mount takes the kept file well before systemd's own
#     start timeout;
#   - the automounts unmount after 10 idle minutes and give up a mount after
#     20 seconds; the links in the home lead to the mounts;
#   - no password is in the journal, the fstab or a unit.
#
# Run it under the shared lock, since other agents share the RAM:
#   flock .superpowers/sdd/2026-11-07-ravnix/vm.lock nix build .#checks.x86_64-linux.desktop-nas-vm
{
  self,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  me = import ../../templates/default/me.nix;
  # The helper's limit for each rbw call.
  limit = self.packages.${pkgs.stdenv.hostPlatform.system}.ravnix-nas-credential.rbwTimeout;
  user = me.ravnix.user.username;

  # The passwords, made up for the test. A sits in the vault and on the
  # server; B is changed once in both.
  passwords = {
    a = "pa ss#word, with=odd chars";
    b = "b pass # two";
    b2 = "b, rotated # three";
  };
  pwFile = name: pkgs.writeText "pw-${name}" "${passwords.${name}}\n";

  fakeRbw = pkgs.writeShellScriptBin "rbw" ''
    # A stand-in for rbw: the vault is locked while /var/lib/fake-rbw/locked
    # exists, `get` hangs while /var/lib/fake-rbw/hang exists, and the
    # password of an item is the file item.NAME (the name's
    # non-alphanumerics as _). Every call logs who ran it and its arguments.
    d=/var/lib/fake-rbw
    echo "$(${pkgs.coreutils}/bin/id -un) XDG_RUNTIME_DIR=''${XDG_RUNTIME_DIR-} RBW_AGENT=''${RBW_AGENT-} $*" >>"$d/log"
    case "$1" in
      unlocked) [ ! -e "$d/locked" ] ;;
      get)
        [ ! -e "$d/locked" ] || exit 1
        # A hung agent: one process that never answers, as rbw would be.
        [ ! -e "$d/hang" ] || exec ${pkgs.coreutils}/bin/sleep 1000
        f="$d/item.$(printf %s "$3" | ${pkgs.coreutils}/bin/tr -c A-Za-z0-9 _)"
        [ -e "$f" ] || exit 1
        ${pkgs.coreutils}/bin/cat "$f"
        ;;
      *) exit 2 ;;
    esac
  '';

  nas = {
    server = "nas";
    accounts = {
      share-owner = {
        username = "owner-a";
        item = "NAS - owner a";
      };
      other = {
        username = "owner-b";
        item = "NAS - owner b";
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
      NAS-b = "/mnt/nas/b";
    };
  };

  # The laptop's modules: the module alone, with home-manager for the links.
  laptop = [
    inputs.home-manager.nixosModules.home-manager
    self.nixosModules.options
    ../../modules/desktop/nas.nix
    ../../templates/default/me.nix
    {
      warnings = lib.mkForce [ ];
      ravnix.nas = lib.mkForce nas;
      users.users.${user}.isNormalUser = true;
      home-manager = {
        useGlobalPkgs = true;
        users.${user} = {
          home.stateVersion = "26.05";
          programs.rbw.package = fakeRbw;
        };
      };
    }
  ];
  host = inputs.nixpkgs.lib.nixosSystem {
    inherit (pkgs.stdenv.hostPlatform) system;
    modules = laptop ++ [
      {
        nixpkgs.overlays = [ self.overlays.default ];
        system.stateVersion = "26.05";
        boot.loader.grub.enable = false;
        fileSystems."/" = {
          device = "none";
          fsType = "tmpfs";
        };
      }
    ];
  };
in
pkgs.testers.runNixOSTest {
  name = "desktop-nas-vm";

  # The module reads pkgs.ravnix for the helper.
  node.pkgs = lib.mkForce (pkgs.extend self.overlays.default);

  nodes.nas = {
    services.samba = {
      enable = true;
      openFirewall = true;
      settings =
        lib.genAttrs
          [
            "share-a"
            "share-ro"
            "share-b"
          ]
          (name: {
            path = "/srv/${name}";
            "read only" = "no";
            "guest ok" = "no";
          });
    };
    users.users = {
      owner-a = {
        isSystemUser = true;
        group = "owners";
      };
      owner-b = {
        isSystemUser = true;
        group = "owners";
      };
    };
    users.groups.owners = { };
    systemd.tmpfiles.rules = [
      "d /srv/share-a 0775 owner-a owners -"
      "d /srv/share-ro 0775 owner-a owners -"
      "d /srv/share-b 0775 owner-b owners -"
    ];
  };

  nodes.laptop = {
    imports = laptop;
    # A test VM mounts only virtualisation.fileSystems, and reading the
    # host's own fileSystems from here would be a loop: these are the cifs
    # file systems of the same modules, evaluated as a host apart.
    virtualisation.fileSystems = lib.filterAttrs (_: fs: fs.fsType == "cifs") host.config.fileSystems;
    systemd.tmpfiles.rules = [ "d /var/lib/fake-rbw 0777 root root -" ];
    # The stand-in rbw logs into its directory, which the units' read-only
    # system would refuse it; the real rbw writes nothing there
    # (tests/desktop/nas-rbw-vm.nix runs it without this).
    systemd.services = lib.genAttrs [
      "ravnix-nas-credential-share-owner"
      "ravnix-nas-credential-other"
    ] (_: { serviceConfig.ReadWritePaths = [ "/var/lib/fake-rbw" ]; });
  };

  testScript = ''
    import shlex
    import time

    secrets = [${lib.concatMapStringsSep ", " (p: "'" + p + "'") (lib.attrValues passwords)}]

    def unit(path, suffix):
        # Quoted for the shell: the name holds a backslash (\x2d).
        return shlex.quote(laptop.succeed(f"systemd-escape -p --suffix={suffix} {shlex.quote(path)}").strip())

    def as_user(cmd):
        return f"su ${user} -s /bin/sh -c {shlex.quote(cmd)}"

    def vault(item, pwfile):
        name = "".join(c if c.isalnum() else "_" for c in item)
        laptop.succeed(f"install -m 644 {pwfile} /var/lib/fake-rbw/item.{name}")

    start_all()
    nas.wait_for_unit("samba-smbd.service")
    nas.succeed(
        "(cat ${pwFile "a"} ${pwFile "a"}) | smbpasswd -s -a owner-a",
        "(cat ${pwFile "b"} ${pwFile "b"}) | smbpasswd -s -a owner-b",
    )
    laptop.wait_for_unit("multi-user.target")
    laptop.wait_for_unit("home-manager-${user}.service")

    points = ["/mnt/nas/a/share-a", "/mnt/nas/a/share-ro", "/mnt/nas/b"]

    with subtest("the automounts are armed at boot, and nothing is mounted"):
        for p in points:
            laptop.succeed(f"systemctl is-active {unit(p, 'automount')}")
            laptop.fail(f"systemctl is-active {unit(p, 'mount')}")
        print(laptop.succeed("grep cifs /etc/fstab"))

    with subtest("with the vault locked a share cannot be opened, and no file is made"):
        laptop.succeed("touch /var/lib/fake-rbw/locked")
        vault("NAS - owner a", "${pwFile "a"}")
        vault("NAS - owner b", "${pwFile "b"}")
        laptop.fail(as_user("timeout 60 ls /mnt/nas/a/share-a"))
        laptop.succeed("test ! -e /run/ravnix/nas/share-owner.cred")
        calls = laptop.succeed("cat /var/lib/fake-rbw/log")
        print(calls)
        assert "unlocked" in calls and " get " not in calls, calls
        laptop.succeed("journalctl -u ravnix-nas-credential-share-owner -o cat | grep -F 'is locked'")
        laptop.succeed(f"systemctl is-active {unit('/mnt/nas/a/share-a', 'automount')}")

    with subtest("after the unlock the next access mounts, with a root-only file"):
        laptop.succeed("rm /var/lib/fake-rbw/locked")
        laptop.succeed(as_user("timeout 60 ls /mnt/nas/a/share-a"))
        laptop.succeed(f"systemctl is-active {unit('/mnt/nas/a/share-a', 'mount')}")
        assert laptop.succeed("stat -c '%U %a' /run/ravnix/nas").strip() == "root 700"
        assert laptop.succeed("stat -c '%U %a' /run/ravnix/nas/share-owner.cred").strip() == "root 600"
        laptop.fail(as_user("cat /run/ravnix/nas/share-owner.cred"))
        laptop.succeed("grep -qx 'username=owner-a' /run/ravnix/nas/share-owner.cred")
        calls = laptop.succeed("cat /var/lib/fake-rbw/log")
        uid = laptop.succeed("id -u ${user}").strip()
        assert f"${user} XDG_RUNTIME_DIR=/run/user/{uid} RBW_AGENT=/nix/store/" in calls, calls
        assert "get -- NAS - owner a owner-a" in calls, calls
        for line in calls.splitlines():
            assert line.startswith("${user} "), f"rbw ran as another user: {line}"

    with subtest("files are the user's, and reach the server as the account's"):
        laptop.succeed(as_user("echo hello > /mnt/nas/a/share-a/note && mkdir /mnt/nas/a/share-a/dir"))
        assert laptop.succeed("stat -c '%U %a' /mnt/nas/a/share-a/note").strip() == "${user} 640"
        assert laptop.succeed("stat -c '%U %a' /mnt/nas/a/share-a/dir").strip() == "${user} 750"
        assert nas.succeed("stat -c %U /srv/share-a/note").strip() == "owner-a"
        opts = laptop.succeed("findmnt -t cifs -no OPTIONS /mnt/nas/a/share-a")
        print(opts)
        assert "rw," in opts and "vers=3.1.1" in opts, opts

    with subtest("the read-only share refuses a write that the server would take"):
        laptop.succeed(as_user("timeout 60 ls /mnt/nas/a/share-ro"))
        assert laptop.succeed("findmnt -t cifs -no OPTIONS /mnt/nas/a/share-ro").startswith("ro,")
        laptop.fail(as_user("touch /mnt/nas/a/share-ro/x"))
        nas.succeed("test ! -e /srv/share-ro/x")

    with subtest("the second account's share is mounted as that account"):
        laptop.succeed(as_user("echo b > /mnt/nas/b/from-b"))
        assert nas.succeed("stat -c %U /srv/share-b/from-b").strip() == "owner-b"
        assert laptop.succeed("stat -c '%U %a' /run/ravnix/nas/other.cred").strip() == "root 600"

    with subtest("mounted again with the vault locked, a share takes the password read before"):
        laptop.succeed("touch /var/lib/fake-rbw/locked")
        laptop.succeed(f"systemctl stop {unit('/mnt/nas/b', 'mount')}")
        laptop.succeed(as_user("timeout 60 cat /mnt/nas/b/from-b"))
        laptop.succeed("journalctl -u ravnix-nas-credential-other -o cat | grep -F 'keep the password read before'")

    with subtest("a changed password reaches the next mount by itself"):
        nas.succeed("(cat ${pwFile "b2"} ${pwFile "b2"}) | smbpasswd -s owner-b")
        vault("NAS - owner b", "${pwFile "b2"}")
        laptop.succeed("rm /var/lib/fake-rbw/locked")
        laptop.succeed(f"systemctl stop {unit('/mnt/nas/b', 'mount')}")
        laptop.succeed(as_user("timeout 60 cat /mnt/nas/b/from-b"))

    with subtest("a hung rbw is stopped by its limit, and the mount takes the kept file"):
        # The limit's timeout runs as the user, inside the unit's sandbox,
        # whose bounding set has no CAP_KILL: it must still stop rbw, and in
        # time for the fallback, before systemd's own start timeout.
        laptop.succeed("touch /var/lib/fake-rbw/hang")
        laptop.succeed(f"systemctl stop {unit('/mnt/nas/b', 'mount')}")
        start = time.monotonic()
        laptop.succeed(as_user("timeout 120 cat /mnt/nas/b/from-b"))
        took = time.monotonic() - start
        assert took < ${toString (2 * limit + 10)}, f"the mount waited {took} s"
        laptop.succeed("journalctl -u ravnix-nas-credential-other -o cat | grep -F 'rbw cannot read the item'")
        laptop.fail("pgrep -f 'bin/[s]leep 1000'")
        laptop.succeed("rm /var/lib/fake-rbw/hang")

    with subtest("a NAS out of reach fails each access, and the share comes back with it"):
        # mount.cifs fails in milliseconds without a route: more than the
        # five starts in 10 s that a mount unit's default start limit takes.
        laptop.succeed(f"systemctl stop {unit('/mnt/nas/b', 'mount')}")
        laptop.succeed("ip link set eth1 down")
        for _ in range(8):
            laptop.fail(as_user("timeout 60 cat /mnt/nas/b/from-b"))
        laptop.succeed(f"systemctl is-active {unit('/mnt/nas/b', 'automount')}")
        laptop.succeed("ip link set eth1 up")
        laptop.wait_until_succeeds(as_user("timeout 60 cat /mnt/nas/b/from-b"), timeout=120)
        laptop.succeed(f"systemctl is-active {unit('/mnt/nas/b', 'mount')}")

    with subtest("the automounts' timeouts are Fedora's"):
        a = unit("/mnt/nas/b", "automount")
        assert laptop.succeed(f"systemctl show -P TimeoutIdleUSec {a}").strip() == "10min"
        m = unit("/mnt/nas/b", "mount")
        assert laptop.succeed(f"systemctl show -P TimeoutUSec {m}").strip() == "20s"

    with subtest("the links in the home lead to the mounts"):
        assert laptop.succeed("readlink -f /home/${user}/NAS-a").strip() == "/mnt/nas/a"
        laptop.succeed(as_user("cat ~/NAS-b/from-b"))

    with subtest("no password is in the journal, the fstab or a unit"):
        files = "/etc/fstab /etc/systemd/system/ravnix-nas-credential-*.service /var/lib/fake-rbw/log"
        for s in secrets:
            q = shlex.quote(s)
            laptop.fail(f"journalctl -o cat | grep -F -- {q}")
            laptop.fail(f"grep -F -- {q} {files}")
            laptop.fail(f"systemctl show -P Environment 'ravnix-nas-credential-*' | grep -F -- {q}")
  '';
}
