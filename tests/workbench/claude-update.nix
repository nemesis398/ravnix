# The Claude Code update timer (Task 6.1) in three VMs: muninn, the server
# shape, which bumps, builds, switches, commits and pushes; huginn, which
# follows the lock it pushed; and forge, which stands in for Forgejo and for
# downloads.claude.ai. Nothing reaches the network.
#
# forge serves three git repositories over HTTPS through git http-backend:
# the private flake (alice/private.git), which wants the write token for a
# push and the read or the write token for a fetch, and upstream/
# claude-code-nix.git and upstream/ravnix.git, which anyone may fetch. It
# also serves claude-code-releases/latest and each version's manifest.json,
# as Anthropic does, and logs every request with the token it came with.
#
# The flakes are stand-ins that build in a moment: claude-code-nix's package
# is a file whose version and content the test sets (and whose build fails
# on purpose while a file `fail` is in the repository), and the private
# flake's host is a derivation with a switch-to-configuration that writes
# down what it was asked to switch to. The vault and rbw are real, as in
# workbench-rbw: the write token is muninn's, the read token huginn's, and
# the commit is signed with the vault's SSH key through rbw's agent.
#
# What is checked: the timers' times (06:00 and 18:00, Persistent); an equal
# version does nothing, and so does a forge that cannot be reached; a build
# that fails switches, commits and pushes nothing and leaves the running
# generation as it was; a newer version is bumped (flake.lock changes in the
# claude-code node alone), built with the ravnix the host runs, verified
# against the manifest, switched, committed with a signature on top of the
# remote's branch and pushed with the write token, after which the sessions
# roll and Remote Control restarts; a checkout of the user's own stays as it
# was; huginn fetches with the read token and switches, pushing nothing; a
# refused push leaves the switch and says so; a locked vault and a second
# run at the same time do nothing; a lock that names a revision only a fork
# has (as GitHub serves them under the upstream's URL), with a version
# upstream's branch lacks, is never followed, and huginn says so once per
# push; huginn does not run ahead of the version the server pushed; and
# with huginn's vault locked its run waits without a word, and the hourly
# retry gets through once the vault is unlocked.
{
  self,
  pkgs,
  lib,
  ...
}:
let
  me = import ../../templates/default/me.nix;
  user = me.ravnix.user.username;
  password = "correct horse battery staple";
  writeToken = "stub-write-token-0123456789";
  readToken = "stub-read-token-9876543210";
  forgeUser = "alice-admin";
  writeItem = "Forge - API token (private, write)";
  readItem = "Forge - API token (private, read)";
  remote = "https://forge/${user}/private.git";
  releases = "https://forge/claude-code-releases";
  # The public half of make-vault.py's key from the seed "signing", as in
  # workbench-rbw.
  signingKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIColigY4B+oJuKGicuW0gkGiUvO5CNpsn7T01CCYuidd";

  vault =
    items:
    import ./rbw/vault.nix {
      inherit pkgs;
      spec = {
        email = me.ravnix.secrets.rbwEmail;
        inherit password items;
        iterations = 5000;
      };
    };
  muninnVault = vault [
    {
      name = writeItem;
      login = {
        username = forgeUser;
        password = writeToken;
      };
    }
    {
      name = "SSH - signing";
      ssh = "signing";
    }
  ];
  huginnVault = vault [
    {
      name = readItem;
      login = {
        username = forgeUser;
        password = readToken;
      };
    }
  ];

  pinentryStub = pkgs.writeShellApplication {
    name = "pinentry-stub";
    text = ''
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

  # What the update tells the user, written down instead of sent.
  notifyStub = pkgs.writeShellScript "ravnix-notify-stub" ''
    printf '%s\t%s\n' "$2" "$4" >>"$HOME/notify.log"
  '';

  cert = pkgs.runCommand "forge-cert" { nativeBuildInputs = [ pkgs.openssl ]; } ''
    mkdir $out
    openssl req -x509 -newkey rsa:2048 -nodes -days 36500 -subj /CN=forge \
      -addext subjectAltName=DNS:forge -keyout $out/key.pem -out $out/cert.pem 2>/dev/null
  '';

  forgeServer = pkgs.writeText "forge.py" ''
    import base64, http.server, os, ssl, subprocess


    def basic(token):
        return "Basic " + base64.b64encode(("${forgeUser}:" + token).encode()).decode()


    TOKENS = {basic("${writeToken}"): "write", basic("${readToken}"): "read"}

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def record(self, access, status):
            with open("/var/log/forge.log", "a") as f:
                f.write("%s %s %s %d\n" % (access, self.command, self.path, status))

        def reply(self, status, body=b"", headers=()):
            self.send_response(status)
            for k, v in headers:
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def body(self):
            if self.headers.get("Transfer-Encoding", "").lower() == "chunked":
                out = b""
                while True:
                    size = int(self.rfile.readline().strip(), 16)
                    if size == 0:
                        self.rfile.readline()
                        return out
                    out += self.rfile.read(size)
                    self.rfile.readline()
            n = int(self.headers.get("Content-Length") or 0)
            return self.rfile.read(n) if n else b""

        def handle_any(self):
            path, _, query = self.path.partition("?")
            if path.startswith("/claude-code-releases/"):
                f = "/srv/releases/" + path[len("/claude-code-releases/"):]
                if ".." in path or not os.path.isfile(f):
                    self.record("release", 404)
                    return self.reply(404)
                self.record("release", 200)
                with open(f, "rb") as fh:
                    return self.reply(200, fh.read())
            auth = self.headers.get("Authorization")
            access = TOKENS.get(auth, "none" if auth is None else "bad")
            push = "receive-pack" in self.path
            if path.startswith("/upstream/"):
                if push:
                    self.record("anon", 403)
                    return self.reply(403)
                access = "anon"
            elif path.startswith("/${user}/private.git/"):
                if access in ("none", "bad"):
                    self.record(access, 401)
                    return self.reply(401, headers=[("WWW-Authenticate", 'Basic realm="forge"')])
                if push and access != "write":
                    self.record(access, 403)
                    return self.reply(403)
            else:
                self.record(access, 404)
                return self.reply(404)
            data = self.body()
            env = {
                "GIT_PROJECT_ROOT": "/srv/git",
                "GIT_HTTP_EXPORT_ALL": "1",
                "PATH_INFO": path,
                "QUERY_STRING": query,
                "REQUEST_METHOD": self.command,
                "CONTENT_TYPE": self.headers.get("Content-Type", ""),
                "CONTENT_LENGTH": str(len(data)),
                "HTTP_CONTENT_ENCODING": self.headers.get("Content-Encoding", ""),
                "GIT_PROTOCOL": self.headers.get("Git-Protocol", ""),
                "REMOTE_USER": "${user}",
                "REMOTE_ADDR": self.client_address[0],
                "PATH": os.environ["PATH"],
            }
            p = subprocess.run(["git", "http-backend"], input=data, env=env, capture_output=True)
            sep = b"\r\n\r\n" if b"\r\n\r\n" in p.stdout else b"\n\n"
            head, _, out = p.stdout.partition(sep)
            status, headers = 200, []
            for line in head.decode().splitlines():
                k, _, v = line.partition(":")
                if k.lower() == "status":
                    status = int(v.split()[0])
                elif k:
                    headers.append((k, v.strip()))
            self.record(access, status)
            self.reply(status, out, headers)

        do_GET = handle_any
        do_POST = handle_any

    s = http.server.ThreadingHTTPServer(("0.0.0.0", 443), H)
    c = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    c.load_cert_chain("${cert}/cert.pem", "${cert}/key.pem")
    s.socket = c.wrap_socket(s.socket, server_side=True)
    s.serve_forever()
  '';

  # claude-code-nix, as far as the update sees it: a package with a version
  # and the download it was made from. Its build fails while ./fail exists.
  sh = "${pkgs.bash}/bin/bash";
  bin = "${pkgs.coreutils}/bin";
  fakeUpstream = pkgs.writeTextDir "flake.nix" ''
    {
      outputs = { self }:
        let
          version = builtins.replaceStrings [ "\n" ] [ "" ] (builtins.readFile ./version);
          download = builtins.derivation {
            name = "claude";
            system = "x86_64-linux";
            builder = "${sh}";
            args = [ "-c" "${bin}/cp ''${./binary} $out" ];
          };
          package = builtins.derivation {
            name = "claude-code-''${version}";
            system = "x86_64-linux";
            builder = "${sh}";
            inherit download;
            args = [ "-c" (if builtins.pathExists ./fail
              then "echo this build fails on purpose >&2; exit 1"
              else "${bin}/mkdir -p $out/bin && ${bin}/cp $download $out/bin/claude") ];
          };
        in {
          packages.x86_64-linux.claude-code = package // { inherit version download; };
        };
    }
  '';
  fakeRavnix =
    marker:
    pkgs.writeTextDir "flake.nix" ''
      { outputs = { self }: { marker = "${marker}"; }; }
    '';
  # The private flake: its hosts are a derivation each, whose
  # switch-to-configuration writes down what it was asked.
  fakePrivate = pkgs.writeTextDir "flake.nix" ''
    {
      inputs.claude-code.url = "git+https://forge/upstream/claude-code-nix.git";
      inputs.ravnix.url = "git+https://forge/upstream/ravnix.git";
      outputs = { self, claude-code, ravnix }:
        let
          pkg = claude-code.packages.x86_64-linux.claude-code;
          host = name: {
            config.system.build.toplevel = builtins.derivation {
              name = "fake-system-''${name}";
              system = "x86_64-linux";
              builder = "${sh}";
              claude = pkg;
              line = "''${name} ''${pkg.version} ''${ravnix.marker}";
              args = [ "-c" '''
                ${bin}/mkdir -p $out/bin
                printf '#!${sh}\necho "%s $1 %s" >> /var/lib/fake-switch.log\n' "$line" "$out" > $out/bin/switch-to-configuration
                ${bin}/chmod +x $out/bin/switch-to-configuration
              ''' ];
            };
            config.home-manager.users.${user}.programs.claude-code.package = pkg;
          };
        in {
          nixosConfigurations.muninn = host "muninn";
          nixosConfigurations.huginn = host "huginn";
        };
    }
  '';

  # What both hosts of the update have: the flake they were "deployed"
  # from, the ravnix they "run", the forge's certificate, the vault and
  # its agent, the update's options, and the notify stand-in.
  updateHost =
    { tokenUrl, tokenItem }:
    { pkgs, ... }:
    {
      warnings = lib.mkForce [ ];
      users.users.root.hashedPasswordFile = lib.mkForce null;
      ravnix.editor.languages = lib.mkForce [ "nix" ];
      ravnix.user.signingKey = lib.mkForce "${signingKey} ${me.ravnix.user.email}";
      ravnix.secrets.gitTokens = lib.mkForce [
        {
          url = tokenUrl;
          username = forgeUser;
          item = tokenItem;
        }
      ];
      ravnix.claudeUpdate = {
        flake = "/var/lib/ravnix-test/deployed";
        inherit remote releases;
        runningVersion = "2.0.0";
        overrideInputs = lib.mkForce { ravnix = "/srv/ravnix-new"; };
        notify = "${notifyStub}";
        rollDeadline = "1m";
      };
      security.pki.certificateFiles = [ "${cert}/cert.pem" ];
      # The stand-in flakes build with a shell from the store that no
      # derivation names.
      nix.settings = {
        sandbox = false;
        substituters = lib.mkForce [ ];
        experimental-features = [
          "nix-command"
          "flakes"
        ];
      };
      system.extraDependencies = [
        pkgs.bash
        pkgs.coreutils
      ];
      environment.systemPackages = [
        pkgs.git
        pkgs.jq
        pkgs.util-linux
      ];
      home-manager.users.${user} = {
        ravnix.rbw.pinentry = pinentryStub;
        systemd.user.timers = lib.genAttrs [ "nextcloud-sync" "vdirsyncer" ] (_: {
          Timer = {
            OnCalendar = lib.mkForce "2099-01-01 00:00:00";
            OnBootSec = lib.mkForce "1y";
          };
        });
      };
      virtualisation = {
        cores = 2;
        diskSize = 4096;
      };
      system.stateVersion = "26.05";
    };
in
pkgs.testers.runNixOSTest {
  name = "workbench-claude-update";

  node.pkgs = lib.mkForce (pkgs.extend self.overlays.default);

  nodes.forge =
    { pkgs, ... }:
    {
      networking.firewall.allowedTCPPorts = [ 443 ];
      systemd.services.forge = {
        wantedBy = [ "multi-user.target" ];
        path = [ pkgs.git ];
        serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 ${forgeServer}";
      };
      environment.systemPackages = [ pkgs.git ];
      virtualisation.memorySize = 768;
      system.stateVersion = "26.05";
    };

  nodes.muninn =
    { ... }:
    {
      imports = [
        self.nixosModules.server
        ../../templates/default/me.nix
        (updateHost {
          tokenUrl = remote;
          tokenItem = writeItem;
        })
      ];
      # A stand-in for Remote Control: its restart is what is checked.
      ravnix.server.remoteControlDir = lib.mkForce null;
      home-manager.users.${user}.systemd.user.services.claude-remote-control = {
        Service.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
        Install.WantedBy = [ "default.target" ];
      };
      virtualisation.memorySize = 2048;
    };

  nodes.huginn =
    { ... }:
    {
      imports = [
        self.nixosModules.common
        (import ../../modules/workbench/claude-update.nix { inherit self; })
        ../../templates/default/me.nix
        (updateHost {
          tokenUrl = remote;
          tokenItem = readItem;
        })
      ];
      ravnix.shape = "laptop";
      # The laptop's user manager runs while someone is logged in; here
      # nobody is.
      users.users.${user}.linger = true;
      virtualisation.memorySize = 1536;
    };

  testScript = ''
    import hashlib
    import json
    import shlex

    USER = "${user}"
    STATE = "/home/" + USER + "/.local/state/ravnix/claude-update"
    PRIVATE = "/srv/git/" + USER + "/private.git"


    def as_user(machine, cmd, check=True):
        script = "su - " + USER + " -c " + shlex.quote("export XDG_RUNTIME_DIR=/run/user/$(id -u); " + cmd)
        return machine.succeed(script) if check else machine.execute(script)


    def unlock(machine, vault):
        machine.wait_for_unit("multi-user.target")
        machine.wait_for_unit("home-manager-" + USER + ".service")
        uid = machine.succeed("id -u " + USER).strip()
        machine.wait_for_unit("user@" + uid + ".service")
        machine.wait_for_unit("rbw-agent.service", USER)
        config = json.loads(as_user(machine, "rbw config show"))
        path = as_user(machine, "bash -ic _ravnix_rbw_db 2>/dev/null").strip()
        assert path.endswith(":" + config["email"] + ".json"), path
        as_user(machine, "mkdir -p " + shlex.quote(path.rsplit("/", 1)[0]) + " && install -m 600 " + vault + "/db.json " + shlex.quote(path))
        out = as_user(machine, "script -qec " + shlex.quote("bash -ic ai-unlock") + " /dev/null")
        assert "unlocked" in out, out
        as_user(machine, "rbw unlocked")


    def upstream(version, fail=False):
        forge.succeed(
            "cd /srv/work/cc && printf '%s\\n' " + version + " > version"
            + " && printf 'fake claude %s\\n' " + version + " > binary"
            + (" && touch fail" if fail else " && rm -f fail")
            + " && git add -A && git commit -qm v" + version + " && git push -q origin HEAD:main"
        )


    def release(version):
        data = ("fake claude " + version + "\n").encode()
        manifest = json.dumps({
            "version": version,
            "platforms": {"linux-x64": {"binary": "claude", "checksum": hashlib.sha256(data).hexdigest(), "size": len(data)}},
        })
        forge.succeed("mkdir -p /srv/releases/" + version + " && printf %s " + shlex.quote(manifest) + " > /srv/releases/" + version + "/manifest.json")
        forge.succeed("printf '%s\\n' " + version + " > /srv/releases/latest")


    def head():
        return forge.succeed("git --git-dir=" + PRIVATE + " rev-parse main").strip()


    def switches(machine):
        return machine.succeed("cat /var/lib/fake-switch.log 2>/dev/null || true").splitlines()


    def notes(machine):
        return as_user(machine, "cat ~/notify.log 2>/dev/null || true")


    def wait_note(machine, text):
        machine.wait_until_succeeds("grep -qF " + shlex.quote(text) + " /home/" + USER + "/notify.log", timeout=180)


    def forge_log():
        return forge.succeed("cat /var/log/forge.log 2>/dev/null || true")


    def generation(machine):
        # A test VM boots without a system profile; nix-env makes one.
        return (machine.succeed("readlink -f /nix/var/nix/profiles/system").strip(), machine.succeed("readlink -f /run/current-system").strip())


    def deploy(machine, lock):
        machine.succeed(
            "mkdir -p /var/lib/ravnix-test/deployed /srv/ravnix-new"
            + " && cp ${fakePrivate}/flake.nix /var/lib/ravnix-test/deployed/"
            + " && cp ${fakeRavnix "new"}/flake.nix /srv/ravnix-new/"
        )
        if lock is None:
            machine.succeed("cd /var/lib/ravnix-test/deployed && nix flake lock")
        else:
            machine.succeed("cat > /var/lib/ravnix-test/deployed/flake.lock << 'EOF'\n" + lock + "EOF\n")
        return machine.succeed("cat /var/lib/ravnix-test/deployed/flake.lock")


    start_all()
    forge.wait_for_unit("forge.service")
    forge.wait_for_open_port(443)
    forge.succeed(
        "git config --global user.email forge@forge && git config --global user.name forge"
        + " && git config --global init.defaultBranch main"
        + " && mkdir -p /srv/git/upstream /srv/git/" + USER + " /srv/work /srv/releases"
        + " && git init -q --bare /srv/git/upstream/claude-code-nix.git"
        + " && git init -q --bare /srv/git/upstream/ravnix.git"
        + " && git init -q --bare " + PRIVATE
        + " && git -C " + PRIVATE + " config http.receivepack true"
        + " && git clone -q /srv/git/upstream/claude-code-nix.git /srv/work/cc"
        + " && cp ${fakeUpstream}/flake.nix /srv/work/cc/"
        + " && git clone -q /srv/git/upstream/ravnix.git /srv/work/ravnix"
        + " && cp ${fakeRavnix "old"}/flake.nix /srv/work/ravnix/"
        + " && cd /srv/work/ravnix && git add -A && git commit -qm old && git push -q origin HEAD:main"
    )
    upstream("2.0.0")
    release("2.0.0")

    unlock(muninn, "${muninnVault}")
    unlock(huginn, "${huginnVault}")

    # Deployed: muninn locks the private flake, and the forge and huginn
    # get that very lock.
    lock = deploy(muninn, None)
    deploy(huginn, lock)
    forge.succeed("git clone -q " + PRIVATE + " /srv/work/private && cp ${fakePrivate}/flake.nix /srv/work/private/")
    forge.succeed("cat > /srv/work/private/flake.lock << 'EOF'\n" + lock + "EOF\n")
    forge.succeed("cd /srv/work/private && git add -A && git commit -qm init && git push -q origin HEAD:main")
    base = head()

    # A checkout of the user's own on muninn, with work in it.
    as_user(muninn, "git clone -q ${remote} ~/private && cd ~/private && echo draft >> flake.nix && git status --porcelain > ~/status-before")
    # From here on, the forge's log is the update's alone.
    forge.succeed(": > /var/log/forge.log")

    with subtest("both timers run at 06:00 and 18:00, and catch up after a pause"):
        for m in (muninn, huginn):
            out = m.succeed("systemctl show ravnix-claude-update.timer -p TimersCalendar -p Persistent")
            assert "OnCalendar=*-*-* 06:00:00" in out and "OnCalendar=*-*-* 18:00:00" in out, out
            assert "Persistent=yes" in out, out
            m.succeed("systemctl is-active ravnix-claude-update.timer")

    with subtest("an equal version does nothing"):
        muninn.succeed("systemctl start ravnix-claude-update.service")
        assert "private.git" not in forge_log(), forge_log()
        assert switches(muninn) == []
        assert head() == base
        muninn.succeed("journalctl -u ravnix-claude-update.service | grep -q 'nothing to do'")

    with subtest("a forge that cannot be reached does nothing"):
        release("2.1.0")
        forge.block()
        muninn.fail("systemctl start ravnix-claude-update.service")
        forge.unblock()
        muninn.succeed("journalctl -u ravnix-claude-update.service | grep -q 'cannot read the latest version'")
        assert "private.git" not in forge_log(), forge_log()
        assert switches(muninn) == []

    with subtest("a build that fails switches, commits and pushes nothing"):
        upstream("2.1.0", fail=True)
        before = generation(muninn)
        muninn.fail("systemctl start ravnix-claude-update.service")
        wait_note(muninn, "did not build on muninn")
        assert generation(muninn) == before
        assert switches(muninn) == []
        assert head() == base
        assert "receive-pack" not in forge_log(), forge_log()
        # The fetch came with the write token, the only token muninn has.
        assert "write GET /" + USER + "/private.git/info/refs?service=git-upload-pack 200" in forge_log(), forge_log()

    with subtest("a newer version is bumped, built, verified, switched, committed and pushed"):
        upstream("2.2.0")
        release("2.2.0")
        rc_before = as_user(muninn, "systemctl --user show -p MainPID --value claude-remote-control.service").strip()
        muninn.succeed("systemctl start ravnix-claude-update.service")
        wait_note(muninn, "muninn runs Claude Code 2.2.0 now (was 2.0.0)")
        # Switched, to Claude Code 2.2.0 built with the ravnix muninn runs.
        lines = switches(muninn)
        assert len(lines) == 1, lines
        name, version, marker, verb, toplevel = lines[0].split()
        assert (name, version, marker, verb) == ("muninn", "2.2.0", "new", "switch"), lines
        assert generation(muninn)[0] == toplevel
        # Checked against the manifest.
        assert "release GET /claude-code-releases/2.2.0/manifest.json 200" in forge_log(), forge_log()
        # Pushed, with the write token, one commit on top of the branch.
        new = head()
        assert new != base
        assert "write POST /" + USER + "/private.git/git-receive-pack 200" in forge_log(), forge_log()
        git = "git --git-dir=" + PRIVATE + " "
        assert forge.succeed(git + "rev-parse " + new + "^").strip() == base
        assert forge.succeed(git + "log -1 --format=%s " + new).strip() == "chore: update Claude Code to 2.2.0"
        assert forge.succeed(git + "diff --name-only " + base + " " + new).split() == ["flake.lock"]
        old_lock = json.loads(forge.succeed(git + "show " + base + ":flake.lock"))
        new_lock = json.loads(forge.succeed(git + "show " + new + ":flake.lock"))
        assert old_lock["nodes"]["claude-code"]["locked"]["rev"] != new_lock["nodes"]["claude-code"]["locked"]["rev"]
        del old_lock["nodes"]["claude-code"], new_lock["nodes"]["claude-code"]
        assert old_lock == new_lock
        # The diff's lines are the claude-code node's revision fields alone.
        diff = forge.succeed(git + "diff -U0 " + base + " " + new + " -- flake.lock")
        changed = [l for l in diff.splitlines() if l[:1] in "+-" and not l.startswith(("+++", "---"))]
        assert changed, diff
        for l in changed:
            assert l[1:].strip().split(":")[0].strip('"') in ("lastModified", "narHash", "rev", "revCount"), diff
        # Signed, with the vault's key.
        assert "gpgsig" in forge.succeed(git + "cat-file commit " + new)
        as_user(muninn, "git --git-dir=" + STATE + "/flake.git verify-commit " + new)
        # The sessions roll, and Remote Control restarts onto the new version.
        muninn.wait_until_succeeds("journalctl --no-pager | grep -qF 'claude-roll: no Claude Code pane in herdr'", timeout=120)
        muninn.wait_until_succeeds("journalctl --no-pager | grep -qF 'restarted claude-remote-control.service onto the installed Claude Code'", timeout=120)
        rc_after = as_user(muninn, "systemctl --user show -p MainPID --value claude-remote-control.service").strip()
        assert rc_after not in ("0", rc_before), (rc_before, rc_after)
        # The user's own checkout is as it was.
        as_user(muninn, "cd ~/private && git status --porcelain | diff - ~/status-before")

    with subtest("huginn fetches the lock with the read token and switches, pushing nothing"):
        pushes = forge_log().count("receive-pack")
        huginn.succeed("systemctl start ravnix-claude-update.service")
        wait_note(huginn, "huginn runs Claude Code 2.2.0 now (was 2.0.0)")
        lines = switches(huginn)
        assert len(lines) == 1 and lines[0].split()[:4] == ["huginn", "2.2.0", "new", "switch"], lines
        log = forge_log()
        assert "read GET /" + USER + "/private.git/info/refs?service=git-upload-pack 200" in log, log
        assert log.count("receive-pack") == pushes, log
        assert head() == new
        # The lock has not moved since: nothing more.
        huginn.succeed("cp /var/lib/ravnix-claude-update/work/flake.lock /var/lib/ravnix-test/deployed/flake.lock")
        huginn.succeed("systemctl start ravnix-claude-update.service")
        assert len(switches(huginn)) == 1
        huginn.succeed("journalctl -u ravnix-claude-update.service | grep -q 'nothing to follow'")

    with subtest("a refused push leaves the switch and says so"):
        forge.succeed("printf '#!/bin/sh\\necho no pushes today >&2\\nexit 1\\n' > " + PRIVATE + "/hooks/pre-receive && chmod +x " + PRIVATE + "/hooks/pre-receive")
        upstream("2.3.0")
        release("2.3.0")
        muninn.succeed("systemctl start ravnix-claude-update.service")
        wait_note(muninn, "the push of the lock to ${remote} was refused")
        assert "no pushes today" in notes(muninn), notes(muninn)
        assert head() == new
        assert switches(muninn)[-1].split()[:4] == ["muninn", "2.3.0", "new", "switch"], switches(muninn)
        forge.succeed("rm " + PRIVATE + "/hooks/pre-receive")

    with subtest("a locked vault: nothing is fetched, built or switched"):
        as_user(muninn, "rbw lock")
        upstream("2.4.0")
        release("2.4.0")
        n = len(switches(muninn))
        muninn.fail("systemctl start ravnix-claude-update.service")
        wait_note(muninn, "could not fetch main of ${remote}")
        assert "the vault is locked" in notes(muninn), notes(muninn)
        assert len(switches(muninn)) == n
        assert head() == new

    with subtest("a second run while one runs does nothing"):
        muninn.succeed("systemd-run --unit=hold -- ${pkgs.util-linux}/bin/flock /var/lib/ravnix-claude-update/update.lock ${pkgs.coreutils}/bin/sleep 300")
        muninn.wait_until_succeeds("systemctl is-active hold")
        muninn.sleep(1)
        n = len(switches(muninn))
        muninn.fail("systemctl start ravnix-claude-update.service")
        muninn.succeed("journalctl -u ravnix-claude-update.service | grep -q 'another update is running'")
        muninn.succeed("systemctl stop hold")
        assert len(switches(muninn)) == n

    with subtest("huginn never takes a revision only a fork has; it follows upstream's own branch"):
        git = "git --git-dir=" + PRIVATE + " "
        cc = "git --git-dir=/srv/git/upstream/claude-code-nix.git "
        # A fork's commit, served under upstream's URL, with a version
        # Anthropic released: the download it names passes the check.
        forge.succeed(
            "cd /srv/work/cc && git checkout -q -b fork"
            + " && printf '9.9.9\\n' > version && printf 'fake claude 9.9.9\\n' > binary"
            + " && git add -A && git commit -qm fork && git push -q origin fork:refs/heads/fork"
            + " && git checkout -q main"
        )
        release("9.9.9")
        fork = forge.succeed(cc + "rev-parse refs/heads/fork").strip()
        upstream_head = forge.succeed(cc + "rev-parse refs/heads/main").strip()
        assert forge.execute(cc + "merge-base --is-ancestor " + fork + " main")[0] != 0
        meta = json.loads(muninn.succeed(
            "nix flake metadata --json --refresh "
            + shlex.quote("git+https://forge/upstream/claude-code-nix.git?ref=refs/heads/fork&rev=" + fork)
        ))
        # What an agent on muninn could push: the same URL, another revision.
        pushed = json.loads(forge.succeed(git + "show main:flake.lock"))
        node = pushed["nodes"]["claude-code"]["locked"]
        for k in ("lastModified", "narHash", "rev", "revCount"):
            node[k] = meta["locked"][k]
        forge.succeed(
            "cd /srv/work/private && git fetch -q origin && git reset -q --hard origin/main"
            + " && printf %s " + shlex.quote(json.dumps(pushed, indent=2) + "\n") + " > flake.lock"
            + " && git commit -qam 'chore: update Claude Code to 9.9.9' && git push -q origin HEAD:main"
        )
        n = len(switches(huginn))
        huginn.succeed("systemctl start ravnix-claude-update.service")
        wait_note(huginn, "names Claude Code 9.9.9")
        # Not taken: root asked upstream for its head, which has 2.4.0, and
        # the server's commit names 9.9.9.
        assert len(switches(huginn)) == n, switches(huginn)
        assert all(l.split()[1] != "9.9.9" for l in switches(huginn)), switches(huginn)
        took = json.loads(huginn.succeed("cat /var/lib/ravnix-claude-update/work/flake.lock"))["nodes"]["claude-code"]["locked"]["rev"]
        assert took == upstream_head, (took, upstream_head)
        assert fork[:12] in notes(huginn) and "has only 2.4.0" in notes(huginn), notes(huginn)
        assert huginn.succeed("systemctl show -p ExecMainStatus --value ravnix-claude-update.service").strip() == "0"
        # The same push again: handled, and nobody is told twice.
        before = notes(huginn)
        huginn.succeed("systemctl start ravnix-claude-update.service")
        huginn.succeed("journalctl -u ravnix-claude-update.service | grep -q 'is followed already'")
        assert len(switches(huginn)) == n
        assert notes(huginn) == before, notes(huginn)

    with subtest("huginn's follow waits quietly for a locked vault, and the hourly retry gets through after the unlock"):
        upstream("2.5.0")
        release("2.5.0")
        # The server has not pushed 2.5.0: huginn does not run ahead.
        n = len(switches(huginn))
        huginn.succeed("systemctl reset-failed ravnix-claude-update.service")
        huginn.succeed("systemctl start ravnix-claude-update.service")
        assert len(switches(huginn)) == n, switches(huginn)
        # The server bumps to 2.5.0 and pushes it.
        out = as_user(muninn, "script -qec " + shlex.quote("bash -ic ai-unlock") + " /dev/null")
        assert "unlocked" in out, out
        muninn.succeed("systemctl reset-failed ravnix-claude-update.service")
        muninn.succeed("systemctl start ravnix-claude-update.service")
        wait_note(muninn, "muninn runs Claude Code 2.5.0 now")
        assert forge.succeed(git + "log -1 --format=%s main").strip() == "chore: update Claude Code to 2.5.0"
        as_user(huginn, "rbw lock")
        before = notes(huginn)
        fetches = forge_log().count("read GET")
        huginn.succeed("systemctl reset-failed ravnix-claude-update.service")
        huginn.fail("systemctl start ravnix-claude-update.service")
        assert huginn.succeed("systemctl show -p ExecMainStatus --value ravnix-claude-update.service").strip() == "75"
        huginn.succeed("journalctl -u ravnix-claude-update.service | grep -q 'vault is locked, or no manager of theirs runs'")
        huginn.succeed("test -e /var/lib/ravnix-claude-update/pending")
        assert notes(huginn) == before, notes(huginn)
        assert forge_log().count("read GET") == fetches, forge_log()
        assert len(switches(huginn)) == n
        out = huginn.succeed("systemctl show ravnix-claude-update-retry.timer -p TimersCalendar")
        assert "OnCalendar=*-*-* *:00:00" in out, out
        huginn.succeed("systemctl is-active ravnix-claude-update-retry.timer")
        # Unlocked, the next retry follows, and the waiting ends.
        out = as_user(huginn, "script -qec " + shlex.quote("bash -ic ai-unlock") + " /dev/null")
        assert "unlocked" in out, out
        # The test started the update more often in ten seconds than
        # systemd's start limit lets through; the timer's hourly retry
        # never comes near it.
        huginn.succeed("systemctl reset-failed ravnix-claude-update.service")
        huginn.succeed("systemctl start ravnix-claude-update-retry.service")
        wait_note(huginn, "huginn runs Claude Code 2.5.0 now (was 2.0.0), from the head of the claude-code input's branch, which the private flake's lock names too")
        assert switches(huginn)[-1].split()[:4] == ["huginn", "2.5.0", "new", "switch"], switches(huginn)
        huginn.wait_until_fails("test -e /var/lib/ravnix-claude-update/pending")
        # With nothing waiting, the retry does not run the update.
        runs = huginn.succeed("journalctl -u ravnix-claude-update.service | grep -c 'Starting' || true").strip()
        huginn.succeed("systemctl start ravnix-claude-update-retry.service")
        assert huginn.succeed("systemctl show -p ConditionResult --value ravnix-claude-update-retry.service").strip() == "no"
        assert huginn.succeed("journalctl -u ravnix-claude-update.service | grep -c 'Starting' || true").strip() == runs
  '';
}
