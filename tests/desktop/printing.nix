# Printing, scanning, the VPNs and the peripherals of huginn
# (modules/desktop/{printing,vpn,peripherals}.nix, packages/{nord,vpn-home}).
# Three parts, all of which must pass:
#
#   1. What the modules set, read from an evaluated host: CUPS without
#      cups-browsed, sane-airscan and a scan app, NetBird with its firewall
#      ports shut, the nord and vpn-home commands built from the typed
#      options, the udev rules, logiops, and what the options refuse.
#   2. The nord and vpn-home commands against stand-ins for nmcli, curl and
#      rbw (helpers/wrappers.test.bash).
#   3. A VM that runs it: the print queues and a job that reaches a printer,
#      a scan from an eSCL scanner found by DNS-SD, NetBird's config and the
#      firewall, logiops, the udev rules, and `nord setup` and `nord up`
#      against the real NetworkManager.
#
# The VM imports the three modules, not nixosModules.desktop: it needs no
# Sway, and the other modules of the desktop are other tasks' to test.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };
  moduleFiles = map (name: ../../modules/desktop + "/${name}.nix") [
    "printing"
    "vpn"
    "peripherals"
  ];

  # A NixOS host of the three modules, the options and the template's values,
  # evaluated and never built.
  host =
    extra:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules =
        hostModules
        ++ [
          self.nixosModules.options
          { nixpkgs.overlays = [ self.overlays.default ]; }
        ]
        ++ moduleFiles
        ++ extra;
    };
  config = (host [ ]).config;
  failedOf = extra: map (a: a.message) (lib.filter (a: !a.assertion) (host extra).config.assertions);

  packageNames = c: map lib.getName c.environment.systemPackages;
  has = c: name: lib.elem name (packageNames c);
  udevNames = c: map lib.getName c.services.udev.packages;

  # Whether evaluating a value fails, for the values the options refuse.
  refused =
    extra: path:
    !(builtins.tryEval (builtins.deepSeq (lib.attrByPath path null (host extra).config) true)).success;
  managementUrl = url: [ { ravnix.vpn.netbird.managementUrl = lib.mkForce url; } ];
  printerUri = uri: [ { ravnix.printing.printers.odd.uri = uri; } ];
  netbirdConfig =
    url: (host (managementUrl url)).config.services.netbird.clients.default.config.ManagementURL;

  firewall = config.networking.firewall;

  expect = ok: message: lib.optional (!ok) message;
  failures =
    # The module files are found by the desktop's import (lib/import-dir.nix).
    lib.concatMap (
      file:
      expect (lib.elem file
        (import ../../modules/desktop/default.nix { inherit lib; }).imports
      ) "modules/desktop/default.nix does not import ${toString file}"
    ) moduleFiles
    # Printing: CUPS on, cups-browsed off (Fedora's is inactive, and it adds
    # queues of whatever a network announces), local only.
    ++ expect config.services.printing.enable "CUPS is not enabled"
    ++ expect (!config.services.printing.browsed.enable) "cups-browsed is enabled"
    ++ expect (
      config.services.printing.listenAddresses == [ "localhost:631" ]
    ) "CUPS listens beyond localhost"
    ++ expect (!config.services.printing.openFirewall) "CUPS opens its port in the firewall"
    ++ expect config.services.avahi.enable "avahi is off, so no DNS-SD printer or scanner is found"
    ++ expect config.services.avahi.nssmdns4 "avahi does not resolve .local names, which the Epson's queue uses"
    ++ expect config.services.ipp-usb.enable "ipp-usb is off, so a USB printer is not reachable"
    # Scanning.
    ++ expect config.hardware.sane.enable "SANE is not enabled"
    ++ expect (lib.elem "sane-airscan" (map lib.getName config.hardware.sane.extraBackends)) "sane-airscan is not a SANE backend"
    ++ expect (lib.elem "escl" config.hardware.sane.disabledDefaultBackends) "sane-backends' escl backend is on beside sane-airscan, so scanners are listed twice"
    ++ expect (has config "simple-scan") "the scan app simple-scan is not installed"
    ++ expect (!config.hardware.sane.openFirewall) "SANE opens a port"
    # The queues come from the typed options and are made by our own unit.
    ++ expect (config.systemd.services ? ravnix-printers) "the unit that creates the queues is missing"
    ++ expect (
      (host [
        {
          ravnix.printing.printers = lib.mkForce { };
          ravnix.printing.defaultPrinter = lib.mkForce null;
        }
      ]).config.systemd.services
        ? ravnix-printers == false
    ) "a user with no printer still gets the queue unit"
    ++ expect (lib.any (m: lib.hasInfix "my printer" m) (failedOf [
      { ravnix.printing.printers."my printer".uri = "ipp://x.example.org/"; }
    ])) "a queue name with a space is not refused"
    ++ expect (lib.any (m: lib.hasInfix "a/b" m) (failedOf [
      { ravnix.printing.printers."a/b".uri = "ipp://x.example.org/"; }
    ])) "a queue name with a slash is not refused"
    ++ expect (lib.any (m: lib.hasInfix "nope" m) (failedOf [
      { ravnix.printing.defaultPrinter = lib.mkForce "nope"; }
    ])) "a default printer that is no queue is not refused"
    ++ expect (lib.any (m: lib.hasInfix "nope" m) (failedOf [
      {
        ravnix.printing.printers = lib.mkForce { };
        ravnix.printing.defaultPrinter = lib.mkForce "nope";
      }
    ])) "a default printer when there are no printers is not refused"
    ++ expect (
      failedOf [ ] == [ ]
    ) "the template's values fail an assertion: ${toString (failedOf [ ])}"
    ++ map (uri: "the printer URI ${builtins.toJSON uri} is not refused") (
      lib.filter
        (
          uri:
          !refused (printerUri uri) [
            "ravnix"
            "printing"
            "printers"
          ]
        )
        [
          ""
          "printer.example.org"
          "ipp://a b"
          "file:///etc/passwd"
          "ipp://"
          "ipp://x.example.org/\nlpadmin"
          "ipp://user:pw@printer.example.org/"
          "ipp://printer.example.org?x@y"
          "ipp://user@printer.example.org/ipp/print"
        ]
    )
    ++ map (uri: "the printer URI ${builtins.toJSON uri} is refused") (
      lib.filter
        (
          uri:
          refused (printerUri uri) [
            "ravnix"
            "printing"
            "printers"
          ]
        )
        [
          "ipp://printer.example.org/ipp/print"
          "ipps://printer.example.org:443/ipp/print"
          "dnssd://Example%20Printer._ipp._tcp.local/?uuid=00000000-0000-0000-0000-000000000000"
          "ipp://EXAMPLE%20ET-1%20Series%20(USB)._ipp._tcp.local/"
          "socket://192.0.2.7:9100"
          "usb://Example/Printer?serial=1"
          "ipp://printer.example.org"
          "ipp://printer.example.org/p@th"
        ]
    )
    # NetBird: a client that keeps the firewall as Fedora has it.
    ++ expect config.services.netbird.enable "NetBird is not enabled"
    ++ expect (!config.services.netbird.ui.enable) "NetBird's UI is installed (Fedora installs none)"
    ++ expect (!config.services.netbird.clients.default.openFirewall) "NetBird opens its WireGuard port"
    ++ expect (
      !config.services.netbird.clients.default.openInternalFirewall
    ) "NetBird opens DNS ports on wt0"
    ++ expect (!(lib.elem 51820 firewall.allowedUDPPorts)) "51820/udp is open"
    ++ expect (firewall.interfaces.wt0.allowedUDPPorts or [ ] == [ ]) "ports are open on wt0"
    ++ expect (
      firewall.allowedTCPPortRanges == [ ] && firewall.allowedUDPPortRanges == [ ]
    ) "port ranges are open"
    ++ expect (lib.all
      (
        i:
        i.allowedTCPPorts == [ ]
        && i.allowedUDPPorts == [ ]
        && i.allowedTCPPortRanges == [ ]
        && i.allowedUDPPortRanges == [ ]
      )
      (lib.attrValues (lib.removeAttrs firewall.interfaces [ "default" ]))
    ) "ports are open on an interface: ${toString (lib.attrNames firewall.interfaces)}"
    ++ expect (!(lib.elem "wt0" firewall.trustedInterfaces)) "wt0 is a trusted interface"
    ++ expect (
      firewall.allowedTCPPorts == [ ]
    ) "TCP ports are open: ${toString firewall.allowedTCPPorts}"
    ++ expect (
      lib.subtractLists [ 5353 ] firewall.allowedUDPPorts == [ ]
    ) "UDP ports other than mDNS are open: ${toString firewall.allowedUDPPorts}"
    ++ expect (
      config.services.netbird.useRoutingFeatures == "client"
    ) "NetBird's routes are not accepted as a client"
    ++ expect (
      netbirdConfig "https://netbird.example.org" == {
        Scheme = "https";
        Host = "netbird.example.org:443";
      }
    ) "an https management URL is not split into scheme and host:443"
    ++ expect (
      netbirdConfig "http://nb.example.org" == {
        Scheme = "http";
        Host = "nb.example.org:80";
      }
    ) "an http management URL is not split into scheme and host:80"
    ++ expect (
      netbirdConfig "https://nb.example.org:8443/" == {
        Scheme = "https";
        Host = "nb.example.org:8443";
      }
    ) "a management URL with a port and a slash is not split right"
    ++ map (url: "the management URL ${builtins.toJSON url} is not refused") (
      lib.filter
        (
          url:
          !refused (managementUrl url) [
            "ravnix"
            "vpn"
            "netbird"
            "managementUrl"
          ]
        )
        [
          ""
          "netbird.example.org"
          "https://nb.example.org/api"
          "https://nb .example.org"
          "ftp://nb.example.org"
          "https://"
          "https://nb.example.org:123456"
        ]
    )
    # NordVPN and the home gateway: the commands exist when their options do.
    ++ expect (has config "nord") "the nord command is not installed"
    ++ expect (has config "vpn-home") "the vpn-home command is not installed"
    ++ expect (
      let
        c =
          (host [
            {
              ravnix.vpn.nord = lib.mkForce null;
              ravnix.vpn.home = lib.mkForce null;
            }
          ]).config;
      in
      !(has c "nord") && !(has c "vpn-home")
    ) "nord or vpn-home is installed without its options"
    ++ expect config.networking.networkmanager.enable "NetworkManager is off, and nord is a NetworkManager profile"
    ++
      expect
        (config.networking.networkmanager.dns == "systemd-resolved" && config.services.resolved.enable)
        "NetworkManager does not hand DNS to systemd-resolved, which nord's routing domain and NetBird's need"
    # Peripherals.
    ++ expect config.services.logiops.enable "logiops is not enabled"
    ++ expect (lib.elem "ravnix-udev-dygma" (udevNames config)) "no udev rules for the Dygma"
    ++ expect (lib.elem "ravnix-udev-magic-trackpad" (udevNames config)) "no udev rules for the Magic Trackpad"
    ++ expect (config.hardware.bluetooth.enable) "Bluetooth is off, and the Magic Trackpad and the MX Master use it"
    ++ expect (lib.hasInfix "ModelInvertHorizontalScrolling=0"
      config.environment.etc."libinput/local-overrides.quirks".text
    ) "the MX Master's libinput quirk is missing";

  # --- the commands against stand-ins --------------------------------------

  fake = name: file: pkgs.writeShellScriptBin name (builtins.readFile file);
  fakeNmcli = fake "nmcli" ./helpers/fake-nmcli.sh;
  fakeCurl = fake "curl" ./helpers/fake-curl.sh;
  fakeRbw = fake "rbw" ./helpers/fake-rbw.sh;
  fakeNotify = fake "notify-send" ./helpers/fake-notify-send.sh;
  stand-ins = {
    networkmanager = fakeNmcli;
    curl = fakeCurl;
    rbw = fakeRbw;
    libnotify = fakeNotify;
  };
  nordPackage = args: pkgs.callPackage ../../packages/nord (stand-ins // args);
  vpnHomePackage =
    args: pkgs.callPackage ../../packages/vpn-home ({ inherit (stand-ins) curl rbw; } // args);

  wrappers =
    pkgs.runCommand "desktop-printing-wrappers"
      {
        nord = nordPackage {
          countryId = 77;
          tokenItem = "tok item";
          keyItem = "key item";
        };
        nordUnbaked = nordPackage { };
        vpnHome = vpnHomePackage {
          apiUrl = "http://gateway.test:8080";
          tokenItem = "home item";
        };
        vpnHomeUnbaked = vpnHomePackage { };
      }
      ''
        export NORD="$nord/bin/nord" NORD_UNBAKED="$nordUnbaked/bin/nord"
        export VPN_HOME="$vpnHome/bin/vpn-home" VPN_HOME_UNBAKED="$vpnHomeUnbaked/bin/vpn-home"
        bash ${self}/tests/desktop/helpers/wrappers.test.bash
        touch $out
      '';

  # --- the VM --------------------------------------------------------------

  # A page for the fake scanner to hand out: the size of the whole platen at
  # 300 dpi in 24-bit color, which is what scanimage asks for by default and
  # airscan insists on getting: it refuses a page of another size or format.
  page = pkgs.runCommand "page.jpg" { nativeBuildInputs = [ pkgs.imagemagick ]; } ''
    magick -size 2550x3507 xc:white -type TrueColor -quality 50 $out
  '';

  # nord with the real NetworkManager and stand-ins for Nord's API and rbw:
  # the keys are WireGuard's documentation examples, valid base64 of 32 bytes.
  vmKey = "yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk=";
  vmPub = "xTIBA5rboUvnH4htodjb6e697QjLERt1NAB4mZqp8Dg=";
  nordVm = pkgs.callPackage ../../packages/nord {
    curl = fakeCurl;
    rbw = fakeRbw;
    libnotify = fakeNotify;
    countryId = 77;
    tokenItem = "tok item";
    keyItem = "key item";
  };

  vm = pkgs.testers.runNixOSTest {
    name = "desktop-printing";

    node.pkgs = lib.mkForce (pkgs.extend self.overlays.default);

    nodes.machine =
      { pkgs, ... }:
      {
        imports = [
          self.nixosModules.options
          ../../templates/default/me.nix
        ]
        ++ moduleFiles;

        # The template's values are placeholders and warn about it.
        warnings = lib.mkForce [ ];

        # Three queues: one whose printer is a socket the test listens on,
        # raw so that no driver is needed, and two whose printers are not
        # there, which must neither fail the boot nor stop the first queue.
        # "away" is a refused port. "nobody" is a DNS-SD name nothing on the
        # network answers to, which is what both real printers are when the
        # laptop is away from home: it takes the resolver path, and the unit
        # is wanted by multi-user.target, so every boot there waits for it.
        # "away" sorts before "desk", so a failure there comes first.
        ravnix.printing = {
          printers = lib.mkForce {
            away.uri = "ipp://127.0.0.1:1/ipp/print";
            nobody.uri = "dnssd://Nobody._ipp._tcp.local/";
            desk = {
              uri = "socket://127.0.0.1:9100";
              model = "raw";
            };
          };
          defaultPrinter = lib.mkForce "desk";
        };

        # The printer: whatever arrives on 9100 is appended to a file.
        systemd.services.fake-printer = {
          wantedBy = [ "multi-user.target" ];
          before = [ "ravnix-printers.service" ];
          serviceConfig.ExecStart = "${pkgs.socat}/bin/socat TCP-LISTEN:9100,bind=127.0.0.1,fork,reuseaddr OPEN:/tmp/printed,creat,append";
        };

        # The scanner: eSCL on all addresses, announced by DNS-SD the way a
        # network scanner is, so airscan finds it through avahi.
        systemd.services.fake-scanner = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            WorkingDirectory = "/tmp";
            ExecStart = "${pkgs.python3}/bin/python3 ${./helpers/escl-server.py} ${page} 8080 0.0.0.0";
          };
        };
        services.avahi.extraServiceFiles.fake-scanner = ''
          <?xml version="1.0" standalone='no'?>
          <!DOCTYPE service-group SYSTEM "avahi-service.dtd">
          <service-group>
            <name>Fake Scanner</name>
            <service>
              <type>_uscan._tcp</type>
              <port>8080</port>
              <txt-record>txtvers=1</txt-record>
              <txt-record>vers=2.0</txt-record>
              <txt-record>rs=eSCL</txt-record>
              <txt-record>ty=Fake Scanner</txt-record>
              <txt-record>pdl=image/jpeg</txt-record>
              <txt-record>cs=color,grayscale</txt-record>
            </service>
          </service-group>
        '';

        environment.systemPackages = [
          pkgs.libinput
          pkgs.jq
          pkgs.iproute2
          pkgs.wireguard-tools
        ];
        virtualisation.memorySize = 2048;
        system.stateVersion = "26.05";
      };

    testScript = ''
      import shlex
      import time

      def login(cmd):
        # A login shell, so that the session variables of SANE are set.
        return machine.succeed("bash -lc " + shlex.quote(cmd))

      def nord(args, check=True):
        # VISUAL is set the way ravnix sets it, and rbw asks it before EDITOR.
        cmd = "FAKE_DIR=/tmp/fake XDG_CACHE_HOME=/tmp/fake/cache HOME=/root VISUAL=false EDITOR=false ${nordVm}/bin/nord " + args
        return machine.succeed(cmd) if check else machine.execute(cmd)

      machine.wait_for_unit("multi-user.target")

      with subtest("CUPS is socket activated, local only, and has the queues"):
        machine.succeed("systemctl cat cups.socket")
        machine.wait_for_unit("cups.service")
        machine.fail("systemctl is-enabled cups-browsed")
        machine.succeed("lpstat -p desk | grep -q 'printer desk is idle'")
        assert "system default destination: desk" in machine.succeed("lpstat -d")
        assert "device for desk: socket://127.0.0.1:9100" in machine.succeed("lpstat -v")
        # Only the loopback listens on 631.
        listeners = machine.succeed("ss -Hltn 'sport = :631'")
        assert "127.0.0.1:631" in listeners or "[::1]:631" in listeners, listeners
        assert "0.0.0.0:631" not in listeners and "*:631" not in listeners, listeners

      with subtest("a printer that is not there neither fails the unit nor stops the others"):
        machine.fail("lpstat -p away")
        machine.fail("lpstat -p nobody")
        assert machine.succeed("systemctl show -p Result --value ravnix-printers").strip() == "success"
        machine.succeed("systemctl is-active cups.socket")
        journal = machine.succeed("journalctl -u ravnix-printers --no-pager")
        assert "away" in journal and "nobody" in journal and "could not" in journal, journal
        # The boot waited for the unit, so how long it ran is how long a boot
        # away from home is held up: the DNS-SD name is given up on in seconds.
        ran = machine.succeed("systemctl show -p ExecMainStartTimestampMonotonic -p ExecMainExitTimestampMonotonic ravnix-printers").split()
        stamps = dict(item.split("=") for item in ran)
        seconds = (int(stamps["ExecMainExitTimestampMonotonic"]) - int(stamps["ExecMainStartTimestampMonotonic"])) / 1e6
        print("ravnix-printers ran for", seconds, "seconds at boot")
        assert 0 < seconds < 60, seconds

      with subtest("a run with the DNS-SD printer away succeeds, and in seconds"):
        start = time.monotonic()
        machine.succeed("systemctl start ravnix-printers.service")
        took = time.monotonic() - start
        print("ravnix-printers took", took, "seconds")
        assert machine.succeed("systemctl show -p Result --value ravnix-printers").strip() == "success"
        assert took < 60, took
        machine.fail("lpstat -p nobody")

      with subtest("a job reaches the printer"):
        machine.succeed("echo 'hello from huginn' | lp -d desk -o raw")
        machine.wait_until_succeeds("grep -q 'hello from huginn' /tmp/printed")
        # Without -d, the default printer takes it.
        machine.succeed("echo 'second page' | lp -o raw")
        machine.wait_until_succeeds("grep -q 'second page' /tmp/printed")

      with subtest("the unit mends a queue whose address changed, and can run again"):
        machine.succeed("lpadmin -p desk -v socket://127.0.0.1:1")
        assert "socket://127.0.0.1:1" in machine.succeed("lpstat -v desk")
        machine.succeed("systemctl start ravnix-printers.service")
        assert "device for desk: socket://127.0.0.1:9100" in machine.succeed("lpstat -v desk")
        machine.succeed("systemctl start ravnix-printers.service")
        assert "system default destination: desk" in machine.succeed("lpstat -d")

      with subtest("a network coming up creates a queue that is missing"):
        machine.succeed("lpadmin -x desk")
        machine.fail("lpstat -p desk")
        # NetworkManager runs everything in dispatcher.d with the interface and
        # the event as arguments.
        script = machine.succeed("grep -l ravnix-printers.service /etc/NetworkManager/dispatcher.d/*").split()[0]
        machine.succeed(script + " eth0 up")
        machine.wait_until_succeeds("lpstat -p desk")
        # The default is set after the last queue was tried, and "nobody" takes
        # its seconds to give up on.
        machine.wait_until_succeeds("lpstat -d | grep -q 'system default destination: desk'")
        # Any other event does nothing.
        machine.succeed("lpadmin -x desk")
        machine.succeed(script + " eth0 down")
        machine.succeed("sleep 3")
        machine.fail("lpstat -p desk")
        machine.succeed("systemctl start ravnix-printers.service")

      with subtest("ipp-usb is ready for a USB printer"):
        machine.succeed("systemctl cat ipp-usb.service")
        machine.succeed("ls /etc/udev/rules.d | grep -qi ipp-usb")

      with subtest("sane-airscan finds a scanner that DNS-SD announces, and scans"):
        machine.wait_for_unit("avahi-daemon.service")
        machine.wait_for_unit("fake-scanner.service")
        machine.succeed("grep -q airscan /etc/sane-config/dll.d/* /etc/sane-config/dll.conf")
        machine.wait_until_succeeds("bash -lc 'scanimage -L' | grep -q \"Fake Scanner\"", timeout=180)
        listing = login("scanimage -L")
        # One entry, from airscan: sane-backends' own escl backend would list
        # the same scanner a second time.
        assert "airscan:" in listing and "escl:" not in listing, listing
        device = listing.split("`")[1].split("'")[0]
        login("scanimage -d " + shlex.quote(device) + " --resolution 300 --format=jpeg > /tmp/scan.jpg")
        assert machine.succeed("head -c 3 /tmp/scan.jpg | od -An -tx1").split() == ["ff", "d8", "ff"]
        machine.succeed("test $(wc -l < /tmp/JOBS) -ge 1")

      with subtest("NetBird runs with the management URL, and its ports are shut"):
        machine.wait_for_unit("netbird.service")
        # The documented enrollment reads the setup key from a file, so that it
        # never sits on a command line (/proc/PID/cmdline is world-readable).
        assert "--setup-key-file" in machine.succeed("netbird up --help 2>&1")
        machine.succeed("netbird status || true")
        machine.wait_until_succeeds("jq -e '.ManagementURL.Host == \"netbird.example.org:443\"' /var/lib/netbird/config.json")
        machine.fail("which netbird-ui")
        rules = machine.succeed("iptables -S; ip6tables -S")
        for port in ["51820", "22054"]:
          assert port not in rules, port + " is open:\n" + rules
        assert "5353" in rules, "mDNS is closed:\n" + rules
        assert "631" not in rules, rules
        assert "8612" not in rules, rules

      with subtest("NetworkManager hands DNS to systemd-resolved"):
        machine.succeed("grep -q '^dns=systemd-resolved' /etc/NetworkManager/NetworkManager.conf")
        machine.wait_for_unit("systemd-resolved.service")
        machine.wait_for_unit("NetworkManager.service")

      with subtest("nord setup builds the profile the header promises in the real NetworkManager"):
        machine.succeed("mkdir -p /tmp/fake/cache")
        machine.succeed("echo '[{\"hostname\":\"de1.example\",\"station\":\"192.0.2.10\",\"technologies\":[{\"identifier\":\"wireguard_udp\",\"metadata\":[{\"name\":\"public_key\",\"value\":\"${vmPub}\"}]}]}]' > /tmp/fake/recommend.json")
        machine.succeed("echo '{\"nordlynx_private_key\":\"${vmKey}\"}' > /tmp/fake/credentials.json")
        machine.succeed("echo '{\"protected\":true}' > /tmp/fake/insights.json")
        out = nord("setup")
        assert "profile 'nord' ready" in out, out
        # With VISUAL=false in the environment, the copy of the key reaches the
        # vault only if the script sets VISUAL itself, as rbw asks it first.
        assert "key copied to Bitwarden as 'key item'" in out, out
        def prop(name):
          return machine.succeed("nmcli -g " + name + " connection show nord").strip()
        assert prop("connection.autoconnect") == "no", prop("connection.autoconnect")
        assert prop("wireguard.fwmark") == "0xca6c", prop("wireguard.fwmark")
        assert prop("ipv6.method") == "link-local", prop("ipv6.method")
        assert prop("ipv4.dns-search") == "~.", prop("ipv4.dns-search")
        assert prop("ipv4.dns-priority") == "-50", prop("ipv4.dns-priority")
        assert prop("ipv4.dns") == "103.86.96.100,103.86.99.100", prop("ipv4.dns")
        for family in ["ipv4", "ipv6"]:
          rule = prop(family + ".routing-rules")
          assert "priority 120" in rule and "fwmark 0x1bd00" in rule and "table 254" in rule, rule
        # nmcli escapes the colons of its terse output, and puts the keys in its own order.
        peers = prop("wireguard.peers").replace("\\", "")
        assert peers.startswith("${vmPub} ") and "endpoint=192.0.2.10:51820" in peers, peers
        assert "allowed-ips=0.0.0.0/0;::/0" in peers and "persistent-keepalive=25" in peers, peers
        assert "off (server 192.0.2.10:51820)" in nord("status")
        # The key is in NetworkManager's root-only keyfile, and nowhere else.
        keyfiles = machine.succeed("grep -rl ${lib.escapeShellArg vmKey} /etc/NetworkManager/system-connections").split()
        assert len(keyfiles) == 1, keyfiles
        assert machine.succeed("stat -c %a " + keyfiles[0]).strip() == "600", keyfiles
        machine.fail("grep -rl ${lib.escapeShellArg vmKey} /tmp/fake/cache /root/.cache")
        assert machine.succeed("ls -A /tmp/fake/cache").strip() == "", "the cache directory is not empty"

      with subtest("nord up brings the tunnel up with NetBird's traffic kept off it"):
        out = nord("up")
        assert "on via 192.0.2.10:51820" in out, out
        machine.succeed("ip link show wg-nord")
        rules = machine.succeed("ip -4 rule; ip -6 rule")
        assert "fwmark 0x1bd00 lookup main" in rules, rules
        assert machine.succeed("wg show wg-nord fwmark").strip() == "0xca6c"
        assert "on via" in nord("status")
        nord("down")
        machine.fail("ip link show wg-nord")
        assert "off (server" in nord("status")

      with subtest("logid runs with the gesture button and SmartShift"):
        machine.wait_for_unit("logid.service")
        cfg = machine.succeed("systemctl cat logid.service")
        path = [l for l in cfg.splitlines() if l.startswith("ExecStart=") and "-c" in l][0].split("-c ")[1].strip()
        text = machine.succeed("cat " + path)
        # libconfig as the generator writes it, with no white space.
        for want in ['name="MX Master 3S"', "cid=0xc3", 'type="Gestures"', "on=true", "threshold=20"]:
          assert want in text, want + " is missing from:\n" + text
        for direction, key in [("None", "F14"), ("Up", "F15"), ("Down", "F16"), ("Left", "F17"), ("Right", "F18")]:
          mapping = 'keys=["KEY_' + key + '"];type="Keypress";};direction="' + direction + '";mode="OnRelease"'
          assert mapping in text, direction + " does not give " + key + " in:\n" + text
        # The device is told apart by its name, and logid has no other.
        assert text.count("name=") == 1, text

      with subtest("the udev rules are valid and sort before uaccess is applied"):
        machine.succeed("udevadm verify /etc/udev/rules.d/60-dygma.rules /etc/udev/rules.d/60-magic-trackpad.rules")
        names = machine.succeed("ls /etc/udev/rules.d").split()
        assert names.index("60-dygma.rules") < names.index("73-seat-late.rules"), names
        assert names.index("60-magic-trackpad.rules") < names.index("73-seat-late.rules"), names
        # The rule lines are exactly the ones the Fedora laptop's two files hold
        # (the comments aside, and its two repeated Dygma lines once): a missing
        # line, such as the evdev ones sway-radial needs, or an added one fails.
        def rules(path):
          lines = machine.succeed("cat " + path).splitlines()
          return {l.strip() for l in lines if l.strip() and not l.strip().startswith("#")}
        dygma = rules("/etc/udev/rules.d/60-dygma.rules")
        assert dygma == {
          'SUBSYSTEMS=="usb", ATTRS{idVendor}=="1209", ATTRS{idProduct}=="2200", MODE="0660", TAG+="uaccess"',
          'SUBSYSTEMS=="usb", ATTRS{idVendor}=="1209", ATTRS{idProduct}=="2201", MODE="0660", TAG+="uaccess"',
          'SUBSYSTEMS=="usb", ATTRS{idVendor}=="35ef", MODE="0660", TAG+="uaccess"',
          'KERNEL=="hidraw*", ATTRS{idVendor}=="35ef", MODE="0660", TAG+="uaccess"',
        }, dygma
        pad = rules("/etc/udev/rules.d/60-magic-trackpad.rules")
        assert pad == {
          'KERNEL=="hidraw*", SUBSYSTEM=="hidraw", DRIVERS=="magicmouse", MODE="0660", TAG+="uaccess"',
          'KERNEL=="hidraw*", KERNELS=="0005:004C:0324.*", MODE="0660", TAG+="uaccess"',
          'KERNEL=="hidraw*", KERNELS=="0003:05AC:0324.*", MODE="0660", TAG+="uaccess"',
          'SUBSYSTEM=="input", DRIVERS=="magicmouse", MODE="0660", TAG+="uaccess"',
          'SUBSYSTEM=="input", KERNELS=="0005:004C:0324.*", MODE="0660", TAG+="uaccess"',
          'SUBSYSTEM=="input", KERNELS=="0003:05AC:0324.*", MODE="0660", TAG+="uaccess"',
        }, pad
        # Neither grants the input group's reach over every device.
        assert not any("GROUP=" in l for l in dygma | pad)

      with subtest("the libinput quirk for the MX Master is where libinput reads it"):
        quirk = machine.succeed("cat /etc/libinput/local-overrides.quirks")
        assert "MatchVendor=0x46D" in quirk and "MatchProduct=0xB034" in quirk, quirk
        # The library reads that very path, and the database with the override is valid.
        machine.succeed("grep -aq /etc/libinput/local-overrides.quirks $(ldd $(which libinput) | awk '/libinput.so/{print $3}')")
        machine.succeed("libinput quirks validate")

      with subtest("Bluetooth is available for the devices that use it"):
        machine.succeed("systemctl cat bluetooth.service")
    '';
  };
in
pkgs.runCommand "desktop-printing"
  {
    # The parts, for building one at a time:
    #   nix build .#checks.x86_64-linux.desktop-printing.wrappers
    passthru = { inherit wrappers vm failures; };
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
        echo ${wrappers} ${vm}
        touch $out
      ''
  )
