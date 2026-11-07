# Nix builder and binary cache: manual check record

The checks that `deploy/compose/nix-builder/` passed on a real host, and how to run them again. They need the host and a client, so `nix flake check` cannot run them. Its two evaluation checks, `services-nix-cache` and `services-nix-builder`, cover what `modules/services/nix-cache.nix` and `nix-builder.nix` put into a host's configuration.

Placeholders: `BUILDER` is the address the compose file binds (`NIX_BIND_ADDRESS`), `SSH_PORT` and `CACHE_PORT` are its two ports, `KEY_NAME` is `NIX_CACHE_KEY_NAME`, `CACHE_KEY` is the cache's public key and `HOST_KEY` is the base64 host key, both from the container's first log, and `CLIENT_KEY` is a file holding the client's private key.

## Run of 2026-11-07

- **Host:** a NAS with Docker 29.6.2 and Compose 5.1.3, an Intel i5-1235U with 12 threads, 31 GiB RAM, cgroup v2, AppArmor and seccomp on. `/dev/kvm` is `crw-rw---- root:kvm`.
- **Builder:** image `nixos/nix:2.35.4`, with openssh 10.6p1 and harmonia 3.3.0 from nixpkgs `26.11pre1109744.4fe25e12eb9f`.
- **Client:** Fedora with upstream Nix 2.35.4, a trusted user of its daemon, reaching `BUILDER` through a mesh VPN.
- **Client key:** a throwaway key made for this run and destroyed after it. The client key that stays is kept in the password manager.

### Before deploying: the host

| Check | Result |
| --- | --- |
| Nix sandbox in a container with Docker's default capabilities (`--option sandbox true --option sandbox-fallback false`) | refused: `this system does not support the kernel namespaces that are required for sandboxing` |
| A build user (`nixbld1`, no sandbox) opens `/dev/kvm` passed with `--device /dev/kvm` | fails while `/etc/group` has no group with the device's gid |
| The same with a group of that gid that lists the build users | `kvm-open-ok`, `groups=30000(nixbld),104(kvm)` |
| Containers that publish a port on one host address, after the host's last boot | all three got their ports, two minutes after boot, without a restart (the host's addresses are static) |

### Deploy

`docker compose up -d` took 1 min 55 s, most of it in `nix-seed` copying the image's 645 MB store. The first start of `nix-builder` installed openssh and harmonia, made both keys, and logged:

```text
start.sh: kvm usable by the build users: yes
start.sh: making the SSH host key (first start)
start.sh: SSH host key for nix.buildMachines.*.publicHostKey: HOST_KEY
start.sh: making the cache's signing key 'KEY_NAME' (first start)
start.sh: cache public key: CACHE_KEY
start.sh: running: nix-daemon, harmonia, sshd
```

`docker inspect nix-builder --format '{{json .NetworkSettings.Ports}}'` showed both ports on `BUILDER`. The host's admin account cannot list `./state`: it is `0700 root`, and the share's ACL does not widen it. The signing key is `0600 root` there and `0400 harmonia` in `/run`.

### The cache

| Check | Result |
| --- | --- |
| `curl http://BUILDER:CACHE_PORT/nix-cache-info` | `StoreDir: /nix/store`, `WantMassQuery: 1`, `Priority: 30` |
| `nix copy --to 'ssh-ng://nix-builder@BUILDER:SSH_PORT?ssh-key=CLIENT_KEY&base64-ssh-public-host-key=HOST_KEY' nixpkgs#hello` | copied |
| `nix path-info --store http://BUILDER:CACHE_PORT nixpkgs#hello` | fails: Nix writes the `.drv` into the store it is given, and the cache is read-only (`unable to upload …: HTTP error 404`) |
| `nix path-info --eval-store auto --store http://BUILDER:CACHE_PORT nixpkgs#hello` | the path; its narinfo carries a `cache.nixos.org-1` and a `KEY_NAME` signature |
| An unsigned path built on the client, before the push | `is not valid` |
| `nix copy --to ssh-ng://…` of that path | refused, `lacks a signature by a trusted key`: `nix copy` asks the remote to check signatures |
| `nix copy --no-check-sigs --to ssh-ng://…` of that path | copied; harmonia served it at once, signed `KEY_NAME` |
| `nix path-info --store http://BUILDER:CACHE_PORT` of that path right after | `is not valid`: the client remembered its earlier miss (`narinfo-cache-negative-ttl`, an hour by default). With `--option narinfo-cache-negative-ttl 0`, found |
| A clean store (`local?root=…`) substitutes that path from the cache, trusting only cache.nixos.org's key | refused, `lacks a signature by a trusted key` |
| The same, trusting only `CACHE_KEY`, for that path and `nixpkgs#hello` | copied, both closures from the cache, every path signed `KEY_NAME` |

### The builder

| Check | Result |
| --- | --- |
| `nix store info --store 'ssh-ng://nix-builder@BUILDER:SSH_PORT?ssh-key=CLIENT_KEY&base64-ssh-public-host-key=HOST_KEY'` | `Version: 2.35.4`, `Trusted: 1`: Nix reads the port in the URL and pins the host key for it |
| The same with another host key | `Host key verification failed` |
| `nix build --builders 'ssh-ng://nix-builder@BUILDER:SSH_PORT x86_64-linux CLIENT_KEY 12 1 kvm,big-parallel,nixos-test - HOST_KEY' --max-jobs 0 nixpkgs#hello --rebuild` | fails, `local builds are disabled (max-jobs = 0)`: Nix 2.35 never sends a `--rebuild` (check) build to a remote builder, for any derivation |
| The same `--builders --max-jobs 0` for a new derivation, without `--rebuild` | `building '…' on 'ssh-ng://nix-builder@BUILDER:SSH_PORT'`, output copied back |
| `nix build --eval-store auto --store 'ssh-ng://…' nixpkgs#hello --rebuild` | `checking outputs of '…hello-2.12.3.drv'`, exit 0: built on the builder without a sandbox, bit for bit the output cache.nixos.org has |
| A nixosTest (`pkgs.testers.runNixOSTest`, one machine) through `--builders … --max-jobs 0`, asserting that `systemd-detect-virt` in the guest says `kvm` | passed on the builder, `systemd-detect-virt says kvm`, 144 s in all |

The guest needed 89 s to reach its root shell, which is slow for KVM. virtiofsd logged `Failed to open file handle for the root node: Operation not permitted`: it gets no `CAP_DAC_READ_SEARCH` in the container and falls back to paths, and the store it shares sits on the NAS's disk pool. Not traced further.

### Supervision

`kill -9` of harmonia inside the container at 17:15:33Z: `start.sh` logged `a service exited with status 137; stopping the others so Docker restarts the container`, Docker restarted the container at 17:15:35Z, and it came back `healthy` with both ports, the same keys, and every account in `/etc/passwd`, `/etc/shadow` and `/etc/group` once.

## Still to check

- After the host's next reboot: both ports in `docker inspect nix-builder --format '{{json .NetworkSettings.Ports}}'`, and the cache answering from a client.
- A host built from ravnix with both services enabled: `nixos-rebuild build` sends its builds to the builder, and a second host substitutes them.
