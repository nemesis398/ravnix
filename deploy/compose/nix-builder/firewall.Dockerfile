# The image of the nix-firewall service in docker-compose.yaml: iptables from
# the pinned nixpkgs, installed into this image's own store. Not into the
# builder's store on the /nix volume: whoever holds the builder key can write
# that one, and this container runs with NET_ADMIN in the host's network
# namespace.
FROM nixos/nix:2.35.4
ARG NIXPKGS
# The garbage collection drops the nixpkgs source the install fetched.
RUN test -n "$NIXPKGS" \
 && nix --extra-experimental-features 'nix-command flakes' profile add \
      --profile /nix/var/nix/profiles/firewall "$NIXPKGS#iptables" \
 && nix --extra-experimental-features nix-command store gc \
 && rm -r /root/.cache
ENV PATH=/nix/var/nix/profiles/firewall/bin:/nix/var/nix/profiles/default/bin
