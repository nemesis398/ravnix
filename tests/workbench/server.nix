# The server shape, muninn, in a VM: hosts/server with the workbench on top of
# the common module, as a user sits down at it. herdr's server runs and
# answers, a pane of it has the user's tools, and the terminal programs of the
# server are on the PATH (aerc, iamb, khal, vdirsyncer, podman, uv, node,
# cargo, odin, lazygit). The Nextcloud sync, the calendar sync and Claude
# Code's Remote Control are user units that need a secret or a login the VM
# does not have: they run here against stand-ins (an rbw that is locked or
# not, a nextcloudcmd that records what it was given, a Radicale for CalDAV,
# a claude that records how it was started), so what they hand to the real
# program, and what they do when the vault is locked, is checked. sshd runs
# with passwords off, Podman runs a container as the user and not as root, and
# the closure of the whole system holds none of the programs of the laptop.
#
# Deviation from the plan's wording (Task 4.1, Step 1): the plan says
# `podman run --rm docker.io/library/hello-world` "from a pre-loaded image".
# A nixosTest has no network, so the VM cannot pull that image; this test
# builds a small image with pkgs.dockerTools, loads it with `podman load`
# inside the VM and runs it as the test user, which checks the same thing:
# that rootless Podman works on the server.
{
  self,
  pkgs,
  lib,
  ...
}:
let
  me = import ../../templates/default/me.nix;
  user = me.ravnix.user;
  odin = (import ../../lib/odin.nix { inherit pkgs lib; }).odin;

  # An rbw whose vault is locked while ~/rbw-locked exists, and otherwise
  # answers every item with a value made from its name. It records each
  # `get` in ~/rbw.log, so a test can see which item was asked for.
  fakeRbw = pkgs.writeShellScriptBin "rbw" ''
    case "$1" in
      unlocked) [ ! -e "$HOME/rbw-locked" ] ;;
      get)
        shift
        [ "$1" = -- ] && shift
        [ ! -e "$HOME/rbw-locked" ] || exit 1
        echo "$1" >>"$HOME/rbw.log"
        printf 'secret-for:%s\n' "$1"
        ;;
      *) exit 0 ;;
    esac
  '';

  # A nextcloudcmd that writes what it was started with: its arguments, and
  # the two variables a non-interactive run reads credentials from.
  fakeNextcloud = pkgs.writeShellScriptBin "nextcloudcmd" ''
    {
      echo RUN
      printf 'arg:%s\n' "$@"
      echo "user:$NC_USER"
      echo "password:$NC_PASSWORD"
    } >>"$HOME/nextcloudcmd.log"
  '';
  fakeNextcloudPackage = pkgs.symlinkJoin {
    name = "fake-nextcloud-client";
    paths = [ fakeNextcloud ];
  };

  # A claude that records how Remote Control started it, and stays up.
  fakeClaudePackage =
    pkgs.writeShellScriptBin "claude" ''
      {
        echo "cwd:$PWD"
        printf 'arg:%s\n' "$@"
        echo "api-key:''${ANTHROPIC_API_KEY-unset}"
      } >"$HOME/remote-control.log"
      exec ${pkgs.coreutils}/bin/sleep infinity
    ''
    // {
      download = null;
    };

  # The image that Podman runs: hello and nothing else. The VM cannot pull
  # one, so the test loads this.
  helloImage = pkgs.dockerTools.buildImage {
    name = "hello";
    tag = "latest";
    copyToRoot = pkgs.buildEnv {
      name = "hello-root";
      paths = [ pkgs.hello ];
      pathsToLink = [ "/bin" ];
    };
    config.Cmd = [ "/bin/hello" ];
  };

  # The programs of the laptop (modules/desktop, the graphical applications):
  # none of them is on the server.
  laptopOnly = [
    "sway"
    "swaylock"
    "swayidle"
    "waybar"
    "fuzzel"
    "dunst"
    "kanshi"
    "greetd"
    "tuigreet"
    "helium"
    "obsidian"
    "ghostty"
    "onlyoffice-desktopeditors"
    "steam"
  ];

  # A calendar published as a file, which the module's feeds read over http.
  feedDir = pkgs.writeTextDir "class.ics" ''
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//ravnix//workbench-server-feed//EN
    BEGIN:VEVENT
    UID:workbench-server-feed-1@example.org
    DTSTAMP:20300101T000000Z
    DTSTART:20300616T090000Z
    DTEND:20300616T093000Z
    SUMMARY:Lesson of the class feed
    END:VEVENT
    END:VCALENDAR
  '';

  event = pkgs.writeText "standup.ics" ''
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//ravnix//workbench-server//EN
    BEGIN:VEVENT
    UID:workbench-server-1@example.org
    DTSTAMP:20300101T000000Z
    DTSTART:20300615T090000Z
    DTEND:20300615T093000Z
    SUMMARY:Standup of the workbench
    END:VEVENT
    END:VCALENDAR
  '';
