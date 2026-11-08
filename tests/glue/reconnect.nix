# The two terminal keys and the main connection, in two VMs (Review Focus
# 1): huginn is the laptop as a user sees it, Sway with the desktop and the
# glue, logged in through the greeter; muninn is the server shape, whose
# herdr server runs from boot.
#
#   - The main key ($mod+Return) opens herdr on muninn: what is typed on
#     huginn reaches a pane there, and every window of it shows the one
#     session of muninn's herdr server.
#   - A killed TCP connection, an IP change of huginn, and a suspend of
#     huginn's VM for 60 s: each time, with no key pressed, herdr attaches
#     again by itself, and within 10 s the window shows the session as it
#     is now: the line a program in the pane printed before the drop, and
#     the one it printed after it, while huginn was away. Only then is
#     anything typed, and it reaches the same pane, run by the same shell;
#     muninn still has exactly one herdr session, served by the same server
#     process.
#   - The main connection forwards the glue's sockets, the link's and the
#     security key agent's, to muninn's runtime directory, and has them
#     there again after each of those, as one connection.
#   - Text that a program in a remote pane copies with OSC 52 lands in
#     huginn's clipboard (wl-paste).
#   - A detach (prefix+d) closes the window and leaves the session.
#   - The second key ($mod+Alt+Return) opens a bash on huginn itself.
#
# What the window shows is read from ghostty itself: a key that ghostty
# takes (write_screen_file, bound in the test node only) writes the screen
# into a file and its path into the clipboard. herdr never sees that key, so
# reading the screen is no input that could make herdr attach or draw. The
# time limit is measured from the drop (for the suspend, from the moment
# huginn runs again) to the moment the window shows the new line, by a
# clock of the driver; nothing waits a fixed time for something to happen.
# Keys are typed in the layout of the Sway config, German, so the typed
# words are letters other than y and z.
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
  password = "correct horse staple";
  snakeoil = import "${pkgs.path}/nixos/tests/ssh-keys.nix" pkgs;
  token = "ravnix-osc52-from-muninn";

  # A key for the stand-in of the security key agent, made for this test.
  keys = pkgs.runCommand "reconnect-test-keys" { nativeBuildInputs = [ pkgs.openssh ]; } ''
    mkdir "$out"
    ssh-keygen -q -t ed25519 -N "" -C reconnect-agent -f "$out/agent"
  '';

  # On muninn, run in a pane: `marker` writes down which pane and which
  # shell ran it, `clipmark` copies the token with OSC 52.
  marker = pkgs.writeShellScriptBin "marker" ''
    printf '%s %s\n' "$HERDR_PANE_ID" "$PPID" >>"$HOME/marks"
  '';
  # `screenmark` prints one line, waits until the test lets it go, which the
  # test does once huginn has dropped the connection, and prints another.
  screenmark = pkgs.writeShellScriptBin "screenmark" ''
    n=$(( $(cat "$HOME/screen-n" 2>/dev/null || echo 0) + 1 ))
    printf '%s\n' "$n" >"$HOME/screen-n"
    printf 'ravnix-before-%s\n' "$n"
    : >"$HOME/screen-waiting-$n"
    while [ ! -e "$HOME/screen-release-$n" ]; do ${pkgs.coreutils}/bin/sleep 0.2; done
    printf 'ravnix-after-%s\n' "$n"
    : >"$HOME/screen-done-$n"
  '';
  clipmark = pkgs.writeShellScriptBin "clipmark" ''
    printf '\033]52;c;%s\007' "$(printf %s ${token} | ${pkgs.coreutils}/bin/base64 -w0)"
    printf '%s\n' copied >>"$HOME/clipmarks"
  '';
  # On huginn, run in the second key's window: where it runs, and in what.
  localmark = pkgs.writeShellScriptBin "localmark" ''
    printf '%s %s\n' "$(${pkgs.hostname}/bin/hostname)" "$(${pkgs.procps}/bin/ps -o comm= -p "$PPID")" >"$HOME/localmark"
  '';
  # The link daemon's xdg-open on huginn writes down what it was given.
  xdgOpen = pkgs.writeShellScript "xdg-open" ''
    printf '%s\n' "$*" >>"$HOME/opened"
  '';

  common = {
    imports = [ ../../templates/default/me.nix ];
    warnings = lib.mkForce [ ];
    ravnix.editor.languages = lib.mkForce [ "nix" ];
    # The security key agent of the template would load handles this test
    # does not have; a stand-in agent listens on its socket instead.
    ravnix.skAgent.keys = lib.mkForce [ ];
    ravnix.skAgent.hosts = lib.mkForce [ ];
    ravnix.serverAccess = {
      identityFile = lib.mkForce "${home}/.ssh/ravnix-server";
      publicKey = lib.mkForce snakeoil.snakeOilEd25519PublicKey;
      hostKey = lib.mkForce snakeoil.snakeOilPublicKey;
    };
    system.stateVersion = "26.05";
  };
