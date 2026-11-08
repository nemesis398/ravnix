# muninn reaches huginn over NetBird (modules/glue/laptop-access.nix,
# packages/ravnix-laptop). Three parts, all of which must pass:
#
#   1. What the module sets, read from evaluated hosts: on the laptop an sshd
#      that keys alone log in to, port 22 open on NetBird's interface and on
#      no other, and the server's key pinned to the server's NetBird address;
#      on the server the `ravnix-laptop` command; which side a host is; what
#      the module refuses to build, and what its options refuse.
#   2. The command against a stand-in for ssh (helpers/fake-ssh.sh,
#      helpers/ravnix-laptop.test.bash): the options ssh gets, the quoting of
#      every word, the exit status, and what each message ssh writes means.
#   3. Two VMs: huginn with sshd and muninn with the command, joined by an
#      interface named like NetBird's (wt0) that stands in for NetBird, and a
#      second one (lan0) that plays the LAN or the WAN of the laptop.
#      Port 22 is open on the first and shut on the second, the command runs
#      on huginn with exactly the words it was given, and with huginn paused
#      or shut down it gives up with exit 75 in under five seconds.
#
# The VMs import the module and the common module, not the desktop: they need
# no Sway. The keys are the ones nixpkgs ships for its own tests
# (nixos/tests/ssh-keys.nix), which protect nothing.
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
  user = me.ravnix.user;
  huginnAddress = me.ravnix.hosts.huginn.address;
  muninnAddress = me.ravnix.server.netbirdAddress;
  identityFile = me.ravnix.laptopAccess.identityFile;

  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };
  moduleFile = ../../modules/glue/laptop-access.nix;
  keys = import (pkgs.path + "/nixos/tests/ssh-keys.nix") pkgs;

  # The laptop's host key is the ed25519 one, the identity of the server's
  # command the ECDSA one. The wrong host key is the right one with a
  # character changed: it parses, and it is not huginn's.
  hostKey = keys.snakeOilEd25519PublicKey;
  wrongHostKey = builtins.replaceStrings [ "PDkv8" ] [ "PDkv9" ] hostKey;
  identityPublicKey = keys.snakeOilPublicKey;

  # --- 1. the module, read from evaluated hosts ------------------------------

  host =
    extra:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules =
        hostModules
        ++ [
          self.nixosModules.options
          {
            nixpkgs.overlays = [ self.overlays.default ];
            users.users.${user.username}.isNormalUser = true;
          }
          moduleFile
        ]
        ++ extra;
    };

  # The laptop as modules/desktop/vpn.nix leaves it: NixOS's NetBird client.
  laptop = [
    {
      ravnix.shape = "laptop";
      services.netbird.enable = true;
    }
  ];
  server = [ { ravnix.shape = "server"; } ];

  failedOf =
    extra:
    lib.filter (lib.hasPrefix "ravnix.laptopAccess") (
      map (a: a.message) (lib.filter (a: !a.assertion) (host extra).config.assertions)
    );
  refused =
    extra: path:
    !(builtins.tryEval (builtins.deepSeq (lib.attrByPath path null (host extra).config) true)).success;
  set = name: value: [ { ravnix.laptopAccess.${name} = lib.mkForce value; } ];

  # The same host with its warnings: hostModules turns them off, because the
  # template's placeholders warn.
  loud =
    extra:
    (inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        ../../templates/default/me.nix
        {
          system.stateVersion = "26.05";
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          nixpkgs.overlays = [ self.overlays.default ];
          users.users.${user.username}.isNormalUser = true;
        }
        self.nixosModules.options
        moduleFile
      ]
      ++ extra;
    }).config.warnings;
  pinWarnings = extra: lib.filter (lib.hasPrefix "ravnix.laptopAccess.hostKey is null") (loud extra);
  # Whether the build is refused for opening the ssh port on NAME, which
  # the message gives as `open on NAME (`.
  opensOn = name: extra: mentions "open on ${name} (" (failedOf extra);
  range = {
    from = 20;
    to = 30;
  };

  l = (host laptop).config;
  s = (host server).config;
  packageNames = c: map lib.getName c.environment.systemPackages;
  has = c: lib.elem "ravnix-laptop" (packageNames c);
  tcpOn = c: iface: c.networking.firewall.interfaces.${iface}.allowedTCPPorts or [ ];
  authorized = c: c.users.users.${user.username}.openssh.authorizedKeys.keys;
  mentions = what: messages: lib.any (lib.hasInfix what) messages;

  goodKeys = [
    keys.snakeOilEd25519PublicKey
    keys.snakeOilPublicKey
    "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC5 someone@example.org"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDPQXmEVMVLmeFRyafKMVWgPDkv8/uRBTwmcEDatZzMD"
  ];
  badKeys = [
    ""
    "ssh-ed25519"
    "not a key"
    # Options in front would be the user's to write, not the key's.
    ''command="id" ${keys.snakeOilEd25519PublicKey}''
    ''from="*" ${keys.snakeOilEd25519PublicKey}''
    # A second line is a second key.
    "${keys.snakeOilEd25519PublicKey}\n${keys.snakeOilPublicKey}"
    # The point is a key of its own, not the YubiKey's.
    "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tAAAAI comment"
    "ssh-dss AAAAB3NzaC1kc3MAAACBAP comment"
  ];
  badFiles = [
    ""
    "key"
    "~/.ssh/key"
    "./key"
  ];

  expect = ok: message: lib.optional (!ok) message;
  failures =
    # The laptop. NixOS opens the ssh port on every interface by default; here
    # it is shut, and opened on NetBird's interface alone.
    expect l.services.openssh.enable "the laptop runs no sshd"
    ++ expect (!l.services.openssh.openFirewall) "sshd opens its port on every interface"
    ++ expect (tcpOn l "wt0" == [ 22 ]) "port 22 is not open on wt0 alone: ${toString (tcpOn l "wt0")}"
    ++ expect (!(lib.elem 22 l.networking.firewall.allowedTCPPorts)) "port 22 is open on every interface"
    ++ expect (lib.attrNames l.networking.firewall.interfaces == [ "wt0" ]) "a port is open on an interface besides wt0"
    ++ expect l.networking.firewall.enable "the laptop has no firewall"
    ++ expect (!l.services.openssh.settings.PasswordAuthentication) "sshd takes passwords"
    ++ expect (!l.services.openssh.settings.KbdInteractiveAuthentication) "sshd takes keyboard-interactive logins"
    ++ expect (l.services.openssh.settings.PermitRootLogin == "no") "root may log in by ssh"
    ++ expect (!(has l)) "the laptop gets the ravnix-laptop command"
    # Only the key the module writes, for the one account.
    ++ expect (!l.services.openssh.authorizedKeysInHomedir) "sshd reads ~/.ssh/authorized_keys"
    ++ expect (
      l.services.openssh.settings.AllowUsers == [ user.username ]
    ) "sshd lets in more than the one account: ${toString l.services.openssh.settings.AllowUsers}"
    # The key: pinned to the server's NetBird address, with nothing it does not need.
    ++ expect (
      authorized l == [ ''restrict,from="${muninnAddress}" ${me.ravnix.laptopAccess.publicKey}'' ]
    ) "the authorized key is not pinned to the server's address and restricted: ${toString (authorized l)}"
    # The interface is the one NetBird's client has.
    ++ expect (
      let
        c =
          (host (
            laptop
            ++ [
              {
                services.netbird.clients.default.interface = "nb0";
                services.netbird.clients.default.port = 51820;
              }
            ]
          )).config;
      in
      tcpOn c "nb0" == [ 22 ] && tcpOn c "wt0" == [ ]
    ) "the port is not opened on the interface NetBird's client is set to"
    # The port is the daemon's.
    ++ expect (
      let
        c = (host (laptop ++ [ { services.openssh.ports = [ 2222 ]; } ])).config;
      in
      tcpOn c "wt0" == [ 2222 ]
    ) "the port opened on wt0 is not the one sshd listens on"
    # Nothing for the laptop to do without a key, and nothing to do for the server.
    ++ expect (
      let
        c = (host (laptop ++ set "publicKey" null)).config;
      in
      !c.services.openssh.enable && authorized c == [ ] && tcpOn c "wt0" == [ ]
    ) "a laptop without a public key still runs sshd or opens the port"
    # The server.
    ++ expect (has s) "the server has no ravnix-laptop command"
    ++ expect (!s.services.openssh.enable) "the server side turns sshd on"
    ++ expect (s.networking.firewall.interfaces == { }) "the server side opens a port"
    ++ expect (authorized s == [ ]) "the server side authorizes a key"
    ++ expect (
      !(has (host (server ++ set "identityFile" null)).config)
    ) "the command is installed without an identity file"
    # Which side a host is: the shape says (ravnix.shape, which hosts/laptop and
    # hosts/server set), and nothing else the host does or imports.
    ++ expect (l.ravnix.laptopAccess.side == "laptop") "the laptop shape is not the laptop side"
    ++ expect (s.ravnix.laptopAccess.side == "server") "the server shape is not the server side"
    ++ expect (
      let
        c = (host (laptop ++ [ self.nixosModules.workbench ])).config;
      in
      c.ravnix.laptopAccess.side == "laptop"
      && c.services.openssh.enable
      && !(has c)
      && failedOf (laptop ++ [ self.nixosModules.workbench ]) == [ ]
    ) "a laptop that imports the workbench is not the laptop side"
    ++ expect (
      let
        c = (host (server ++ [ { programs.sway.enable = true; services.netbird.enable = true; } ])).config;
      in
      has c && !c.services.openssh.enable
    ) "a server that runs Sway is not the server side"
    ++ expect (
      let
        c = (host (server ++ [ { ravnix.laptopAccess.side = "laptop"; services.netbird.enable = true; } ])).config;
      in
      c.services.openssh.enable && !(has c)
    ) "the side set on the host does not win over the shape"
    # A host with no shape is no end: the glue refuses it once, in
    # modules/glue/shape.nix, and this module does nothing for it.
    ++ expect (
      let
        c = (host [ ]).config;
      in
      c.ravnix.shape == null && c.ravnix.laptopAccess.side == null && !c.services.openssh.enable && !(has c)
    ) "a host with no shape gets an end"
    # What the module will not build.
    ++ expect (failedOf laptop == [ ]) "the laptop side fails its own assertions: ${toString (failedOf laptop)}"
    ++ expect (failedOf server == [ ]) "the server side fails its own assertions: ${toString (failedOf server)}"
    ++ expect (mentions "firewall" (failedOf (laptop ++ [ { networking.firewall.enable = false; } ]))) "a laptop without a firewall builds"
    ++ expect (mentions "22" (failedOf (laptop ++ [ { networking.firewall.allowedTCPPorts = [ 22 ]; } ]))) "port 22 open on every interface builds"
    ++ expect (mentions "22" (
      failedOf (
        laptop
        ++ [
          {
            networking.firewall.allowedTCPPortRanges = [
              {
                from = 20;
                to = 30;
              }
            ];
          }
        ]
      )
    )) "port 22 inside an open range builds"
    ++ expect (mentions "22" (
      failedOf (laptop ++ [ { networking.firewall.allowedTCPPorts = [ 2222 ]; services.openssh.ports = [ 22 2222 ]; } ])
    )) "a second ssh port open on every interface builds"
    ++ expect (mentions "NetBird" (failedOf (laptop ++ [ { services.netbird.enable = lib.mkForce false; } ]))) "a laptop without NetBird's client builds"
    ++ expect (refused (laptop ++ [ { services.openssh.openFirewall = true; } ]) [ "services" "openssh" "openFirewall" ]) "sshd opening its port on every interface is not refused"
    ++ expect (mentions "ravnix.hosts.huginn" (
      failedOf (server ++ [ { ravnix.hosts = lib.mkForce { }; } ])
    )) "a server without the laptop in ravnix.hosts builds"
    # Every other way NixOS has to open the port.
    ++ expect (opensOn "wlan0" (
      laptop ++ [ { networking.firewall.interfaces.wlan0.allowedTCPPorts = [ 22 ]; } ]
    )) "port 22 open on another interface builds"
    ++ expect (opensOn "wlan0" (
      laptop ++ [ { networking.firewall.interfaces.wlan0.allowedTCPPortRanges = [ range ]; } ]
    )) "port 22 inside a range open on another interface builds"
    ++ expect (opensOn "wl+" (
      laptop ++ [ { networking.firewall.interfaces."wl+".allowedTCPPorts = [ 22 ]; } ]
    )) "port 22 open on an interface pattern builds"
    ++ expect (opensOn "+" (
      laptop ++ [ { networking.firewall.interfaces."+".allowedTCPPortRanges = [ range ]; } ]
    )) "port 22 in a range open on the pattern that is every interface builds"
    ++ expect (opensOn "default" (
      laptop ++ [ { networking.firewall.interfaces.default.allowedTCPPorts = [ 22 ]; } ]
    )) "port 22 open on the interface \"default\", which is every interface, builds"
    ++ expect (opensOn "default" (
      laptop ++ [ { networking.firewall.interfaces.default.allowedTCPPortRanges = [ range ]; } ]
    )) "port 22 in a range open on \"default\" builds"
    ++ expect (mentions "trustedInterfaces" (
      failedOf (laptop ++ [ { networking.firewall.trustedInterfaces = [ "lan0" ]; } ])
    )) "a trusted interface other than NetBird's builds"
    ++ expect (mentions "lan0, wlan0" (
      failedOf (laptop ++ [ { networking.firewall.trustedInterfaces = [ "lan0" "wlan0" ]; } ])
    )) "the trusted interfaces are not named"
    # And what they leave alone.
    ++ expect (
      failedOf (laptop ++ [ { networking.firewall.interfaces.wlan0.allowedTCPPorts = [ 8080 ]; } ]) == [ ]
    ) "another port on another interface is refused"
    ++ expect (
      failedOf (laptop ++ [ { networking.firewall.trustedInterfaces = [ "wt0" ]; } ]) == [ ]
    ) "NetBird's own interface as a trusted one is refused"
    ++ expect (
      failedOf (
        laptop
        ++ [
          {
            services.openssh.ports = [ 2222 ];
            networking.firewall.interfaces.wlan0.allowedTCPPorts = [ 22 ];
          }
        ]
      ) == [ ]
    ) "port 22 on another interface is refused when sshd listens on 2222"
    ++ expect (opensOn "wlan0" (
      laptop
      ++ [
        {
          services.openssh.ports = [ 2222 ];
          networking.firewall.interfaces.wlan0.allowedTCPPorts = [ 2222 ];
        }
      ]
    )) "port 2222, sshd's own, open on another interface builds"
    # The pin of the key is to an address.
    ++ expect (mentions "netbirdAddress" (
      failedOf (laptop ++ [ { ravnix.server.netbirdAddress = lib.mkForce "muninn.example.org"; } ])
    )) "a server with a name for its NetBird address builds"
    ++ expect (
      failedOf (laptop ++ [ { ravnix.server.netbirdAddress = lib.mkForce "fd00::2"; } ]) == [ ]
    ) "an IPv6 NetBird address of the server is refused"
    # The server end says that it trusts the first key, until one is pinned.
    ++ expect (
      lib.length (pinWarnings server) == 1 && lib.hasInfix "ssh_host_ed25519_key.pub" (lib.head (pinWarnings server))
    ) "the server does not warn, naming the file to copy, while hostKey is null"
    ++ expect (pinWarnings (server ++ set "hostKey" hostKey) == [ ]) "the server warns with a host key"
    ++ expect (pinWarnings (server ++ set "identityFile" null) == [ ]) "a server without the command warns about its host key"
    ++ expect (pinWarnings laptop == [ ]) "the laptop warns about the server's host key"
    # What the options refuse.
    ++ map (k: "the public key ${builtins.toJSON k} is accepted") (
      lib.filter (k: !(refused (set "publicKey" k) [ "ravnix" "laptopAccess" "publicKey" ])) badKeys
    )
    ++ map (k: "the host key ${builtins.toJSON k} is accepted") (
      lib.filter (k: !(refused (set "hostKey" k) [ "ravnix" "laptopAccess" "hostKey" ])) badKeys
    )
    ++ map (k: "the public key ${builtins.toJSON k} is refused") (
      lib.filter (k: refused (set "publicKey" k) [ "ravnix" "laptopAccess" "publicKey" ]) goodKeys
    )
    ++ map (f: "the identity file ${builtins.toJSON f} is accepted") (
      lib.filter (f: !(refused (set "identityFile" f) [ "ravnix" "laptopAccess" "identityFile" ])) badFiles
    )
    ++ expect (
      !(refused (set "hostKey" null) [ "ravnix" "laptopAccess" "hostKey" ])
    ) "a null host key is refused";

  # --- 2. the command against a stand-in for ssh -----------------------------

  fakeSsh = pkgs.writeShellScriptBin "ssh" (builtins.readFile ./helpers/fake-ssh.sh);
  identity = pkgs.writeText "ravnix-laptop-identity" "not a key\n";
  baked = {
    address = huginnAddress;
    user = user.username;
    identityFile = "${identity}";
  };
  package = args: pkgs.callPackage ../../packages/ravnix-laptop args;
  fake = args: package ({ sshCommand = "${fakeSsh}/bin/ssh"; } // baked // args);

  wrappers =
    pkgs.runCommand "glue-laptop-access-wrappers"
      {
        laptop = fake { hostKey = hostKey; };
        laptopTofu = fake { };
        laptopNokey = fake {
          identityFile = "/no/such/dir/ravnix-laptop-key";
        };
        laptopNossh = package (
          baked
          // {
            sshCommand = "/no/such/ssh";
          }
        );
        laptopUnbaked = package { sshCommand = "${fakeSsh}/bin/ssh"; };
        HOST_KEY = hostKey;
        IDENTITY = "${identity}";
      }
      ''
        export LAPTOP="$laptop/bin/ravnix-laptop" LAPTOP_TOFU="$laptopTofu/bin/ravnix-laptop"
        export LAPTOP_NOKEY="$laptopNokey/bin/ravnix-laptop" LAPTOP_NOSSH="$laptopNossh/bin/ravnix-laptop"
        export LAPTOP_UNBAKED="$laptopUnbaked/bin/ravnix-laptop"
        bash ${self}/tests/glue/helpers/ravnix-laptop.test.bash
        touch $out
      '';

  # --- 3. the VMs ------------------------------------------------------------

  lanHuginn = "192.0.2.10";
  lanMuninn = "192.0.2.20";
  # A second address of the server on the NetBird network, which the key's
  # pin to the server's own address must refuse.
  strangerAddress = "198.51.100.21";

  # The command with ssh itself, for the variants of the test: another host
  # key, and none.
  real = args: package (baked // { inherit identityFile; } // args);
  withWrongHostKey = real { hostKey = wrongHostKey; };
  withoutHostKey = real { };

  vm = pkgs.testers.runNixOSTest {
    name = "glue-laptop-access";

    node.pkgs = lib.mkForce (pkgs.extend self.overlays.default);

    defaults =
      { ... }:
      {
        imports = [
          self.nixosModules.common
          moduleFile
          ../../templates/default/me.nix
        ];

        # The template's values are placeholders and warn about it; here the
        # warnings are noise.
        warnings = lib.mkForce [ ];

        # The keys of the test are nixpkgs's own. The server's command is
        # built with the host key it pins, which is huginn's.
        ravnix.laptopAccess = {
          publicKey = lib.mkForce identityPublicKey;
          hostKey = lib.mkForce hostKey;
        };

        # The editor comes with the common module; the VM needs one language,
        # not the toolchains of the rest.
        ravnix.editor.languages = lib.mkForce [ "nix" ];

        # wt0 stands in for NetBird's interface: the same name, on the one
        # network both VMs share. lan0 is the laptop's other network.
        virtualisation = {
          interfaces = {
            wt0.vlan = 1;
            lan0.vlan = 2;
          };
          cores = 2;
          memorySize = 2048;
        };
        system.stateVersion = "26.05";
      };

    nodes.huginn =
      { config, pkgs, ... }:
      {
        ravnix.shape = "laptop";

        # NetBird's client, as modules/desktop/vpn.nix has it. It is not
        # enrolled, so it never touches wt0: the module reads its interface.
        services.netbird.enable = true;

        networking.interfaces = {
          wt0.ipv4.addresses = [
            {
              address = huginnAddress;
              prefixLength = 24;
            }
          ];
          lan0.ipv4.addresses = [
            {
              address = lanHuginn;
              prefixLength = 24;
            }
          ];
        };

        # The laptop's host key, which the server's command pins.
        services.openssh.hostKeys = [
          {
            type = "ed25519";
            path = "/etc/ssh/ssh_host_ed25519_key";
          }
        ];
        environment.etc."ssh/ssh_host_ed25519_key" = {
          source = keys.snakeOilEd25519PrivateKey;
          mode = "0600";
        };

        # A second account that the server's key is authorized for (as a
        # NixOS host may have): sshd must not let it in.
        users.users.other = {
          isNormalUser = true;
          openssh.authorizedKeys.keys = [ identityPublicKey ];
        };

        # Something else that listens on every interface, and is open on
        # every interface: it shows that lan0 is up and that what is shut
        # there is port 22.
        networking.firewall.allowedTCPPorts = [ 8080 ];
        systemd.services.control = {
          wantedBy = [ "multi-user.target" ];
          serviceConfig.ExecStart = "${pkgs.python3}/bin/python3 -m http.server 8080 --bind :: --directory /tmp";
        };
      };

    nodes.muninn =
      { config, pkgs, ... }:
      {
        ravnix.shape = "server";

        networking.interfaces = {
          wt0.ipv4.addresses = [
            {
              address = muninnAddress;
              prefixLength = 24;
            }
            {
              address = strangerAddress;
              prefixLength = 24;
            }
          ];
          lan0.ipv4.addresses = [
            {
              address = lanMuninn;
              prefixLength = 24;
            }
          ];
        };

        environment.systemPackages = [
          pkgs.netcat-openbsd
          pkgs.openssh
        ];
      };

    testScript = ''
      import base64
      import shlex

      USER = "${user.username}"
      HOME = "/home/" + USER
      KEY = "${identityFile}"
      HUGINN = "${huginnAddress}"
      MUNINN = "${muninnAddress}"
      STRANGER = "${strangerAddress}"
      HUGINN_LAN = "${lanHuginn}"
      HOST_KEY = "${hostKey}"
      WITHOUT_HOST_KEY = "${withoutHostKey}/bin/ravnix-laptop"
      WRONG_HOST_KEY = "${withWrongHostKey}/bin/ravnix-laptop"


      def put(machine, path, data):
          machine.succeed("echo " + base64.b64encode(data).decode() + " | base64 -d > " + path)


      def get(machine, path):
          return base64.b64decode(machine.succeed("base64 -w0 < " + path))


      def as_user(cmd):
          return "su - " + USER + " -c " + shlex.quote(cmd)


      def laptop(args, stdin=None, binary="ravnix-laptop", tag="rl"):
          """Runs the command on muninn as the user. args is shell text for the
          user's shell. Returns (exit status, stdout, stderr, milliseconds)."""
          base = HOME + "/" + tag
          script = (
              "start=$(date +%s%N)\n"
              + binary + " " + args + " >" + base + ".out 2>" + base + ".err"
              + (" <" + base + ".in" if stdin is not None else " </dev/null") + "\n"
              + "rc=$?\n"
              + "end=$(date +%s%N)\n"
              + 'echo "$rc $(( (end - start) / 1000000 ))" >' + base + ".rc\n"
          )
          put(muninn, "/tmp/" + tag + ".sh", script.encode())
          muninn.succeed("chmod 755 /tmp/" + tag + ".sh")
          if stdin is not None:
              put(muninn, base + ".in", stdin)
              muninn.succeed("chown " + USER + " " + base + ".in")
          muninn.succeed(as_user("bash /tmp/" + tag + ".sh"))
          rc, ms = muninn.succeed("cat " + base + ".rc").split()
          return int(rc), get(muninn, base + ".out"), get(muninn, base + ".err"), int(ms)


      def words(ws):
          return " ".join(shlex.quote(w) for w in ws)


      start_all()
      for m in (huginn, muninn):
          m.wait_for_unit("multi-user.target")
          m.wait_for_unit("home-manager-" + USER + ".service")
      huginn.wait_for_unit("sshd.service")
      muninn.wait_until_succeeds("ping -c1 -W1 " + HUGINN)
      muninn.wait_until_succeeds("ping -c1 -W1 " + HUGINN_LAN)

      # The identity file of the command, where the option says, as the user
      # keeps it: a file no one else reads.
      muninn.succeed("install -d -m 700 -o " + USER + " " + HOME + "/.ssh")
      muninn.succeed("install -m 600 -o " + USER + " ${keys.snakeOilPrivateKey} " + KEY)

      # ssh with nothing but the key, for the cases that do not go through the command.
      raw = (
          "ssh -F /dev/null -i " + KEY + " -o IdentitiesOnly=yes -o IdentityAgent=none -o BatchMode=yes"
          " -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
      )

      with subtest("huginn takes ssh on the NetBird interface and on no other"):
          # What listens: sshd, on every address. What is shut is the firewall's.
          print(huginn.succeed("ss -ltn"))
          muninn.succeed("nc -z -w 3 " + HUGINN + " 22")
          # lan0 is up, and what is open on every interface is reachable there.
          muninn.succeed("nc -z -w 3 " + HUGINN_LAN + " 8080")
          muninn.fail("nc -z -w 3 " + HUGINN_LAN + " 22")
          # The same from the other side of the NetBird network's address.
          muninn.succeed("nc -z -w 3 -s " + MUNINN + " " + HUGINN + " 22")

      with subtest("the same holds over IPv6"):
          def link_local(dev):
              return huginn.succeed("ip -6 -o addr show dev " + dev + " scope link").split()[3].split("/")[0]

          on_nb = link_local("wt0") + "%wt0"
          on_lan = link_local("lan0") + "%lan0"
          muninn.wait_until_succeeds("ping -6 -c1 -W1 " + on_nb)
          muninn.wait_until_succeeds("ping -6 -c1 -W1 " + on_lan)
          muninn.succeed("nc -6 -z -w 3 " + on_nb + " 22")
          # The control listens on IPv6 as well: lan0 answers there.
          muninn.succeed("nc -6 -z -w 3 " + on_lan + " 8080")
          muninn.fail("nc -6 -z -w 3 " + on_lan + " 22")

      with subtest("sshd takes keys only"):
          effective = huginn.succeed("sshd -T").lower()
          assert "passwordauthentication no" in effective, effective
          assert "kbdinteractiveauthentication no" in effective, effective
          assert "permitrootlogin no" in effective, effective
          # The one key file the module writes, and the one account.
          assert "authorizedkeysfile /etc/ssh/authorized_keys.d/%u\n" in effective, effective
          assert "allowusers " + USER + "\n" in effective, effective

      with subtest("the key is restricted and pinned to the server's NetBird address"):
          line = huginn.succeed("cat /etc/ssh/authorized_keys.d/" + USER).strip()
          assert line == 'restrict,from="' + MUNINN + '" ${identityPublicKey}', line
          # From the address the key is pinned to, it logs in.
          muninn.succeed(as_user(raw + " -b " + MUNINN + " " + USER + "@" + HUGINN + " true"))
          # From another address on the same network, it does not.
          status, out = muninn.execute(as_user(raw + " -b " + STRANGER + " " + USER + "@" + HUGINN + " true 2>&1"))
          assert status != 0 and "Permission denied" in out, (status, out)

      with subtest("sshd takes no other key and no other account"):
          # The refusals come from an address of their own, so that sshd's
          # penalties for failed logins never touch the server's.
          stranger = raw + " -b " + STRANGER + " "
          # A key in the account's own authorized_keys, where sshd looks by
          # default, is no key here: it would log in from any address.
          muninn.succeed("install -m 600 -o " + USER + " ${keys.snakeOilEd25519PrivateKey} " + HOME + "/.ssh/other_key")
          huginn.succeed("install -d -m 700 -o " + USER + " " + HOME + "/.ssh")
          huginn.succeed("echo '${keys.snakeOilEd25519PublicKey}' > " + HOME + "/.ssh/authorized_keys")
          huginn.succeed("chown " + USER + " " + HOME + "/.ssh/authorized_keys; chmod 600 " + HOME + "/.ssh/authorized_keys")
          status, out = muninn.execute(as_user(stranger.replace(KEY, HOME + "/.ssh/other_key") + USER + "@" + HUGINN + " true 2>&1"))
          assert status != 0 and "Permission denied" in out, (status, out)
          # The server's own key, authorized for a second account, is no key
          # for that account.
          status, out = muninn.execute(as_user(stranger + "other@" + HUGINN + " true 2>&1"))
          assert status != 0 and "Permission denied" in out, (status, out)
          journal = huginn.succeed("journalctl -u sshd.service --no-pager")
          assert "User other from " + STRANGER + " not allowed because not listed in AllowUsers" in journal, journal

      with subtest("ravnix-laptop returns the output of a command run on huginn"):
          rc, out, err, ms = laptop("hostname")
          assert (rc, out, err) == (0, b"huginn\n", b""), (rc, out, err)
          rc, out, err, ms = laptop("whoami")
          assert (rc, out, err) == (0, (USER + "\n").encode(), b""), (rc, out, err)
          print("a command took", ms, "ms")

      with subtest("every word arrives as one word, whatever is in it"):
          ws = [
              "a b", "c;d", "$(touch /tmp/pwned)", "`touch /tmp/pwned`", '"quoted"', "it's", "back\\slash",
              "*", "~", "#x", "&", "|", ">out", "", "-n", "--", "two\nlines", "ä – ö", "  lead and trail  ",
              "!", "{a,b}", "$HOME", "%s", "; touch /tmp/pwned", "&& touch /tmp/pwned", "tab\there", "\\",
              "'", '"', "x" * 50000,
          ]
          rc, out, err, ms = laptop("printf '%s\\0' " + words(ws))
          assert rc == 0 and err == b"", (rc, err)
          assert out.split(b"\0")[:-1] == [w.encode() for w in ws], out[:2000]
          huginn.fail("test -e /tmp/pwned")
          muninn.fail("test -e /tmp/pwned")

      with subtest("the exit status, the two output streams and standard input are the command's"):
          rc, out, err, ms = laptop("sh -c " + shlex.quote("echo out; echo err >&2; exit 7"))
          assert (rc, out, err) == (7, b"out\n", b"err\n"), (rc, out, err)
          rc, out, err, ms = laptop("cat", stdin=b"some\ndata\x00\xff\n")
          assert (rc, out, err) == (0, b"some\ndata\x00\xff\n", b""), (rc, out, err)
          rc, out, err, ms = laptop("sh -c 'exit 255'")
          assert (rc, out, err) == (255, b"", b""), (rc, out, err)
          rc, out, err, ms = laptop("no-such-command-on-huginn")
          assert rc == 127 and b"not found" in err, (rc, err)

      with subtest("runs at the same time answer separately"):
          script = "for i in 1 2 3 4 5 6; do (ravnix-laptop sh -c \"echo run $i\" > " + HOME + "/par.$i 2>&1) & done; wait\n"
          put(muninn, "/tmp/par.sh", script.encode())
          muninn.succeed(as_user("bash /tmp/par.sh"))
          for i in range(1, 7):
              assert muninn.succeed("cat " + HOME + "/par." + str(i)) == "run " + str(i) + "\n"

      with subtest("a host key that is not huginn's is refused, and is not called a sleeping laptop"):
          rc, out, err, ms = laptop("true", binary=WRONG_HOST_KEY, tag="wrong")
          assert rc == 255 and out == b"", (rc, out, err)
          assert b"ssh to huginn failed" in err and b"offline or asleep" not in err, err
          assert b"Host key verification failed" in err or b"IDENTIFICATION HAS CHANGED" in err, err

      with subtest("without a pinned host key the first one is remembered, and a changed one is refused"):
          state = muninn.succeed(as_user("echo ''${XDG_STATE_HOME:-$HOME/.local/state}")).strip()
          known = state + "/ravnix-laptop/known_hosts"
          muninn.fail("test -e " + known)
          rc, out, err, ms = laptop("hostname", binary=WITHOUT_HOST_KEY, tag="tofu")
          assert (rc, out) == (0, b"huginn\n"), (rc, out, err)
          assert muninn.succeed("cat " + known).startswith("huginn " + HOST_KEY.split()[0] + " " + HOST_KEY.split()[1]), muninn.succeed("cat " + known)
          rc, out, err, ms = laptop("hostname", binary=WITHOUT_HOST_KEY, tag="tofu")
          assert (rc, out) == (0, b"huginn\n"), (rc, out, err)
          muninn.succeed("sed -i 's/PDkv8/PDkv9/' " + known)
          rc, out, err, ms = laptop("hostname", binary=WITHOUT_HOST_KEY, tag="tofu")
          assert rc == 255 and b"offline or asleep" not in err, (rc, err)
          assert b"Host key verification failed" in err or b"IDENTIFICATION HAS CHANGED" in err, err
          # Not in the user's own known_hosts.
          muninn.fail("test -e " + HOME + "/.ssh/known_hosts")

      with subtest("with sshd stopped on huginn the command says so at once"):
          huginn.succeed("systemctl stop sshd.service")
          rc, out, err, ms = laptop("true")
          assert rc == 75 and out == b"" and err == b"ravnix-laptop: huginn is offline or asleep\n", (rc, out, err)
          print("a refused connection took", ms, "ms")
          assert ms < 5000, ms
          huginn.succeed("systemctl start sshd.service")
          huginn.wait_for_unit("sshd.service")
          rc, out, err, ms = laptop("true")
          assert rc == 0, (rc, err)

      with subtest("a laptop that stops answering during the handshake is given up on in under five seconds"):
          # A listener in place of sshd that accepts and then says nothing:
          # not a word (the banner exchange), or a banner and then nothing
          # (the key exchange). ConnectTimeout has to bound both, since
          # ServerAliveInterval only starts with the session.
          stall = (
              "import socket, sys\n"
              "s = socket.socket()\n"
              "s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)\n"
              "s.bind(('0.0.0.0', 22))\n"
              "s.listen(8)\n"
              "held = []\n"
              "while True:\n"
              "    c, _ = s.accept()\n"
              "    if sys.argv[1] == 'banner':\n"
              "        c.sendall(b'SSH-2.0-OpenSSH_stall\\r\\n')\n"
              "    held.append(c)\n"
          )
          put(huginn, "/tmp/stall.py", stall.encode())
          huginn.succeed("systemctl stop sshd.service")
          for mode in ["silent", "banner"]:
              huginn.succeed("systemd-run --unit stall --collect ${pkgs.python3}/bin/python3 /tmp/stall.py " + mode)
              huginn.wait_until_succeeds("nc -z 127.0.0.1 22")
              # Bounded, so that a handshake nothing times out shows as a failure here.
              rc, out, err, ms = laptop("true", binary="timeout 30 ravnix-laptop", tag="stall")
              print("a handshake that stalls (" + mode + ") took", ms, "ms; exit", rc)
              assert rc == 75 and err == b"ravnix-laptop: huginn is offline or asleep\n", (mode, rc, err)
              assert ms < 5000, (mode, ms)
              huginn.succeed("systemctl stop stall.service")
          huginn.succeed("systemctl start sshd.service")
          huginn.wait_for_unit("sshd.service")
          rc, out, err, ms = laptop("true")
          assert rc == 0, (rc, err)

      with subtest("a session that the laptop closes in the middle of a command is a silent 255, ssh's own line among the command's"):
          # ssh says so on its own standard error, not in the file of -E, so the
          # command cannot tell it from a command that exits 255, and the line
          # is in the command's stderr.
          base = HOME + "/gone"
          script = "ravnix-laptop sh -c 'echo started >&2; sleep 121' >" + base + ".out 2>" + base + ".err </dev/null; echo $? >" + base + ".rc\n"
          put(muninn, "/tmp/gone.sh", script.encode())
          muninn.succeed("setsid -f su - " + USER + " -c 'bash /tmp/gone.sh' >/dev/null 2>&1 </dev/null")
          huginn.wait_until_succeeds("pgrep -u " + USER + " -f '^sleep 121$'", timeout=60)
          # sshd's process for the session ends, and with it the connection.
          huginn.succeed("pkill -u " + USER + " -f 'sshd-session: .*@notty'")
          muninn.wait_until_succeeds("test -s " + base + ".rc", timeout=30)
          closed = get(muninn, base + ".err")
          print("a closed session gave", muninn.succeed("cat " + base + ".rc").strip(), repr(closed))
          assert muninn.succeed("cat " + base + ".rc").strip() == "255"
          assert closed == b"started\nConnection to " + HUGINN.encode() + b" closed by remote host.\r\n", closed
          huginn.succeed("pkill -u " + USER + " -f '^sleep 121$' || true")

      with subtest("a session that is reset in the middle of a command is a 75, after ssh's own line"):
          base = HOME + "/reset"
          script = "ravnix-laptop sh -c 'echo started >&2; sleep 122' >" + base + ".out 2>" + base + ".err </dev/null; echo $? >" + base + ".rc\n"
          put(muninn, "/tmp/reset.sh", script.encode())
          muninn.succeed("setsid -f su - " + USER + " -c 'bash /tmp/reset.sh' >/dev/null 2>&1 </dev/null")
          huginn.wait_until_succeeds("pgrep -u " + USER + " -f '^sleep 122$'", timeout=60)
          # The laptop answers whatever the session sends next with a reset, as
          # a machine does that has restarted and lost the connection.
          reject = "-p tcp --dport 22 -j REJECT --reject-with tcp-reset"
          huginn.succeed("iptables -I INPUT 1 " + reject)
          muninn.wait_until_succeeds("test -s " + base + ".rc", timeout=30)
          huginn.succeed("iptables -D INPUT " + reject)
          reset = get(muninn, base + ".err")
          print("a reset session gave", muninn.succeed("cat " + base + ".rc").strip(), repr(reset))
          assert muninn.succeed("cat " + base + ".rc").strip() == "75"
          assert reset == b"started\nRead from remote host " + HUGINN.encode() + b": Connection reset by peer\r\nravnix-laptop: huginn is offline or asleep\n", reset
          huginn.succeed("pkill -u " + USER + " -f 'sshd-session: .*@notty' || true")
          huginn.succeed("pkill -u " + USER + " -f '^sleep 122$' || true")
          rc, out, err, ms = laptop("true")
          assert rc == 0, (rc, err)

      with subtest("a laptop that falls asleep in the middle of a command is given up on in seconds"):
          # A command that runs for two minutes, started in the background.
          script = "ravnix-laptop sleep 120 >" + HOME + "/mid.out 2>" + HOME + "/mid.err </dev/null; rc=$?; date +%s%N >" + HOME + "/mid.end; echo $rc >" + HOME + "/mid.rc\n"
          put(muninn, "/tmp/mid.sh", script.encode())
          muninn.succeed("setsid -f su - " + USER + " -c 'bash /tmp/mid.sh' >/dev/null 2>&1 </dev/null")
          # The command itself, and not another sleep of the user's.
          huginn.wait_until_succeeds("pgrep -u " + USER + " -f '^sleep 120$'", timeout=60)
          # Asleep: the machine does not run, so nothing answers. The two
          # stamps are of muninn's clock, so the time is a guest's, not the
          # test driver's.
          muninn.succeed("date +%s%N > " + HOME + "/stopped")
          huginn.send_monitor_command("stop")
          muninn.wait_until_succeeds("test -s " + HOME + "/mid.rc", timeout=60)
          ended = int(muninn.succeed("cat " + HOME + "/mid.end"))
          gave_up = (ended - int(muninn.succeed("cat " + HOME + "/stopped"))) / 1e9
          print("the link was given up on after", gave_up, "seconds")
          assert muninn.succeed("cat " + HOME + "/mid.rc").strip() == "75"
          assert b"huginn is offline or asleep" in get(muninn, HOME + "/mid.err")
          assert gave_up < 5, gave_up

      with subtest("a laptop that is asleep is given up on in under five seconds"):
          rc, out, err, ms = laptop("true")
          assert rc == 75 and out == b"" and err == b"ravnix-laptop: huginn is offline or asleep\n", (rc, out, err)
          print("a sleeping laptop took", ms, "ms")
          assert ms < 5000, ms

      with subtest("the laptop wakes and the command works again"):
          huginn.send_monitor_command("cont")
          huginn.wait_until_succeeds("true")
          huginn.succeed("pkill -x sleep || true")
          muninn.wait_until_succeeds(as_user("ravnix-laptop true </dev/null"), timeout=90)
          rc, out, err, ms = laptop("hostname")
          assert (rc, out, err) == (0, b"huginn\n", b""), (rc, out, err)

      with subtest("a laptop that shuts down in the middle of a command closes the session: a silent 255, ssh's own line among the command's"):
          # A clean shutdown ends the session's processes while the network is
          # still up, so sshd closes the connection (no reset, no silence).
          base = HOME + "/down"
          script = "ravnix-laptop sh -c 'echo started >&2; sleep 123' >" + base + ".out 2>" + base + ".err </dev/null; echo $? >" + base + ".rc\n"
          put(muninn, "/tmp/down.sh", script.encode())
          muninn.succeed("setsid -f su - " + USER + " -c 'bash /tmp/down.sh' >/dev/null 2>&1 </dev/null")
          huginn.wait_until_succeeds("pgrep -u " + USER + " -f '^sleep 123$'", timeout=60)
          huginn.shutdown()
          muninn.wait_until_succeeds("test -s " + base + ".rc", timeout=60)
          down = get(muninn, base + ".err")
          print("a laptop that shut down mid-command gave", muninn.succeed("cat " + base + ".rc").strip(), repr(down))
          assert muninn.succeed("cat " + base + ".rc").strip() == "255"
          assert down == b"started\nConnection to " + HUGINN.encode() + b" closed by remote host.\r\n", down

      with subtest("a laptop that is shut down is given up on in under five seconds"):
          rc, out, err, ms = laptop("true")
          assert rc == 75 and out == b"" and err == b"ravnix-laptop: huginn is offline or asleep\n", (rc, out, err)
          print("a laptop that is off took", ms, "ms")
          assert ms < 5000, ms
    '';
  };
in
pkgs.runCommand "glue-laptop-access"
  {
    # The parts, for building one at a time:
    #   nix build .#checks.x86_64-linux.glue-laptop-access.wrappers
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
