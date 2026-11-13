# The VPN commands of huginn: `nord` and `vpn-home`. Every personal value is a
# typed option of modules/options/peripherals.nix (ravnix.vpn.*); the secrets
# stay in Bitwarden and rbw reads them when a command runs.
#
# NetBird, the mesh the laptop roams on, is not here: both shapes share one
# client, which modules/glue/netbird.nix sets up, with the reasons for each
# setting.
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
in
{
  config = lib.mkMerge [
    {
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
