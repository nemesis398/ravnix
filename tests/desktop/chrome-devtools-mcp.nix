# The Chrome DevTools MCP server on a headless Helium, started the way Claude
# Code starts it, on both shapes of ravnix: the laptop's desktop, with a
# Wayland display that the browser has to leave alone, and the server shape,
# with no display at all. Two VMs, one after the other.
#
# On each, the test reads the MCP server `chrome-devtools` from ~/.claude.json
# (put there by the home-manager activation, modules/common/claude-mcp.nix),
# runs exactly that command with a small MCP client (helpers/
# chrome-devtools-mcp-probe.py), and checks what the wrapper
# (packages/chrome-devtools-mcp-helium) exists for:
#
#   - the first navigation right after the browser is launched succeeds and
#     the page is read back, including what its script wrote. Helium's own
#     uBlock Origin would reload the tab before its lists were loaded, abort
#     that navigation (net::ERR_ABORTED) and hang new_page; the wrapper gives
#     every launch a profile in which it is switched off. The probe also reads
#     that profile's Preferences while the server runs;
#   - every launch has a directory of its own, cdh.PID.XXXXXX, with the profile
#     and a TMPDIR (t) in it, in /tmp when TMPDIR is unset; the browser runs
#     with that TMPDIR, the server's file tools accept a path in it and refuse
#     one in the user's runtime directory or in /tmp itself, and the runtime
#     directory is never written to, nor chosen as the directory of a launch
#     when TMPDIR points into it;
#   - no launch directory, no file of the server and no browser process is
#     left behind, whether the server ends by its stdin closing or by SIGTERM,
#     which is how Claude Code stops a server;
#   - the server asks Google for nothing (the usage statistics and CrUX
#     notices of the server are absent), and the browser runs headless: on the
#     desktop no window appears in the compositor, and the environment the
#     desktop module sets for Wayland (NIXOS_OZONE_WL, which makes Helium ask
#     for a Wayland display) does not matter;
#   - the browser runs with its sandbox (no --no-sandbox, and its renderers
#     under seccomp) and talks to the server over a pipe: no remote-debugging
#     port, and no TCP socket listening;
#   - a TMPDIR of 40 bytes, the longest the wrapper accepts, works with the real
#     Helium when the PID in the name of the launch has 7 digits, the worst
#     case the 40 was worked out for, and one too long for Chromium's singleton
#     socket, as one under a deep directory is, is passed over;
#   - PUPPETEER_DANGEROUS_NO_SANDBOX=true in the caller's environment, which
#     would start the browser without its sandbox, changes nothing;
#   - on the server, Helium is only the browser of the wrapper: no helium on
#     the PATH, no menu entry, no display variable and no compositor.
#
# There is no network in the VM. The page comes from a local HTTP server.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  me = import ../../templates/default/me.nix;
  user = me.ravnix.user.username;
  unfree = import ../../lib/unfree.nix { inherit lib; };

  # The pkgs of the nodes: the overlay, and the unfree names of the desktop.
  nodePkgs = import inputs.nixpkgs {
    inherit system;
    config.allowUnfreePredicate = unfree.predicate {
      packetTracer = false;
      widevine = false;
    };
    overlays = [ self.overlays.default ];
  };

  page = pkgs.writeTextDir "probe.html" ''
    <!doctype html>
    <html>
      <head><title>Probe page</title></head>
      <body>
        <h1>probe-ok</h1>
        <div id="out"></div>
        <script>document.getElementById("out").textContent = "js-" + (6 * 7);</script>
      </body>
    </html>
  '';

  # What the probe's --exec runs while the server is up: a few facts about the
  # browser the launch started, as key=value lines. (The brackets in the
  # patterns keep ps and pgrep from finding the command that looks for them.)
  inspect = pkgs.writeShellApplication {
    name = "inspect-browser";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.iproute2
      pkgs.procps
    ];
    text = ''
      uid=$(id -u)
      args=$(ps -u "$uid" -o args=)
      main=$(pgrep -u "$uid" -f -- '[-]-remote-debugging-pipe' | head -n 1 || true)
      count() { grep -c -- "$1" <<<"$args" || true; }

      echo "main=$main"
      echo "no_sandbox=$(count '[-]-no-sandbox')"
      echo "debug_port=$(count '[-]-remote-debugging-port')"
      echo "debug_pipe=$(count '[-]-remote-debugging-pipe')"

      # The browser's processes: the main one and everything below it.
      pids=$(pgrep -u "$uid" -f -- '[-]-user-data-dir=|[-]-type=' | paste -sd'|' - || true)
      if [[ -n $pids ]]; then
        echo "listening=$(ss -H -ltnp 2>/dev/null | grep -cE "pid=($pids)," || true)"
      else
        echo "listening=none-found"
      fi

      # Renderers run under seccomp (mode 2) when the sandbox is on.
      renderers=0 unsandboxed=0
      for p in $(pgrep -u "$uid" -f -- '[-]-type=renderer' || true); do
        renderers=$((renderers + 1))
        grep -q '^Seccomp:[[:space:]]*2' "/proc/$p/status" || unsandboxed=$((unsandboxed + 1))
      done
      echo "renderers=$renderers"
      echo "unsandboxed=$unsandboxed"

      if [[ -n $main ]]; then
        echo "browser_$(tr '\0' '\n' <"/proc/$main/environ" | grep '^TMPDIR=' || echo TMPDIR=unset)"
      fi

      # Nothing of the launch in the runtime directory.
      echo "runtime_hits=$(find "$XDG_RUNTIME_DIR" -maxdepth 3 \( -name 'cdh.*' -o -name 'chrome-devtools-mcp*' -o -name '.org.chromium.*' -o -name '.com.google.*' \) 2>/dev/null | wc -l)"
    '';
  };

  # A Claude Code that is none: the package is not under test, and the real
  # one is a download the VM does not need.
  fakeClaude =
    pkgs.writeShellScriptBin "claude" "exit 0"
    // {
      download = null;
    };

  node = shape: extraPackages: {
    imports = [
      shape
      ../../templates/default/me.nix
    ];
    # The template's values are placeholders and warn about it.
    warnings = lib.mkForce [ ];
    ravnix.editor.languages = lib.mkForce [ "nix" ];
    ravnix.nextcloud = lib.mkForce null;
    home-manager.users.${user}.programs.claude-code.package = lib.mkForce fakeClaude;

    systemd.services.probe-page = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8099 --bind 127.0.0.1 --directory ${page}";
    };
    environment.systemPackages = [
      pkgs.jq
      pkgs.procps
      pkgs.iproute2
    ]
    ++ extraPackages;
    virtualisation = {
      cores = 2;
      memorySize = 3072;
      diskSize = 4096;
    };
    system.stateVersion = "26.05";
  };
