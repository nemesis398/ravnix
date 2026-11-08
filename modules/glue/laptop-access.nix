# The server reaches the laptop: `ravnix-laptop COMMAND` on muninn runs a
# command on huginn over the NetBird mesh and returns its output (the command
# is packages/ravnix-laptop; its values are ravnix.laptopAccess, in
# modules/options/laptop-access.nix). One module for both ends, and
# `ravnix.laptopAccess.side` says which end the host is; it follows
# `ravnix.shape`, which nixosModules.laptop and nixosModules.server set, so no
# host sets it. Other options would be a guess (a laptop may run the workbench
# for its toolchains, a server may run Sway in a test). A host with no shape
# is refused once for all of the glue (modules/glue/shape.nix); here it is no
# end, and gets neither the laptop's sshd nor the command.
#
# The laptop end. huginn runs sshd for keys alone, and the firewall opens its
# port on NetBird's interface and on no other: the laptop roams, so any Wi-Fi
# or LAN it is on must find 22 shut. The firewall does that, and not
# ListenAddress: sshd with a ListenAddress fails to start when NetBird's
# address is not there yet, which is every boot before the client is up, and
# sshd.service would be down until someone restarts it. So sshd listens on
# every address and the packets of the other interfaces never reach it.
# `services.openssh.openFirewall` is turned off, since its default opens the
# port everywhere, and the module refuses a host that opens it another way,
# every one that NixOS has: the global networking.firewall.allowedTCPPorts and
# allowedTCPPortRanges; the same lists of any other interface, wildcard names
# such as "wl+" included; those of the interface called "default", which
# nixpkgs applies to every interface in place of the global lists; and
# trustedInterfaces other than NetBird's and loopback, where everything is
# accepted. It refuses as well a host with no firewall, or no NetBird client
# to take the interface from. The interface is the one NixOS's client has,
# services.netbird.clients.default (modules/desktop/vpn.nix enables it), not a
# second spelling of "wt0". What no assertion can see is a free-form rule
# (extraCommands, extraInputRules, a ruleset of nftables' own); the README of
# packages/ravnix-laptop lists them.
#
# The key it accepts is the server's own, for this and nothing else: the
# public half of ravnix.laptopAccess.identityFile. sshd on the laptop takes no
# other: authorizedKeysInHomedir is off, so a key in ~/.ssh/authorized_keys
# counts for nothing, and AllowUsers names the one account. The key works for
# commands only (`restrict` takes away forwarding of ports, agents and
# displays, and the terminal), and from the server's NetBird address only
# (ravnix.server.netbirdAddress, which must be an IP address: sshd matches
# `from=` against the address a connection comes from and does not resolve a
# name): the same key from another address is refused. The account is the
# user's, on both hosts.
#
# The server end is the command and nothing else: no daemon, no unit, no
# port. It logs in with the key of its own that identityFile names, never
# with the YubiKey (modules/glue/sk-agent.nix) and never with Bitwarden's
# agent.
#
# A host without the values does nothing: the laptop without a public key
# runs no sshd for this, the server without an identity file gets no command.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;

  cfg = config.ravnix.laptopAccess;
  user = config.ravnix.user.username;
  sshd = config.services.openssh;
  firewall = config.networking.firewall;

  # NetBird's interface on this host, from the client that modules/desktop/
  # vpn.nix turns on, if there is one.
  interface = lib.attrByPath [ "services" "netbird" "clients" "default" "interface" ] null config;
  # huginn's address in the NetBird network, as ravnix.hosts has it.
  huginn = lib.attrByPath [ "ravnix" "hosts" "huginn" "address" ] null config;

  # The ssh ports that the open-port lists of a firewall scope (the global one,
  # or an entry of networking.firewall.interfaces) open.
  opened =
    scope:
    lib.filter (
      port:
      lib.elem port scope.allowedTCPPorts
      || lib.any (range: range.from <= port && port <= range.to) scope.allowedTCPPortRanges
    ) sshd.ports;
  everywhere = opened firewall;
  # The entries of networking.firewall.interfaces, other than NetBird's, that
  # open one: by name, which iptables reads as a pattern when it ends in `+`,
  # and "default", which stands for every interface.
  elsewhere = lib.filterAttrs (name: scope: name != interface && opened scope != [ ]) firewall.interfaces;
  # Loopback is trusted by default, and is no network the laptop roams on.
  trusted = lib.filter (name: name != interface && name != "lo") firewall.trustedInterfaces;
  ipAddress = builtins.match "([0-9]+[.]){3}[0-9]+|.*:.*" config.ravnix.server.netbirdAddress != null;

  laptop = cfg.side == "laptop" && cfg.publicKey != null;
  server = cfg.side == "server" && cfg.identityFile != null;
