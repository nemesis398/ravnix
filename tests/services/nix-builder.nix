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
  # The types themselves, so a refusal is the type's and not any other
  # failure. A list's own check only asks for a list; its elements are
  # checked by the element type.
  sub = off.options.ravnix.nixBuilder.type.getSubOptions [ ];
  accepts = option: value: sub.${option}.type.check value;
  systemAccepted = sub.systems.type.nestedTypes.elemType.check;
  sshOpts = h: h.config.systemd.services.nix-daemon.environment.NIX_SSHOPTS or null;

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
    # A builder that cannot be reached, or that goes silent mid-build, ends
    # the daemon's ssh within seconds instead of the kernel's timeouts.
    ++ expect "NIX_SSHOPTS of the daemon with a builder" (sshOpts kvm)
      "-oConnectTimeout=5 -oServerAliveInterval=15 -oServerAliveCountMax=4"
    ++ expect "NIX_SSHOPTS of the daemon without a builder" (sshOpts off) null
    ++ expect "the base64 host key is accepted" (accepts "hostKey" hostKey) true
    ++ expect "a host key pasted as a raw line, not base64" (accepts "hostKey"
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnlyNotARealKeyExampleOnlyNotARealKey nix-builder"
    ) false
    ++ expect "the default key path is accepted" (accepts "sshKey" "/etc/nix/nix-builder_ed25519") true
    ++ expect "a relative private key path" (accepts "sshKey" "etc/nix/key") false
    # The machines file separates its fields by spaces, and lists systems
    # with commas, so a value with either would shift every field after it.
    ++ expect "a private key path with a space" (accepts "sshKey" "/etc/nix/builder key") false
    ++ expect "a system name is accepted" (systemAccepted "aarch64-linux") true
    ++ expect "a system with a comma" (systemAccepted "x86_64-linux,i686-linux") false
    ++ expect "a system with a space" (systemAccepted "x86_64-linux ") false
    ++ expect "an empty list of systems" (accepts "systems" [ ]) false
    ++ expect "a user that ssh would read as an option" (accepts "sshUser" "-oProxyCommand=x") false
    ++ expect "maxJobs = 0" (accepts "maxJobs" 0) false;
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
