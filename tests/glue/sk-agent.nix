# The security key's agent in three VMs: huginn (the common module and the
# glue, shape "laptop") runs the agent of ravnix.skAgent.keys, muninn (the
# server shape, with the glue) reaches the git hosts through it, and forge is
# a stand-in for GitHub and Forgejo at once: muninn resolves both
# "github.com" and the template's Forgejo host to it, and its user git
# accepts ssh keys and git pushes, on port 22 and, as a Forgejo's own ssh
# server does, on 2222. The main connection is stood in for by `ssh -N -R`
# from huginn to muninn, which forwards the agent's socket as
# ravnix.skAgent.socket says, the way Task 5.2's connection will.
#
# Two plain keys stand in for the security key's handles (nixpkgs' test keys,
# whose public halves are known while the test is evaluated): an ed25519
# key, which the forge accepts, and an ECDSA one, which it does not know
# and which huginn's user also logs in to muninn with.
# Every other key is made for this test alone, and the forge accepts each of
# them too, so that a key used where it must not be shows as a login: a key
# that is not on the list, the key in two stand-ins for an agent that holds
# the vault's keys (rbw's agent, at the socket SSH_AUTH_SOCK names, and the
# Bitwarden desktop app's agent, on its own socket), and muninn's own
# ~/.ssh/id_ed25519. The two stand-ins run in debug mode, so that every
# request they get is a line of their log. On muninn, rbw's own agent does
# not start, so that its stand-in is the only agent at rbw's socket.
#
# What it checks:
#   - huginn's agent holds the listed handles and nothing else, on a socket
#     of its own (mode 600) apart from SSH_AUTH_SOCK; a handle that is
#     missing, or whose public half is not the listed one, is not loaded and
#     the loading unit fails naming it, while the agent keeps the others; a
#     killed agent comes back with its keys, over the socket it left behind,
#     and so does one that finds a stale socket there; loading the keys
#     again drops a key that was added by hand, and a locked agent makes the
#     loading unit fail and say so;
#   - on muninn, with the forward up, ssh and git to github.com and to the
#     Forgejo host log in with the listed key through the forwarded socket,
#     also with `-o IdentityAgent=` given as the brief writes it, and with
#     a host name in other capitals; neither stand-in (rbw's agent, the
#     Bitwarden desktop app's) gets a single request, and no other key logs
#     in; the forwarded socket is the user's alone (mode 600), and another
#     user on muninn cannot use it;
#   - with the forward gone (a socket left behind with no listener, no
#     socket, a laptop frozen behind a live forward, an agent that is busy
#     or not running behind a live forward), the same commands fail within
#     5 s, before any connection to the forge, with a message that names the
#     laptop and the reason, and again no other agent or key is tried;
#   - an agent that holds a key that is not on the list: muninn refuses
#     while that key is all it holds, and never offers it when the listed
#     one is there too; an agent that holds no key is refused by name;
#   - a second login session on muninn, without a forward of its own, uses
#     the first one's, and the first still works once the second is gone;
#   - the forward comes back after a drop, over the socket the drop left;
#   - ssh to a host that is not a git host of the list is left as it was.
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
  forgejo = lib.last me.ravnix.skAgent.hosts;
  snakeoil = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
  bare = key: lib.concatStringsSep " " (lib.take 2 (lib.splitString " " key));

  # The stand-ins for the security key's handles, where huginn has them,
  # and their public halves as a file.
  standIn = rec {
    handle = "${home}/.ssh/keys/stand-in-sk";
    private = snakeoil.snakeOilEd25519PrivateKey;
    publicKey = snakeoil.snakeOilEd25519PublicKey;
    pub = pkgs.writeText "stand-in.pub" "${publicKey}\n";
  };
  second = rec {
    handle = "${home}/.ssh/keys/second-sk";
    private = snakeoil.snakeOilPrivateKey;
    publicKey = snakeoil.snakeOilPublicKey;
    pub = pkgs.writeText "second.pub" "${publicKey}\n";
  };

  # huginn's user logs in to muninn with the second stand-in's key: the
  # server shape takes the account's keys from the configuration alone,
  # never from ~/.ssh/authorized_keys, so the public half is needed while
  # the test is evaluated. A key generated in a derivation (like `keys`
  # below) would have to be read back with import-from-derivation, and this
  # public repository holds no private key of its own, so the login key is
  # nixpkgs' ECDSA test key. The forge does not know this one, so no login
  # there is ever made with it.
  login = second;

  # The keys made for this test: a key that is not on the list, the key in
  # the two stand-in agents (rbw's and the Bitwarden desktop app's), and
  # muninn's own default key. The key named "bitwarden" is the vault's.
  keys = pkgs.runCommand "sk-agent-test-keys" { nativeBuildInputs = [ pkgs.openssh ]; } ''
    mkdir "$out"
    for name in extra bitwarden default; do
      ssh-keygen -q -t ed25519 -N "" -C "$name" -f "$out/$name"
    done
  '';

  common = {
    imports = [ ../../templates/default/me.nix ];
    warnings = lib.mkForce [ ];
    ravnix.editor.languages = lib.mkForce [ "nix" ];
    ravnix.skAgent.keys = lib.mkForce [
      { inherit (standIn) handle publicKey; }
      { inherit (second) handle publicKey; }
    ];
    users.users.${user}.linger = true;
    system.stateVersion = "26.05";
  };
