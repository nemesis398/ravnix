# muninn as an OCI image: the Docker run

**Root in this container is root on the Docker host.** The container needs
`SYS_ADMIN` with Docker's AppArmor profile off, in the host's own user
namespace, and nothing then locks Docker's read-only `/proc/sys` and `/sys` or
its masked paths: root in muninn can remount them, mount a fresh `/proc`, and
write what the host kernel runs or obeys as root (`kernel.core_pattern`, the
other host-wide sysctls). Run it only where that is acceptable, and guard root in
it like the host's root. The compose files say the same at their tops, with the
narrower ways (rootless Podman with `--systemd=always`, Docker with
`userns-remap`, an AppArmor profile that allows only the mounts the image needs),
none of which was tried.

The record of Task 4.4 for `hosts/server/oci.nix`, `deploy/compose/muninn` and
`deploy/k8s`. `tests/workbench/oci.nix` (the check `workbench-oci`) shows what
needs no container: the image's entrypoint (a guard, run there against
stand-ins), stop signal and environment, its volume, the layer that holds the
Nix database record, the settings of a container, the deploy files' grants and
their pull policy, and a closure with none of the laptop's programs. This file
records what only a Docker host shows.

The host was a NAS: Linux 6.18.15, Docker 29.6.2 with Compose 5.1.3, cgroup v2
with the systemd cgroup driver, overlay2, runc 1.3.5, AppArmor and Docker's
default seccomp profile on. It runs other people's services, so the run was one
Compose project with a name of its own (`ravnix-muninn-test`), one volume of
that project, a published port on the host's loopback only, and memory and CPU
limits (4 GiB, 4 CPUs). Nothing else was touched.

What was seen of the host's other containers: `docker ps -a` and a snapshot of
every container's start time, restart count and health, and of the images,
volumes and networks, were taken **before** round 1 (12 containers, 11 of them
running and one an exited job of another Compose project, 3 volumes, 10
networks). Round 1 took **no snapshot afterwards**. After `docker compose down
-v`, only a plain `docker ps` was looked at, and it listed 11 running
containers; the project's container, volume and network were gone (`docker
inspect` said so). That is not the comparison by start time, restart count and
health that the cleanup proof needs. That comparison belongs to round 2, which
takes a fresh snapshot at its start as well as at its end.

Placeholders as elsewhere: `HOST` is the Docker host, `BUILDER` the Nix builder,
`alice` the template's user.

## Status of this record

**Steps 2 and 3 of the task are open.** Two rounds have run, and each found
what the image, the compose files or the test script still lacked; a third
waits.

- **Round 1** ran the first image (`ravnix/muninn:zdrqddvyczgmg1hqqapvd8cdf8gldhsz`)
  on the NAS, with two stand-ins for what the image now does itself: an
  entrypoint that remounts the cgroup tree writable before `init` (the image's
  entrypoint does that now, behind a guard), and Podman's `containers.conf`
  written by hand. Its image, its volume layout (the home at `/home/alice`
  itself) and its compose files are not the committed ones. Everything below
  under "Round 1" is from it.
- **Round 2** ran the image and the two compose files as committed then. The
  system booted clean and the cleanup proof held (nothing of the project
  remained, the snapshots before and after were equal, both images were
  removed), but `docker-checks.sh` failed in all three of its runs: an ssh
  login with a key, rootless Podman's network, and, in the two runs after a
  container was made, the checks of PID 1. "Round 2" below has the causes
  and the fixes.
- **Round 3** is the same run on the fixed image, and it has **not been run**.
  Until it has passed, Step 2 is not done. It waits for the maintainer's go,
  because root in the container is root on the NAS, which is shared.

What a round has to show, on the image built from the tree as committed:

1. The entrypoint's guard lets a private cgroup namespace through and the stage 2
   output is clean (no `signature mismatch`, no symlink errors), and the system is
   `running` with no failed unit. If `systemd-machine-id-commit.service` still
   times out on a quiet disk pool, that is the image's to fix.
2. `docker info --format '{{.SecurityOptions}}'` and the container's
   `HostConfig.UsernsMode`: the reasoning above assumes the daemon uses no
   `userns-remap`.
3. `tests/workbench/oci/docker-checks.sh` three times, with `HOST_PORT` the
   published port: against the base compose file (Podman without the override
   must fail at `/proc`, and say so), against the base and the Podman file
   together, and in a container made again from the same volume. Its output
   includes Task 4.1's Remote Control check, the Nix database check, and `docker
   inspect` of the grants (`Privileged` false, `CapAdd`, `SecurityOpt`,
   `CgroupnsMode` private, no devices, no binds).
4. A health check that says `healthy`, the stop and its exit code, and that a
   container made again from the same volume keeps the home's files and sshd's
   host key.
5. That the image is never pulled: with `MUNINN_TAG` set to a tag that is not
   loaded, `docker compose up` stops and says the image is not there.
6. The cleanup: `docker compose down -v`, `docker image rm` of the exact tags
   loaded (no prune of any kind), and the lists of containers, volumes,
   networks and images of the project all empty, `docker system df` before and
   after, and the snapshots equal.

The commands, with `HOST` the Docker host, `P` the project `ravnix-muninn-test`:

```sh
ssh HOST docker load < result                       # prints Loaded image: ravnix/muninn:TAG
MUNINN_TAG=TAG MUNINN_BIND_ADDRESS=127.0.0.1 MUNINN_SSH_PORT=42222 \
  MUNINN_MEM_LIMIT=4g MUNINN_CPUS=4 \
  docker compose -p P -f docker-compose.yaml [-f docker-compose.podman.yaml] up -d
