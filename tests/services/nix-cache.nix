# modules/services/nix-cache.nix makes a host use the binary cache that
# ravnix.services.nix-cache places: its url as the first substituter, ahead
# of cache.nixos.org, and its key as trusted, with a short connect timeout so
# a host away from the cache does not hang. A disabled cache changes nothing,
# an enabled one without its key fails an assertion naming the option, a
# malformed key is refused, the url follows the service to another host, and
# a host can still override the timeouts.
{
  self,
  inputs,
  pkgs,
  lib,
  ...
}:
let
  host = import ./helpers/host.nix { inherit inputs lib self; };
  module = ../../modules/services/nix-cache.nix;
  upstream = "https://cache.nixos.org/";
  upstreamKey = "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=";
  key = "cache.example.org-1:rL9Ff7wZpxDq4Wv3mN2hK5sT8yU1oE6aG0jC3bV7nXA=";

  hosts.ravnix.hosts = {
    box-a = {
      address = "198.51.100.7";
      runtime = "docker";
    };
    box-b = {
      address = "2001:db8::7";
      runtime = "docker";
    };
  };
  placed = on: {
    ravnix.services.nix-cache = {
      enable = true;
      host = on;
      port = 8501;
    };
  };
  withKey = value: { ravnix.nixCache.publicKey = lib.mkForce value; };

  on = host [
    module
    hosts
    (placed "box-a")
    (withKey key)
  ];
  moved = host [
    module
    hosts
    (placed "box-b")
    (withKey key)
  ];
  # The template sets a key, but no cache is placed.
  off = host [ module ];
  keyless = host [
    module
    hosts
    (placed "box-a")
    (withKey null)
  ];
  malformed = builtins.tryEval (
    (host [
      module
      hosts
      (placed "box-a")
      (withKey "cache.example.org-1:not base64")
    ]).config.nix.settings.trusted-public-keys
  );
  overridden = host [
    module
    hosts
    (placed "box-a")
    (withKey key)
    { nix.settings.connect-timeout = 30; }
  ];

  ravnixFailed = h: lib.filter (lib.hasInfix "ravnix") h.failed;
  expect =
    what: got: want:
    lib.optional (got != want) "${what}: expected ${builtins.toJSON want}, got ${builtins.toJSON got}";

  failures =
    expect "substituters of a host with the cache" on.config.nix.settings.substituters [
      "http://198.51.100.7:8501"
      upstream
    ]
    ++ expect "the cache's key is trusted" (lib.elem key on.config.nix.settings.trusted-public-keys) true
    ++ expect "cache.nixos.org's key stays trusted" (lib.elem upstreamKey on.config.nix.settings.trusted-public-keys) true
    ++ expect "connect-timeout" (on.config.nix.settings.connect-timeout or null) 5
    ++ expect "narinfo-cache-negative-ttl" (on.config.nix.settings.narinfo-cache-negative-ttl or null) 60
    ++ expect "failed assertions of a host with the cache" (ravnixFailed on) [ ]
    ++ expect "substituters after the cache moved to an IPv6 host" moved.config.nix.settings.substituters [
      "http://[2001:db8::7]:8501"
      upstream
    ]
    ++ expect "substituters of a host without the cache" off.config.nix.settings.substituters [ upstream ]
    ++ expect "the key of an unplaced cache is trusted" (lib.elem key off.config.nix.settings.trusted-public-keys) false
    ++ expect "failed assertions of a host without the cache" (ravnixFailed off) [ ]
    ++ lib.optional (
      lib.filter (lib.hasInfix "ravnix.nixCache.publicKey") keyless.failed == [ ]
    ) "a cache without a key failed no assertion naming ravnix.nixCache.publicKey; failed: ${toString keyless.failed}"
    ++ lib.optional malformed.success "a malformed cache key was accepted"
    ++ expect "a host's own connect-timeout" (overridden.config.nix.settings.connect-timeout or null) 30;
in
pkgs.runCommand "services-nix-cache" { } (
  if failures == [ ] then
    "touch $out"
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
