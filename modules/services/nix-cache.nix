# A host that imports this asks the binary cache placed by
# ravnix.services.nix-cache before cache.nixos.org, and trusts the paths its
# key signed. The cache (deploy/compose/nix-builder) serves the builder's own
# store, so whatever was built there, and everything the builder fetched to
# build it, comes from the LAN.
{ config, lib, ... }:
let
  service = config.ravnix.services.nix-cache or { enable = false; };
  key = config.ravnix.nixCache.publicKey;
in
{
  config = lib.mkIf service.enable {
    assertions = [
      {
        assertion = key != null;
        message = "ravnix.services.nix-cache is enabled, but ravnix.nixCache.publicKey is not set. The cache prints its public key at its first start (`cache public key:` in its log).";
      }
    ];

    nix.settings = {
      # NixOS appends cache.nixos.org with mkAfter, so this one is asked
      # first; the cache's own priority (30, ahead of cache.nixos.org's 40)
      # says the same.
      substituters = [ service.url ];
      trusted-public-keys = lib.optional (key != null) key;
      # A host away from the LAN, or a cache that is down, would otherwise
      # stall each Nix command for curl's default of five minutes before
      # Nix moves on to cache.nixos.org.
      connect-timeout = lib.mkDefault 5;
      # A miss is remembered for an hour by default, so a path the builder
      # finished after a host asked for it stayed invisible to that host
      # (seen in tests/services/nix-builder.md). A minute costs one more
      # lookup per missing path.
      narinfo-cache-negative-ttl = lib.mkDefault 60;
    };
  };
}
