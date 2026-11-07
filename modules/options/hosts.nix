# The host registry: every machine that runs a ravnix host or a service, how
# it runs workloads and where it is reached. Services name a host from here.
{ lib, ... }:
let
  inherit (lib) mkOption types;
  ravnix = import ./types.nix { inherit lib; };
in
{
  options.ravnix.hosts = mkOption {
    default = { };
    description = "The machines your hosts and services run on, by a name of your choice.";
    type = types.attrsOf (
      types.submodule {
        options = {
          address = mkOption {
            type = ravnix.address;
            example = "192.0.2.10";
            description = "Where the host is reached: an IPv4 or IPv6 address, or a DNS name.";
          };

          runtime = mkOption {
            type = types.enum [
              "nixos"
              "docker"
              "proxmox-ct"
              "external"
            ];
            description = ''
              How the host runs workloads: `nixos` builds from this flake,
              `docker` gets compose files, `proxmox-ct` gets guest
              definitions, and `external` only serves what already runs there.
            '';
          };

          sshTarget = mkOption {
            type = types.nullOr ravnix.sshTarget;
            default = null;
            example = "admin@nas.example.org";
            description = "How ssh reaches the host: `[user@]host` (host an address or an ssh alias) or `ssh://[user@]host[:port]`; null when nothing logs in.";
          };
        };
      }
    );
  };
}
