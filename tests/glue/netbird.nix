# The NetBird client on both shapes (modules/glue/netbird.nix), read from
# evaluated hosts. The laptop's client is what modules/desktop/vpn.nix used to
# set on its own, and the move must not change it; the server's is the same
# client with two differences, and no port opens on either.
#
#   1. The laptop, compared with the configuration it had before the move,
#      written out here: the client, its management URL from the option, the
#      loose reverse path filter, no port, no routes disabled.
#   2. The server: the client, the same management URL, `netbird` on the PATH,
#      the routes of the mesh not accepted and the reverse path filter left
#      as it was, no routing features, resolved and NetworkManager not turned on
#      by it, and the firewall exactly as the same server without the client
#      has it.
#   3. What a host without the value gets: the build is refused, the message
#      names the option, and no client is half set up.
#   4. The container form, which cannot run a tunnel, has no client.
{
  self,
  inputs,
  lib,
  system,
  ...
}:
let
  template = import ../../templates/default/me.nix;
  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };
  quiet = {
    system.stateVersion = "26.05";
    warnings = lib.mkForce [ ];
  };

  buildServer =
    modules:
    inputs.nixpkgs.lib.nixosSystem {
      modules = hostModules ++ [ { nixpkgs.hostPlatform = lib.mkDefault system; } ] ++ modules;
    };
  buildLaptop =
    modules:
    inputs.nixpkgs.lib.nixosSystem {
      modules = [
        ../../templates/default/me.nix
        quiet
      ]
      ++ modules;
    };

  server = buildServer [ self.nixosModules.server ];
  laptop = buildLaptop [
    self.nixosModules.laptop
    self.nixosModules.hardware-ideapad-pro-5-16ahp9
  ];
  # The server without a client: the baseline the firewall is compared with.
  bare = buildServer [
    self.nixosModules.server
    { services.netbird.enable = lib.mkForce false; }
  ];
  withUrl = url: [ { ravnix.vpn.netbird.managementUrl = lib.mkForce url; } ];
  # The template's values without the management URL.
  withoutUrl = {
    ravnix = template.ravnix // {
      vpn = builtins.removeAttrs template.ravnix.vpn [ "netbird" ];
    };
  };

  s = server.config;
  l = laptop.config;
  b = bare.config;

  netbird = c: c.services.netbird;
  default = c: c.services.netbird.clients.default;
  urlOf = c: (default c).config.ManagementURL;
  # NixOS's wrapper of the client, whose binary is the plain `netbird`.
  hasNetbird = c: lib.any (p: (p.meta.mainProgram or null) == "netbird") c.environment.systemPackages;
  failedOf = h: map (a: a.message) (lib.filter (a: !a.assertion) h.config.assertions);
  refused =
    h: !(builtins.tryEval (builtins.unsafeDiscardStringContext h.config.system.build.toplevel.drvPath)).success;

  # Everything the firewall lets in, per interface and globally.
  ports = fw: {
    inherit (fw)
      allowedTCPPorts
      allowedUDPPorts
      allowedTCPPortRanges
      allowedUDPPortRanges
      trustedInterfaces
      checkReversePath
      ;
    interfaces = lib.mapAttrs (_: i: {
      inherit (i)
        allowedTCPPorts
        allowedUDPPorts
        allowedTCPPortRanges
        allowedUDPPortRanges
        ;
    }) fw.interfaces;
  };
  # The same, without the interface NetBird's module names with empty lists.
  portsOf =
    c:
    let
      p = ports c.networking.firewall;
    in
    p
    // {
      interfaces = lib.filterAttrs (
        _: i:
        i != {
          allowedTCPPorts = [ ];
          allowedUDPPorts = [ ];
          allowedTCPPortRanges = [ ];
          allowedUDPPortRanges = [ ];
        }
      ) p.interfaces;
    };

  expect = ok: message: lib.optional (!ok) message;
  failures =
    # The laptop, as it was before the move.
    expect (netbird l).enable "the laptop has no NetBird client"
    ++ expect (!(netbird l).ui.enable) "the laptop installs NetBird's UI"
    ++ expect ((netbird l).useRoutingFeatures == "client") "the laptop does not accept NetBird's routes as a client: ${(netbird l).useRoutingFeatures}"
    ++ expect (!(default l).openFirewall) "the laptop's client opens its WireGuard port"
    ++ expect (!(default l).openInternalFirewall) "the laptop's client opens DNS ports on wt0"
    ++ expect ((default l).interface == "wt0" && (default l).port == 51820 && (default l).name == "netbird") "the laptop's client is not the default one: ${(default l).interface} ${toString (default l).port} ${(default l).name}"
    ++ expect (
      urlOf l == {
        Scheme = "https";
        Host = "netbird.example.org:443";
      }
    ) "the laptop's management URL is not the option's: ${builtins.toJSON (urlOf l)}"
    ++ expect (!((default l).config ? DisableClientRoutes)) "the laptop got a setting for its routes: ${builtins.toJSON (default l).config}"
    ++ expect (l.networking.firewall.checkReversePath == "loose") "the laptop's reverse path filter is not loose: ${toString l.networking.firewall.checkReversePath}"
    ++ expect (!(lib.elem 51820 l.networking.firewall.allowedUDPPorts)) "the laptop opens 51820/udp"
    ++ expect (l.services.resolved.enable && l.networking.networkmanager.enable) "the laptop lost resolved or NetworkManager"
    ++ expect (hasNetbird l) "the laptop's PATH has no netbird"
    ++ expect (l.systemd.services ? netbird) "the laptop has no netbird.service"
    # The server.
    ++ expect (netbird s).enable "the server has no NetBird client"
    ++ expect (!(netbird s).ui.enable) "the server installs NetBird's UI"
    ++ expect (!(default s).openFirewall) "the server's client opens its WireGuard port"
    ++ expect (!(default s).openInternalFirewall) "the server's client opens DNS ports on wt0"
    ++ expect (
      urlOf s == {
        Scheme = "https";
        Host = "netbird.example.org:443";
      }
    ) "the server's management URL is not the option's: ${builtins.toJSON (urlOf s)}"
    ++ expect (s.systemd.services ? netbird) "the server has no netbird.service"
    ++ expect (hasNetbird s) "the server's PATH has no netbird (netbird up --setup-key-file needs it)"
    ++ expect (
      s.environment.etc."netbird/config.d/50-nixos.json".text == builtins.toJSON (default s).config
    ) "the config the client starts with is not the one the option holds"
    # The server takes no routes: it reaches the house directly, and a route
    # of the mesh to a network behind its gateway would take that traffic
    # into the tunnel. It forwards nothing and loosens nothing.
    ++ expect ((default s).config.DisableClientRoutes == true) "the server accepts the routes of the mesh"
    ++ expect ((netbird s).useRoutingFeatures == "none") "the server has routing features: ${(netbird s).useRoutingFeatures}"
    ++ expect (s.networking.firewall.checkReversePath == b.networking.firewall.checkReversePath) "the server's reverse path filter changed: ${toString s.networking.firewall.checkReversePath}"
    ++ expect (s.boot.kernel.sysctl == b.boot.kernel.sysctl) "the server's sysctl settings changed"
    # DNS: the server's own choice of resolver stays its own.
    ++ expect (s.services.resolved.enable == b.services.resolved.enable) "the client changed whether the server runs resolved"
    ++ expect (!s.services.resolved.enable) "the server shape turns resolved on"
    ++ expect (!s.networking.networkmanager.enable) "the server shape turns NetworkManager on"
    # No port opens.
    ++ expect (portsOf s == portsOf b) "the client changed the server's firewall: ${builtins.toJSON (portsOf s)} against ${builtins.toJSON (portsOf b)}"
    ++ expect (s.networking.firewall.enable == b.networking.firewall.enable) "the client changed whether the firewall runs"
    ++ expect (!(lib.elem 51820 s.networking.firewall.allowedUDPPorts)) "51820/udp is open on the server"
    ++ expect (!(lib.elem "wt0" s.networking.firewall.trustedInterfaces)) "wt0 is a trusted interface on the server"
    # The management URL follows the option, on both ends.
    ++ lib.concatMap (
      case:
      expect (
        urlOf (buildServer ([ self.nixosModules.server ] ++ withUrl case.url)).config == case.want
      ) "the server's management URL ${case.url} is not ${builtins.toJSON case.want}"
    ) [
      {
        url = "http://nb.example.org";
        want = {
          Scheme = "http";
          Host = "nb.example.org:80";
        };
      }
      {
        url = "https://nb.example.org:8443/";
        want = {
          Scheme = "https";
          Host = "nb.example.org:8443";
        };
      }
    ]
    # A host without the value is refused, by name, and nothing is half set up.
    ++ (
      let
        none = inputs.nixpkgs.lib.nixosSystem {
          modules = [
            withoutUrl
            {
              system.stateVersion = "26.05";
              warnings = lib.mkForce [ ];
              nixpkgs.hostPlatform = system;
              boot.loader.grub.enable = false;
              fileSystems."/" = {
                device = "none";
                fsType = "tmpfs";
              };
            }
            self.nixosModules.server
          ];
        };
      in
      expect (builtins.any (lib.hasInfix "ravnix.vpn.netbird.managementUrl is not set") (failedOf none)) "without a management URL no failed assertion names it: ${toString (failedOf none)}"
      ++ expect (refused none) "a server without a management URL builds"
      ++ expect (!none.config.services.netbird.enable) "a server without a management URL gets a client with no server to enroll with"
      ++ expect (!(none.config.systemd.services ? netbird)) "a server without a management URL gets netbird.service"
    )
    # The container form cannot run a tunnel (no /dev/net/tun, no NET_ADMIN).
    ++ (
      let
        oci = buildServer [
          self.nixosModules.server
          self.nixosModules.server-oci
        ];
      in
      expect (!oci.config.services.netbird.enable) "the OCI image has a NetBird client, which cannot run in a container"
      ++ expect (!(oci.config.systemd.services ? netbird)) "the OCI image has netbird.service"
    );
in
inputs.nixpkgs.legacyPackages.${system}.runCommand "glue-netbird" { } (
  if failures == [ ] then
    "touch $out"
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