in
pkgs.testers.runNixOSTest {
  name = "desktop-chrome-devtools-mcp";

  node.pkgs = lib.mkForce nodePkgs;

  # The desktop module does not bring a compositor yet (Sway arrives with its
  # own module); the display the test needs is Sway, headless, of the node.
  nodes.desktop = node self.nixosModules.desktop [ pkgs.sway ];
  nodes.server = node self.nixosModules.server [ ];

  testScript = ''
    import json
    import re
    import shlex

    USER = "${user}"
    HOME = "/home/" + USER
    PROBE = "${pkgs.python3}/bin/python3 -I ${./helpers/chrome-devtools-mcp-probe.py} --url http://127.0.0.1:8099/probe.html"
    UBO = "blockjmkbacgjkknlgpkjjiijinjdanf"
    SWAY_CONFIG = "${pkgs.writeText "sway.conf" "exec_always true\n"}"


    def as_user(machine, cmd, env=""):
        # A login shell, so the environment is the one the user's session has.
        return machine.succeed("su - " + USER + " -c " + shlex.quote(env + cmd))


    def run_probe(machine, name, args="", env="", server_args=""):
        """Starts the declared server as Claude Code does and returns the probe's account."""
        machine.succeed("rm -f /tmp/" + name + ".err")
        entry = json.loads(machine.succeed("jq -c '.mcpServers[\"chrome-devtools\"]' " + HOME + "/.claude.json"))
        command = " ".join(shlex.quote(c) for c in [entry["command"]] + entry["args"]) + server_args
        out = as_user(machine, PROBE + " " + args + " -- " + command + " 2>/tmp/" + name + ".err", env)
        return json.loads(out), machine.succeed("cat /tmp/" + name + ".err")


    def assert_clean(machine, where):
        """No launch directory in WHERE, no file of the server in /tmp, and no process of the browser is left."""
        machine.wait_until_succeeds("! pgrep -u " + USER + " -f 'cdh[.]'", timeout=30)
        left = machine.succeed("ls -d " + where + "/cdh.* /tmp/chrome-devtools-mcp-* 2>/dev/null || true").strip()
        assert not left, "files of a launch are left behind: " + left


    def facts(account, index):
        """The key=value lines that inspect-browser printed, as a dict."""
        done = account["exec"][index]
        assert done["status"] == 0, done
        return dict(l.split("=", 1) for l in done["stdout"].splitlines() if "=" in l)


    def check_page(account, what):
        first = account["first"]
        assert not first["isError"], what + ": the first call failed: " + first["text"]
        assert "Unable to navigate" not in first["text"], what + ": the navigation failed: " + first["text"]
        assert "probe-ok" in account["snapshot"], what + ": the page was not read back: " + account["snapshot"]
        assert "js-42" in account["snapshot"], what + ": the page's script did not run: " + account["snapshot"]
        assert "Probe page" in account["script"], what + ": the title was not read: " + account["script"]
        assert "navigate_page" in account["tools"] and "new_page" in account["tools"], account["tools"]
        print(what + ": the first call took " + str(first["seconds"]) + " s")


    def check_server(machine, display):
        machine.wait_for_unit("multi-user.target")
        machine.wait_for_unit("home-manager-" + USER + ".service")
        machine.wait_for_unit("probe-page.service")
        machine.wait_until_succeeds("curl -sf http://127.0.0.1:8099/probe.html | grep -q probe-ok", timeout=30)

        # The user's runtime directory: the wrapper must stay out of it, so the
        # probe sets XDG_RUNTIME_DIR as a session does, and TMPDIR is unset, as
        # it is in one (the launch then goes to /tmp).
        uid = machine.succeed("id -u " + USER).strip()
        runtime = "/run/user/" + uid
        machine.succeed("loginctl enable-linger " + USER)
        machine.wait_for_unit("user@" + uid + ".service")
        # PUPPETEER_DANGEROUS_NO_SANDBOX is what a shell rc written for another
        # project may export: Puppeteer then starts the browser with
        # --no-sandbox. The wrapper unsets it, so every probe below runs with
        # it set and the check of the browser's sandbox sees through it.
        env = "env -u TMPDIR XDG_RUNTIME_DIR=" + runtime + " PUPPETEER_DANGEROUS_NO_SANDBOX=true CHROME_DEVEL_SANDBOX=/nowhere/chrome-sandbox "

        with subtest("the server is in ~/.claude.json as the wrapper, by its store path"):
            entry = json.loads(machine.succeed("jq -c '.mcpServers[\"chrome-devtools\"]' " + HOME + "/.claude.json"))
            assert entry["type"] == "stdio", entry
            assert entry["command"].startswith("/nix/store/") and entry["command"].endswith("/bin/chrome-devtools-mcp-helium"), entry
            on_path = as_user(machine, "readlink -f $(command -v chrome-devtools-mcp-helium)").strip()
            assert on_path == machine.succeed("readlink -f " + entry["command"]).strip(), (on_path, entry)

        if display:
            with subtest("the desktop's session asks Helium for Wayland, and a compositor runs"):
                assert as_user(machine, "echo $NIXOS_OZONE_WL").strip() == "1"
                machine.succeed(
                    "systemd-run --unit=sway-headless --uid=" + USER
                    + " -E XDG_RUNTIME_DIR=" + runtime
                    + " -E WLR_BACKENDS=headless -E WLR_LIBINPUT_NO_DEVICES=1"
                    + " -E WLR_RENDERER=pixman -E LIBSEAT_BACKEND=noop"
                    + " /run/current-system/sw/bin/sway --config " + SWAY_CONFIG
                )
                machine.wait_until_succeeds("test -S " + runtime + "/wayland-1", timeout=60)
                sock = machine.succeed("ls " + runtime + "/sway-ipc.*.sock").strip()
                env += "WAYLAND_DISPLAY=wayland-1 NIXOS_OZONE_WL=1 SWAYSOCK=" + sock + " "
        else:
            with subtest("the server shape has no display and no desktop"):
                login_env = as_user(machine, "env").splitlines()
                # (The test driver exports DISPLAY=:0.0 in every profile,
                # nixos/modules/testing/test-instrumentation.nix; nothing
                # listens there, which is the case the server is in.)
                for name in ["WAYLAND_DISPLAY", "NIXOS_OZONE_WL"]:
                    assert not any(l.startswith(name + "=") for l in login_env), name + " is set on the server"
                machine.fail("test -e /run/current-system/sw/bin/sway")
                machine.fail("ls " + runtime + "/wayland-* /tmp/.X11-unix/X* 2>/dev/null | grep .")
                machine.fail("pgrep -x 'sway|Xorg|Xwayland'")
            with subtest("Helium is the browser of the wrapper and nothing else"):
                machine.fail("su - " + USER + " -c 'command -v helium'")
                machine.fail("ls /run/current-system/sw/share/applications/helium.desktop")
                machine.fail("ls /etc/profiles/per-user/" + USER + "/share/applications/helium.desktop")

        def clients(n):
            # A window of the compositor is a node with a process id.
            own = [n] if n.get("pid") else []
            return own + [c for k in ("nodes", "floating_nodes") for child in n.get(k, []) for c in clients(child)]

        if display:
            with subtest("control: a Helium that is not headless does open a window on the display"):
                # Without this, "no window opened" below could hold for any browser.
                machine.succeed(
                    "systemd-run --unit=helium-window --uid=" + USER
                    + " -E XDG_RUNTIME_DIR=" + runtime + " -E WAYLAND_DISPLAY=wayland-1 -E HOME=" + HOME
                    + " -E NIXOS_OZONE_WL=1 /run/current-system/sw/bin/helium"
                    + " --user-data-dir=/tmp/window-profile --no-first-run --disable-gpu --ozone-platform=wayland about:blank"
                )
                machine.wait_until_succeeds(
                    "su - " + USER + " -c " + shlex.quote("SWAYSOCK=" + sock + " swaymsg -t get_tree | jq -e '[.. | .pid? // empty | select(. > 0)] | length > 0'"),
                    timeout=60,
                )
                machine.succeed("systemctl stop helium-window.service")
                machine.wait_until_succeeds("! pgrep -u " + USER + " -f window-profile", timeout=30)
                machine.succeed("rm -r /tmp/window-profile")

        tree = "swaymsg -t get_tree" if display else "true"
        prefs = "jq -c '.extensions.settings' /tmp/cdh.*/profile/Default/Preferences"
        probe_browser = "${inspect}/bin/inspect-browser"
        refused = "Access denied"

        with subtest("navigate_page right after the launch succeeds, and the profile has uBO off"):
            account, err = run_probe(
                machine, "navigate",
                "--first navigate_page"
                + " --call " + shlex.quote('take_screenshot={"filePath": "{t}/inside.png"}')
                + " --call " + shlex.quote('take_screenshot={"filePath": "' + runtime + '/outside.png"}')
                + " --call " + shlex.quote('take_screenshot={"filePath": "/tmp/outside.png"}')
                + " --exec " + shlex.quote("ls -d /tmp/cdh.*/profile /tmp/cdh.*/t")
                + " --exec " + shlex.quote(prefs)
                + " --exec " + shlex.quote(tree)
                + " --exec " + shlex.quote(probe_browser)
                + " --exec " + shlex.quote("ls /tmp/cdh.*/t"),
                env,
            )
            check_page(account, "navigate_page")
            dirs, settings, windows, browser, tmp_files = account["exec"]
            assert dirs["status"] == 0 and len(dirs["stdout"].split()) == 2, dirs
            assert json.loads(settings["stdout"])[UBO]["disable_reasons"] == [1], settings
            if display:
                # A window of the browser would be a node with a process id.
                nodes = json.loads(windows["stdout"])

                assert clients(nodes) == [], "a window opened on the display: " + str(clients(nodes))
            for notice in ["Google collects usage statistics", "send trace URLs to the Google CrUX API"]:
                assert notice not in err, "the server printed its Google notice: " + err

            # The server's file tools: the TMPDIR of the launch is their root,
            # and neither the runtime directory nor /tmp itself is one.
            inside, outside_runtime, outside_tmp = account["calls"]
            assert not inside["isError"], "a file in the launch's TMPDIR was refused: " + inside["text"]
            assert "inside.png" in tmp_files["stdout"], "the screenshot is not in the launch's TMPDIR: " + tmp_files["stdout"]
            assert outside_runtime["isError"] and refused in outside_runtime["text"], "a file in the runtime directory was accepted: " + str(outside_runtime)
            assert outside_tmp["isError"] and refused in outside_tmp["text"], "a file in /tmp was accepted: " + str(outside_tmp)
            machine.fail("ls " + runtime + "/outside.png /tmp/outside.png")

            # The browser: its TMPDIR is the launch's, it runs with its sandbox,
            # and it talks over a pipe, with no port.
            f = facts(account, 3)
            assert f["main"], "no browser process was found: " + str(f)
            assert f["browser_TMPDIR"].startswith("/tmp/cdh.") and f["browser_TMPDIR"].endswith("/t"), f
            assert f["debug_pipe"] != "0" and f["debug_port"] == "0", f
            assert f["no_sandbox"] == "0", "the browser runs with --no-sandbox: " + str(f)
            assert int(f["renderers"]) >= 1 and f["unsandboxed"] == "0", "a renderer runs without seccomp: " + str(f)
            assert f["listening"] == "0", "the browser listens on a TCP port: " + str(f)
            assert f["runtime_hits"] == "0", "the runtime directory holds files of the launch: " + str(f)
            print("the browser: " + json.dumps(f, sort_keys=True))
            print("the file tools: " + json.dumps([c["text"][:120] for c in account["calls"]]))

            assert account["exit"]["how"] == "stdin-closed" and account["exit"]["code"] == 0, account["exit"]
            assert_clean(machine, "/tmp")
            machine.succeed("test -z \"$(find " + runtime + " -maxdepth 3 \\( -name 'cdh.*' -o -name 'chrome-devtools-mcp*' \\) )\"")

        with subtest("new_page right after the launch succeeds"):
            account, err = run_probe(machine, "newpage", "--first new_page", env)
            check_page(account, "new_page")
            assert_clean(machine, "/tmp")

        with subtest("a server that has to be stopped with SIGTERM leaves nothing behind"):
            account, err = run_probe(machine, "sigterm", "--first navigate_page --stop sigterm", env)
            check_page(account, "sigterm")
            assert account["exit"]["how"] == "sigterm", account["exit"]
            assert_clean(machine, "/tmp")

        with subtest("a short TMPDIR that is set is used"):
            as_user(machine, "mkdir -p /tmp/tt")
            account, err = run_probe(
                machine, "shorttmp",
                "--first navigate_page --launch-base /tmp/tt"
                + " --call " + shlex.quote('take_screenshot={"filePath": "{t}/inside.png"}')
                + " --exec " + shlex.quote("ls -d /tmp/tt/cdh.*/t"),
                env + "TMPDIR=/tmp/tt ",
            )
            check_page(account, "TMPDIR=/tmp/tt")
            assert account["exec"][0]["status"] == 0, account["exec"]
            assert not account["calls"][0]["isError"], account["calls"]
            assert "not using" not in err, err
            assert_clean(machine, "/tmp/tt")
            assert_clean(machine, "/tmp")
            machine.succeed("rmdir /tmp/tt")

        with subtest("a TMPDIR of 40 bytes, the longest accepted, works with the real browser, even with a 7-digit PID"):
            # The 40 bytes leave room for a PID of 7 digits in the name of the
            # launch (cdh.PID.XXXXXX/t), as a host that has been up for weeks
            # has. The VM's PIDs are small, so the next one is set to 1999990.
            edge = "/tmp/" + "e" * 35
            assert len(edge.encode()) == 40, edge
            as_user(machine, "mkdir -p " + edge)
            if int(machine.succeed("cat /proc/sys/kernel/pid_max")) < 2000000:
                machine.succeed("echo 4194304 > /proc/sys/kernel/pid_max")
            machine.succeed("echo 1999989 > /proc/sys/kernel/ns_last_pid")
            account, err = run_probe(
                machine, "edgetmp",
                "--first navigate_page --exec " + shlex.quote("ls -d " + edge + "/cdh.*"),
                env + "TMPDIR=" + edge + " ",
            )
            check_page(account, "TMPDIR of 40 bytes")
            assert "not using" not in err, err
            name = account["exec"][0]["stdout"].strip()
            assert re.fullmatch(re.escape(edge) + r"/cdh\.\d{7}\.[A-Za-z0-9]{6}", name), "the PID is not 7 digits: " + name
            assert_clean(machine, edge)
            machine.succeed("rmdir " + edge)

        with subtest("a TMPDIR too long for Chromium's singleton socket is passed over"):
            long_dir = "/tmp/" + "x" * 120
            as_user(machine, "mkdir -p " + long_dir)
            account, err = run_probe(machine, "longtmp", "--first navigate_page", env + "TMPDIR=" + long_dir + " ")
            check_page(account, "long TMPDIR")
            assert "not using TMPDIR=" in err, err
            assert_clean(machine, long_dir)
            assert_clean(machine, "/tmp")
            machine.succeed("rmdir " + long_dir)

        with subtest("a TMPDIR inside the runtime directory is passed over"):
            as_user(machine, "mkdir -p " + runtime + "/tt")
            account, err = run_probe(machine, "runtimetmp", "--first navigate_page", env + "TMPDIR=" + runtime + "/tt ")
            check_page(account, "TMPDIR in the runtime directory")
            assert "runtime directory" in err, err
            machine.succeed("test -z \"$(ls -A " + runtime + "/tt)\"")
            assert_clean(machine, "/tmp")
            machine.succeed("rmdir " + runtime + "/tt")

        with subtest("several launches in a row all navigate"):
            for n in range(3):
                account, err = run_probe(machine, "again" + str(n), "--first navigate_page", env)
                check_page(account, "launch " + str(n + 1))
            assert_clean(machine, "/tmp")

        with subtest("a killed wrapper's launch is removed by the next launch"):
            # Stands in for a wrapper that was killed: a launch of a PID that is gone.
            as_user(machine, "mkdir -p /tmp/cdh.999999.ABCDEF/profile/Default /tmp/cdh.999999.ABCDEF/t")
            account, err = run_probe(machine, "sweep", "--first navigate_page", env)
            check_page(account, "after a killed wrapper")
            assert_clean(machine, "/tmp")


    desktop.start()
    check_server(desktop, True)
    desktop.shutdown()

    server.start()
    check_server(server, False)
    server.shutdown()
  '';
}
