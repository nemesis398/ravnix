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

## Second run of 2026-11-07: the review's fixes

More placeholders: `PROJECT` is the project directory, `SUBNET` the project network (`NIX_BUILDER_SUBNET`) and `GATEWAY` its first address, the host's side of the bridge. `NAS_A`, `NAS_B` and `NAS_C` are the host's three LAN addresses, `NAS_B` its management address, `ROUTER` the LAN's router and `MESH_HOST` a mesh VPN address in `100.64.0.0/10`.

### Rollback of the egress rule

Written down before the rule was first applied. From `PROJECT`:

```sh
docker compose stop nix-firewall
docker compose run --rm --no-deps nix-firewall bash /firewall.sh --remove
docker compose rm -f nix-firewall
```

Then delete the `nix-firewall` service and the builder's `depends_on` on it from `docker-compose.yaml`. If Compose itself is broken, the same removal runs from the image:

```sh
docker run --rm --network host --cap-drop ALL --cap-add NET_ADMIN --cap-add NET_RAW \
  -e NIX_BUILDER_SUBNET=SUBNET -v PROJECT/firewall.sh:/firewall.sh:ro \
  local/nix-builder-firewall bash /firewall.sh --remove
```

The host does not save the rule, so a reboot with `nix-firewall` stopped also clears it.

### iptables versions

