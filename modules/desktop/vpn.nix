# The VPNs of huginn: NetBird, the mesh the laptop roams on, and the `nord`
# and `vpn-home` commands. Every personal value is a typed option of
# modules/options/peripherals.nix (ravnix.vpn.*); the secrets stay in
# Bitwarden and rbw reads them when a command runs.
#
# NetBird. NixOS's module manages the client, `netbird.service`, on wt0, as
# the Fedora package does. Two of its defaults open ports that Fedora's
# firewall keeps shut, and both are turned off:
#   - openFirewall opens 51820/udp for direct peer connections. Fedora's
#     public zone has ssh, mdns and dhcpv6-client and nothing for NetBird;
#     peers reach this client through hole punching and the relays, which
#     need no inbound port.
#   - openInternalFirewall opens 5353 and 22054 (udp) on wt0 for the DNS
#     forwarder of a routing peer. This client forwards nothing.
# `useRoutingFeatures = "client"` is what NetBird's routes need (the home
# LAN behind a routing peer, an exit node): it loosens reverse path filtering
# to "loose", as Fedora's kernel default is, and opens no port. The UI is not
# installed, as on Fedora (NETBIRD_SKIP_UI_APP).
# The management server is written into the client's config before it first
# starts (config.d, merged by the module), so one command enrolls with it:
#
#   netbird up --setup-key-file <(rbw get SETUP-KEY-ITEM)
#
# The setup key of a reusable group enrolls any machine into the mesh, so it
# never goes on a command line, where every local user reads it from /proc
# while `netbird up` runs and the shell keeps it in its history.
# --setup-key-file is read by the CLI itself, so a process substitution works,
# and rbw reads the key from the vault at that moment.
#
# NordVPN is a NetworkManager WireGuard profile that `nord setup` builds once.
# That needs NetworkManager, and systemd-resolved to route DNS: the profile's
# "~." routing domain and NetBird's split-DNS domain on wt0 are told apart by
# resolved, which picks the longest. Both are enabled here with mkDefault, so
# that a host can still choose otherwise.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ravnix.vpn;

  # NetBird's config.json holds the management URL as a Go url.URL, an object;
  # only the scheme and the host with its port decide where the client goes.
  managementUrl =
    let
      m = builtins.match "(https?)://([A-Za-z0-9.-]+)(:([0-9]+))?/?" cfg.netbird.managementUrl;
      scheme = builtins.elemAt m 0;
      port =
        if builtins.elemAt m 3 != null then
          builtins.elemAt m 3
        else if scheme == "https" then
          "443"
        else
          "80";
    in
    {
      Scheme = scheme;
      Host = "${builtins.elemAt m 1}:${port}";
    };
in
{
  config = lib.mkMerge [
    {
      services.netbird = {
        enable = true;
        ui.enable = false;
        useRoutingFeatures = "client";
        clients.default = {
          openFirewall = false;
          openInternalFirewall = false;
          config.ManagementURL = managementUrl;
        };
      };

      networking.networkmanager.enable = lib.mkDefault true;
      networking.networkmanager.dns = lib.mkDefault "systemd-resolved";
      services.resolved.enable = lib.mkDefault true;
    }

    (lib.mkIf (cfg.nord != null) {
      environment.systemPackages = [
        (pkgs.ravnix.nord.override {
          inherit (cfg.nord) countryId tokenItem keyItem;
        })
      ];
    })

    (lib.mkIf (cfg.home != null) {
      environment.systemPackages = [
        (pkgs.ravnix.vpn-home.override {
          inherit (cfg.home) apiUrl tokenItem;
        })
      ];
    })
  ];
}
