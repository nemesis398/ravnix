# The link in two VMs, as it runs: muninn is the server shape, which brings
# the glue, huginn a host with the common module, the glue and the laptop's
# shape, whose daemon runs stand-ins for xdg-open, notify-send and obsidian
# that write down what they were asked. The main connection is stood in for
# by `ssh -N -R` from huginn to muninn, which forwards the daemon's socket as
# ravnix.link.socket says.
#
# While the forward is down, muninn's xdg-open, an Obsidian rename, a
# commit and notify-send queue on disk, the commit behind the rename; they
# survive a reboot of muninn, and the delivery service sleeps while they
# wait; when the forward comes up, the service delivers each once and in
# order, and the commit runs last, after the rename. The stand-in obsidian
# does what Obsidian and the sync between the hosts would: it renames the
# note in muninn's vault (over ssh). The vault signs its commits with an
# ssh key in an agent, whose socket the service gets from the user
# manager's environment: while the agent is away the commit fails, is not
# made unsigned, and is tried again; once the agent is there it is made
# and signed. A program the daemon started outlives a restart of the
# daemon. A dropped connection that left its socket behind does not keep
# the next forward from working. And xdg-open on muninn is the link's, on
# huginn xdg-utils'.
#
# The vault on both hosts (modules/glue/vault.nix): the skill values say
# ravnix-link on both, the repository here on muninn and not on huginn. The
# commit queued behind the rename above is asked for with vault-commit on
# muninn, so muninn's own commits wait for the Obsidian operations before
# them. A note written on huginn, where the vault has no .git, and
# committed there with vault-commit, goes to muninn over ssh and waits
# until muninn's copy has it as huginn wrote it; the test copies it over,
# as the sync would, and the delivery service commits it, signed. A note
# muninn has already is answered as committed; vault-commit on muninn
# commits at once when nothing waits; and commits asked for on both hosts
# at once all land, none failing on git's index.lock.
{
  self,
  pkgs,
  lib,
  ...
}:
let
  me = import ../../templates/default/me.nix;
  user = me.ravnix.user.username;
  home = "/home/${user}";
  note = "Notizen/Über Grüße – Entwurf.md";
  # A session note written on huginn.
  session = "AI/sessions/2026-11-13 Über – Grüße.md";
  renamed = "Notizen/Neu – Grüße.md";

  # huginn's user logs in to muninn with nixpkgs' test key: the server
  # shape takes the account's keys from the configuration alone, never from
  # ~/.ssh/authorized_keys, so the public half is needed while the test is
  # evaluated. The signing key is made for this test alone.
  snakeoil = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
  keys = pkgs.runCommand "link-test-keys" { nativeBuildInputs = [ pkgs.openssh ]; } ''
    mkdir "$out"
    ssh-keygen -q -t ed25519 -N "" -C link-sign -f "$out/sign"
  '';

  # What the daemon runs on huginn: each run is a line of ~/link.log, the
  # program's name and its arguments separated by " | ".
  stub =
    name: extra:
    pkgs.writeShellScript name ''
      {
        printf '%s' ${name}
        printf ' | %s' "$@"
        printf '\n'
      } >>"$HOME/link.log"
      ${extra}
    '';
  # Obsidian renames the note, and the sync brings the rename to muninn's
  # copy of the vault; here both are one mv on muninn.
  obsidian = stub "obsidian" ''
    if [ "$1" = rename ]; then
      p=''${2#path=}
      n=''${3#name=}
      ssh muninn "mv -- $(printf %q "vault/$p") $(printf %q "vault/''${p%/*}/$n.md")"
    fi
  '';

  common = {
    imports = [ ../../templates/default/me.nix ];
    warnings = lib.mkForce [ ];
    ravnix.editor.languages = lib.mkForce [ "nix" ];
    users.users.${user}.linger = true;
    virtualisation = {
      cores = 2;
      memorySize = 2048;
    };
    system.stateVersion = "26.05";
  };
in
pkgs.testers.runNixOSTest {
  name = "glue-link";
  # The nodes read pkgs.ravnix; runNixOSTest sets node.pkgs itself.
  node.pkgs = lib.mkForce (pkgs.extend self.overlays.default);

  nodes.muninn =
    { ... }:
    {
      imports = [
        common
        self.nixosModules.server
      ];
      ravnix.shape = "server";
      # The test framework gives root an empty password, for a console login
      # when the test runs interactively; the server shape refuses a root
      # password, and the driver needs none.
      users.users.root.hashedPasswordFile = lib.mkForce null;
      ravnix.link.vault = lib.mkForce "${home}/vault";
      users.users.${user}.openssh.authorizedKeys.keys = [ snakeoil.snakeOilEd25519PublicKey ];
      # The agent that signs the vault's commits, as the agent's module
      # gives its socket to the user manager (Task 4.3). Forced over rbw's
      # socket, which modules/common/rbw.nix sets there. rbw's agent runs in
      # this VM too (the server shape brings the rbw-agent user unit, wanted
      # by default.target, and the user lingers), but it is locked and holds
      # no vault and no key. The test's own agent takes SSH_AUTH_SOCK
      # because rbw's holds nothing here, and it is the one that signs the
      # vault's commits.
      home-manager.users.${user}.systemd.user.sessionVariables.SSH_AUTH_SOCK =
        lib.mkForce "\${XDG_RUNTIME_DIR}/test-agent.sock";
      ravnix.server.remoteControlDir = lib.mkForce null;
      ravnix.nextcloud = lib.mkForce null;
      virtualisation.diskSize = 4096;
    };

  nodes.huginn =
    { pkgs, lib, ... }:
    {
      imports = [
        common
        self.nixosModules.common
        self.nixosModules.glue
      ];
      ravnix.shape = "laptop";
      # The template's key for muninn's laptop access would ask for NetBird,
      # which this test has no use for; laptop access has its own test.
      ravnix.laptopAccess.publicKey = lib.mkForce null;
      ravnix.link.programs = {
        # A target with "bleibt" starts a process that stays, as a browser
        # that xdg-open started would.
        xdgOpen = toString (
          stub "xdg-open" ''
            case "$1" in *bleibt*)
              sleep 1000 </dev/null >/dev/null 2>&1 &
              echo $! >"$HOME/bleibt.pid" ;;
            esac
          ''
        );
        notifySend = toString (stub "notify-send" "");
        obsidian = toString obsidian;
      };
      # huginn's copy of the vault, at the same path as muninn's; the
      # laptop sends its commits to muninn, the name of the ssh block below.
      ravnix.link.vault = lib.mkForce "${home}/vault";
      ravnix.link.programs.server = "muninn";
      # A desktop brings xdg-utils; on the laptop it stays the xdg-open.
      environment.systemPackages = [ pkgs.xdg-utils ];
      # How huginn's user reaches muninn here, in ~/.ssh/config, which
      # home-manager writes (and the glue's terminal module too).
      home-manager.users.${user}.programs.ssh = {
        enable = true;
        enableDefaultConfig = false;
        matchBlocks.muninn = {
          identityFile = "~/.ssh/id_ed25519";
          extraOptions = {
            StrictHostKeyChecking = "no";
            UserKnownHostsFile = "/dev/null";
            LogLevel = "ERROR";
          };
        };
      };
    };

  testScript = ''
    import shlex

    USER = "${user}"
    HOME = "${home}"
    NOTE = "${note}"
    RENAMED = "${renamed}"
    SESSION = "${session}"
    JQ = "${pkgs.jq}/bin/jq"


    def as_user(machine, cmd, check=True):
        uid = machine.succeed("id -u " + USER).strip()
        script = (
            "su - " + USER + " -c "
            + shlex.quote("export XDG_RUNTIME_DIR=/run/user/" + uid + "; " + cmd)
        )
        return machine.succeed(script) if check else machine.execute(script)


    def runs():
        return as_user(huginn, "cat ~/link.log 2>/dev/null || true").splitlines()


    def forward():
        mu = muninn.succeed("id -u " + USER).strip()
        hu = huginn.succeed("id -u " + USER).strip()
        as_user(
            huginn,
            "ssh -f -N -o ExitOnForwardFailure=yes"
            + " -R /run/user/" + mu + "/ravnix-link.sock:/run/user/" + hu + "/ravnix-link.sock muninn"
            # In the background, it must not hold the test's output open.
            + " </dev/null >/dev/null 2>&1",
        )


    def drop_forward():
        huginn.succeed("pkill -u " + USER + " -x ssh || true")
        huginn.wait_until_fails("pgrep -u " + USER + " -x ssh")


    start_all()
    for m in (muninn, huginn):
        m.wait_for_unit("multi-user.target")
        m.wait_for_unit("user@" + m.succeed("id -u " + USER).strip() + ".service")
    muninn.wait_for_unit("sshd.service")

    with subtest("huginn's user reaches muninn over ssh"):
        # The public half is muninn's in its configuration
        # (users.users.<user>.openssh.authorizedKeys.keys); only the private
        # half goes in at run time, into huginn's ~/.ssh.
        as_user(huginn, "install -D -m 600 ${snakeoil.snakeOilEd25519PrivateKey} ~/.ssh/id_ed25519")
        as_user(huginn, "ssh muninn true")

    with subtest("xdg-open is the link's on muninn and xdg-utils' on huginn"):
        target = as_user(muninn, 'readlink -f "$(command -v xdg-open)"').strip()
        as_user(muninn, "grep -q 'ravnix-link' " + shlex.quote(target))
        as_user(muninn, "grep -q 'ravnix-link' \"$(readlink -f /run/current-system/sw/bin/xdg-open)\"")
        as_user(muninn, "grep -q 'notify-send' \"$(readlink -f \"$(command -v notify-send)\")\"")
        laptop = as_user(huginn, 'readlink -f "$(command -v xdg-open)"').strip()
        assert "xdg-utils" in laptop, laptop

    with subtest("muninn's vault is a git repository with a note, whose commits are signed"):
        as_user(
            muninn,
            "mkdir -p ~/vault/Notizen && cd ~/vault && git init -q"
            + " && printf 'alt\\n' >" + shlex.quote(NOTE)
            + " && git add -A && git -c commit.gpgsign=false commit -qm init"
            + " && install -m 600 ${keys}/sign ~/.ssh/sign"
            + " && git config commit.gpgsign true && git config gpg.format ssh"
            + " && git config user.signingkey \"key::$(cat ${keys}/sign.pub)\""
            + " && printf '%s %s\\n' \"$(git config user.email)\" \"$(cat ${keys}/sign.pub)\" >~/.ssh/allowed_signers"
            + " && git config gpg.ssh.allowedSignersFile ~/.ssh/allowed_signers",
        )
        muninn.wait_for_unit("ravnix-link-deliver.service", user=USER)

    with subtest("with the laptop away, the requests queue on disk"):
        out = as_user(muninn, "xdg-open https://example.org/eins 2>&1")
        assert "queued" in out, out
        out = as_user(muninn, "ravnix-link obsidian rename path=" + shlex.quote(NOTE) + " name='Neu – Grüße' 2>&1")
        assert "queued" in out, out
        # An edit to the old path, while the rename waits.
        as_user(muninn, "printf 'bearbeitet\\n' >>" + shlex.quote("vault/" + NOTE))
        # The vault skills' entry point, which goes through the queue.
        out = as_user(
            muninn,
            "vault-commit 'vault: rename and edit' " + shlex.quote(NOTE) + " " + shlex.quote(RENAMED) + " 2>&1",
        )
        assert "queued" in out, out
        as_user(muninn, "notify-send -a herdr -u critical Frage 'Darf ich?'")
        status = as_user(muninn, "ravnix-link status")
        assert "4 requests wait" in status, status
        assert as_user(muninn, "git -C ~/vault log --format=%s").split() == ["init"]

    with subtest("the queue survives a reboot of muninn"):
        muninn.shutdown()
        muninn.start()
        muninn.wait_for_unit("multi-user.target")
        muninn.wait_for_unit("ravnix-link-deliver.service", user=USER)
        status = as_user(muninn, "ravnix-link status")
        assert "4 requests wait" in status, status

    with subtest("while the laptop is away, the delivery service sleeps"):
        pid = as_user(muninn, "systemctl --user show -p MainPID --value ravnix-link-deliver.service").strip()
        assert pid not in ("", "0"), pid

        # utime and stime, in ticks of 10 ms: a service that spins takes
        # about 500 in 5 s.
        def ticks():
            return int(muninn.succeed("awk '{print $14 + $15}' /proc/" + pid + "/stat").strip())

        before = ticks()
        muninn.sleep(5)
        used = ticks() - before
        assert used < 100, f"the delivery service took {used} ticks of processor time in 5 s"

    with subtest("the daemon listens on a socket of the user's alone"):
        huginn.systemctl("start ravnix-link-daemon.service", user=USER)
        huginn.wait_for_unit("ravnix-link-daemon.service", user=USER)
        huginn.wait_until_succeeds("test -S /run/user/$(id -u " + USER + ")/ravnix-link.sock")
        mode = huginn.succeed("stat -c %a /run/user/$(id -u " + USER + ")/ravnix-link.sock").strip()
        assert mode == "600", mode

    with subtest("on reconnect they are delivered once and in order, and the commit waits for the agent"):
        muninn.wait_for_unit("sshd.service")
        forward()
        mode = muninn.succeed("stat -c %a /run/user/$(id -u " + USER + ")/ravnix-link.sock").strip()
        assert mode == "600", mode
        # The rename is done and the vault shows it; the commit ran, and
        # failed without the agent.
        muninn.wait_until_succeeds(
            "su - " + USER + " -c 'ravnix-link status' | grep -q 'attempt 1 failed'", timeout=60
        )
        got = runs()
        assert got == [
            "xdg-open | https://example.org/eins",
            "obsidian | rename | path=" + NOTE + " | name=Neu – Grüße",
            "notify-send | -u | critical | -a | herdr | -- | Frage | Darf ich?",
        ], got
        status = as_user(muninn, "ravnix-link status")
        print(status)
        assert "1 request waits" in status, status
        assert as_user(muninn, "git -C ~/vault log --format=%s").split() == ["init"]

    with subtest("the delivery service signs the commit once the agent is there"):
        mu = muninn.succeed("id -u " + USER).strip()
        env = as_user(muninn, "systemctl --user show-environment")
        assert "SSH_AUTH_SOCK=/run/user/" + mu + "/test-agent.sock" in env.splitlines(), env
        as_user(
            muninn,
            "${pkgs.openssh}/bin/ssh-agent -a \"$XDG_RUNTIME_DIR/test-agent.sock\" </dev/null >/dev/null 2>&1"
            + " && SSH_AUTH_SOCK=\"$XDG_RUNTIME_DIR/test-agent.sock\" ${pkgs.openssh}/bin/ssh-add -q ~/.ssh/sign",
        )
        # The service tries again when the backoff is over, with nothing
        # but the agent changed.
        muninn.wait_until_succeeds(
            "su - " + USER + " -c 'ravnix-link status' | grep -q 'nothing waits'", timeout=180
        )
        log = as_user(muninn, "git -C ~/vault log --format=%s").split("\n")
        assert log[0] == "vault: rename and edit", log
        as_user(muninn, "git -C ~/vault verify-commit HEAD")
        files = as_user(muninn, "git -C ~/vault -c core.quotePath=false ls-files").splitlines()
        assert files == [RENAMED], files
        content = as_user(muninn, "git -C ~/vault show HEAD:" + shlex.quote(RENAMED))
        assert content == "alt\nbearbeitet\n", content

    with subtest("nothing is delivered twice"):
        muninn.systemctl("restart ravnix-link-deliver.service", user=USER)
        as_user(muninn, "ravnix-link flush")
        huginn.systemctl("restart ravnix-link-daemon.service", user=USER)
        huginn.wait_for_unit("ravnix-link-daemon.service", user=USER)
        as_user(muninn, "ravnix-link flush")
        assert len(runs()) == 3, runs()

    with subtest("a request with the laptop there is carried out at once"):
        as_user(muninn, "xdg-open " + HOME + "/Nextcloud/x.pdf")
        assert runs()[-1] == "xdg-open | " + HOME + "/Nextcloud/x.pdf", runs()

    with subtest("a program the daemon started outlives a restart of the daemon"):
        as_user(muninn, "xdg-open https://example.org/bleibt")
        huginn.wait_until_succeeds("test -s " + HOME + "/bleibt.pid")
        pid = huginn.succeed("cat " + HOME + "/bleibt.pid").strip()
        huginn.succeed("grep -q '^State:.*sleeping' /proc/" + pid + "/status")
        cgroup = huginn.succeed("cat /proc/" + pid + "/cgroup")
        assert ".scope" in cgroup and "ravnix-link-daemon" not in cgroup, cgroup
        huginn.systemctl("restart ravnix-link-daemon.service", user=USER)
        huginn.wait_for_unit("ravnix-link-daemon.service", user=USER)
        huginn.succeed("grep -q '^State:.*sleeping' /proc/" + pid + "/status")

    with subtest("a dropped connection's socket does not block the next forward"):
        drop_forward()
        mu = muninn.succeed("id -u " + USER).strip()
        sock = "/run/user/" + mu + "/ravnix-link.sock"
        # A socket nobody listens on, as a connection that died leaves it.
        as_user(
            muninn,
            "rm -f " + sock + " && ${pkgs.python3}/bin/python3 -c "
            + shlex.quote("import socket; socket.socket(socket.AF_UNIX).bind('" + sock + "')"),
        )
        as_user(muninn, "test -S " + sock)
        out = as_user(muninn, "xdg-open https://example.org/zwei 2>&1")
        assert "queued" in out, out
        forward()
        muninn.wait_until_succeeds(
            "su - " + USER + " -c 'ravnix-link status' | grep -q 'nothing waits'", timeout=60
        )
        assert runs()[-1] == "xdg-open | https://example.org/zwei", runs()

    with subtest("each host's skill values say how it commits to the vault"):
        values = "~/.config/ravnix/skill-values.json"
        got = as_user(muninn, JQ + " -r '.vault.commitVia, .vault.repositoryHere' " + values).split()
        assert got == ["ravnix-link", "true"], got
        got = as_user(huginn, JQ + " -r '.vault.commitVia, .vault.repositoryHere' " + values).split()
        assert got == ["ravnix-link", "false"], got

    with subtest("a note made on huginn is committed on muninn once the sync brings it"):
        before = as_user(muninn, "git -C ~/vault log --format=%s").split("\n")
        as_user(huginn, "test ! -e ~/vault/.git")
        as_user(
            huginn,
            "mkdir -p ~/vault/AI/sessions && printf 'vom Laptop\\n' >" + shlex.quote("vault/" + SESSION),
        )
        out = as_user(huginn, "vault-commit 'vault: Sitzung – „vom Laptop“' " + shlex.quote(SESSION) + " 2>&1")
        print(out)
        assert "queued" in out and "sync" in out, out
        status = as_user(muninn, "ravnix-link status")
        print(status)
        assert "waits until the vault here has 1 file as the laptop wrote it" in status, status
        assert as_user(muninn, "git -C ~/vault log --format=%s").split("\n") == before
        # The sync, as nextcloudcmd would bring the file to muninn's copy.
        as_user(
            huginn,
            "ssh muninn " + shlex.quote("mkdir -p vault/AI/sessions && cat >" + shlex.quote("vault/" + SESSION))
            + " <" + shlex.quote("vault/" + SESSION),
        )
        muninn.wait_until_succeeds(
            "su - " + USER + " -c 'ravnix-link status' | grep -q 'nothing waits'", timeout=120
        )
        log = as_user(muninn, "git -C ~/vault log --format=%s").split("\n")
        assert log[0] == "vault: Sitzung – „vom Laptop“", log
        files = as_user(muninn, "git -C ~/vault -c core.quotePath=false show --format= --name-only HEAD").strip()
        assert files == SESSION, files
        as_user(muninn, "git -C ~/vault verify-commit HEAD")
        content = as_user(muninn, "git -C ~/vault show HEAD:" + shlex.quote(SESSION))
        assert content == "vom Laptop\n", content

    with subtest("a commit from huginn of what muninn has already is answered as made"):
        as_user(huginn, "printf 'zweite Fassung\\n' >>" + shlex.quote("vault/" + SESSION))
        as_user(
            huginn,
            "ssh muninn " + shlex.quote("cat >" + shlex.quote("vault/" + SESSION))
            + " <" + shlex.quote("vault/" + SESSION),
        )
        out = as_user(huginn, "vault-commit 'vault: zweite Fassung' " + shlex.quote("${home}/vault/" + SESSION) + " 2>&1")
        assert "queued" not in out, out
        log = as_user(muninn, "git -C ~/vault log --format=%s").split("\n")
        assert log[0] == "vault: zweite Fassung", log

    with subtest("vault-commit on muninn commits at once when nothing waits"):
        as_user(muninn, "printf 'auf muninn\\n' >vault/muninn.md")
        out = as_user(
            muninn,
            "SSH_AUTH_SOCK=\"$XDG_RUNTIME_DIR/test-agent.sock\" vault-commit 'vault: auf muninn' muninn.md 2>&1",
        )
        assert "queued" not in out, out
        log = as_user(muninn, "git -C ~/vault log --format=%s").split("\n")
        assert log[0] == "vault: auf muninn", log
        as_user(muninn, "git -C ~/vault verify-commit HEAD")

    with subtest("commits asked for on both hosts at once all land"):
        for i in range(3):
            as_user(huginn, "printf 'h%d\\n' >vault/h%d.md" % (i, i))
            as_user(muninn, "printf 'm%d\\n' >vault/m%d.md" % (i, i))
        # The sync has brought huginn's files already.
        as_user(huginn, "tar -C vault -cf - h0.md h1.md h2.md | ssh muninn 'tar -C vault -xf -'")
        # Three on each host, all at once: each run's output and status go
        # to files; huginn's runs in the background while muninn's run.
        batch = (
            "export SSH_AUTH_SOCK=$XDG_RUNTIME_DIR/test-agent.sock; rm -f ~/rc-* ~/out-*;"
            + " for i in 0 1 2; do (vault-commit \"vault: %s$i\" %s$i.md >~/out-$i 2>&1; echo $? >~/rc-$i) & done; wait"
        )
        uid = huginn.succeed("id -u " + USER).strip()
        huginn.succeed(
            "su - " + USER + " -c "
            + shlex.quote("export XDG_RUNTIME_DIR=/run/user/" + uid + "; " + batch % ("h", "h"))
            + " >/dev/null 2>&1 &"
        )
        as_user(muninn, batch % ("m", "m"))
        huginn.wait_until_succeeds("test -s " + HOME + "/rc-0 && test -s " + HOME + "/rc-1 && test -s " + HOME + "/rc-2", timeout=120)
        for machine in (huginn, muninn):
            for i in range(3):
                code = machine.succeed("cat " + HOME + "/rc-%d" % i).strip()
                out = machine.succeed("cat " + HOME + "/out-%d" % i)
                print(machine.name, i, code, out)
                assert code == "0", (machine.name, i, out)
                assert "index.lock" not in out, (machine.name, i, out)
        muninn.wait_until_succeeds(
            "su - " + USER + " -c 'ravnix-link status' | grep -q 'nothing waits'", timeout=120
        )
        log = as_user(muninn, "git -C ~/vault log --format=%s -6").strip().split("\n")
        assert sorted(log) == sorted(["vault: h0", "vault: h1", "vault: h2", "vault: m0", "vault: m1", "vault: m2"]), log
        assert as_user(muninn, "git -C ~/vault status --porcelain").strip() == "", "uncommitted files remain"
  '';
}