in
pkgs.testers.runNixOSTest (
  { nodes, ... }:
  {
    name = "workbench-server";

    nodes.machine =
      { pkgs, ... }:
      {
        imports = [
          self.nixosModules.server
          ../../templates/default/me.nix
        ];

        # The template's values are placeholders and warn about it (the
        # options tests check that they do); here the warnings are noise.
        warnings = lib.mkForce [ ];

        # The editor of both hosts comes with the module; the VM needs one
        # language, not the toolchain of each (tests/common/nvim.nix runs the
        # editor with every language).
        ravnix.editor.languages = lib.mkForce [ "nix" ];

        # Where Remote Control starts, a git repository of the user's.
        ravnix.server.remoteControlDir = lib.mkForce "/home/${user.username}/work";

        # The calendar sync talks to a CalDAV server in the VM.
        ravnix.calendar = {
          caldavUrl = lib.mkForce "http://127.0.0.1:5232/";
          carddavUrl = lib.mkForce "http://127.0.0.1:5232/";
          # A name with a dot and a dash, which vdirsyncer's own names cannot
          # have; the feed needs no password.
          feeds = lib.mkForce {
            "class-2.0" = {
              url = "http://127.0.0.1:8099/class.ics";
              color = "light magenta";
            };
          };
        };
        systemd.services.calendar-feed = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8099 --bind 127.0.0.1 --directory ${feedDir}";
        };
        services.radicale = {
          enable = true;
          settings = {
            server.hosts = [ "127.0.0.1:5232" ];
            auth.type = "none";
          };
        };

        home-manager.users.${user.username} = {
          programs.rbw.package = lib.mkForce fakeRbw;
          programs.claude-code.package = lib.mkForce fakeClaudePackage;
        };
        ravnix.workbench.nextcloudSync.package = fakeNextcloudPackage;

        # A second system whose herdr unit has other text, which the test
        # switches to: a switch must not restart the server, whatever changed.
        specialisation.probe.configuration.home-manager.users.${user.username}.systemd.user.services.herdr-server.Service.RestartSec =
          lib.mkForce 3;

        environment.systemPackages = [
          pkgs.curl
          pkgs.jq
          pkgs.git
        ];
        virtualisation = {
          cores = 2;
          memorySize = 2048;
          diskSize = 4096;
        };
        system.stateVersion = "26.05";
      };

    testScript =
      { nodes, ... }:
      let
        closure = pkgs.closureInfo { rootPaths = [ nodes.machine.system.build.toplevel ]; };
      in
      ''
        import json
        import re
        import shlex

        USER = "${user.username}"
        HOME = "/home/" + USER
        LAPTOP_ONLY = ${builtins.toJSON laptopOnly}


        def as_user(cmd, check=True):
            # A login shell, so the PATH is the one the user has when they ssh
            # in, and a terminal type of a real terminal.
            script = "su - " + USER + " -c " + shlex.quote("export TERM=xterm-256color; " + cmd)
            return machine.succeed(script) if check else machine.execute(script)


        def user_ctl(args, check=True):
            return as_user("XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user " + args, check)


        def user_journal(unit):
            return as_user("XDG_RUNTIME_DIR=/run/user/$(id -u) journalctl --user -u " + unit + " --no-pager -o cat", False)[1]


        machine.wait_for_unit("multi-user.target")
        machine.wait_for_unit("home-manager-" + USER + ".service")
        # The user's manager runs without a login: the units below are the
        # server's work, and it must do it with nobody logged in.
        machine.wait_for_unit("user@" + machine.succeed("id -u " + USER).strip() + ".service")

        with subtest("herdr's server runs and answers"):
            machine.wait_for_unit("herdr-server.service", USER)
            machine.wait_until_succeeds("su - " + USER + " -c 'herdr status server'", timeout=60)
            status = json.loads(as_user("herdr status server --json"))
            assert status["running"] and status["compatible"], status
            # The configuration the module wrote is one herdr accepts.
            as_user("herdr config check")

        with subtest("a pane of the server is bash, with the user's tools on its PATH"):
            made = json.loads(as_user("herdr workspace create --cwd " + HOME))
            pane = made["result"]["root_pane"]["pane_id"]
            probe = (
                "{ echo shell=$(readlink -f /proc/$$/exe); type -P lazygit rg claude odin; } > " + HOME + "/pane.out"
            )
            as_user("herdr pane run " + pane + " " + shlex.quote(probe))
            machine.wait_until_succeeds("test -s " + HOME + "/pane.out && grep -q claude " + HOME + "/pane.out", timeout=60)
            out = machine.succeed("cat " + HOME + "/pane.out")
            assert re.search(r"^shell=/nix/store/\S+-bash-interactive-\S+/bin/bash$", out, re.M), out
            for tool in ["lazygit", "rg", "claude", "odin"]:
                assert "/bin/" + tool in out, tool + " is not on a pane's PATH:\n" + out

        with subtest("the terminal programs of the server are on the PATH"):
            for command in [
                "aerc -v",
                "iamb --version",
                "khal --version",
                "vdirsyncer --version",
                "podman --version",
                "uv --version",
                "node --version",
                "cargo --version",
                "rustc --version",
                "cc --version",
                "odin version",
                "lazygit --version",
                "herdr --version",
            ]:
                as_user(command)

        with subtest("there is one Odin, the one the tools are built with"):
            resolved = as_user("readlink -f $(command -v odin)").strip()
            assert resolved.startswith("${odin}/"), resolved

        with subtest("sshd runs, and takes no password"):
            machine.wait_for_unit("sshd.service")
            machine.wait_for_open_port(22)
            effective = machine.succeed("sshd -T").lower()
            assert "passwordauthentication no" in effective, effective
            assert "kbdinteractiveauthentication no" in effective, effective
            assert "permitrootlogin no" in effective, effective

        with subtest("Podman runs a container as the user, not as root"):
            as_user("podman load -i ${helloImage}")
            assert as_user("podman info --format '{{.Host.Security.Rootless}}'").strip() == "true"
            out = as_user("podman run --rm localhost/hello:latest")
            assert "Hello, world!" in out, out
            # The container's process belongs to the user on the host, not to
            # root: it ran with no daemon and no root-owned storage.
            assert as_user("stat -c %U ~/.local/share/containers/storage").strip() == USER
            machine.fail("test -e /var/lib/containers/storage/overlay-images/images.json")

        with subtest("no program of the laptop is in the closure of the system"):
            names = [p.split("-", 1)[1] for p in open("${closure}/store-paths").read().split()]
            bad = sorted({n for n in names if re.match(r"(?:" + "|".join(map(re.escape, LAPTOP_ONLY)) + r")(?:-[0-9].*)?$", n)})
            assert not bad, "the closure of the server holds: " + ", ".join(bad)
            # What the server is for is in it, so the test cannot pass on an
            # empty list.
            assert any(re.match(r"herdr-[0-9]", n) for n in names) and any(n.startswith("aerc-") for n in names)

        with subtest("the Nextcloud sync unit exists, runs every few minutes, and is enabled"):
            user_ctl("cat nextcloud-sync.service")
            assert user_ctl("is-enabled nextcloud-sync.timer").strip() == "enabled"
            assert user_ctl("is-active nextcloud-sync.timer").strip() == "active"
            unit = user_ctl("cat nextcloud-sync.service")
            # The password is handed over in the environment of the one
            # process, never in the unit.
            assert "secret" not in unit and "PASSWORD" not in unit, unit

        with subtest("the Nextcloud sync does nothing and says why while the vault is locked"):
            as_user("touch ~/rbw-locked; rm -f ~/nextcloudcmd.log")
            code, _ = machine.execute("su - " + USER + " -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user start nextcloud-sync.service'")
            assert code != 0, "the sync claims success with the vault locked"
            assert user_ctl("is-failed nextcloud-sync.service", False)[1].strip() == "failed"
            assert "locked" in user_journal("nextcloud-sync.service"), user_journal("nextcloud-sync.service")
            machine.fail("test -e " + HOME + "/nextcloudcmd.log")

        with subtest("the Nextcloud sync hands its password to nextcloudcmd in the environment"):
            as_user("rm -f ~/rbw-locked ~/rbw.log")
            user_ctl("start nextcloud-sync.service")
            log = as_user("cat ~/nextcloudcmd.log").splitlines()
            runs = [i for i, l in enumerate(log) if l == "RUN"]
            assert len(runs) == len(${builtins.toJSON me.ravnix.nextcloud.folders}), log
            body = "\n".join(log)
            assert "user:${me.ravnix.nextcloud.user}" in body, body
            assert "password:secret-for:${me.ravnix.nextcloud.passwordItem}" in body, body
            # Not on the command line, where any process could read it.
            args = [l for l in log if l.startswith("arg:")]
            assert not [a for a in args if "secret" in a], args
            assert "arg:--non-interactive" in args, args
            # Hidden files are part of the copy (the vault holds .obsidian,
            # .claude and .agents), and .git is still kept out.
            assert "arg:-h" in args, args
            assert "arg:--exclude-anchored" in args, args
            assert "arg:${me.ravnix.nextcloud.url}" in args, args
            for folder in ${builtins.toJSON me.ravnix.nextcloud.folders}:
                assert "arg:" + folder in args, (folder, args)
                assert "arg:" + HOME + "/Nextcloud" + folder in args, (folder, args)
            # The item was read once for the whole run, from the vault.
            assert as_user("cat ~/rbw.log").splitlines() == ["${me.ravnix.nextcloud.passwordItem}"]

        with subtest("the real nextcloudcmd takes the command line the sync unit gives it, with no display"):
            # The stand-in replaced the client for the unit; this is the package
            # the module installs by default (a Qt program, which must not ask
            # for a display or a platform plugin). It gets each argv the unit
            # built, word for word, except the local folder and the server: the
            # server is a port nobody listens on. A flag it does not know makes
            # it print its usage, which the assertion below would show.
            runs = []
            for line in as_user("cat ~/nextcloudcmd.log").splitlines():
                if line == "RUN":
                    runs.append([])
                elif line.startswith("arg:"):
                    runs[-1].append(line[len("arg:"):])
            assert len(runs) == len(${builtins.toJSON me.ravnix.nextcloud.folders}), runs
            for argv in runs:
                assert "-h" in argv and "--path" in argv and "--exclude-anchored" in argv, argv
                argv = argv[:-2] + [HOME + "/nc-headless", "http://127.0.0.1:9"]
                code, out = as_user(
                    "mkdir -p ~/nc-headless && NC_USER=nobody NC_PASSWORD=x "
                    "${pkgs.nextcloud-client}/bin/nextcloudcmd " + " ".join(map(shlex.quote, argv)) + " 2>&1",
                    False,
                )
                assert code != 0, out
                assert "Error connecting to server" in out, out
                for bad in ["Usage:", "--help", "xcb", "qt.qpa", "platform plugin", "display"]:
                    assert bad not in out, bad + " in:\n" + out

        with subtest("the calendar syncs from a CalDAV server into khal"):
            machine.wait_for_unit("radicale.service")
            machine.wait_for_open_port(5232)
            base = "http://127.0.0.1:5232/${me.ravnix.calendar.user}"
            machine.succeed(
                "curl -sf -X MKCOL -u ${me.ravnix.calendar.user}:x -H 'Content-Type: application/xml' "
                "--data '<?xml version=\"1.0\"?><create xmlns=\"DAV:\" xmlns:C=\"urn:ietf:params:xml:ns:caldav\">"
                "<set><prop><resourcetype><collection/><C:calendar/></resourcetype>"
                "<displayname>personal</displayname></prop></set></create>' " + base + "/personal/"
            )
            machine.succeed(
                "curl -sf -X PUT -u ${me.ravnix.calendar.user}:x -H 'Content-Type: text/calendar' "
                "--data-binary @${event} " + base + "/personal/standup.ics"
            )
            machine.wait_for_unit("calendar-feed.service")
            machine.wait_for_open_port(8099)
            # Locked first: the unit fails and says so, and the account's
            # calendars stay where they are, on the server.
            as_user("touch ~/rbw-locked")
            code, _ = machine.execute("su - " + USER + " -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user start vdirsyncer.service'")
            assert code != 0
            assert "locked" in user_journal("vdirsyncer.service")
            machine.fail("test -e " + HOME + "/.local/share/calendars/personal")
            status = as_user("ls ~/.local/share/vdirsyncer/status 2>/dev/null || true").split()
            assert not [n for n in status if n.startswith(("calendars", "contacts"))], status
            # The feed needs no password, so it was copied before the vault
            # was asked, and does not wait for an unlock.
            feed = as_user("cat ~/.local/share/calendars-readonly/class-2.0/*.ics")
            assert "Lesson of the class feed" in feed, feed
            as_user("rm -f ~/rbw-locked")
            user_ctl("start vdirsyncer.service")
            listed = as_user("khal list 2030-06-15 1d")
            assert "Standup of the workbench" in listed, listed
            listed = as_user("khal list 2030-06-16 1d")
            assert "Lesson of the class feed" in listed, listed
            assert user_ctl("is-enabled vdirsyncer.timer").strip() == "enabled"

        with subtest("iamb and aerc have their accounts"):
            iamb = as_user("cat ~/.config/iamb/config.toml")
            assert "${me.ravnix.matrix.userId}" in iamb and "${me.ravnix.matrix.homeserver}" in iamb, iamb
            accounts = as_user("cat ~/.config/aerc/accounts.conf")
            assert "${me.ravnix.mail.main.imap.host}" in accounts and "${me.ravnix.mail.main.smtp.host}" in accounts, accounts
            # The password is whatever the credential commands print. They are
            # run here against the stand-in vault, which answers with the name
            # of the item it was asked for: the item is the one named in the
            # option, whatever its spelling, and rbw is what answers.
            commands = re.findall(r"^(?:source|outgoing)-cred-cmd\s*=\s*(.+)$", accounts, re.M)
            assert len(commands) == 2, accounts
            for command in commands:
                assert as_user(command).strip() == "secret-for:${me.ravnix.mail.main.passwordItem}", command

        with subtest("Claude Code's Remote Control is enabled, and waits for a login"):
            assert user_ctl("is-enabled claude-remote-control.service").strip() == "enabled"
            # No login and no repository yet: the unit is skipped, not
            # restarted every half minute behind an "active" that is not.
            machine.execute("su - " + USER + " -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user start claude-remote-control.service'")
            assert user_ctl("is-active claude-remote-control.service", False)[1].strip() == "inactive"
            assert user_ctl("show -p ConditionResult --value claude-remote-control.service").strip() == "no"
            machine.fail("test -e " + HOME + "/remote-control.log")

        with subtest("Remote Control waits for the state file as well: a login without ~/.claude.json is not enough"):
            # What copying ~/.claude/ to a new machine leaves behind: the
            # login and the repository, and not the file next to ~/.claude/
            # that holds the answers to the first-run dialogs. Started like
            # this, Claude Code would ask on a terminal that is not there.
            as_user("mkdir -p ~/.claude ~/work && git init -q ~/work && echo '{}' > ~/.claude/.credentials.json && rm -f ~/.claude.json")
            machine.execute("su - " + USER + " -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user start claude-remote-control.service'")
            assert user_ctl("is-active claude-remote-control.service", False)[1].strip() == "inactive"
            assert user_ctl("show -p ConditionResult --value claude-remote-control.service").strip() == "no"
            machine.fail("test -e " + HOME + "/remote-control.log")
            machine.fail("test -e " + HOME + "/.claude.json")

        with subtest("Remote Control starts once there is a login, its state file and a repository, as the development VM before it had it"):
            as_user("echo '{\"numStartups\": 3, \"projects\": {\"keep\": {\"me\": true}}}' > ~/.claude.json")
            user_ctl("start claude-remote-control.service")
            machine.wait_until_succeeds("su - " + USER + " -c 'test -s ~/remote-control.log'", timeout=60)
            log = as_user("cat ~/remote-control.log").splitlines()
            assert "cwd:" + HOME + "/work" in log, log
            assert log[1:6] == ["arg:remote-control", "arg:--name", "arg:machine", "arg:--spawn", "arg:worktree"], log
            assert "api-key:unset" in log, log
            # Nix does the updating: the setting that keeps Claude Code from
            # replacing itself is in the settings file the unit's claude reads.
            settings = json.loads(as_user("cat ~/.claude/settings.json"))
            assert settings["env"]["DISABLE_AUTOUPDATER"] == "1", settings
            # The consent prompt that cannot be answered under systemd is
            # answered in the file Claude Code keeps it in, and the rest of
            # the file is as it was.
            state = json.loads(as_user("cat ~/.claude.json"))
            assert state["remoteDialogSeen"] is True and state["numStartups"] == 3 and state["projects"] == {"keep": {"me": True}}, state
            assert user_ctl("is-active claude-remote-control.service").strip() == "active"

        with subtest("a ~/.claude.json that is not JSON stops Remote Control and is left as it is"):
            user_ctl("stop claude-remote-control.service")
            as_user("rm -f ~/remote-control.log; echo 'not json' > ~/.claude.json")
            code, _ = machine.execute("su - " + USER + " -c 'XDG_RUNTIME_DIR=/run/user/$(id -u) systemctl --user start claude-remote-control.service'")
            assert code != 0
            assert as_user("cat ~/.claude.json").strip() == "not json"
            machine.fail("test -e " + HOME + "/remote-control.log")
            user_ctl("stop claude-remote-control.service", False)
            user_ctl("reset-failed claude-remote-control.service", False)

        with subtest("a switch leaves herdr's server and its panes running"):
            # The workspace made above is still open, the server's process is
            # the same after the switch, and the unit on disk is the new one:
            # the change arrived and the running server was kept.
            before = user_ctl("show -p MainPID --value herdr-server.service").strip()
            assert before.isdigit() and int(before) > 1, before
            machine.succeed("/run/current-system/specialisation/probe/bin/switch-to-configuration test")
            machine.wait_for_unit("home-manager-" + USER + ".service")
            machine.wait_until_succeeds("grep -q '^RestartSec=3$' " + HOME + "/.config/systemd/user/herdr-server.service", timeout=60)
            after = user_ctl("show -p MainPID --value herdr-server.service").strip()
            assert after == before, "the switch restarted herdr's server: " + before + " -> " + after
            assert user_ctl("is-active herdr-server.service").strip() == "active"
            assert pane in as_user("herdr pane list"), "the pane is gone after the switch"
      '';
  }
)