in
{
  options.ravnix.laptopAccess.side = mkOption {
    type = types.nullOr (
      types.enum [
        "laptop"
        "server"
      ]
    );
    default = config.ravnix.shape;
    defaultText = lib.literalExpression "config.ravnix.shape";
    description = ''
      Which end of the connection this host is: `laptop` takes ssh over NetBird
      from the server (when `ravnix.laptopAccess.publicKey` is set), `server`
      gets the `ravnix-laptop` command (when `ravnix.laptopAccess.identityFile`
      is set). It is the shape of the host (`ravnix.shape`), which
      nixosModules.laptop and nixosModules.server set; a host without a shape
      is no end (the glue refuses such a host, once, in modules/glue/shape.nix).
    '';
  };

  config = lib.mkMerge [
    (lib.mkIf laptop {
      services.openssh = {
        enable = true;
        # Its default opens the port on every interface.
        openFirewall = false;
        # Only the key this module writes below: not ~/.ssh/authorized_keys,
        # and not another account.
        authorizedKeysInHomedir = false;
        settings = {
          PasswordAuthentication = false;
          KbdInteractiveAuthentication = false;
          PermitRootLogin = "no";
          AllowUsers = [ user ];
        };
      };

      networking.firewall.interfaces = lib.optionalAttrs (interface != null) {
        ${interface}.allowedTCPPorts = sshd.ports;
      };

      users.users.${user}.openssh.authorizedKeys.keys = [
        ''restrict,from="${config.ravnix.server.netbirdAddress}" ${cfg.publicKey}''
      ];

      assertions = [
        {
          assertion = firewall.enable;
          message = "ravnix.laptopAccess: the laptop needs networking.firewall.enable: the firewall is what keeps the ssh port shut on every interface but NetBird's";
        }
        {
          assertion = interface != null;
          message = "ravnix.laptopAccess: the laptop has no NetBird client to take the interface from; enable services.netbird (modules/desktop/vpn.nix does)";
        }
        {
          assertion = everywhere == [ ];
          message = "ravnix.laptopAccess: port ${toString everywhere} is open on every interface (networking.firewall.allowedTCPPorts or allowedTCPPortRanges); the laptop's ssh port is open on NetBird's interface alone";
        }
        {
          assertion = elsewhere == { };
          message = "ravnix.laptopAccess: the ssh port is open on ${lib.concatStringsSep ", " (lib.attrNames elsewhere)} (networking.firewall.interfaces; \"default\" is every interface, and a name ending in + a pattern); the laptop's ssh port is open on NetBird's interface alone";
        }
        {
          assertion = trusted == [ ];
          message = "ravnix.laptopAccess: networking.firewall.trustedInterfaces names ${lib.concatStringsSep ", " trusted}, which accepts everything, the ssh port included; only NetBird's interface may be trusted";
        }
        {
          assertion = ipAddress;
          message = "ravnix.laptopAccess: ravnix.server.netbirdAddress is ${config.ravnix.server.netbirdAddress}, a name; the laptop pins the key to it with from=, which sshd matches against the address a connection comes from, so it must be an IP address";
        }
      ];
    })

    (lib.mkIf server {
      environment.systemPackages = [
        (pkgs.ravnix.ravnix-laptop.override {
          address = huginn;
          inherit user;
          inherit (cfg) identityFile hostKey;
        })
      ];

      warnings = lib.optional (cfg.hostKey == null) "ravnix.laptopAccess.hostKey is null, so ravnix-laptop trusts the first host key the laptop shows and remembers it. Once huginn is installed, copy /etc/ssh/ssh_host_ed25519_key.pub from it into ravnix.laptopAccess.hostKey, and the command refuses every other key from its first use on.";

      assertions = [
        {
          assertion = huginn != null;
          message = "ravnix.laptopAccess: ravnix.hosts.huginn is not set; its address in your NetBird network is where ravnix-laptop connects to";
        }
      ];
    })
  ];
}
