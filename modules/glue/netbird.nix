# The NetBird client of both shapes: the mesh the laptop roams on, and the one
# the server is reached by (muninn runs commands on huginn over it, and huginn
# takes its ssh from muninn's address in it: modules/glue/laptop-access.nix).
# One definition, because the two hosts must agree on the management server
# and on what the client may do. The personal value is
# ravnix.vpn.netbird.managementUrl (modules/options/peripherals.nix); the
# secrets stay in Bitwarden. The laptop's NordVPN and home VPN commands stay in
# modules/desktop/vpn.nix.
#
# NixOS's module manages the client, `netbird.service`, on wt0, as the Fedora
# package does. Two of its defaults open ports, and both are turned off on
# both shapes:
#   - openFirewall opens 51820/udp for direct peer connections. Fedora's
#     public zone has ssh, mdns and dhcpv6-client and nothing for NetBird,
#     and the server's firewall opens only what its own modules name; peers
#     reach a client through hole punching and the relays, which need no
#     inbound port.
#   - openInternalFirewall opens 5353 and 22054 (udp) on wt0 for the DNS
#     forwarder of a routing peer. These clients forward nothing.
# So no port opens on either host. (NixOS still lists wt0 in
# networking.firewall.interfaces, with empty lists.) The UI is not installed,
# as on Fedora (NETBIRD_SKIP_UI_APP), and a server has no screen.
#
# The management server is written into the client's config before it first
# starts (config.d, merged by the module), so one command enrolls with it:
#
#   netbird up --setup-key-file <(rbw get SETUP-KEY-ITEM)     # huginn
#   some-command-printing-the-key | netbird up --setup-key-file /dev/stdin
#                                                               # muninn
#
# The setup key of a reusable group enrolls any machine into the mesh, so it
# never goes on a command line, where every local user reads it from /proc
# while `netbird up` runs and the shell keeps it in its history.
# --setup-key-file is read by the CLI itself, so a process substitution or a
# pipe on stdin works. The client "default" gives the plain name `netbird`, on
# the PATH of both hosts.
#
# What a shape asks for besides that:
#
# The laptop: useRoutingFeatures = "client", which is what NetBird's routes
# need (the home LAN behind a routing peer, an exit node). In NixOS that
# loosens reverse path filtering to "loose", as Fedora's kernel default is,
# and opens no port; the laptop takes the routes, since it leaves the house.
#
# The server: useRoutingFeatures = "none", and the client takes no routes
# (DisableClientRoutes in its config; `netbird up --disable-client-routes` is
# the same). The server sits in the house, on a VLAN of its own, and reaches
# the other networks of the house through its gateway. NetBird (0.82, the
# Linux client with its own routing table) puts the routes it learns from a
# routing peer into that table, and a rule ahead of it, `from all lookup main
# suppress_prefixlength 0`, lets any route of the main table that is not the
# default route win. So a network the server is attached to directly stays
# direct, but a home network behind the gateway, which the main table reaches
# by the default route alone, would go into the tunnel and through the routing
# peer: the server's DNS servers and everything else on the house's other
# VLANs, over the mesh and back. The server needs the peers (the laptop at its
# mesh address) and no route, so it accepts none. Without routes there is
# nothing for "client" to loosen, so the reverse path filter is left as the
# host has it (the packets of peers come from the mesh's own addresses, which
# wt0 reaches, so even a strict filter passes them), and nothing is forwarded. To let a server take a route after all, set
# `services.netbird.clients.default.config.DisableClientRoutes = false` and
# `services.netbird.useRoutingFeatures = "client"` in the host.
#
# DNS. NetBird's client finds out how the host resolves names (client/
# internal/dns, host_unix.go) and adds its own, never replacing the host's
# way: with systemd-resolved it sets the DNS servers and the domains of wt0
# alone (per link), with resolvconf (openresolv, which NixOS has when
# resolved is off, and which the unit then gets on its PATH) it adds its
# configuration to the merged file, and with a plain /etc/resolv.conf it puts
# its own server first and keeps the original servers as its fallback. In all
# three the server keeps resolving its LAN names and the internet through the
# resolvers it has, and NetBird adds the mesh's domain. This module turns
# neither resolved nor NetworkManager on for the server (the laptop's
# vpn.nix does, for nord's sake). The one thing the client cannot decide is
# what the management server pushes: a nameserver group for every domain
# (match-all) would send the host's lookups to it. That is the mesh
# administrator's choice, made in the dashboard; the client has
# DisableDNS in its config (`netbird up --disable-dns`) to refuse every
# nameserver of the dashboard, and the server does not set it, because the
# mesh's own names are useful to it.
#
# A host without ravnix.vpn.netbird.managementUrl gets no client at all and a
# failed assertion that names the option (modules/options/default.nix), as
# any missing value does; a client that enrolls with no server to enroll with
# would be worse than no client.
#
# The container form of the server (hosts/server/oci.nix) cannot run a
# tunnel: it has no /dev/net/tun and no NET_ADMIN, and the unit would fail
# for ever. It turns the client off; the settings below follow
# services.netbird.enable.
{
  config,
  lib,
  options,
  ...
}:
let
  cfg = config.ravnix.vpn.netbird;
  server = config.ravnix.shape == "server";

  # NetBird's config.json holds the management URL as a Go url.URL, an object;
  # only the scheme and the host with its port decide where the client goes.
  managementUrl =
    let
      m = builtins.match "(https?)://([A-Za-z0-9.-]+)(:([0-9]+))?/?" cfg.managementUrl;
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
    # The client is on unless a host turns it off (the container form), and
    # only where there is a management server to name.
    (lib.mkIf options.ravnix.vpn.netbird.managementUrl.isDefined {
      services.netbird.enable = lib.mkDefault true;
    })

    (lib.mkIf config.services.netbird.enable {
      services.netbird = {
        ui.enable = false;
        clients.default = {
          openFirewall = false;
          openInternalFirewall = false;
          config.ManagementURL = managementUrl;
        };
      };
    })

    (lib.mkIf (config.services.netbird.enable && !server) {
      services.netbird.useRoutingFeatures = "client";
    })

    (lib.mkIf (config.services.netbird.enable && server) {
      services.netbird.useRoutingFeatures = "none";
      services.netbird.clients.default.config.DisableClientRoutes = true;
    })
  ];
}