in
pkgs.testers.runNixOSTest {
  name = "glue-sk-agent";
  # The nodes read pkgs.ravnix; runNixOSTest sets node.pkgs itself.
  node.pkgs = lib.mkForce (pkgs.extend self.overlays.default);

  nodes.forge =
    { pkgs, ... }:
    {
      services.openssh = {
        enable = true;
        ports = [
          22
          2222
        ];
        settings = {
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
          # Every connection, every key offered and every login, with its
          # fingerprint.
          LogLevel = "VERBOSE";
        };
      };
      users.users.git = {
        isNormalUser = true;
        shell = pkgs.bashInteractive;
      };
      environment.systemPackages = [ pkgs.git ];
      virtualisation.memorySize = 768;
      system.stateVersion = "26.05";
    };

  nodes.muninn =
    { nodes, ... }:
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
      users.users.${user}.openssh.authorizedKeys.keys = [ login.publicKey ];
      # Keep rbw's agent from starting with the user's manager (Task 4.3, the
      # server shape brings it). The decoy at rbw's socket stands in for rbw's
      # agent, which in the VM is locked, has no vault and refuses an added
      # key, and the decoy cannot bind a socket the real agent already holds.
      home-manager.users.${user}.systemd.user.services.rbw-agent.Install.WantedBy = lib.mkForce [ ];
      # Another account on muninn, which must not reach the forwarded agent.
      users.users.other.isNormalUser = true;
      ravnix.server.remoteControlDir = lib.mkForce null;
      ravnix.nextcloud = lib.mkForce null;
      networking.hosts.${nodes.forge.networking.primaryIPAddress} = [
        "forge"
        "github.com"
        forgejo
      ];
      # The forge's host keys are made at its first boot; the test takes
      # them on first use. The system's file is read after the user's, so
      # this adds to the module's configuration and overrides none of it.
      programs.ssh.extraConfig = ''
        StrictHostKeyChecking accept-new
      '';
      virtualisation = {
        cores = 2;
        memorySize = 2048;
        diskSize = 4096;
      };
    };

  nodes.huginn =
    { lib, ... }:
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
      virtualisation = {
        cores = 2;
        memorySize = 1536;
      };
    };

  testScript = ''
    import datetime
    import shlex
    import time

    USER = "${user}"
    HOME = "${home}"
    FORGEJO = "${forgejo}"
    KEYS = "${keys}"
    STAND_IN = "${standIn.handle}"
    SECOND = "${second.handle}"
    LISTED = sorted(["${bare standIn.publicKey}", "${bare second.publicKey}"])
    # How huginn reaches muninn: the login key alone, and no ssh configuration.
    SSH = (
        "ssh -F /dev/null -i ~/.ssh/login -o IdentitiesOnly=yes -o IdentityAgent=none"
        + " -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
    )
    # rbw's agent socket, which SSH_AUTH_SOCK names in a session on muninn.
    RBW = "$XDG_RUNTIME_DIR/rbw/ssh-agent-socket"


    def uid(machine):
        return machine.succeed("id -u " + USER).strip()


    def sock(machine):
        return "/run/user/" + uid(machine) + "/sk-agent.sock"


    def as_user(machine, cmd, check=True):
        script = (
            "su - " + USER + " -c "
            + shlex.quote("export XDG_RUNTIME_DIR=/run/user/" + uid(machine) + "; " + cmd)
        )
        return machine.succeed(script) if check else machine.execute(script)


    def held():
        """The keys huginn's agent holds, as `type base64`, sorted."""
        status, out = as_user(huginn, "SSH_AUTH_SOCK=" + sock(huginn) + " ssh-add -L 2>&1", check=False)
        if status == 1:
            return []
        assert status == 0, out
        return sorted(" ".join(line.split()[:2]) for line in out.splitlines())


    def keys_unit(prop):
        return as_user(huginn, "systemctl --user show -p " + prop + " --value sk-agent-keys.service").strip()


    def after_loading(action):
        """Runs action, waits for the next run of sk-agent-keys to end, and
        returns how it ended: active or failed."""
        before = keys_unit("InvocationID")
        action()

        def ended(_):
            return keys_unit("InvocationID") not in ("", before) and keys_unit("ActiveState") in ("active", "failed")

        retry(ended, timeout=datetime.timedelta(seconds=60))
        return keys_unit("ActiveState")


    def loader_log():
        return huginn.succeed("journalctl -o cat --no-pager _SYSTEMD_USER_UNIT=sk-agent-keys.service")


    def loader_logged(*needles):
        """The loader's journal has each needle; journald may lag behind
        the unit's state by a moment."""
        retry(lambda _: all(n in loader_log() for n in needles), timeout=datetime.timedelta(seconds=10))


    def fingerprint(path):
        return huginn.succeed("ssh-keygen -lf " + path).split()[1]


    def forward():
        as_user(
            huginn,
            SSH + " -f -N -o ExitOnForwardFailure=yes"
            + " -R " + sock(muninn) + ":" + sock(huginn) + " muninn"
            # In the background, it must not hold the test's output open.
            + " </dev/null >/dev/null 2>&1",
        )
        muninn.succeed("test -S " + sock(muninn))


    def drop_forward():
        huginn.succeed("pkill -u " + USER + " -x ssh || true")
        huginn.wait_until_fails("pgrep -u " + USER + " -x ssh")


    def forge_log():
        return forge.succeed("journalctl -u sshd.service -o cat --no-pager")


    def decoy_requests():
        """The requests both stand-in agents, rbw's and the Bitwarden desktop
        app's, have had."""
        muninn.sleep(1)
        out = muninn.succeed(
            "journalctl -o cat --no-pager _SYSTEMD_USER_UNIT=decoy-rbw.service"
            + " + _SYSTEMD_USER_UNIT=decoy-bitwarden.service"
        )
        return out.count("process_message:")


    def on_muninn(cmd):
        """cmd as the user on muninn, with SSH_AUTH_SOCK at rbw's agent."""
        start = time.monotonic()
        status, out = as_user(muninn, "SSH_AUTH_SOCK=" + RBW + " " + cmd + " 2>&1", check=False)
        return status, out, time.monotonic() - start


    def logged_in(before):
        """What the forge logged since before, once it has a login with the
        listed key in it; and no other key, no stand-in agent."""
        new = [""]

        def accepted(_):
            new[0] = forge_log()[len(before):]
            return "Accepted publickey for git" in new[0] and STAND_IN_FP in new[0]

        retry(accepted, timeout=datetime.timedelta(seconds=10))
        for fp in OTHER_FPS:
            assert fp not in new[0], (fp, new[0])
        return new[0]


    def logs_in(cmd):
        """cmd logs in to the forge with the listed key, and with no other."""
        before = forge_log()
        decoys = decoy_requests()
        status, out, _ = on_muninn(cmd)
        assert status == 0, out
        logged_in(before)
        assert decoy_requests() == decoys, "a stand-in agent (rbw's or the Bitwarden desktop app's) was asked"


    def refused(cmd, *needles):
        """cmd fails within 5 s, before any connection, naming the laptop."""
        before = forge_log()
        decoys = decoy_requests()
        status, out, took = on_muninn(cmd)
        print(f"refused in {took:.2f} s, exit {status}: {out.strip()}")
        assert status != 0, out
        assert took < 5, f"{cmd} took {took:.1f} s to fail"
        assert "huginn" in out and "laptop" in out, out
        for needle in needles:
            assert needle in out, (needle, out)
        assert "Connection from" not in forge_log()[len(before):], "muninn connected to the forge"
        assert decoy_requests() == decoys, "a stand-in agent (rbw's or the Bitwarden desktop app's) was asked"
        return out


    start_all()
    for m in (muninn, huginn):
        m.wait_for_unit("multi-user.target")
        m.wait_for_unit("user@" + uid(m) + ".service")
    forge.wait_for_unit("sshd.service")
    muninn.wait_for_unit("sshd.service")

    with subtest("the keys and the forge"):
        # Keys go in at run time: an option that reads a file would read it
        # while the test is evaluated.
        as_user(huginn, "install -D -m 600 ${login.private} ~/.ssh/login")
        as_user(huginn, SSH + " muninn true")
        as_user(muninn, "install -D -m 600 " + KEYS + "/default ~/.ssh/id_ed25519 && chmod 700 ~/.ssh")
        as_user(muninn, "install -m 600 " + KEYS + "/bitwarden ~/.ssh/bitwarden")
        forge.succeed(
            "install -d -m 700 -o git -g users ~git/.ssh"
            + " && cat ${standIn.pub} " + KEYS + "/extra.pub " + KEYS + "/bitwarden.pub " + KEYS + "/default.pub"
            + " >~git/.ssh/authorized_keys"
            + " && chown git ~git/.ssh/authorized_keys && chmod 600 ~git/.ssh/authorized_keys"
            + " && su - git -c 'git init -q --bare alice/project.git'"
        )
        STAND_IN_FP = fingerprint("${standIn.pub}")
        OTHER_FPS = [fingerprint(KEYS + "/" + n + ".pub") for n in ("extra", "bitwarden", "default")]

    with subtest("rbw's agent and the Bitwarden desktop app's, stood in for, hold a key the forge takes"):
        # decoy-rbw stands in for rbw's agent, at the socket SSH_AUTH_SOCK
        # names. decoy-bitwarden stands in for the Bitwarden desktop app's
        # agent, on its own socket, which nothing in ravnix points at.
        as_user(
            muninn,
            "mkdir -p -m 700 $XDG_RUNTIME_DIR/rbw"
            + " && systemd-run --user --unit=decoy-rbw ssh-agent -d -a " + RBW
            + " && systemd-run --user --unit=decoy-bitwarden ssh-agent -d -a ~/.bitwarden-ssh-agent.sock",
        )
        muninn.wait_until_succeeds("test -S /run/user/" + uid(muninn) + "/rbw/ssh-agent-socket")
        muninn.wait_until_succeeds("test -S " + HOME + "/.bitwarden-ssh-agent.sock")
        for s in (RBW, "~/.bitwarden-ssh-agent.sock"):
            as_user(muninn, "SSH_AUTH_SOCK=" + s + " ssh-add -q ~/.ssh/bitwarden")
        # The count sees a request, which the checks below rely on.
        before = decoy_requests()
        as_user(muninn, "SSH_AUTH_SOCK=" + RBW + " ssh-add -l")
        assert decoy_requests() > before
        # Without the module's configuration, ssh takes that key.
        before = forge_log()
        as_user(
            muninn,
            "SSH_AUTH_SOCK=" + RBW + " ssh -F /dev/null -o StrictHostKeyChecking=accept-new git@github.com true",
        )
        bitwarden = fingerprint(KEYS + "/bitwarden.pub")
        retry(lambda _: bitwarden in forge_log()[len(before):], timeout=datetime.timedelta(seconds=10))

    with subtest("a missing handle is not loaded, and the loading unit names it"):
        huginn.wait_for_unit("sk-agent.service", user=USER)
        huginn.wait_until_succeeds("systemctl --user -M " + USER + "@ is-failed sk-agent-keys.service")
        loader_logged(STAND_IN, SECOND)
        assert held() == [], held()

    with subtest("one handle there: the agent holds it, and the unit names the other"):
        as_user(huginn, "install -D -m 600 ${standIn.private} " + STAND_IN)
        state = after_loading(lambda: huginn.systemctl("restart sk-agent.service", user=USER))
        assert state == "failed", state
        assert held() == ["${bare standIn.publicKey}"], held()

    with subtest("a handle whose public half is not the listed one is not loaded"):
        as_user(huginn, "install -m 600 " + KEYS + "/extra " + SECOND)
        state = after_loading(lambda: huginn.systemctl("restart sk-agent-keys.service", user=USER))
        assert state == "failed", state
        loader_logged("is not the key")
        assert held() == ["${bare standIn.publicKey}"], held()

    with subtest("both handles there: the agent holds both and nothing else"):
        as_user(huginn, "install -m 600 ${second.private} " + SECOND)
        state = after_loading(lambda: huginn.systemctl("restart sk-agent.service", user=USER))
        assert state == "active", state
        assert held() == LISTED, held()

    with subtest("loading the keys again drops a key that was added by hand"):
        as_user(huginn, "SSH_AUTH_SOCK=" + sock(huginn) + " ssh-add -q " + KEYS + "/extra")
        assert len(held()) == 3, held()
        state = after_loading(lambda: huginn.systemctl("restart sk-agent-keys.service", user=USER))
        assert state == "active", state
        assert held() == LISTED, held()

    with subtest("a locked agent makes the loading unit fail and say so"):
        as_user(huginn, "printf '#!/bin/sh\\necho lock-word\\n' >~/askpass && chmod 700 ~/askpass")
        lock = "SSH_AUTH_SOCK=" + sock(huginn) + " SSH_ASKPASS=$HOME/askpass SSH_ASKPASS_REQUIRE=force ssh-add "
        as_user(huginn, lock + "-x </dev/null")
        state = after_loading(lambda: huginn.systemctl("restart sk-agent-keys.service", user=USER))
        assert state == "failed", state
        loader_logged("may be locked")
        as_user(huginn, lock + "-X </dev/null")
        state = after_loading(lambda: huginn.systemctl("restart sk-agent-keys.service", user=USER))
        assert state == "active", state
        assert held() == LISTED, held()

    with subtest("the agent's socket is its own, mode 600, and not SSH_AUTH_SOCK"):
        mode = huginn.succeed("stat -c %a " + sock(huginn)).strip()
        assert mode == "600", mode
        env = as_user(huginn, "systemctl --user show-environment; echo SSH_AUTH_SOCK=$SSH_AUTH_SOCK")
        assert "sk-agent" not in env, env

    with subtest("a killed agent leaves its socket, and comes back with its keys"):
        pid = as_user(huginn, "systemctl --user show -p MainPID --value sk-agent.service").strip()
        state = after_loading(lambda: huginn.succeed("kill -9 " + pid))
        assert state == "active", state
        assert as_user(huginn, "systemctl --user show -p MainPID --value sk-agent.service").strip() != pid
        assert held() == LISTED, held()

    with subtest("a stale socket with no listener does not keep the agent from starting"):
        huginn.systemctl("stop sk-agent.service", user=USER)
        as_user(
            huginn,
            "${pkgs.python3}/bin/python3 -c "
            + shlex.quote("import socket; socket.socket(socket.AF_UNIX).bind('" + sock(huginn) + "')"),
        )
        huginn.succeed("test -S " + sock(huginn))
        state = after_loading(lambda: huginn.systemctl("start sk-agent.service", user=USER))
        assert state == "active", state
        assert held() == LISTED, held()

    with subtest("with the forward up, ssh and git on muninn log in with the listed key alone"):
        forward()
        logs_in("ssh git@github.com true")
        logs_in("ssh -p 2222 git@" + FORGEJO + " true")
        # As the brief writes the command.
        logs_in("ssh -o IdentityAgent=" + sock(muninn) + " git@" + FORGEJO + " true")
        # A host name is the same host in other capitals, for DNS and for ssh.
        logs_in("ssh git@GitHub.COM true")
        logs_in("ssh -p 2222 git@" + FORGEJO.upper() + " true")
        # The forwarded socket is the user's alone.
        owner = muninn.succeed("stat -c '%a %U' " + sock(muninn)).strip()
        assert owner == "600 " + USER, owner
        status, out = muninn.execute("su - other -c 'SSH_AUTH_SOCK=" + sock(muninn) + " ssh-add -l' 2>&1")
        assert status == 2, (status, out)
        as_user(
            muninn,
            "git init -q ~/project && cd ~/project"
            + " && git -c user.name=t -c user.email=t@t -c commit.gpgsign=false commit -q --allow-empty -m one"
            + " && git remote add github git@github.com:alice/project.git"
            + " && git remote add forgejo ssh://git@" + FORGEJO + ":2222/~/alice/project.git",
        )
        logs_in("git -C ~/project push -q github HEAD:main")
        logs_in("git -C ~/project push -q forgejo HEAD:other")
        forge.succeed("su - git -c 'git -C alice/project.git rev-parse main other'")

    with subtest("with the forward gone, the same commands fail at once, naming the laptop"):
        drop_forward()
        # sshd leaves the socket of a closed forward behind, with nobody on it.
        muninn.succeed("test -S " + sock(muninn))
        refused("ssh git@github.com true", "not connected")
        refused("ssh git@GitHub.COM true", "not connected")
        refused("ssh -o IdentityAgent=" + sock(muninn) + " git@" + FORGEJO + " true", "not connected")
        refused("git -C ~/project push -q github HEAD:main", "not connected")
        refused("git -C ~/project fetch -q forgejo", "not connected")

    with subtest("with no socket at all, the same"):
        muninn.succeed("rm " + sock(muninn))
        refused("ssh git@github.com true", "not connected", sock(muninn))

    with subtest("a laptop frozen behind a live forward is refused within 5 s"):
        forward()
        logs_in("ssh git@github.com true")
        pid = huginn.succeed("pgrep -u " + USER + " -x ssh").strip()
        huginn.succeed("kill -STOP " + pid)
        refused("ssh git@" + FORGEJO + " true", "does not answer")
        huginn.succeed("kill -CONT " + pid)
        logs_in("ssh git@github.com true")

    with subtest("an agent that is busy behind a live forward is refused within 5 s"):
        # ssh-agent answers one request at a time, and a security key's
        # signature holds it until the touch: a stopped agent stands in.
        agent_pid = as_user(huginn, "systemctl --user show -p MainPID --value sk-agent.service").strip()
        huginn.succeed("kill -STOP " + agent_pid)
        refused("ssh git@github.com true", "does not answer", "waiting for a touch")
        huginn.succeed("kill -CONT " + agent_pid)
        logs_in("ssh git@github.com true")

    with subtest("an agent that is not running behind a live forward is refused by name"):
        huginn.systemctl("stop sk-agent.service", user=USER)
        refused("ssh git@github.com true", "not running", "systemctl --user status sk-agent")
        state = after_loading(lambda: huginn.systemctl("start sk-agent.service", user=USER))
        assert state == "active", state
        logs_in("ssh git@github.com true")

    with subtest("an agent that holds a key not on the list"):
        agent = "SSH_AUTH_SOCK=" + sock(huginn)
        as_user(huginn, agent + " ssh-add -D && " + agent + " ssh-add -q " + KEYS + "/extra")
        refused("ssh git@github.com true", "none of the keys")
        # Beside the listed one, it is never offered.
        as_user(huginn, agent + " ssh-add -q " + STAND_IN)
        logs_in("ssh git@github.com true")
        logs_in("git -C ~/project push -q forgejo HEAD:other")
        # Nor when the forge refuses the listed key that the agent holds:
        # ssh then gives up, and does not go on to the other key.
        as_user(huginn, agent + " ssh-add -D && " + agent + " ssh-add -q " + SECOND + " " + KEYS + "/extra")
        before = forge_log()
        status, out, _ = on_muninn("ssh git@github.com true")
        assert status != 0 and "Permission denied" in out, out
        new = forge_log()[len(before):]
        assert "Connection from" in new, new
        assert "Accepted publickey" not in new and fingerprint(KEYS + "/extra.pub") not in new, new
        # A restart of the agent holds the list again, and only the list.
        state = after_loading(lambda: huginn.systemctl("restart sk-agent.service", user=USER))
        assert state == "active", state
        assert held() == LISTED, held()
        # The forward reaches the new agent: each use connects to the path anew.
        logs_in("ssh git@github.com true")

    with subtest("an agent that holds no key is refused by name"):
        as_user(huginn, "SSH_AUTH_SOCK=" + sock(huginn) + " ssh-add -D")
        refused("ssh git@github.com true", "holds no key")
        state = after_loading(lambda: huginn.systemctl("restart sk-agent-keys.service", user=USER))
        assert state == "active", state
        logs_in("ssh git@github.com true")

    with subtest("a second login session on muninn uses the first one's forward"):
        before = forge_log()
        out = as_user(huginn, SSH + " muninn 'echo SOCK=$SSH_AUTH_SOCK; ssh git@github.com true && echo in' 2>&1")
        lines = out.splitlines()
        # The session has no forward of its own: its SSH_AUTH_SOCK is rbw's
        # socket, which the common module sets in every login shell (Task 4.3),
        # and ssh still takes the first session's forward.
        rbw_sock = "SOCK=/run/user/" + uid(muninn) + "/rbw/ssh-agent-socket"
        assert rbw_sock in lines and "in" in lines, out
        logged_in(before)
        # The first one still works once the second has gone.
        logs_in("ssh git@" + FORGEJO + " true")

    with subtest("the forward comes back after a drop, over the socket it left"):
        drop_forward()
        muninn.succeed("test -S " + sock(muninn))
        refused("ssh git@github.com true", "not connected")
        forward()
        logs_in("ssh git@github.com true")
        logs_in("git -C ~/project push -q github HEAD:again")

    with subtest("a host that is not on the list is left as it was"):
        drop_forward()
        before = forge_log()
        status, out, _ = on_muninn("ssh git@forge true")
        assert status == 0 and "sk-agent" not in out and "huginn" not in out, out
        # It took the key of rbw's stand-in agent, as SSH_AUTH_SOCK says.
        retry(lambda _: bitwarden in forge_log()[len(before):], timeout=datetime.timedelta(seconds=10))
  '';
}
