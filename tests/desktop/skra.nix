# skrá, the web interface for CUPS (packages/skra, modules/desktop/skra.nix).
# Three parts, all of which must pass:
#
#   1. What the module sets, read from an evaluated host: the socket on
#      127.0.0.1:7631 and nowhere else, the service that it starts (with
#      MemoryMax=100M, Restart=on-failure and NoNewPrivileges, as dist/ of
#      skrá has them), the config.json with the queues of
#      ravnix.printing.printers, the launcher, and what the switch turns off.
#   2. The program, built by the package, run in the sandbox with the very
#      config.json the module writes: it must accept the file (an unknown key
#      is an error), answer on its loopback port, and refuse to listen on
#      anything else. skra has no --help or --version: it starts serving at
#      once, whatever its arguments.
#   3. A VM that runs it as the user's units: the socket is the only listener
#      and starts the service on the first request, the page shows the
#      declared queue read-only, the user holds the CUPS rights and the journal
#      access the CUPS log needs, and the service exits again when idle.
#
# The VM imports common, printing and skra, not nixosModules.desktop: it needs
# no Sway. common brings home-manager, which the units and the config are.
{
  self,
  pkgs,
  lib,
  system,
  inputs,
  ...
}:
let
  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };
  moduleFiles = map (name: ../../modules/desktop + "/${name}.nix") [
    "printing"
    "skra"
  ];
  host =
    extra:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = hostModules ++ [ self.nixosModules.common ] ++ moduleFiles ++ extra;
    };
  plain = host [ ];

  user = (import ../../templates/default/me.nix).ravnix.user.username;
  homeOf = h: h.config.home-manager.users.${user};
  unitsOf = h: (homeOf h).systemd.user;
  socketOf = h: (unitsOf h).sockets.skra;
  serviceOf = h: (unitsOf h).services.skra;
  configOf = h: builtins.fromJSON (builtins.readFile (homeOf h).xdg.configFile."skra/config.json".source);
  configFileOf = h: (homeOf h).xdg.configFile."skra/config.json".source;
  hasConfig = h: (homeOf h).xdg.configFile ? "skra/config.json";

  package = self.packages.${system}.skra;
  off = host [ { ravnix.printing.skra.enable = lib.mkForce false; } ];
  noPrinters = host [ { ravnix.printing.printers = lib.mkForce { }; ravnix.printing.defaultPrinter = lib.mkForce null; } ];
  twoPrinters = host [
    {
      ravnix.printing.printers = lib.mkForce {
        zeta.uri = "ipp://z.example.org/ipp/print";
        alpha.uri = "ipp://a.example.org/ipp/print";
      };
      ravnix.printing.defaultPrinter = lib.mkForce null;
    }
  ];

  list = x: if builtins.isList x then x else [ x ];
  expect = ok: message: lib.optional (!ok) message;
  failures =
    expect (lib.elem (builtins.elemAt moduleFiles 1)
      (import ../../modules/desktop/default.nix { inherit lib; }).imports
    ) "modules/desktop/default.nix does not import modules/desktop/skra.nix"
    # On by default, where printing is.
    # The declared default, not the evaluated value: the template's me.nix
    # sets the option as well, so the value would be true whatever the default.
    ++ expect (
      plain.options.ravnix.printing.skra.enable.default == true
    ) "ravnix.printing.skra.enable is not on by default"
    ++ expect plain.config.ravnix.printing.skra.enable "ravnix.printing.skra.enable is off in the template"
    # The socket: loopback and the one port, never a wildcard.
    ++ expect (
      list (socketOf plain).Socket.ListenStream or [ ] == [ "127.0.0.1:7631" ]
    ) "the socket does not listen on exactly 127.0.0.1:7631: ${builtins.toJSON (socketOf plain).Socket}"
    ++ expect (
      !lib.hasInfix "0.0.0.0" (builtins.toJSON (socketOf plain))
    ) "the socket unit names 0.0.0.0"
    ++ expect (
      (socketOf plain).Install.WantedBy or null == [ "sockets.target" ]
    ) "the socket is not wanted by sockets.target"
    # The service: the package's binary, started by the socket, limited.
    ++ expect (
      list (serviceOf plain).Service.ExecStart or null == [ (lib.getExe package) ]
    ) "the service does not run the package's binary: ${builtins.toJSON ((serviceOf plain).Service.ExecStart or null)}"
    ++ expect (
      !lib.hasInfix ".local/bin" (builtins.toJSON (serviceOf plain))
    ) "the service names ~/.local/bin"
    ++ expect ((serviceOf plain).Service.MemoryMax or null == "100M") "MemoryMax is not 100M"
    ++ expect ((serviceOf plain).Service.Restart or null == "on-failure") "Restart is not on-failure"
    ++ expect ((serviceOf plain).Service.NoNewPrivileges or null == true) "NoNewPrivileges is not set"
    ++ expect ((serviceOf plain).Service.Type or null == "simple") "the service is not Type=simple"
    ++ expect (
      list ((serviceOf plain).Unit.Requires or null) == [ "skra.socket" ]
      && list ((serviceOf plain).Unit.After or null) == [ "skra.socket" ]
    ) "the service does not require and follow skra.socket"
    # Only the socket is started: the service has no Install section, so no
    # login starts it and nothing runs while the page is closed.
    ++ expect (
      !((serviceOf plain) ? Install) || (serviceOf plain).Install == { }
    ) "the service has an Install section, so it would start without a request"
    # The config holds what NixOS knows, and nothing else.
    ++ expect (hasConfig plain) "no ~/.config/skra/config.json"
    ++ expect (configOf plain == {
      declared_queues = [ "office" ];
      cupsd_conf_managed = true;
    }) "config.json is not the template's queue and cupsd_conf_managed: ${builtins.toJSON (configOf plain)}"
    ++ expect (
      (configOf twoPrinters).declared_queues == [
        "alpha"
        "zeta"
      ]
    ) "declared_queues is not the sorted queue names of ravnix.printing.printers"
    ++ expect (
      (configOf noPrinters).declared_queues == [ ]
    ) "declared_queues is not empty for a host with no printers"
    # idle_exit, listen and the CUPS socket are skrá's own defaults.
    ++ expect (
      !(lib.any (k: configOf plain ? ${k}) [
        "listen"
        "idle_exit"
        "cups_socket"
        "user"
        "state_dir"
      ])
    ) "config.json sets a key that skrá's default (or the socket unit) decides"
    # The launcher.
    ++ expect (
      lib.elem "skra.desktop" (map lib.getName plain.config.environment.systemPackages)
    ) "no skra launcher in the system profile"
    # The switch turns all of it off.
    ++ expect (
      !(hasConfig off) && !((unitsOf off).sockets ? skra) && !((unitsOf off).services ? skra)
    ) "ravnix.printing.skra.enable = false leaves the units or the config"
    ++ expect (
      !(lib.elem "skra.desktop" (map lib.getName off.config.environment.systemPackages))
    ) "ravnix.printing.skra.enable = false leaves the launcher";

  # --- the program ---------------------------------------------------------

  # The sandbox has a loopback of its own, so the default port is free.
  smoke =
    pkgs.runCommand "desktop-skra-smoke"
      {
        nativeBuildInputs = [
          package
          pkgs.curl
          pkgs.go
        ];
        config = configFileOf plain;
        launcher = lib.findFirst (p: lib.getName p == "skra.desktop") null plain.config.environment.systemPackages;
      }
      ''
        failed=0
        fail() { printf 'FAIL: %s\n' "$*" >&2; failed=1; }

        # The launcher, line by line as tests/desktop/webapps.nix reads its own.
        file=$launcher/share/applications/skra.desktop
        want() { grep -qxF -- "$1" "$file" || fail "skra.desktop lacks the line $1"; }
        want "Type=Application"
        want "Name=skrá"
        want "Exec=helium --app=http://127.0.0.1:7631/"
        want "StartupWMClass=chrome-127.0.0.1__-Default"
        want "Terminal=false"
        want "StartupNotify=true"
        grep -q '^Icon=.' "$file" || fail "skra.desktop has no icon"
        if grep '^Exec=' "$file" | sed 's/%%//g' | grep -q '%'; then fail "skra.desktop has a field code in Exec"; fi

        # cgo stays on, as in upstream's `go build`. Without it Go's resolver
        # never asks nss, so a printer's .local name (nss-mdns, printing.nix)
        # does not resolve and its ink levels are missing.
        go version -m "$(command -v skra)" | grep -qF 'build	CGO_ENABLED=1' ||
          fail "skra is built without cgo: $(go version -m "$(command -v skra)" | grep CGO || echo 'no CGO_ENABLED line')"

        [ "$failed" = 0 ] || exit 1

        export HOME=$TMPDIR/home USER=tester
        mkdir -p "$HOME/.config/skra"
        install -m 0644 "$config" "$HOME/.config/skra/config.json"
        # The config is read from here, as the user's service reads it.
        unset XDG_CONFIG_HOME

        skra >"$TMPDIR/log" 2>&1 &
        pid=$!
        trap 'kill $pid 2>/dev/null || true' EXIT
        for _ in $(seq 100); do
          curl -fs -o "$TMPDIR/page" http://127.0.0.1:7631/ && break
          kill -0 $pid 2>/dev/null || { cat "$TMPDIR/log" >&2; echo "skra exited" >&2; exit 1; }
          sleep 0.1
        done
        [ -s "$TMPDIR/page" ] || { cat "$TMPDIR/log" >&2; echo "no page" >&2; exit 1; }
        grep -qi 'skr' "$TMPDIR/page"
        # Not socket activated, so it stays up and says so.
        grep -q 'socket-activated: false' "$TMPDIR/log"
        # A wrong Host is refused (DNS rebinding).
        code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.example:7631' http://127.0.0.1:7631/)
        [ "$code" = 403 ] || { echo "a foreign Host got $code, not 403" >&2; exit 1; }
        kill $pid; wait $pid || true
        trap - EXIT

        # It refuses to listen beyond the loopback.
        echo '{"listen": "0.0.0.0:7631"}' >"$HOME/.config/skra/config.json"
        if skra >"$TMPDIR/wild" 2>&1; then
          echo "skra started on 0.0.0.0" >&2; exit 1
        fi
        grep -q 'not allowed' "$TMPDIR/wild"
        touch $out
      '';

  # --- the VM --------------------------------------------------------------

  vm = pkgs.testers.runNixOSTest {
    name = "desktop-skra";

    node.pkgs = lib.mkForce (pkgs.extend self.overlays.default);

    nodes.machine =
      { pkgs, ... }:
      {
        imports = [ ../../templates/default/me.nix ] ++ [ self.nixosModules.common ] ++ moduleFiles;
        warnings = lib.mkForce [ ];
        ravnix.shape = "laptop";
        # One queue, a raw one on a socket nobody listens on: CUPS holds the
        # job, and the queue exists, which is all the page needs.
        ravnix.printing = {
          printers = lib.mkForce {
            desk = {
              uri = "socket://127.0.0.1:9100";
              model = "raw";
            };
          };
          defaultPrinter = lib.mkForce "desk";
        };
        # The user manager runs while someone is logged in; here nobody is.
        users.users.${user}.linger = true;
        # An interface of the test (see the .local subtest) that avahi leaves be.
        services.avahi.denyInterfaces = [ "dum0" ];
        environment.systemPackages = [
          pkgs.curl
          pkgs.avahi
          pkgs.iproute2
        ];
        virtualisation.memorySize = 2048;
        system.stateVersion = "26.05";
      };

    testScript = ''
      import shlex

      USER = "${user}"

      def as_user(cmd, check=True):
        script = "su - " + USER + " -c " + shlex.quote("export XDG_RUNTIME_DIR=/run/user/$(id -u); " + cmd)
        return machine.succeed(script) if check else machine.execute(script)

      machine.wait_for_unit("multi-user.target")
      machine.wait_for_unit("home-manager-" + USER + ".service")
      uid = machine.succeed("id -u " + USER).strip()
      machine.wait_for_unit("user@" + uid + ".service")
      machine.wait_for_unit("cups.service")
      machine.wait_until_succeeds("lpstat -p desk")

      with subtest("only the socket is started, on the loopback"):
        as_user("systemctl --user is-active skra.socket")
        status, _ = as_user("systemctl --user is-active skra.service", check=False)
        assert status != 0, "skra.service runs with no request made"
        listeners = machine.succeed("ss -Hltn 'sport = :7631'")
        assert "127.0.0.1:7631" in listeners, listeners
        assert "0.0.0.0:7631" not in listeners and "*:7631" not in listeners and "[::]:7631" not in listeners, listeners
        assert len(listeners.strip().splitlines()) == 1, listeners

      with subtest("the first request starts the service, and the page is there"):
        page = as_user("curl -fsS http://127.0.0.1:7631/")
        assert "skr" in page, page[:300]
        as_user("systemctl --user is-active skra.service")
        assert as_user("systemctl --user show -p MemoryMax --value skra.service").strip() == str(100 * 1024 * 1024)
        assert as_user("systemctl --user show -p NoNewPrivileges --value skra.service").strip() == "yes"
        assert as_user("systemctl --user show -p Restart --value skra.service").strip() == "on-failure"

      with subtest("the config is the one the module wrote, and the queue is declared"):
        cfg = as_user("cat ~/.config/skra/config.json")
        assert '"desk"' in cfg and "cupsd_conf_managed" in cfg, cfg
        printers = as_user("curl -fsS http://127.0.0.1:7631/printers")
        assert "desk" in printers and "declared in ravnix" in printers, printers

      with subtest("the user holds the CUPS admin rights that skra uses"):
        groups = machine.succeed("id -nG " + USER).split()
        assert "wheel" in groups, groups
        # SystemGroup is a cups-files.conf directive; the files are links.
        conf = machine.succeed("grep -RhE '^SystemGroup' /etc/cups/")
        assert "wheel" in conf.split(), conf
        # What skra does over cups.sock, as the user and without a password.
        as_user("lpadmin -p vmcheck -E -v socket://127.0.0.1:9 -m raw")
        as_user("lpadmin -x vmcheck")
        # A user outside wheel and lpadmin has none of it: the control.
        status, out = machine.execute("su -s ${pkgs.runtimeShell} nobody -c 'lpadmin -p vmnope -E -v socket://127.0.0.1:9 -m raw' 2>&1")
        assert status != 0, "a user outside wheel may administer CUPS: " + out
        machine.fail("lpstat -p vmnope")

      with subtest("the user may read the CUPS log from the journal"):
        out = as_user("journalctl -u cups.service --no-pager -n 20 2>&1")
        assert "not seeing messages" not in out and "insufficient" not in out and "No journal files" not in out, out
        # The control: a user outside wheel, adm and systemd-journal is told so.
        status, out = machine.execute("su -s ${pkgs.runtimeShell} nobody -c 'journalctl -u cups.service --no-pager -n 20' 2>&1")
        assert "not seeing messages" in out or "insufficient" in out or "No journal files" in out, out

      with subtest("a write needs the token, and skra acts as the user"):
        base = "http://127.0.0.1:7631"
        post = lambda path, extra="": as_user("curl -s -o /dev/null -w '%{http_code}' -X POST " + extra + " " + base + path).strip()
        assert post("/printers/desk/pause") == "403", "a write with no token got through"
        assert post("/printers/desk/pause", "-H 'X-Skra-Token: wrong'") == "403"
        token = as_user("cat ~/.local/state/skra/token").strip()
        header = "-H 'X-Skra-Token: " + token + "'"
        # With the token, skra pauses the queue in CUPS as the user (PeerCred).
        assert post("/printers/desk/pause", header) == "200"
        machine.succeed("lpstat -p desk | grep -qi disabled")
        assert post("/printers/desk/resume", header) == "200"
        machine.fail("lpstat -p desk | grep -qi disabled")
        # The declared queue cannot be removed from the page.
        assert post("/printers/desk/delete", header) == "403"
        machine.succeed("lpstat -p desk")

      with subtest("skra shows the CUPS log through the journal"):
        log = as_user("curl -fsS http://127.0.0.1:7631/printers/log")
        # The lines of cups.service itself, from the journal as the user.
        assert "Starting CUPS Scheduler" in log and "cupsd[" in log, log[:1500]

      with subtest("a .local name resolves through nss-mdns inside skra"):
        # An address of this machine, published by avahi under a name nothing
        # else knows. skra's add page resolves the host of an address and
        # refuses one that is this machine's own CUPS: it can only say so when
        # the name resolved, which Go's own resolver (no cgo) cannot do for
        # .local, and which the user's printers need for their ink levels.
        # The address is on a dummy interface that avahi ignores: avahi refuses
        # to publish an address of an interface it serves under another name
        # ("Local name collision").
        ip = "192.0.2.77"
        machine.succeed("ip link add dum0 type dummy && ip addr add " + ip + "/32 dev dum0 && ip link set dum0 up")
        machine.succeed("systemd-run --unit=publish-skra-vm avahi-publish -a skra-vm.local " + ip)
        try:
          machine.wait_until_succeeds("getent hosts skra-vm.local | grep -qF " + ip, timeout=30)
        except Exception:
          print(machine.execute("systemctl status publish-skra-vm --no-pager; journalctl -u publish-skra-vm -u avahi-daemon --no-pager | tail -30; grep ^hosts /etc/nsswitch.conf; avahi-resolve -n skra-vm.local; getent hosts skra-vm.local")[1])
          raise
        token = as_user("cat ~/.local/state/skra/token").strip()
        out = as_user("curl -s -X POST -H 'X-Skra-Token: " + token + "' --data-urlencode name=viaMdns --data-urlencode address=ipp://skra-vm.local:631/ipp/print --data-urlencode driver=everywhere http://127.0.0.1:7631/printers/add")
        assert "own CUPS" in out, out
        machine.fail("lpstat -p viaMdns")

      with subtest("the service exits when idle and the socket starts it again"):
        # A second config, for a short idle time, read through the user
        # manager's environment; the module's config.json is not touched.
        machine.succeed("install -d -o " + USER + " /tmp/idle/skra")
        machine.succeed("""printf '{"idle_exit": "3s"}' > /tmp/idle/skra/config.json""")
        as_user("systemctl --user stop skra.service")
        as_user("systemctl --user set-environment XDG_CONFIG_HOME=/tmp/idle")
        as_user("curl -fsS -o /dev/null http://127.0.0.1:7631/")
        as_user("systemctl --user is-active skra.service")
        machine.wait_until_fails("su - " + USER + " -c 'XDG_RUNTIME_DIR=/run/user/" + uid + " systemctl --user is-active skra.service'", timeout=60)
        as_user("systemctl --user is-active skra.socket")
        as_user("curl -fsS -o /dev/null http://127.0.0.1:7631/")
        as_user("systemctl --user is-active skra.service")
        as_user("systemctl --user unset-environment XDG_CONFIG_HOME")
    '';
  };
in
pkgs.runCommand "desktop-skra"
  {
    # The parts, for building one at a time:
    #   nix build .#checks.x86_64-linux.desktop-skra.smoke
    passthru = { inherit smoke vm failures; };
  }
  (
    if failures != [ ] then
      ''
        printf '%s\n' ${lib.escapeShellArgs failures} >&2
        exit 1
      ''
    else
      ''
        # The parts are the inputs: this builds only when each one has passed.
        echo ${smoke} ${vm}
        touch $out
      ''
  )