The host's Docker writes its rules with the host's iptables 1.8.9, and `nix-firewall` with 1.8.13 from the pinned nixpkgs, both through nf_tables. In a throwaway network namespace (`docker run --network none` with the host's root mounted read-only), the image's iptables applied the rule next to chains and rules that the host's own binary had written, the way Docker and UGOS do. Both binaries then printed the table identically: the same SHA-256 for `iptables-nft -S` and for `iptables-nft-save -t filter`. The host's binary ran `-C`, `-I` and `-D` around the new rules without complaint, and rules that the host's binary wrote passed `firewall.sh --check`.

### Moved out of the share

The project moved from the host's Docker share, whose ACL made `docker-compose.yaml`, `start.sh` and `.env` mode `0777`, to `PROJECT`, outside every share. Nothing had been changed before the move: `start.sh` still had the hash it was deployed with, and `state/` was `0700 root` with no ACL entry, and its keys were `0600 root`. The host's admin account has no sudo, so a root container wrote the files, and `docker compose down` in the old directory, `cp -a` of `state/` by a root container, and a hash comparison of the four key files inside that container (it printed `same` four times and nothing else) moved the state.

```text
$ ls -la PROJECT
drwxr-xr-x 1 root root   132 Nov  7 19:33 .
drwxr-xr-x 1 root root    28 Nov  7 19:24 ..
-rw-r--r-- 1 root root 11421 Nov  7 19:24 docker-compose.yaml
-rw-r--r-- 1 root root  1192 Nov  7 19:24 .env
-rw-r--r-- 1 root root   750 Nov  7 19:24 firewall.Dockerfile
-rw-r--r-- 1 root root  6278 Nov  7 19:33 firewall.sh
-rw-r--r-- 1 root root 13295 Nov  7 19:24 start.sh
drwx------ 1 root root    34 Nov  7 19:26 state
$ getfacl -p PROJECT PROJECT/start.sh PROJECT/docker-compose.yaml PROJECT/firewall.sh PROJECT/state   (one line per file here)
# file: PROJECT                       owner: root  group: root  user::rwx group::r-x other::r-x
# file: PROJECT/start.sh              owner: root  group: root  user::rw- group::r-- other::r--
# file: PROJECT/docker-compose.yaml   owner: root  group: root  user::rw- group::r-- other::r--
# file: PROJECT/firewall.sh           owner: root  group: root  user::rw- group::r-- other::r--
# file: PROJECT/state                 owner: root  group: root  user::rwx group::--- other::---
```

No ACL entries beyond the mode bits, and the parent directory is `root:root 0755` as well. Inside the container, `state/ssh/ssh_host_ed25519_key` and `state/cache/secret-key` are `0600 root`. After the checks below, a root container removed the old directory and the copy of the keys in it. The share showed no snapshot directory that could still hold one.

### The update path, run

The move was also an update. Round one's tools came from an unpinned nixpkgs and its daemon from the image's profile. Before the switch, Nix 2.34.9 from the pin opened the live database (schema 10) from inside the running container: `nix-store --store local --query --hash` of the image's `base-system` path. The first start of the new project then logged:

```text
start.sh: kvm usable by the build users: yes
start.sh: installing nix, openssh and harmonia from github:NixOS/nixpkgs/<flake.lock's nixpkgs>
start.sh: SSH host key for nix.buildMachines.*.publicHostKey: HOST_KEY
start.sh: cache public key: CACHE_KEY
start.sh: running nix (Nix) 2.34.9, harmonia, sshd
```

The install took 8 s. The keys are the old ones. `/nix/var/nix/profiles/ravnix` links to the new profile, with no `ravnix-next` and no old generation left, and `/state/tools-pin` holds the pin. The daemon runs as `ravnix/bin/nix-daemon`, and sshd and harmonia run from the pin's openssh 10.6p1 and harmonia 3.3.0. `nix-store --gc --print-roots` lists `profiles/ravnix` and `profiles/default-1-link`, so a collection keeps both. From the client, `nix store info --store 'ssh-ng://…'` says `Version: 2.34.9`, `Trusted: 1`.

### The egress rule

From inside the builder, `bash -c ': </dev/tcp/HOST/PORT'` under `timeout 5`, before the rule (round one's container on its old subnet) and after:

| Target | Before | After |
| --- | --- | --- |
| `GATEWAY`, the host's SSH port | connected | no answer in 5 s |
| `NAS_A`, `NAS_B`, `NAS_C`, the host's SSH port | connected | no answer in 5 s |
| `ROUTER`, ports 53 and 80 | refused, so reached | no answer in 5 s |
| a LAN client, port 22 | no answer in 5 s | no answer in 5 s |
| `MESH_HOST` and `100.64.0.1` | `Network is unreachable` from the router | no answer in 5 s |
| `https://cache.nixos.org/nix-cache-info` | HTTP 200 | HTTP 200 |
| `https://github.com/NixOS/nixpkgs` | HTTP 200 | HTTP 200 |

The rule's counters went from 0 to 20 packets on `-d 10.0.0.0/8 -j DROP` and from 0 to 10 on `-d 100.64.0.0/10 -j DROP` during those probes, and the input chain's `DROP` from 6 to 26. That chain also counts the host's own SSDP announcements: the host sends them from `GATEWAY` to `239.255.255.250:1900` on every bridge, and the kernel loops them back into its input chain (`tcpdump -q` on the bridge, headers only). Dropping the host's echo of its own multicast costs nothing.

From the client, the cache still answered: `nix-cache-info` as before, and the narinfo of the image's `base-system` path with `Sig: KEY_NAME:…`. The SSH port still took a login: the `nix store info` above.

The rule, as `iptables-nft -S` printed it on the host:

```text
-A DOCKER-USER -s SUBNET -j RAVNIX-NIX-BUILDER-OUT
-A DOCKER-USER -j UG_FORWARD
-A DOCKER-USER ! -i docker0 ! -o docker0 -j ACCEPT
-A INPUT -s SUBNET -j RAVNIX-NIX-BUILDER-IN
-A INPUT -j UGDOS_PROTECT
-A INPUT -j UG_SSH_INPUT
-A INPUT -j UG_INPUT
-A RAVNIX-NIX-BUILDER-OUT -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A RAVNIX-NIX-BUILDER-OUT -d 10.0.0.0/8 -j DROP
-A RAVNIX-NIX-BUILDER-OUT -d 172.16.0.0/12 -j DROP
-A RAVNIX-NIX-BUILDER-OUT -d 192.168.0.0/16 -j DROP
-A RAVNIX-NIX-BUILDER-OUT -d 100.64.0.0/10 -j DROP
-A RAVNIX-NIX-BUILDER-IN -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A RAVNIX-NIX-BUILDER-IN -j DROP
```

The rule matches on the source address. The build users cannot forge one, because they hold no capability. Root in the container could (Docker's defaults include `NET_RAW`), and root there is whoever holds the builder key, a trusted user anyway.

Re-applied, nothing doubles: `firewall.sh --once` twice and `--check` inside the running `nix-firewall` all said `the rule for SUBNET is in place`, and the counts stayed at one jump in `DOCKER-USER`, one in `INPUT`, five rules in the output chain and two in the input chain. The SHA-256 of the whole filter table (`iptables-nft-save` without counters) stayed the same, and so did it after `docker compose restart nix-firewall`, whose log said `the rule for SUBNET is in place`. With the jump in `INPUT` deleted by hand, the keeper put it back 2.3 s later and logged `put the rule for SUBNET back in place`.

### A dropped connection in the middle of a build

From the client, two remote builds of a derivation that sleeps 600 s went through `nix build --eval-store auto --store 'ssh-ng://…'`. Both ran ssh with `-F /dev/null -oIdentitiesOnly=yes -oIdentityAgent=none` in `NIX_SSHOPTS`, which stands in for root's ssh with no configuration of its own, as the daemon on a NixOS host runs it. One also had the module's `-oConnectTimeout=5 -oServerAliveInterval=15 -oServerAliveCountMax=4`; the other had nothing more. Once both builds were running, `kill -STOP` froze the builder's per-connection processes (`sshd-session: nix-builder@notty` and `nix-daemon --stdio`, two of each), so both connections went silent:

| Client | After the freeze |
| --- | --- |
| with the module's options | failed after 68 s: `Timeout, server BUILDER not responding.`, then `error: Nix daemon disconnected unexpectedly` |
| without them | still waiting after 240 s, ended by hand |

`kill -CONT` and `kill -TERM` of the frozen processes then left no build behind on the builder, and the container stayed `healthy` with no restart.

A frozen process is not a closed lid. The host's kernel still acknowledged every TCP segment, so TCP keepalive would never have ended the second client; after a real drop it ends one after about two hours. The server-alive checks fail the same way in both cases, because they wait for ssh's answer and not the kernel's.

### What the cache is and what it costs

- **Why harmonia:** the header of `docker-compose.yaml` says it. One store, no push, and no write path into the cache but the builder's SSH key, where ncps and attic would each have meant a second store or a push.
- **Reads need no login.** Whoever reaches `BUILDER:CACHE_PORT` can read every path in the store, the host closures built there included. That holds a host's configuration, with its personal values, and never a secret as long as secrets stay out of the store. The port is bound to one address on one segment.
- **Priority 30 off the LAN.** The cache says `Priority: 30`, ahead of cache.nixos.org's 40, so a host away from home without the mesh tries it first. `connect-timeout = 5` (`modules/services/nix-cache.nix`) bounds each attempt.
- **Garbage collection.** The store's filesystem is shared with every backup. When the backups bring its free space under `NIX_MIN_FREE`, every build starts a collection, and since nothing but the two tool profiles is rooted there, each collection empties the cache. `NIX_MAX_FREE` can then never be reached, so the next build collects again. Today the pool has 11 TiB free, against a `NIX_MIN_FREE` of 2000 GiB, and the store holds 3.5 GiB. A limit on the store's own size, enforced by a job, would be the real policy; there is none yet.

## Still to check

- After the host's next reboot: both ports in `docker inspect nix-builder --format '{{json .NetworkSettings.Ports}}'`, the cache answering from a client, and the egress rule back in place (`docker compose ps` shows `nix-firewall` healthy, and the probes above give the same results). Docker starts both containers by itself after a reboot, in no order, so a build that arrives before `nix-firewall`'s first pass would still reach the LAN. The window is the time between the two containers' starts.
- The host's next UGOS update: the rule still in place afterward, or put back by the keeper within its interval.
- A real lid close or network change on a laptop in the middle of a remote build, and not only a frozen connection (above).
- A host built from ravnix with both services enabled: `nixos-rebuild build` sends its builds to the builder, and a second host substitutes them.