in
pkgs.testers.runNixOSTest {
  name = "glue-reconnect";

  # As tests/desktop/sway.nix: the overlay and the desktop's unfree names.
  node.pkgs = lib.mkForce (
    import pkgs.path {
      system = pkgs.stdenv.hostPlatform.system;
      config.allowUnfreePredicate = (import ../../lib/unfree.nix { inherit lib; }).predicate { };
      overlays = [ self.overlays.default ];
    }
  );

  nodes.muninn =
    { ... }:
    {
      imports = [
        common
        self.nixosModules.server
      ];
      # The test framework gives root an empty password; the server shape
      # refuses one, and the driver needs none.
      users.users.root.hashedPasswordFile = lib.mkForce null;
      ravnix.server.remoteControlDir = lib.mkForce null;
      ravnix.nextcloud = lib.mkForce null;
      # The host key huginn pins (ravnix.serverAccess.hostKey), a copy with
      # the mode sshd demands.
      environment.etc."ssh/ssh_host_rsa_key" = {
        source = snakeoil.snakeOilPrivateKey;
        mode = "0600";
      };
      services.openssh.hostKeys = lib.mkForce [
        {
          type = "rsa";
          path = "/etc/ssh/ssh_host_rsa_key";
        }
      ];
      environment.systemPackages = [
        marker
        screenmark
        clipmark
      ];
      virtualisation = {
        cores = 2;
        memorySize = 2048;
        diskSize = 4096;
      };
    };

  nodes.huginn =
    { nodes, ... }:
    {
      imports = [
        common
        self.nixosModules.desktop
        self.nixosModules.glue
      ];
      ravnix.shape = "laptop";
      ravnix.server.netbirdAddress = lib.mkForce nodes.muninn.networking.primaryIPAddress;
      # Laptop access asks for NetBird; it has its own test.
      ravnix.laptopAccess.publicKey = lib.mkForce null;
      ravnix.link.programs.xdgOpen = toString xdgOpen;
      users.users.${user}.password = password;
      # Software rendering, in the test node only (tests/desktop/sway.nix).
      environment.sessionVariables = {
        WLR_RENDERER = "pixman";
        WLR_NO_HARDWARE_CURSORS = "1";
      };
      ravnix.desktop.gpu.primary = "0000:00:10.0";
      home-manager.sharedModules = [
        {
          # The browser and the music app of the session layout stay out of
          # the VM: they are not what is tested, and they need memory.
          xdg.dataFile."applications/helium.desktop".text = ''
            [Desktop Entry]
            Type=Application
            Name=Helium
            Exec=true
          '';
          xdg.dataFile."applications/webapp-apple-music.desktop".text = ''
            [Desktop Entry]
            Type=Application
            Name=Apple Music
            Exec=true
          '';
          # The test reads what the focused window shows from ghostty: this
          # key writes the screen into a file and its path into the
          # clipboard, and ghostty takes it, so herdr never sees it.
          programs.ghostty.settings.keybind = [ "ctrl+shift+f9=write_screen_file:copy" ];
        }
      ];
      environment.systemPackages = [
        localmark
        pkgs.openssh
      ];
      virtualisation = {
        qemu.options = [ "-vga none -device virtio-gpu-pci,bus=pcie.0,addr=0x10" ];
        cores = 2;
        memorySize = 3072;
      };
    };

  testScript =
    { nodes, ... }:
    ''
      import json
      import shlex
      import time

      USER = "${user}"
      HOME = "${home}"
      PASSWORD = "${password}"
      TOKEN = "${token}"
      MUNINN_IP = "${nodes.muninn.networking.primaryIPAddress}"
      # The main key's herdr, which ravnix-terminal runs by its store path.
      CLIENTS = "-f '/bin/herdr --remote ravnix-server'"


      def uid(machine):
          return machine.succeed("id -u " + USER).strip()


      def as_user(machine, cmd, check=True):
          env = "export XDG_RUNTIME_DIR=/run/user/" + uid(machine) + " WAYLAND_DISPLAY=wayland-1; "
          script = "su - " + USER + " -c " + shlex.quote(env + cmd)
          return machine.succeed(script) if check else machine.execute(script)


      def diagnose(what):
          print("--- " + what + ": huginn's processes ---")
          print(huginn.execute("ps -eo pid,ppid,user,args --width 250 | grep -v ' \\[' | tail -80")[1])
          print(huginn.execute("journalctl -b --no-pager -o short-monotonic --user-unit ravnix-connection.service | tail -40; journalctl -b --no-pager -o cat | tail -60")[1])
          print("--- " + what + ": muninn ---")
          print(as_user(muninn, "herdr session list; herdr pane list; ss -tnp; cat ~/marks", check=False)[1])
          huginn.screenshot(what.replace(" ", "-"))


      def until(what, condition, timeout=60):
          def check(_last):
              return condition()

          try:
              with huginn.nested("waiting for " + what):
                  retry(check, timeout)
          except Exception:
              diagnose(what)
              raise


      def marks():
          return as_user(muninn, "cat ~/marks 2>/dev/null || true").splitlines()


      def sessions():
          out = as_user(muninn, "herdr session list --json")
          return json.loads(out)["sessions"]


      def herdr_server_pid():
          return as_user(muninn, "systemctl --user show -p MainPID --value herdr-server.service").strip()


      def windows():
          """The terminal windows on huginn's Sway, by their con ids."""
          sock = huginn.succeed("ls /run/user/" + uid(huginn) + "/sway-ipc.*.sock | head -n1").strip()
          tree = json.loads(as_user(huginn, "swaymsg -s " + sock + " -t get_tree"))
          found = set()

          def walk(node):
              if node.get("app_id") == "com.mitchellh.ghostty":
                  found.add(node["id"])
              for child in node.get("nodes", []) + node.get("floating_nodes", []):
                  walk(child)

          walk(tree)
          return found


      def pids(pattern):
          return set(huginn.execute("pgrep -u " + USER + " " + pattern)[1].split())


      def under_main_key(pid):
          """Whether a process descends from the main key's wrapper."""
          while pid not in ("0", "1", ""):
              comm = huginn.succeed("cat /proc/" + pid + "/comm").strip()
              if comm == "ravnix-terminal" or comm == "herdr":
                  return True
              pid = huginn.succeed("awk '{print $4}' /proc/" + pid + "/stat").strip()
          return False


      def screen():
          """What the focused ghostty window shows, as ghostty writes it: a key herdr never sees."""
          as_user(huginn, "wl-copy --clear || true")
          huginn.send_key("ctrl-shift-f9")
          status, text = as_user(
              huginn,
              'for i in $(seq 30); do p=$(timeout 1 wl-paste --no-newline 2>/dev/null) && [ -f "$p" ] && exec cat -- "$p"; sleep 0.1; done; exit 1',
              check=False,
          )
          return text if status == 0 else ""


      def plant():
          """Before a drop: `screenmark` in the main key's pane, its first line on the screen."""
          n = str(int(as_user(muninn, "cat ~/screen-n 2>/dev/null || echo 0").strip()) + 1)
          huginn.send_chars("screenmark\n")
          until("screenmark " + n + " to wait on muninn", lambda: as_user(muninn, "test -e ~/screen-waiting-" + n, check=False)[0] == 0)
          until("ravnix-before-" + n + " in the window", lambda: "ravnix-before-" + n in screen(), 30)
          return n


      def release(n):
          """The pane prints its second line now, whether huginn is there or not."""
          as_user(muninn, "touch ~/screen-release-" + n)
          until("screenmark " + n + " to print its second line", lambda: as_user(muninn, "test -e ~/screen-done-" + n, check=False)[0] == 0)


      def reattached(what, n, since, clients, budget=10):
          """With no key pressed: herdr attaches again by itself, and the window shows the session as it is now."""
          def new_clients():
              now = pids(CLIENTS)
              return len(now) == len(clients) and not (now & clients)

          until(what + ": herdr to attach again by itself", new_clients, budget + 50)
          attached = time.monotonic() - since
          # Past the budget, keep looking a while so a failure says how late it was.
          while time.monotonic() - since < budget + 50:
              text = screen()
              if "ravnix-before-" + n in text and "ravnix-after-" + n in text:
                  took = time.monotonic() - since
                  break
          else:
              diagnose(what)
              raise AssertionError(what + ": the window never showed what the pane printed while huginn was away: " + repr(text))
          print(what + ": herdr ran again after %.1f s, and the window showed the session after %.1f s, with no key pressed" % (attached, took))
          assert took <= budget, what + ": the window showed the session only after %.1f s" % took


      def type_marker_until_seen(what, budget):
          """Type `marker` on huginn until muninn has a new line; return the seconds it took."""
          before = len(marks())
          started = time.monotonic()
          # Past the budget, keep trying a while so a failure says how late it was.
          while time.monotonic() - started < budget + 50:
              huginn.send_chars("marker\n")
              deadline = time.monotonic() + 1.0
              while time.monotonic() < deadline:
                  lines = marks()
                  if len(lines) > before:
                      return time.monotonic() - started, lines[before:]
                  time.sleep(0.2)
          diagnose(what)
          raise AssertionError(what + ": nothing typed on huginn reached muninn")


      def forwarded():
          """The forwards of the main connection answer on muninn, as one connection."""
          run = "/run/user/" + uid(muninn)
          # Until the new forward replaces it, the socket is the one of the
          # dead connection, whose session on muninn takes a connection and
          # answers nothing until sshd ends it (ClientAlive, 30 s): ask
          # again rather than wait.
          held = as_user(muninn, "SSH_AUTH_SOCK=" + run + "/sk-agent.sock timeout 3 ssh-add -L", check=False)
          if held[0] != 0 or "reconnect-agent" not in held[1]:
              return False
          connections = huginn.execute("pgrep -u " + USER + " -f -c '/bin/ssh -N .*ravnix-server$'")[1].strip()
          return connections == "1"


      def link_delivers(n):
          target = "https://example.org/forward-" + str(n)
          as_user(muninn, "ravnix-link open " + target)
          until("the link to deliver " + target, lambda: target in as_user(huginn, "cat ~/opened 2>/dev/null || true"))


      def same_session(what):
          """Once the window shows the session: what is typed reaches the same pane and shell."""
          took, lines = type_marker_until_seen(what, 10)
          print(what + ": typed text reached muninn after %.1f s more" % took)
          assert all(line == FIRST for line in lines), what + ": another pane or shell: " + repr(lines) + " != " + FIRST
          assert len(sessions()) == 1, what + ": " + repr(sessions())
          assert herdr_server_pid() == SERVER, what + ": herdr's server is another process"


      start_all()
      muninn.wait_for_unit("multi-user.target")
      muninn.wait_for_unit("user@" + uid(muninn) + ".service")
      muninn.wait_for_unit("sshd.service")
      as_user(muninn, "systemctl --user is-active herdr-server.service")
      SERVER = herdr_server_pid()

      huginn.wait_for_unit("multi-user.target")
      huginn.wait_for_unit("greetd.service")
      # The key the laptop logs in to the server with, from outside the store.
      as_user(huginn, "install -D -m 600 ${snakeoil.snakeOilEd25519PrivateKey} ~/.ssh/ravnix-server")

      with subtest("logging in on huginn starts the session"):
          huginn.wait_until_tty_matches("1", "Username")
          huginn.send_chars(USER + "\n")
          huginn.wait_until_tty_matches("1", "Password")
          huginn.send_chars(PASSWORD + "\n")
          until("Sway", lambda: huginn.execute("pgrep -u " + USER + " -x sway")[0] == 0, 120)
          huginn.wait_for_file("/run/user/" + uid(huginn) + "/wayland-1")
          # The session layout places what it started and then focuses
          # workspace 2; only then is the focus where a key puts it.
          until(
              "the session layout",
              lambda: "focus -> workspace 2" in as_user(huginn, "cat $XDG_RUNTIME_DIR/sway-session-layout.log 2>/dev/null || true"),
              120,
          )

      with subtest("the main key opens herdr on muninn"):
          before = windows()
          clients = pids(CLIENTS)
          huginn.send_key("meta_l-ret")
          until("a new window of the main key", lambda: len(windows() - before) == 1)
          until("herdr attached from huginn", lambda: len(pids(CLIENTS) - clients) == 1)
          took, lines = type_marker_until_seen("the first attach", 60)
          FIRST = lines[0]
          assert FIRST.startswith("w") and len(FIRST.split()) == 2, FIRST
          print("the main key's window shows pane and shell " + FIRST)
          assert len(sessions()) == 1, sessions()

      with subtest("the main connection forwards the glue's sockets to muninn"):
          as_user(huginn, "ssh-keygen -y -f ${keys}/agent >/dev/null; install -m 600 ${keys}/agent ~/agent-key")
          as_user(huginn, "ssh-agent -a $XDG_RUNTIME_DIR/sk-agent.sock >/dev/null && SSH_AUTH_SOCK=$XDG_RUNTIME_DIR/sk-agent.sock ssh-add -q ~/agent-key")
          until("the forwards on muninn", forwarded)
          run = "/run/user/" + uid(muninn)
          muninn.succeed("test -S " + run + "/ravnix-link.sock && test -S " + run + "/sk-agent.sock")
          # Both are the user's alone.
          for name in ("ravnix-link.sock", "sk-agent.sock"):
              owner = muninn.succeed("stat -c %U:%a " + run + "/" + name).strip()
              assert owner == USER + ":600", name + ": " + owner
          link_delivers(1)

      with subtest("text copied with OSC 52 in the remote pane lands in huginn's clipboard"):
          as_user(huginn, "wl-copy --clear || true")
          clips = len(as_user(muninn, "cat ~/clipmarks 2>/dev/null || true").splitlines())
          huginn.send_chars("clipmark\n")
          until("clipmark to run on muninn", lambda: len(as_user(muninn, "cat ~/clipmarks 2>/dev/null || true").splitlines()) > clips)
          until("the token in huginn's clipboard", lambda: as_user(huginn, "timeout 5 wl-paste --no-newline", check=False)[1] == TOKEN, 30)

      with subtest("a killed TCP connection: the same session within 10 s, with no key pressed"):
          n = plant()
          clients = pids(CLIENTS)
          huginn.succeed("ss -K dst " + MUNINN_IP + " dport = :22")
          since = time.monotonic()
          release(n)
          reattached("after the killed connection", n, since, clients)
          same_session("after the killed connection")
          until("the forwards after the killed connection", forwarded)
          link_delivers(2)

      with subtest("an IP change of huginn: the same session within 10 s, with no key pressed"):
          old = huginn.succeed("ip -4 -o addr show dev eth1 | awk '{print $4}'").strip()
          new = "192.168.1.77/24"
          assert old != new, old
          n = plant()
          clients = pids(CLIENTS)
          huginn.succeed("ip addr add " + new + " dev eth1 && ip addr del " + old + " dev eth1")
          since = time.monotonic()
          release(n)
          reattached("after the IP change", n, since, clients)
          same_session("after the IP change")
          until("the forwards after the IP change", forwarded)
          # The new connections come from the new address.
          muninn.succeed("ss -tn state established '( sport = :22 )' | grep -F 192.168.1.77:")
          link_delivers(3)

      with subtest("huginn suspended for 60 s: the same session within 10 s, with no key pressed"):
          n = plant()
          clients = pids(CLIENTS)
          huginn.send_monitor_command("stop")
          stopped = time.monotonic()
          # While huginn stands still, the pane prints the line the window
          # must show once huginn is back.
          release(n)
          # The driver's clock, not huginn's, which stands still.
          time.sleep(max(0, 60 - (time.monotonic() - stopped)))
          huginn.send_monitor_command("cont")
          since = time.monotonic()
          reattached("after the suspend", n, since, clients)
          same_session("after the suspend")
          until("the forwards after the suspend", forwarded)
          link_delivers(4)

      with subtest("exactly one herdr session, and every window of the main key in it"):
          assert len(sessions()) == 1, sessions()
          assert herdr_server_pid() == SERVER
          clients = len(pids(CLIENTS))
          assert clients == 2, "the main key's windows: " + str(clients)

      with subtest("a detach closes the window and leaves the session"):
          before = windows()
          clients = pids(CLIENTS)
          huginn.send_key("ctrl-b")
          huginn.send_key("d")
          until("the detached window to close", lambda: len(before - windows()) == 1)
          until("its herdr to end", lambda: len(clients - pids(CLIENTS)) == 1)
          assert len(sessions()) == 1, sessions()
          assert herdr_server_pid() == SERVER

      with subtest("the second key opens a bash on huginn"):
          before = windows()
          shells = pids("-x bash")
          huginn.send_key("meta_l-alt-ret")
          until("a new window of the second key", lambda: len(windows() - before) == 1)
          until("a new shell on huginn", lambda: len(pids("-x bash") - shells) >= 1)
          new_shells = pids("-x bash") - shells
          # Nothing in it goes to muninn.
          assert not any(under_main_key(p) for p in new_shells), new_shells

          def answers():
              huginn.send_chars("localmark\n")
              return as_user(huginn, "cat ~/localmark 2>/dev/null || true").strip() == "huginn bash"

          until("the shell to answer", answers, 30)
    '';
}
