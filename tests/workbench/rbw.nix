# The secrets and keys of the server, in a VM: rbw's agent as a user unit
# from boot, its SSH agent in SSH_AUTH_SOCK of the shell and of the user
# manager, commits signed through it, the HTTPS token helper, the Proxmox
# update key, and Claude Code's telemetry off.
#
# The vault is a stand-in, but rbw is not: ./rbw/make-vault.py writes rbw's
# local copy of a vault with the test's own master password, items and SSH
# keys, and the real rbw and rbw-agent of the system run on it. They never
# ask the server to unlock or read (the stand-in's server is a name that
# does not resolve here), so this is the agent the server runs, down to its
# SSH socket and its lock. The master password comes from a stand-in
# pinentry, which logs every time it is asked: the module's pinentry guard
# must ask it only for a person at a terminal where rbw waits.
#
# What the brief asks is checked as it says: the socket lists the key after
# an unlock, `git commit -S` signs, after a reboot the agent is locked and
# ai-unlock is the way back, and the token helper gives the write token,
# as the Basic password for the forge's user, only to the one remote it is
# for. Besides: a locked agent refuses an SSH request at once and asks no
# terminal, even the terminal ai-unlock last ran in; a user unit signs as
# a shell does (Task 5.3's vault-commit runs as one); a read of the vault
# renews rbw's lock timeout, so a timer that reads keeps it unlocked; the
# token helper hands out nothing while the vault is locked or the item is
# missing, never to another repository, host, scheme or user, and never to
# a helper that stores credentials.
{
  self,
  pkgs,
  lib,
  ...
}:
let
  me = import ../../templates/default/me.nix;
  user = me.ravnix.user;
  password = "correct horse battery staple";
  token = "stub-write-token-0123456789";
  forgeUser = "alice-admin";
  item = "Forge - API token (private, write)";

  vault = import ./rbw/vault.nix {
    inherit pkgs;
    spec = {
      email = me.ravnix.secrets.rbwEmail;
      inherit password;
      iterations = 5000;
      items = [
        {
          name = item;
          login = {
            username = forgeUser;
            password = token;
          };
        }
        {
          name = "SSH - signing";
          ssh = "signing";
        }
        {
          name = "SSH - proxmox update";
          ssh = "proxmox-update";
        }
      ];
    };
  };
  # The public halves of the two keys, as make-vault.py derives them from
  # their seeds: written here because the configuration needs them before
  # anything is built. The test checks they are the vault's.
  signingKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIColigY4B+oJuKGicuW0gkGiUvO5CNpsn7T01CCYuidd";
  proxmoxKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDQ29lICEgLMf15mNd1EzcpkA0u+l5AFh+xW9MsP0OlJ";

  # The pinentry behind the guard: answers with the master password, and
  # records each time it is run and on which terminal.
  pinentryStub = pkgs.writeShellApplication {
    name = "pinentry-stub";
    text = ''
      printf 'ASKED %s\n' "$*" >>"$HOME/pinentry.log"
      echo "OK stub"
      while IFS= read -r line; do
        case $line in
          GETPIN*) printf 'D %s\nOK\n' ${lib.escapeShellArg password} ;;
          BYE*) echo OK; exit 0 ;;
          *) echo OK ;;
        esac
      done
    '';
  };

  # A forge over HTTPS: asks for Basic credentials, records what it was
  # sent, and answers an authenticated request with an empty repository.
  cert = pkgs.runCommand "forge-cert" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out
    openssl req -x509 -newkey rsa:2048 -nodes -days 36500 -subj /CN=forge.test \
      -addext subjectAltName=DNS:forge.test -keyout $out/key.pem -out $out/cert.pem 2>/dev/null
  '';
  forge = pkgs.writeText "forge.py" ''
    import http.server, ssl, sys
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            auth = self.headers.get("Authorization")
            with open("/tmp/forge.log", "a") as f:
                f.write("%s %s\n" % (self.path, auth))
            if auth is None:
                self.send_response(401)
                self.send_header("WWW-Authenticate", 'Basic realm="forge"')
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.end_headers()
    s = http.server.HTTPServer(("127.0.0.1", 8443), H)
    c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    c.load_cert_chain("${cert}/cert.pem", "${cert}/key.pem")
    s.socket = c.wrap_socket(s.socket, server_side=True)
    s.serve_forever()
  '';
  remote = "https://forge.test:8443/${user.username}/private.git";
