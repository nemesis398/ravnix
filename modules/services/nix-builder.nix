# A host that imports this hands its builds to the builder placed by
# ravnix.services.nix-builder (deploy/compose/nix-builder): one ssh-ng
# machine in /etc/nix/machines, with the builder's host key pinned. With
# ravnix.nixBuilder.kvm it also takes the builds that need KVM, nixosTests
# among them.
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
  };
}
