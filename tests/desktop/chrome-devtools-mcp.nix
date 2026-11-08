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
#   - no profile directory and no browser process is left behind, whether the
#     server ends by its stdin closing or by SIGTERM, which is how Claude Code
#     stops a server;
#   - the server asks Google for nothing (the usage statistics and CrUX
#     notices of the server are absent), and the browser runs headless: on the
#     desktop no window appears in the compositor, and the environment the
#     desktop module sets for Wayland (NIXOS_OZONE_WL, which makes Helium ask
#     for a Wayland display) does not matter;
#   - a TMPDIR that is too long for Chromium's singleton socket, as one under
#     a deep directory is, still works, because the wrapper passes it over;
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
        """Neither a profile nor a process of the wrapper, or the browser it started, is left."""
        machine.wait_until_succeeds("! pgrep -u " + USER + " -f chrome-devtools-helium", timeout=30)
        left = machine.succeed("ls -d " + where + "/chrome-devtools-helium.* 2>/dev/null || true").strip()
        assert not left, "profile directories are left behind: " + left


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

        # The user's runtime directory, where the wrapper puts the profile when
        # TMPDIR is unset, as it is in a session.
        uid = machine.succeed("id -u " + USER).strip()
        runtime = "/run/user/" + uid
        machine.succeed("loginctl enable-linger " + USER)
        machine.wait_for_unit("user@" + uid + ".service")
        env = "env XDG_RUNTIME_DIR=" + runtime + " "

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
        ls_profile = 'ls -d "$XDG_RUNTIME_DIR"/chrome-devtools-helium.*'
        prefs = "jq -c '.extensions.settings' \"$XDG_RUNTIME_DIR\"/chrome-devtools-helium.*/Default/Preferences"

        with subtest("navigate_page right after the launch succeeds, and the profile has uBO off"):
            account, err = run_probe(
                machine, "navigate",
                "--first navigate_page --exec " + shlex.quote(ls_profile) + " --exec " + shlex.quote(prefs) + " --exec " + shlex.quote(tree),
                env,
            )
            check_page(account, "navigate_page")
            profile, settings, windows = account["exec"]
            assert profile["status"] == 0 and profile["stdout"].count("chrome-devtools-helium.") == 1, profile
            assert profile["stdout"].startswith(runtime + "/"), "the profile is not in the runtime directory: " + profile["stdout"]
            assert json.loads(settings["stdout"])[UBO]["disable_reasons"] == [1], settings
            if display:
                # A window of the browser would be a node with a process id.
                nodes = json.loads(windows["stdout"])

                assert clients(nodes) == [], "a window opened on the display: " + str(clients(nodes))
            for notice in ["Google collects usage statistics", "send trace URLs to the Google CrUX API"]:
                assert notice not in err, "the server printed its Google notice: " + err
            assert account["exit"]["how"] == "stdin-closed" and account["exit"]["code"] == 0, account["exit"]
            assert_clean(machine, runtime)

        with subtest("new_page right after the launch succeeds"):
            account, err = run_probe(machine, "newpage", "--first new_page", env)
            check_page(account, "new_page")
            assert_clean(machine, runtime)

        with subtest("a server that has to be stopped with SIGTERM leaves nothing behind"):
            account, err = run_probe(machine, "sigterm", "--first navigate_page --stop sigterm", env)
            check_page(account, "sigterm")
            assert account["exit"]["how"] == "sigterm", account["exit"]
            assert_clean(machine, runtime)

        with subtest("a short TMPDIR that is set is used"):
            account, err = run_probe(
                machine, "shorttmp",
                "--first navigate_page --exec " + shlex.quote("ls -d /tmp/chrome-devtools-helium.*"),
                env + "TMPDIR=/tmp ",
            )
            check_page(account, "TMPDIR=/tmp")
            assert account["exec"][0]["status"] == 0, account["exec"]
            assert_clean(machine, "/tmp")

        with subtest("a TMPDIR too long for Chromium's singleton socket is passed over"):
            long_dir = "/tmp/" + "x" * 120
            machine.succeed("install -d -o " + USER + " " + long_dir)
            account, err = run_probe(machine, "longtmp", "--first navigate_page", env + "TMPDIR=" + long_dir + " ")
            check_page(account, "long TMPDIR")
            assert "not using TMPDIR=" in err, err
            assert_clean(machine, long_dir)
            assert_clean(machine, runtime)
            machine.succeed("rmdir " + long_dir)

        with subtest("several launches in a row all navigate"):
            for n in range(3):
                account, err = run_probe(machine, "again" + str(n), "--first navigate_page", env)
                check_page(account, "launch " + str(n + 1))
            assert_clean(machine, runtime)

        with subtest("a killed wrapper's profile is removed by the next launch"):
            # Stands in for a wrapper that was killed: a profile of a PID that is gone.
            as_user(machine, "mkdir -p " + runtime + "/chrome-devtools-helium.999999.ABCDEF/Default")
            account, err = run_probe(machine, "sweep", "--first navigate_page", env)
            check_page(account, "after a killed wrapper")
            assert_clean(machine, runtime)


    desktop.start()
    check_server(desktop, True)
    desktop.shutdown()

    server.start()
    check_server(server, False)
    server.shutdown()
  '';
}