in
pkgs.testers.runNixOSTest {
  name = "workbench-rbw";

  nodes.machine =
    { pkgs, ... }:
    {
      imports = [
        self.nixosModules.server
        ../../templates/default/me.nix
      ];
      warnings = lib.mkForce [ ];
      users.users.root.hashedPasswordFile = lib.mkForce null;
      ravnix.editor.languages = lib.mkForce [ "nix" ];

      ravnix.user.signingKey = lib.mkForce "${signingKey} ${user.email}";
      ravnix.secrets.gitTokens = lib.mkForce [
        {
          url = remote;
          username = forgeUser;
          inherit item;
        }
        # An item the vault does not have.
        {
          url = "https://forge.test:8443/${user.username}/missing.git";
          username = forgeUser;
          item = "Forge - API token (missing)";
        }
      ];
      ravnix.server.proxmoxUpdate = lib.mkForce {
        alias = "proxmox-update";
        hostName = "127.0.0.1";
        user = "pve";
        publicKey = "${proxmoxKey} proxmox-update";
      };

      # The Proxmox node stands in here: the update key runs one command and
      # nothing else, as the docs tell the node to take it.
      users.users.pve = {
        isNormalUser = true;
        openssh.authorizedKeys.keys = [
          ''command="echo update-ran",restrict ${proxmoxKey}''
        ];
      };

      networking.hosts."127.0.0.1" = [ "forge.test" ];
      systemd.services.forge = {
        wantedBy = [ "multi-user.target" ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${forge}";
      };

      home-manager.users.${user.username} = {
        ravnix.rbw.pinentry = pinentryStub;
        # A helper that stores what another helper found: the token must
        # never reach it.
        programs.git.settings.credential.helper = "store";
        # The sync timers read the vault on the clock of the VM, which would
        # renew rbw's lock timeout in the subtest that waits for it to run
        # out: here they cannot fire (as in workbench-server).
        systemd.user.timers = lib.genAttrs [ "nextcloud-sync" "vdirsyncer" ] (_: {
          Timer = {
            OnCalendar = lib.mkForce "2099-01-01 00:00:00";
            OnBootSec = lib.mkForce "1y";
          };
        });
      };

      environment.systemPackages = [
        pkgs.jq
        pkgs.util-linux
      ];
      virtualisation = {
        cores = 2;
        memorySize = 2048;
        diskSize = 4096;
      };
      system.stateVersion = "26.05";
    };

  testScript = ''
    import base64
    import json
    import shlex
    import time

    USER = "${user.username}"
    HOME = "/home/" + USER
    ITEM = ${builtins.toJSON item}
    TOKEN = ${builtins.toJSON token}
    REMOTE = ${builtins.toJSON remote}


    def as_user(cmd, check=True):
        script = "su - " + USER + " -c " + shlex.quote("export XDG_RUNTIME_DIR=/run/user/$(id -u); " + cmd)
        return machine.succeed(script) if check else machine.execute(script)


    def on_terminal(cmd, check=True):
        # An interactive bash on a terminal of its own, as a person has it.
        return as_user("script -qec " + shlex.quote("bash -ic " + shlex.quote(cmd)) + " /dev/null", check)


    def asked():
        return as_user("cat ~/pinentry.log 2>/dev/null || true").count("ASKED")


    def boot():
        machine.wait_for_unit("multi-user.target")
        machine.wait_for_unit("home-manager-" + USER + ".service")
        uid = machine.succeed("id -u " + USER).strip()
        machine.wait_for_unit("user@" + uid + ".service")
        machine.wait_for_unit("rbw-agent.service", USER)
        return uid


    def put_vault():
        config = json.loads(as_user("rbw config show"))
        path = as_user("bash -ic _ravnix_rbw_db 2>/dev/null").strip()
        assert path.endswith(":" + config["email"] + ".json"), path
        as_user("mkdir -p " + shlex.quote(path.rsplit("/", 1)[0]) + " && install -m 600 ${vault}/db.json " + shlex.quote(path))


    def ssh_add_fails_fast():
        start = time.monotonic()
        code, out = as_user("timeout 20 ssh-add -l 2>&1", False)
        took = time.monotonic() - start
        assert code not in (0, 124), (code, out)
        assert took < 10, "ssh-add waited " + str(took) + " s on a locked agent"
        return out


    uid = boot()
    sock = "/run/user/" + uid + "/rbw/ssh-agent-socket"

    with subtest("the stand-in vault holds the keys the configuration names"):
        assert machine.succeed("cat '${vault}/SSH - signing.pub'").strip() == "${signingKey}"
        assert machine.succeed("cat '${vault}/SSH - proxmox update.pub'").strip() == "${proxmoxKey}"
        put_vault()

    with subtest("rbw's agent runs from boot as a user unit, locked, with its SSH socket"):
        machine.succeed("test -S " + sock)
        assert as_user("rbw unlocked", False)[0] != 0
        # The shell and the user manager point SSH_AUTH_SOCK at it.
        assert as_user("echo $SSH_AUTH_SOCK").strip() == sock
        env = as_user("systemctl --user show-environment")
        assert "SSH_AUTH_SOCK=" + sock in env.splitlines(), env

    with subtest("a locked agent refuses an SSH request at once and asks nobody"):
        before = asked()
        out = ssh_add_fails_fast()
        assert asked() == before, "the agent asked for the master password: " + as_user("cat ~/pinentry.log")

    with subtest("ai-unlock on a terminal unlocks, and the socket lists the key"):
        out = on_terminal("ai-unlock")
        assert "unlocked" in out, out
        assert asked() == 1, as_user("cat ~/pinentry.log")
        assert "--ttyname /dev/pts/" in as_user("cat ~/pinentry.log")
        as_user("rbw unlocked")
        keys = as_user("ssh-add -L")
        assert "${signingKey}" in keys and "${proxmoxKey}" in keys, keys

    with subtest("git commit signs through the agent, and the signature verifies"):
        as_user("git init -q ~/repo && cd ~/repo && git commit -q --allow-empty -m signed")
        as_user("cd ~/repo && git verify-commit HEAD")
        out = as_user("cd ~/repo && git log -1 --format=%G?")
        assert out.strip() == "G", out
        # Explicitly as the brief has it.
        as_user("cd ~/repo && git commit -q -S --allow-empty -m signed-again && git verify-commit HEAD")

    with subtest("a user unit signs too: the user manager hands it the agent"):
        as_user("systemd-run --user --wait --collect -p WorkingDirectory=" + HOME + "/repo git commit -q --allow-empty -m from-a-unit")
        assert as_user("cd ~/repo && git log -1 --format=%s").strip() == "from-a-unit"
        as_user("cd ~/repo && git verify-commit HEAD")

    with subtest("the Proxmox key runs the forced command, and ssh offers no other key"):
        as_user("ssh-keyscan -t ed25519 127.0.0.1 > ~/.ssh/known_hosts 2>/dev/null")
        conf = as_user("ssh -G proxmox-update")
        assert "identitiesonly yes" in conf and "user pve" in conf and "hostname 127.0.0.1" in conf, conf
        out = as_user("ssh -v proxmox-update 2>&1")
        assert "update-ran" in out, out
        offered = [l for l in out.splitlines() if "Offering public key" in l]
        assert len(offered) == 1 and "proxmox-update" in offered[0], offered
        # The command is the node's to choose: what the client asks for is not run.
        out = as_user("ssh proxmox-update 'touch /tmp/escaped' 2>&1")
        assert "update-ran" in out, out
        machine.fail("test -e /tmp/escaped")

    with subtest("the token helper gives the write token to its remote alone, as the Basic password"):
        def fill(url, extra=""):
            q = shlex.quote("url=" + url + "\n" + extra + "\n")
            return as_user("printf %s " + q + " | GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=false git credential fill 2>&1", False)

        code, out = fill(REMOTE)
        assert code == 0, out
        assert "username=${forgeUser}\npassword=" + TOKEN + "\n" in out, out
        # The host as git passes it, whatever its case: the same server.
        code, out = fill("https://FORGE.Test:8443/" + USER + "/private.git")
        assert code == 0 and "password=" + TOKEN + "\n" in out, out
        # Another repository of the same user, the bare host, another host,
        # plain http, another user in the URL, a path that only starts the
        # same: no token, and git has nowhere else to get one.
        for url in [
            "https://forge.test:8443/" + USER + "/other.git",
            "https://forge.test:8443/" + USER + "/private.git-evil",
            "https://forge.test:8443/" + USER + "/private.git/../other.git",
            "https://forge.test:8443/",
            "https://forge.test/" + USER + "/private.git",
            "https://other.test:8443/" + USER + "/private.git",
            "http://forge.test:8443/" + USER + "/private.git",
            "https://someone@forge.test:8443/" + USER + "/private.git",
        ]:
            code, out = fill(url)
            assert code != 0 and TOKEN not in out, (url, out)
        # The token never leaves through another helper, nor a cache.
        as_user("printf 'url=%s\\nusername=${forgeUser}\\npassword=%s\\n\\n' " + shlex.quote(REMOTE) + " " + shlex.quote(TOKEN) + " | git credential approve")
        machine.fail("test -e " + HOME + "/.git-credentials")
        # git sends it to the forge as the password of the forge's user.
        machine.wait_for_unit("forge.service")
        machine.wait_for_open_port(8443)
        as_user("GIT_SSL_CAINFO=${cert}/cert.pem GIT_TERMINAL_PROMPT=0 git ls-remote " + REMOTE, False)
        sent = [l.split(" ", 1)[1] for l in machine.succeed("cat /tmp/forge.log").splitlines() if not l.endswith(" None")]
        assert sent, machine.succeed("cat /tmp/forge.log")
        assert all(base64.b64decode(s.split(" ", 1)[1]).decode() == "${forgeUser}:" + TOKEN for s in sent), sent
        machine.succeed("rm /tmp/forge.log")
        as_user("GIT_SSL_CAINFO=${cert}/cert.pem GIT_TERMINAL_PROMPT=0 git ls-remote https://forge.test:8443/" + USER + "/other.git", False)
        assert " None" in machine.succeed("cat /tmp/forge.log") and "Basic" not in machine.succeed("cat /tmp/forge.log")

    with subtest("the limit: a storing helper configured after the reset, in a repository, is handed the token"):
        # git reads the repository's config after the user's, so its helper
        # comes after the empty helper line that resets the list. What this
        # shows is documented (modules/common/tokens.nix): do not configure
        # store or cache in a repository or with -c on a host with tokens.
        as_user("cd ~/repo && git config credential.helper store")
        as_user("cd ~/repo && printf 'url=%s\\nusername=${forgeUser}\\npassword=%s\\n\\n' " + shlex.quote(REMOTE) + " " + shlex.quote(TOKEN) + " | git credential approve")
        assert TOKEN in as_user("cat ~/.git-credentials")
        as_user("rm ~/.git-credentials && cd ~/repo && git config --unset credential.helper")

    with subtest("the token helper says so and gives nothing when the item is missing"):
        code, out = fill("https://forge.test:8443/" + USER + "/missing.git")
        assert code != 0 and "Forge - API token (missing)" in out, out

    with subtest("Claude Code's telemetry and error reports are off wherever it gets its environment"):
        for var in ["DISABLE_TELEMETRY", "DISABLE_ERROR_REPORTING"]:
            assert var + "=1" in as_user("systemctl --user show-environment").splitlines(), var
            assert as_user("echo $" + var).strip() == "1", var
            assert as_user("bash -ic 'echo $" + var + "' 2>/dev/null").strip() == "1", var
            assert json.loads(as_user("cat ~/.claude/settings.json"))["env"][var] == "1", var

    with subtest("locked from the terminal ai-unlock ran in, the agent asks that terminal nothing"):
        # The terminal stays open, as a herdr pane does: its rbw was the
        # last to talk to the agent, so the agent would prompt there.
        as_user("rm -f ~/term.done; (script -qec " + shlex.quote("bash -ic 'rbw lock; touch ~/term.done; sleep 60'") + " /dev/null >/dev/null 2>&1 &)")
        as_user("for i in $(seq 50); do test -e ~/term.done && break; sleep 0.2; done; test -e ~/term.done")
        before = asked()
        ssh_add_fails_fast()
        as_user("cd ~/repo && ! timeout 20 git commit -q --allow-empty -m locked")
        assert asked() == before, as_user("cat ~/pinentry.log")
        assert as_user("rbw unlocked", False)[0] != 0

    with subtest("the token helper gives nothing while the vault is locked, and asks nobody"):
        before = asked()
        code, out = fill(REMOTE)
        assert code != 0 and TOKEN not in out and "locked" in out, out
        assert asked() == before

    with subtest("a read renews rbw's lock timeout, and without reads the vault locks"):
        # A config with a lock timeout of 8 s, for this subtest only.
        as_user("cp --remove-destination $(readlink -f ~/.config/rbw/config.json) ~/.config/rbw/config.json && chmod u+w ~/.config/rbw/config.json")
        as_user("jq '.lock_timeout = 8' ~/.config/rbw/config.json > ~/c.json && mv ~/c.json ~/.config/rbw/config.json")
        as_user("systemctl --user restart rbw-agent.service")
        on_terminal("ai-unlock")
        for _ in range(4):
            machine.sleep(4)
            as_user("rbw get -- " + shlex.quote(ITEM) + " >/dev/null")
        as_user("rbw unlocked")
        machine.sleep(12)
        assert as_user("rbw unlocked", False)[0] != 0
        as_user("rm ~/.config/rbw/config.json")
        machine.succeed("systemctl restart home-manager-" + USER + ".service")
        as_user("test -L ~/.config/rbw/config.json")
        # The agent reads its config at its start.
        as_user("systemctl --user restart rbw-agent.service")

    with subtest("an unlock arms the 12-hour lock by the wall clock, which locks the vault and says so"):
        as_user("systemctl --user stop rbw-relock.timer", False)
        # A request the guard refuses arms nothing.
        ssh_add_fails_fast()
        assert as_user("systemctl --user is-active rbw-relock.timer", False)[1].strip() == "inactive"
        on_terminal("ai-unlock")
        assert as_user("systemctl --user is-active rbw-relock.timer").strip() == "active"
        # A realtime deadline 12 hours from now, which a suspend does not
        # stretch: a calendar timer, not a monotonic one.
        timer = as_user("systemctl --user show rbw-relock.timer -p TimersCalendar -p TimersMonotonic -p NextElapseUSecRealtime")
        props = dict(l.split("=", 1) for l in timer.splitlines() if "=" in l)
        assert props.get("TimersMonotonic", "") == "" and props.get("TimersCalendar", "") != "", timer
        due = int(as_user("date -d \"$(systemctl --user show rbw-relock.timer -p NextElapseUSecRealtime --value)\" +%s").strip())
        now = int(machine.succeed("date +%s").strip())
        assert abs(due - now - 12 * 3600) < 180, (due - now, timer)
        # A second unlock moves the deadline and leaves one timer.
        on_terminal("rbw lock; ai-unlock")
        assert len(as_user("systemctl --user list-timers --all --no-legend 'rbw-relock*'").splitlines()) == 1
        # The 12 hours, as if they had passed.
        as_user("systemctl --user start rbw-relock.service")
        assert as_user("rbw unlocked", False)[0] != 0
        said = as_user("journalctl --user -u rbw-relock.service --no-pager -o cat")
        assert "ai-unlock" in said and "12h" in said, said
        # What needs the vault says that it is locked, and stops.
        code, _ = as_user("systemctl --user start nextcloud-sync.service", False)
        assert code != 0
        assert "locked" in as_user("journalctl --user -u nextcloud-sync.service --no-pager -o cat"), "nextcloud-sync does not say the vault is locked"
        ssh_add_fails_fast()

    with subtest("after a reboot the agent is locked, refuses at once, and ai-unlock brings it back"):
        on_terminal("ai-unlock")
        machine.shutdown()
        machine.start()
        uid = boot()
        machine.succeed("test -S " + sock)
        assert as_user("rbw unlocked", False)[0] != 0
        before = asked()
        ssh_add_fails_fast()
        assert asked() == before
        out = on_terminal("ai-unlock")
        assert "unlocked" in out, out
        assert "${signingKey}" in as_user("ssh-add -L")
        as_user("cd ~/repo && git commit -q --allow-empty -m after-reboot && git verify-commit HEAD")

    with subtest("rbw stop-agent, as ai-unlock's repair runs it, leaves the next rbw to start the unit again"):
        old = as_user("systemctl --user show -p MainPID --value rbw-agent.service").strip()
        as_user("rbw stop-agent")
        # rbw stop-agent waits for the agent to exit, which ends the unit
        # without a failure: nothing restarts it. The state is read with
        # as_user and compared here: `systemctl is-active` exits 3 for
        # inactive, and the driver runs a command line with pipefail, so a
        # `... | grep -qx inactive` never succeeds (that, not a restart, was
        # why the first runs of this test timed out here).
        machine.fail("test -e /proc/" + old)
        for _ in range(10):
            state = as_user("systemctl --user is-active rbw-agent.service", False)[1].strip()
            if state == "inactive":
                break
            machine.sleep(1)
        assert state == "inactive", state + "\n" + as_user("systemctl --user status rbw-agent.service --no-pager 2>&1; journalctl --user -u rbw-agent.service --no-pager -n 30 2>&1", False)[1]
        on_terminal("ai-unlock")
        assert as_user("systemctl --user is-active rbw-agent.service").strip() == "active"
        # One agent, the unit's.
        pids = as_user("pgrep -u " + USER + " -x rbw-agent").split()
        assert len(pids) == 1, pids
        assert pids[0] == as_user("systemctl --user show -p MainPID --value rbw-agent.service").strip(), pids
        assert "${signingKey}" in as_user("ssh-add -L")
  '';
}