ssh HOST 'bash -s -- P-muninn-1 ODIN 42222 [podman]' < tests/workbench/oci/docker-checks.sh
docker compose -p P -f docker-compose.yaml down -v
docker image rm ravnix/muninn:TAG
```

## Build and transfer

The image is built from the check's test configuration (the template's
placeholder values, one editor language), on the NAS builder from Task 1.4:

```sh
nix build .#checks.x86_64-linux.workbench-oci.image --print-out-paths --no-link \
  --builders 'ssh-ng://nix-builder@BUILDER:SSH_PORT x86_64-linux CLIENT_KEY 16 1 big-parallel,kvm,nixos-test - HOST_KEY' \
  --max-jobs 0 --option builders-use-substitutes true
```

`builders-use-substitutes` lets the builder fetch the closure from cache.nixos.org
itself, but the laptop still substituted most of it too (Nix schedules a local
substitution before it hands a derivation to a builder), so the first build moved
the closure over the laptop's link as well. It took about 13 minutes on a builder
that was busy with other tasks.

The result of round 1 is a gzip tarball of 2,174,196,560 bytes, 76 layers, 6.93 GB
in Docker. It goes to the host as a stream, with no tarball on the host:

```sh
ssh HOST docker load < /nix/store/...-muninn.tar.gz
```

That took 30 minutes 40 seconds. The 2 GB crossed the network in about ten; the
rest was Docker writing 6.9 GB to a disk pool that `iostat` showed at 98 %
utilization (about 5 MB/s written per disk) while the builder was working for
other tasks. A second image that shares its layers is not written again, only
read through.

## Round 1: what systemd needed from Docker

Each step used the same Compose file and changed one thing; a failure shows in
`docker logs` and in the exit code of the container.

| Container got | Result |
| --- | --- |
| nothing added (private cgroup namespace, `tmpfs` on `/run`) | Stage 2 of the image fails every mount: `mount: /nix/store: permission denied`, `Activation script snippet 'specialfs' failed`. systemd exits at once with status 255 |
| `cap_add: SYS_ADMIN` | `mount: /nix/store: bind /nix/store failed`. Docker's AppArmor profile refuses mounts even with the capability. Exit 255 |
| `SYS_ADMIN` and `security_opt: apparmor=unconfined` | Stage 2 is clean. systemd 262 starts (`Detected virtualization docker`, seen with `SYSTEMD_LOG_LEVEL=debug`, `SYSTEMD_LOG_TARGET=console` and a tty), then: `Failed to create /init.scope control group: Read-only file system`, `Failed to allocate manager object`, `Exiting PID 1`. Exit 255. Docker mounts the cgroup tree read-only, and systemd does not remount it |
| the same, and `mount -o remount,rw /sys/fs/cgroup` before `init` | systemd runs. `/proc/1/cgroup` is `0::/init.scope`, `/sys/fs/cgroup` is `cgroup2 rw,nosuid,nodev,noexec,relatime,nsdelegate,memory_recursiveprot`, the user manager of the lingering user is up and so is herdr's server |

So the settings Docker needed are `cap_add: [SYS_ADMIN]`, `security_opt:
[apparmor=unconfined]`, a private cgroup namespace (Docker's default on cgroup
v2, written down as `cgroup: private`), and the cgroup tree remounted writable
inside the container. The last is the image's business: with a private namespace
the tree it makes writable is the container's own subtree and no other
container's, and the entrypoint now makes sure of the namespace before it does
(it reads `/proc/self/cgroup` and refuses to start unless it says `0::/`).
`cgroup: host` with a writable bind of the host's `/sys/fs/cgroup`, which is the
usual recipe, would let root in muninn write the cgroups of every container on
the host, and was not tried. Not privileged, no device, no host path, no network
of its own. What those grants add up to is at the top of this file.

The `tmpfs` on `/run` (and its `exec` option) is **reasoned and was never
tried without**: every round-1 run had it. The reason is that the system's
activation puts `/run/current-system` and more under `/run` before systemd
starts, and systemd mounts a tmpfs of its own on `/run` when there is none,
which would hide them; Docker mounts tmpfs `noexec` unless asked, and `exec` is
the safe side. Round 2 may run once without it to find out.

As resolved by `docker compose config` before the first start (round 1):
`cap_add: [SYS_ADMIN]`, `cgroup: private`, `cpus: 4`, `mem_limit` and
`memswap_limit` 4 GiB, `pids_limit: 4096`, `security_opt: [apparmor=unconfined]`,
`stop_signal: SIGRTMIN+3`, `stop_grace_period: 1m`, `tmpfs: [/run:exec,mode=755,size=256m]`,
one named volume at `/home/alice` (now `/home`), one port on `127.0.0.1`.

## Round 1: the checks, through docker exec

`tests/workbench/oci/docker-checks.sh` repeats the checks of
`tests/workbench/server.nix` that a container can show. Round 1 ran its first
form (the same commands, without the Remote Control and Nix database checks that
were added after the review) against the container of the last row above: 36
passed, 1 failed.

- PID 1 is the system's systemd, in `0::/init.scope`.
- `user@1000.service` is active with nobody logged in, `herdr status server
  --json` says `running` and `compatible`, `herdr config check` accepts the
  module's configuration, and `herdr-server.service` is an active user unit.
- A pane made with `herdr workspace create` and `herdr pane run` runs bash from
  the store with `lazygit`, `rg`, `claude` and `odin` on its PATH.
- `aerc`, `iamb`, `khal`, `vdirsyncer`, `podman`, `uv`, `node`, `cargo`,
  `rustc`, `cc`, `odin`, `lazygit` and `herdr` print their versions, and the
  `odin` a pane resolves to is the one the tools are built with.
- `sshd` is active; `sshd -T` says passwords, keyboard-interactive and root login
  are off; an ed25519 key made in the volume logs in as the user over
  `127.0.0.1`; a login without a key is refused (`Permission denied
  (publickey)`); the published port answers on the host's loopback with
  `SSH-2.0-OpenSSH_10.6`.
- `nextcloud-sync.service` and `vdirsyncer.service` exit with status 75 while the
  vault is locked, which is what they must do.
- None of the laptop's programs is on the system's PATH.
- Rootless Podman: `podman info` says `Rootless true`.

The one failure: the system was `degraded`, because
`systemd-machine-id-commit.service` timed out after 90 seconds. It writes the
transient machine ID to disk, and the disk pool was starved (see above). Started
by hand later, with the pool quiet, it finished in under a second. Round 2
states what the system says.

## Round 1: rootless Podman inside

It works, with more than the base file grants. Each step below is the next
error after the last fix, run as the user with `podman run --rm localhost/hello:latest`
(an image loaded with `podman load` from a stream):

| Error | Fix |
| --- | --- |
| `pasta failed ... Failed to open() /dev/net/tun` | the device `/dev/net/tun` (or `--network host` or `none`) |
| `crun: join keyctl ...: Operation not permitted` | `keyring = false` in `containers.conf`: Docker's seccomp profile blocks `keyctl` |
| `crun: open /proc/sys/net/ipv4/ping_group_range: Read-only file system` | unmask `/proc`, or `--network host` |
| `crun: mount proc to proc: Operation not permitted` | `security_opt: systempaths=unconfined`: a nested container mounts a `/proc` of its own, which the kernel refuses while the outer one has masked paths |
| `crun: pivot_root: Operation not permitted` | `no_pivot_root = true`: the default seccomp profile blocks `pivot_root` |

After the last: `Hello, world!` with `--network host` and with `--network none`;
`podman info` says the storage driver is `overlay`, rootless, with seccomp. The
default network (pasta) needs `/dev/net/tun` and was not retried with it.

Two of the fixes are the image's (`keyring`, `no_pivot_root`, set in
`hosts/server/oci.nix` for the container form only, keeping Docker's seccomp
profile). The other two are the compose file's, and are in
`docker-compose.podman.yaml` and not in the base file, because the base file does
not need them. Root in muninn could unmask `/proc` anyway, because it has
`SYS_ADMIN` and no AppArmor, so `systempaths=unconfined` grants root nothing new.
What it changes is for everyone else: every process in muninn, the account's
agents and the containers they run, sees `/proc` unmasked. `no_pivot_root` has a
cost of its own: a container that Podman runs changes root instead of pivoting
it and can leave that root, reaching muninn's file system with the account's
rights (rootless Podman maps the container's root to the account). In this form
run only images you trust. The alternative that was not tried is
`seccomp=unconfined`, which removes the need for the `containers.conf` settings
and widens the container more.

## What the review and round 1 changed in the image

- The entrypoint is a guard (`system.build.ociEntrypoint`) that reads
  `/proc/self/cgroup` and refuses to start unless it says exactly `0::/`, which
  is what a private cgroup namespace shows; then it remounts `/sys/fs/cgroup`
  writable and execs the system's init, which execs systemd as PID 1. The
  remount used to run unconditionally in stage 2 (`boot.postBootCommands`), where
  a container with the host's cgroup namespace would have made the host's whole
  hierarchy writable. The stand-in of round 1 was the same remount, in an
  entrypoint of the compose file.
- Stage 2 printed `signature mismatch: /etc/resolv.conf` and could not make the
  symlinks `/etc/hostname` and `/etc/hosts`, because Docker mounts those three as
  single files. The image no longer manages them
  (`networking.resolvconf.enable = false`, `environment.etc.hostname.enable` and
  `hosts.enable` false). `docker compose down` took 3.5 seconds with systemd as
  PID 1 and `SIGRTMIN+3`, so the stop signal works.
- Podman's `containers.conf`, as above.
- The volume is `/home`, which is root's, and the host key of sshd is in
  `/home/.muninn-ssh`, beside the account's home and not in it. In the home the
  account could replace the key's directory by a link, and `sshd-keygen`, which
  runs as root and makes the directory with `chmod 0755`, would have followed it.
  It is still one volume.
- `PermitRootLogin` is `no` whatever the shape says: root in the container is
  root on the host, and the container is updated by an image swap and never by a
  login. (Task 4.2 lets root in with a key for the deploy of a machine.)
- `PATH` in the image puts `/run/wrappers/bin` first, as on a NixOS machine.
- The compose files and the StatefulSet never pull (`pull_policy: never`,
  `imagePullPolicy: Never`), because a tag that is not loaded would otherwise be
  fetched from a registry namespace nobody here controls and run with the rights
  above. The pod asks for the runtime's default seccomp profile.

The `workbench-oci` check pins each of these, and mutating them makes it fail
(`tests/workbench/oci.nix`): the guard is run against stand-ins in a host
namespace, below the root, with a v1 line, empty, missing and with a failing
mount.

## Not shown yet

Everything in "Status of this record" under round 2. The Kubernetes manifests
were validated against the schema with `kubeconform` and never applied.

## Round 2

The image and the compose files as committed after the review, run by the
script of the task on the same host: Docker with the security options
`apparmor`, `seccomp` (builtin) and `cgroupns`, no `userns`, and the container's
`UsernsMode` empty. As inspected: `Privileged=false`, `CapAdd=[CAP_SYS_ADMIN]`,
`SecurityOpt=[apparmor=unconfined]`, `CgroupnsMode=private`, no device, the
one volume at `/home`, a tmpfs on `/run`, 24 masked paths, 4096 pids, 4 GiB,
4 CPUs; with the Podman file `Devices=[/dev/net/tun]` and no masked path.

What held:

- `pull_policy: never` is in the resolved file, and a start with a tag that is
  not loaded was refused (`No such image`); nothing was pulled.
- PID 1 is systemd 262 in `0::/init.scope`, `/sys/fs/cgroup` is
  `rw,nosuid,nodev,noexec,relatime,nsdelegate,memory_recursiveprot`, the
  system is `running` with no failed unit (`systemd-machine-id-commit` did not
  time out again), stage 2 is clean, and the health check says `healthy` at
  0.09 % CPU, 39 MiB and 51 pids.
- Podman without the Podman file fails at `proc`, as it must.
- `compose stop` took 6.1 s and the container exited with 0; a container made
  again from the same volume kept the home's files and sshd's host key.
- The cleanup: `down -v`, both images removed by their tags, every list of what
  the project left empty, and the snapshots of the host's other containers
  (start times, restarts, health), images, volumes and networks equal.

What failed: 44 passed and 1 failed against the base file, 43 and 4 with the
Podman file and in the container made again. Each failure was reproduced on a
stand-in for Docker (rootful Podman with Docker's default seccomp profile,
Docker's capabilities and SELinux labels off in place of AppArmor), where the
old script gave the same 44 and 1, and found:

| Failure | Cause | Fix |
| --- | --- | --- |
| `ssh login: Permission denied (publickey)`, all three runs | the script put its key into `~/.ssh/authorized_keys`, which the server shape's sshd never reads: `hosts/server/deploy.nix` makes `AuthorizedKeysFile /etc/ssh/authorized_keys.d/%u` the only key file (round 1 ran a tree from before it). The home's owner and modes were right; the same key in `/etc/ssh/authorized_keys.d/alice` logged in | the script puts its key there, as root, and checks that a key in the home is refused. The compose file no longer says a key in the volume logs in: a key is the configuration's (`users.users.USER.openssh.authorizedKeys.keys`) |
| `podman run: Failed to pivot_root() into empty tmpfs: Operation not permitted`, with `/dev/net/tun` | pasta, Podman's network for a rootless container, sandboxes itself with `pivot_root`, and Docker's default seccomp profile allows `pivot_root` to nobody, `SYS_ADMIN` or not. With the same profile plus `pivot_root` the stand-in ran `Hello, world!` on pasta | the image's `containers.conf` gives Podman's containers muninn's own network (`netns = "host"`), and the Podman file drops `/dev/net/tun`, which nothing uses then. Not taken: a seccomp profile of Docker's with `pivot_root`, a copy to keep in step with Docker |
| `PID 1 is ... "readlink": executable file not found`, `PID 1 is in 0::/`, after a container was made | the script looked at PID 1 first and waited for the system later; only the run against the base file had a wait before it (in the task's script). Right after `up -d`, stage 2 had not made `/run/current-system` (the `PATH` of `docker exec`), and then systemd had not moved into `/init.scope` | the script waits for `systemctl is-system-running` before its first check |

`workbench-oci` now holds the image to `netns = "host"`, the Podman file to no
device, and the script's key file to the one the image's sshd reads;
`workbench-oci-checks-script` runs the script against a fake `docker` that
answers like a container that is still booting.
