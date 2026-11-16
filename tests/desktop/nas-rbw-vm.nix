# The NAS mounts' real path (modules/desktop/nas.nix): the credentials unit,
# sandboxed as the module has it, runs the real setpriv and the real rbw as
# the user, against the user's real rbw-agent, from boot (the user lingers,
# so the user manager and the agent run as they do after a login). The vault
# is the stand-in of tests/workbench/rbw.nix (./../workbench/rbw/
# make-vault.py writes rbw's local copy of it, which the real agent unlocks
# and reads), with two items of one name, "NAS", told apart by their users,
# as a NAS's two accounts are. The pinentry behind ravnix's guard is a
# stand-in that answers and logs each time it is asked. Samba runs on the same
# machine, so the shares are mounted over loopback.
#
#   - with the agent locked, opening a share fails, no file is made, and
#     nothing asks for the master password: rbw under setpriv sees the lock;
#   - after ai-unlock on a terminal (the one prompt), the next access mounts:
#     rbw, with only setpriv's reset environment and XDG_RUNTIME_DIR, found
#     the user's configuration, vault copy and agent socket; the file holds
#     the item's password byte for byte (spaces, `#`, `,` and `=`), and each
#     account got the item of its own user; nothing prompted again; no
#     second agent runs;
#   - locked again with `rbw lock`, a remount keeps the file and prompts
#     nobody;
#   - with the agent stopped, a remount keeps the file and starts no agent
#     (RBW_AGENT is false there, so rbw cannot start one in a system unit);
#   - no password is in the journal.
#
# Run it under the shared lock, since other agents share the RAM:
#   flock .superpowers/sdd/2026-11-07-ravnix/vm.lock nix build .#checks.x86_64-linux.desktop-nas-rbw-vm
{
  self,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  me = import ../../templates/default/me.nix;
  user = me.ravnix.user.username;
  master = "correct horse battery staple";
  passwords = {
    a = "pa ss#word, with=odd chars";
    b = "b pass # two";
  };

  vault = import ../workbench/rbw/vault.nix {
    inherit pkgs;
    spec = {
      email = me.ravnix.secrets.rbwEmail;
      password = master;
      iterations = 5000;
      items = [
        {
          name = "NAS";
          login = {
            username = "owner-a";
            password = passwords.a;
          };
        }
        {
          name = "NAS";
          login = {
            username = "owner-b";
            password = passwords.b;
          };
        }
      ];
    };
  };

  # The pinentry behind the guard: answers with the master password, and
  # records each time it is run.
  pinentryStub = pkgs.writeShellApplication {
    name = "pinentry-stub";
    text = ''
      printf 'ASKED %s\n' "$*" >>"$HOME/pinentry.log"
      echo "OK stub"
      while IFS= read -r line; do
        case $line in
          GETPIN*) printf 'D %s\nOK\n' ${lib.escapeShellArg master} ;;
          BYE*) echo OK; exit 0 ;;
          *) echo OK ;;
        esac
      done
    '';
  };

  nas = {
    server = "127.0.0.1";
    accounts = {
      a = {
        username = "owner-a";
        item = "NAS";
      };
      b = {
        username = "owner-b";
        item = "NAS";
      };
    };
    shares = [
      {
        share = "share-a";
        account = "a";
        mountPoint = "/mnt/nas/a";
      }
      {
        share = "share-b";
        account = "b";
        mountPoint = "/mnt/nas/b";
      }
    ];
  };

  laptop = [
    self.nixosModules.common
    ../../modules/desktop/nas.nix
    ../../templates/default/me.nix
    {
      warnings = lib.mkForce [ ];
      ravnix.editor.languages = lib.mkForce [ "nix" ];
      ravnix.nas = lib.mkForce nas;
      home-manager.users.${user}.ravnix.rbw.pinentry = pinentryStub;
      system.stateVersion = "26.05";
    }
  ];
  # The cifs file systems of the same modules, evaluated as a host apart: a
  # test VM mounts only virtualisation.fileSystems.
  host = inputs.nixpkgs.lib.nixosSystem {
    inherit (pkgs.stdenv.hostPlatform) system;
    modules = laptop ++ [
      {
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
  name = "desktop-nas-rbw-vm";

  node.pkgs = lib.mkForce (pkgs.extend self.overlays.default);

  nodes.machine = {
    imports = laptop;
    virtualisation.fileSystems = lib.filterAttrs (_: fs: fs.fsType == "cifs") host.config.fileSystems;
    # The user manager, and rbw-agent in it, from boot, as after a login.
    users.users.${user}.linger = true;

    services.samba = {
      enable = true;
      settings = lib.genAttrs [ "share-a" "share-b" ] (name: {
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
      "d /srv/share-b 0775 owner-b owners -"
    ];

    environment.systemPackages = [
      pkgs.jq
      pkgs.util-linux
    ];
    virtualisation = {
      cores = 2;
      memorySize = 2048;
      diskSize = 4096;
    };
  };

  testScript = ''
    import json
    import shlex

    USER = "${user}"
    PASSWORDS = json.loads(${builtins.toJSON (builtins.toJSON passwords)})


    def as_user(cmd, check=True):
        script = "su - " + USER + " -c " + shlex.quote("export XDG_RUNTIME_DIR=/run/user/$(id -u); " + cmd)
        return machine.succeed(script) if check else machine.execute(script)


    def on_terminal(cmd):
        return as_user("script -qec " + shlex.quote("bash -ic " + shlex.quote(cmd)) + " /dev/null")


    def asked():
        return as_user("cat ~/pinentry.log 2>/dev/null || true").count("ASKED")


    def agents():
        # Every rbw-agent of the machine, by pid (the pattern does not match
        # the shell that runs pgrep).
        return machine.succeed("pgrep -f 'bin/[r]bw-agent' || true").split()


    def remount(path):
        unit = machine.succeed("systemd-escape -p --suffix=mount " + path).strip()
        machine.succeed("systemctl stop " + shlex.quote(unit))
        return as_user("timeout 60 cat " + path + "/note")


    def credentials(account):
        return machine.succeed("cat /run/ravnix/nas/" + account + ".cred")


    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("samba-smbd.service")
    machine.wait_for_unit("home-manager-" + USER + ".service")
    uid = machine.succeed("id -u " + USER).strip()
    machine.wait_for_unit("user@" + uid + ".service")
    machine.wait_for_unit("rbw-agent.service", USER)
    for name, account in (("a", "owner-a"), ("b", "owner-b")):
        machine.succeed(
            "printf '%s\\n%s\\n' " + shlex.quote(PASSWORDS[name]) + " " + shlex.quote(PASSWORDS[name])
            + " | smbpasswd -s -a " + account
        )

    with subtest("the stand-in vault is where the user's rbw reads it"):
        config = json.loads(as_user("rbw config show"))
        path = as_user("bash -ic _ravnix_rbw_db 2>/dev/null").strip()
        assert path.endswith(":" + config["email"] + ".json"), path
        as_user("mkdir -p " + shlex.quote(path.rsplit("/", 1)[0]) + " && install -m 600 ${vault}/db.json " + shlex.quote(path))
        assert as_user("rbw unlocked", False)[0] != 0

    with subtest("with the agent locked, a share cannot be opened, and nothing prompts"):
        code, _ = as_user("timeout 60 ls /mnt/nas/a", False)
        assert code != 0
        machine.succeed("test ! -e /run/ravnix/nas/a.cred")
        machine.succeed("journalctl -u ravnix-nas-credential-a -o cat | grep -F 'is locked'")
        assert asked() == 0, as_user("cat ~/pinentry.log")

    with subtest("after ai-unlock the next access mounts, through the real rbw as the user"):
        out = on_terminal("ai-unlock")
        assert "unlocked" in out, out
        assert asked() == 1, as_user("cat ~/pinentry.log")
        as_user("timeout 60 ls /mnt/nas/a")
        assert credentials("a") == "username=owner-a\npassword=" + PASSWORDS["a"] + "\n"
        assert machine.succeed("stat -c '%U %a' /run/ravnix/nas /run/ravnix/nas/a.cred").split() == ["root", "700", "root", "600"]
        # The item of the other user of the same name, for the other account.
        as_user("timeout 60 ls /mnt/nas/b")
        assert credentials("b") == "username=owner-b\npassword=" + PASSWORDS["b"] + "\n"
        as_user("echo a > /mnt/nas/a/note && echo b > /mnt/nas/b/note")
        assert machine.succeed("stat -c %U /srv/share-a/note /srv/share-b/note").split() == ["owner-a", "owner-b"]
        assert asked() == 1, as_user("cat ~/pinentry.log")
        main = as_user("systemctl --user show -P MainPID rbw-agent.service").strip()
        assert agents() == [main], (agents(), main)

    with subtest("locked again, a remount keeps the file and prompts nobody"):
        as_user("rbw lock")
        assert as_user("rbw unlocked", False)[0] != 0
        assert remount("/mnt/nas/b").strip() == "b"
        machine.succeed("journalctl -u ravnix-nas-credential-b -o cat | grep -F 'keep the password read before'")
        assert asked() == 1, as_user("cat ~/pinentry.log")

    with subtest("with the agent stopped, a remount keeps the file and starts no agent"):
        as_user("systemctl --user stop rbw-agent.service")
        assert agents() == [], agents()
        assert remount("/mnt/nas/a").strip() == "a"
        assert agents() == [], agents()
        assert as_user("systemctl --user is-active rbw-agent.service", False)[1].strip() == "inactive"
        assert asked() == 1, as_user("cat ~/pinentry.log")

    with subtest("no password is in the journal"):
        for p in PASSWORDS.values():
            machine.fail("journalctl -o cat | grep -F -- " + shlex.quote(p))
  '';
}
