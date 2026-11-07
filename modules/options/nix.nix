# The Nix binary cache and the remote builder: what a host needs to use them
# besides their place, which ravnix.services.nix-cache and
# ravnix.services.nix-builder give. Both run in one container
# (deploy/compose/nix-builder), which prints the two public keys below at its
# first start. Every value has a default, because most hosts of most users
# have no builder; modules/services/nix-cache.nix and nix-builder.nix assert
# the ones an enabled service needs.
{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.ravnix.nixCache.publicKey = mkOption {
    # An ed25519 public key: a name, a colon and 32 bytes in base64.
    type = types.nullOr (types.strMatching "[A-Za-z0-9._-]+:[A-Za-z0-9+/]{43}=");
    default = null;
    example = "cache.example.org-1:rL9Ff7wZpxDq4Wv3mN2hK5sT8yU1oE6aG0jC3bV7nXA=";
    description = ''
      The public half of the cache's signing key, `name:base64`, as the cache
      prints it at its first start. Hosts trust paths it signed. The secret
      half stays on the cache host and in the password manager.
    '';
  };

  options.ravnix.nixBuilder = {
    hostKey = mkOption {
      # base64 of the whole .pub line; a raw line has a space and fails.
      type = types.nullOr (types.strMatching "[A-Za-z0-9+/]+={0,2}");
      default = null;
      example = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUV4YW1wbGVPbmx5Tm90QVJlYWxLZXlFeGFtcGxlT25seU5vdEFSZWFsS2V5IG5peC1idWlsZGVyCg==";
      description = ''
        The builder's SSH host public key, base64-encoded as a whole line
        (`base64 -w0 ssh_host_ed25519_key.pub`), as the builder prints it at
        its first start. Pinned, so no host trusts the builder on first use.
      '';
    };

    sshUser = mkOption {
      type = types.strMatching "[a-z_][a-z0-9_-]*";
      default = "nix-builder";
      description = "The user the hosts log in to the builder as.";
    };

    sshKey = mkOption {
      # A string, not a path: a path would copy the key into the store.
      type = types.strMatching "/.+";
      default = "/etc/nix/nix-builder_ed25519";
      description = ''
        The private key root logs in to the builder with: an absolute path on
        the host, to a file only root can read, written there from the
        password manager. It must not be in the Nix store.
      '';
    };

    kvm = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = ''
        Whether the builder's build users can open /dev/kvm, as its start log
        says. Then it gets the kvm and nixos-test features, and nixosTests
        run there.
      '';
    };

    maxJobs = mkOption {
      type = types.ints.positive;
      default = 4;
      description = "How many builds a host runs on the builder at once.";
    };

    speedFactor = mkOption {
      type = types.ints.positive;
      default = 1;
      description = "How much faster the builder is than other machines that could build, for Nix to choose between them.";
    };

    systems = mkOption {
      type = types.nonEmptyListOf types.nonEmptyStr;
      default = [ "x86_64-linux" ];
      description = "The systems the builder builds for.";
    };
  };
}
