# A host that imports this hands its builds to the builder placed by
# ravnix.services.nix-builder (deploy/compose/nix-builder): one ssh-ng
# machine in /etc/nix/machines, with the builder's host key pinned. With
# ravnix.nixBuilder.kvm it also takes the builds that need KVM, nixosTests
# among them.
#
# What that costs: the builder gets nearly every build the host cannot
# substitute, ravnix's own, every flake input's and every nixosTest, and runs
# it without the Nix sandbox, as the container's build users, with the
# container's world-readable files in reach. Its egress rule keeps those
# builds off the LAN, the mesh and the NAS itself, not off the internet.
# Their outputs are signed by the cache every host trusts, so a build that
# behaves differently without the sandbox gives every host that output. The
# host's own `sandbox = true` no longer describes where its builds run.
#
# The private key root logs in with is a root-only file on the host, written
# by hand from the password manager (ravnix.nixBuilder.sshKey): a deliberate
# exception to secrets from rbw at runtime, because the root Nix daemon
# builds unattended, for example while muninn's update timer runs and rbw is
# locked.
{ config, lib, ... }:
let
  service = config.ravnix.services.nix-builder or { enable = false; };
  cfg = config.ravnix.nixBuilder;
in
{
  config = lib.mkIf service.enable {
    assertions = [
      {
        assertion = cfg.hostKey != null;
        message = "ravnix.services.nix-builder is enabled, but ravnix.nixBuilder.hostKey is not set. The builder prints it at its first start (`SSH host key for nix.buildMachines.*.publicHostKey:` in its log).";
      }
      {
        assertion = !lib.hasPrefix "${builtins.storeDir}/" cfg.sshKey;
        message = "ravnix.nixBuilder.sshKey is \"${cfg.sshKey}\", in the Nix store, which every user of the host can read. Point it at a file only root can read.";
      }
    ];

    nix.distributedBuilds = true;
    nix.buildMachines = [
      {
        # Nix reads a port in ssh-ng://user@host:port and pins the host key
        # for it (tests/services/nix-builder.md).
        hostName = service.authority;
        protocol = "ssh-ng";
        inherit (cfg)
          sshUser
          sshKey
          maxJobs
          speedFactor
          systems
          ;
        supportedFeatures =
          if cfg.kvm then
            [
              "kvm"
              "big-parallel"
              "nixos-test"
            ]
          else
            [ "big-parallel" ];
        publicHostKey = cfg.hostKey;
      }
    ];
    # The builder fetches from cache.nixos.org itself instead of receiving
    # every input through this host's uplink.
    nix.settings.builders-use-substitutes = true;

    # Nix gives its ssh no timeouts, so an unreachable builder held a build
    # for the kernel's SYN timeout (about two minutes), and one that went
    # silent mid-build, a closed lid or another network, until TCP keepalive
    # gave up (over two hours). The daemon appends these to every ssh it
    # starts.
    systemd.services.nix-daemon.environment.NIX_SSHOPTS = lib.mkDefault "-oConnectTimeout=5 -oServerAliveInterval=15 -oServerAliveCountMax=4";
  };
}
