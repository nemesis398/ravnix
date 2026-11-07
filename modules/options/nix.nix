# The Nix binary cache and the remote builder: what a host needs to use them
# besides their place, which ravnix.services.nix-cache and
# ravnix.services.nix-builder give. Both run in one container
# (deploy/compose/nix-builder), which prints the two public keys below at its
# first start. Every value has a default, because most hosts of most users
# have no builder; modules/services/nix-cache.nix and nix-builder.nix assert
# the ones an enabled service needs.
#
# None of these types comes from types.nix: the keys are base64, and the
# builder's values end up in the space-separated /etc/nix/machines, so they
# refuse whitespace where types.nix's absolutePath allows it.
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
      prints it at its first start. Hosts trust every path it signed, and it
      signs every path in the builder's store, including what a host holding
      the builder key uploaded unsigned. So trusting this key means trusting
      root on every host that holds ravnix.nixBuilder.sshKey. The secret half
      stays on the cache host and in the password manager.
    '';
  };

  options.ravnix.nixBuilder = mkOption {
    default = { };
    description = ''
      How a host hands its builds to the builder that
      ravnix.services.nix-builder places. A host that enables it sends the
      builder nearly every build it cannot substitute: its own, every flake
      input's, every nixosTest. Builds there run without the Nix sandbox, as
      the container's build users, and can read the container's
      world-readable files. While the builder's egress rule
      (deploy/compose/nix-builder/firewall.sh) holds, they reach the
      internet from the NAS but not the LAN, the mesh or the NAS itself. The
      builder probes the rule from inside before it serves and every ten
      seconds after, and stops serving builds after three failed probes in a
      row, so up to about half a minute of builds can run without it. The
      router's public address is not covered. Their outputs are signed by the
      cache that every host trusts ahead of cache.nixos.org, so a build that
      behaves differently without the sandbox gives every host that
      different output. The host's own `sandbox = true` no longer
      describes where those builds run.
    '';
    type = types.submodule {
      options = {
        hostKey = mkOption {
          # base64 of the whole .pub line; a raw line has a space and fails.
          type = types.nullOr (types.strMatching "[A-Za-z0-9+/]+={0,2}");
          default = null;
          example = "c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5URTVBQUFBSUV4YW1wbGVPbmx5Tm90QVJlYWxLZXlFeGFtcGxlT25seU5vdEFSZWFsS2V5IG5peC1idWlsZGVyCg==";
          description = ''
            The builder's SSH host public key, base64-encoded as a whole line
            (`base64 -w0 ssh_host_ed25519_key.pub`), as the builder prints it
            at its first start. Pinned, so no host trusts the builder on first
            use.
          '';
        };

        sshUser = mkOption {
          type = types.strMatching "[a-z_][a-z0-9_-]*";
          default = "nix-builder";
          description = "The user the hosts log in to the builder as.";
        };

        sshKey = mkOption {
          # A string, not a path: a path would copy the key into the store. No
          # whitespace, because the machines file separates its fields by it.
          type = types.strMatching "/[^[:space:]]+";
          default = "/etc/nix/nix-builder_ed25519";
          description = ''
            The private key root logs in to the builder with: a file on the
            host, mode 0600 and owned by root, outside the Nix store. Today
            ravnix does not write it: the user creates it by hand from the
            password manager's item, for example
            `sudo install -m 600 /dev/stdin /etc/nix/nix-builder_ed25519`, on
            every host that enables the builder, and replaces it there when
            the key changes. A host without the file builds locally.

            This is a deliberate exception to "secrets come from the password
            manager at runtime through rbw": the root Nix daemon builds
            unattended, for example while muninn's update timer runs and rbw
            is locked, so the key has to be on disk.

            The key is also a key to the cache: whatever a host that holds it
            uploads, the cache signs for every other host.
          '';
        };

        kvm = mkOption {
          type = types.bool;
          default = false;
          example = true;
          description = ''
            Whether the builder's build users can open /dev/kvm, as its start
            log says. Then it gets the kvm and nixos-test features, and
            nixosTests run there.
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
          # Nix system names, such as x86_64-linux; the machines file joins
          # them with commas.
          type = types.nonEmptyListOf (types.strMatching "[a-z0-9_]+-[a-z0-9_]+");
          default = [ "x86_64-linux" ];
          description = "The systems the builder builds for.";
        };
      };
    };
  };
}
