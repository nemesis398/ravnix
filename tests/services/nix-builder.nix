# modules/services/nix-builder.nix makes a host hand its builds to the
# builder that ravnix.services.nix-builder places: one ssh-ng machine in
# /etc/nix/machines, with the builder's host key pinned and the features
# nixosTests need when the builder has KVM. A disabled builder changes
# nothing, an enabled one without its host key fails an assertion naming the
# option, a host key pasted as a raw line instead of base64 is refused, so
# is a private key path inside the Nix store, and the machine follows the
# service to another host, an IPv6 one in brackets.
{
  self,
  inputs,
  pkgs,
  lib,
  ...
}:
let
  host = import ./helpers/host.nix { inherit inputs lib self; };
  module = ../../modules/services/nix-builder.nix;
  # base64 of "ssh-ed25519 AAAA…ExampleOnly… nix-builder\n"; not a real key.
  hostKey = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUV4YW1wbGVPbmx5Tm90QVJlYWxLZXlFeGFtcGxlT25seU5vdEFSZWFsS2V5IG5peC1idWlsZGVyCg==";

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
    ravnix.services.nix-builder = {
      enable = true;
      host = on;
      port = 2222;
    };
  };
  builder = values: { ravnix.nixBuilder = lib.mapAttrs (_: lib.mkForce) values; };
  with' =
    on: values:
    host [
      module
      hosts
      (placed on)
      (builder ({ inherit hostKey; } // values))
    ];

  kvm = with' "box-a" { kvm = true; };
  noKvm = with' "box-a" { kvm = false; };
  moved = with' "box-b" { kvm = true; };
  tuned = with' "box-a" {
    kvm = true;
    sshUser = "builder";
    sshKey = "/root/.ssh/builder";
    maxJobs = 8;
    speedFactor = 2;
  };
  # The template sets every value, but no builder is placed.
  off = host [ module ];
  hostKeyless = with' "box-a" { hostKey = null; };
  inStore = with' "box-a" { sshKey = "${builtins.storeDir}/abc-key"; };
  refused =
    values:
    !(builtins.tryEval (builtins.deepSeq (with' "box-a" values).config.ravnix.nixBuilder true)).success;

  machines = h: h.config.environment.etc."nix/machines".text or null;
  line =
    target: features: "ssh-ng://${target} x86_64-linux /etc/nix/nix-builder_ed25519 4 1 ${features} - ${hostKey}\n";
  ravnixFailed = h: lib.filter (lib.hasInfix "ravnix") h.failed;
  expect =
    what: got: want:
    lib.optional (got != want) "${what}: expected ${builtins.toJSON want}, got ${builtins.toJSON got}";

  failures =
    expect "machines of a builder with KVM" (machines kvm) (
      line "nix-builder@198.51.100.7:2222" "kvm,big-parallel,nixos-test"
    )
    ++ expect "machines of a builder without KVM" (machines noKvm) (
      line "nix-builder@198.51.100.7:2222" "big-parallel"
    )
    ++ expect "machines after the builder moved to an IPv6 host" (machines moved) (
      line "nix-builder@[2001:db8::7]:2222" "kvm,big-parallel,nixos-test"
    )
    ++ expect "machines with every value set" (machines tuned) ''
      ssh-ng://builder@198.51.100.7:2222 x86_64-linux /root/.ssh/builder 8 2 kvm,big-parallel,nixos-test - ${hostKey}
    ''
    ++ expect "distributedBuilds with a builder" kvm.config.nix.distributedBuilds true
    ++ expect "builders-use-substitutes" (kvm.config.nix.settings.builders-use-substitutes or null) true
    ++ expect "failed assertions of a host with a builder" (ravnixFailed kvm) [ ]
    ++ expect "a host without a builder has a machines file" (
      off.config.environment.etc ? "nix/machines"
    ) false
    ++ expect "distributedBuilds without a builder" off.config.nix.distributedBuilds false
    ++ expect "failed assertions of a host without a builder" (ravnixFailed off) [ ]
    ++ lib.optional (
      lib.filter (lib.hasInfix "ravnix.nixBuilder.hostKey") hostKeyless.failed == [ ]
    ) "a builder without a host key failed no assertion naming ravnix.nixBuilder.hostKey; failed: ${toString hostKeyless.failed}"
    ++ lib.optional (
      lib.filter (lib.hasInfix "ravnix.nixBuilder.sshKey") inStore.failed == [ ]
    ) "a private key path in the Nix store failed no assertion naming ravnix.nixBuilder.sshKey; failed: ${toString inStore.failed}"
    ++ lib.optional (
      !refused {
        hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnlyNotARealKeyExampleOnlyNotARealKey nix-builder";
      }
    ) "a host key pasted as a raw line, not base64, was accepted"
    ++ lib.optional (!refused { sshKey = "etc/nix/key"; }) "a relative private key path was accepted"
    ++ lib.optional (!refused { maxJobs = 0; }) "maxJobs = 0 was accepted";
in
pkgs.runCommand "services-nix-builder" { } (
  if failures == [ ] then
    "touch $out"
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
