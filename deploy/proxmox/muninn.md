# The server as a Proxmox VM

How a ravnix server becomes a VM on a Proxmox VE node: build its image and
its home volume, copy both to the node, create the VM with `qm`, start it.
The disk layout and the boot are `nixosModules.server-vm`
(`hosts/server/images.nix`); the host's network and its sizes are the
private flake's. Keep a record of your own run beside your values, in the
private flake, with the real VMID, address and `qm config`. This page uses
placeholders.

| Placeholder | Example | What it is |
| --- | --- | --- |
| `HOST` | `muninn` | the host in your private flake's `nixosConfigurations` |
| `NODE` | | the Proxmox node, as `ssh` reaches it as root |
| `VMID` | `pvesh get /cluster/nextid` | the next free id in the node's range |
| `STORAGE` | `local-zfs` | where the disks go |
| `BRIDGE`, `TAG` | `vmbr0`, the server VLAN | the network the VM sits in |

## 1. Build the image and the home volume

First set who may deploy: `ravnix.server.deployKeys` and
`ravnix.server.deployFrom` in `me.nix`. The image's root takes exactly those
keys, from exactly those addresses; with no deploy key, root takes none.
No account has a password either, so the console offers no login: the way
in is then the guest agent, `qm guest exec VMID -- COMMAND` on the node,
which runs as root in the VM; for example
`-- /run/current-system/sw/bin/nixos-rebuild switch --rollback`, back to the
generation before. Choosing an older generation in the boot menu over
`qm terminal VMID` is another. A root password for the console is not one:
the server's assertions refuse it, because typed into `su` in a session of
the account, an agent there can catch it. Nor set one by hand with
`passwd`: with `users.mutableUsers` on, it stays in `/etc/shadow`, out of
the assertions' sight.

On a machine with Nix, from the private flake, with a builder if you have one
(the image copies the whole system closure, about 8 GiB, into a disk):

```sh
nix build PRIVATE_FLAKE#nixosConfigurations.HOST.config.system.build.images.qemu-efi \
          PRIVATE_FLAKE#nixosConfigurations.HOST.config.system.build.homeVolume
```

`result/` holds `nixos-image-efi-qcow2-*.qcow2`, the system disk, sized to
its closure plus 512 MiB. `result-1/home.qcow2` is the home volume, an empty
ext4 of 1 GiB labelled `home`. Both grow to whatever disk Proxmox gives them,
at the next boot.

## 2. Copy them to the node

Into the import directory of a storage with the `import` content type (the
node's `local` has it by default):

```sh
scp result/nixos-image-efi-qcow2-*.qcow2 root@NODE:/var/lib/vz/import/HOST-system.qcow2
scp result-1/home.qcow2 root@NODE:/var/lib/vz/import/HOST-home.qcow2
```

## 3. Create the VM

On the node. The image starts systemd-boot from the firmware's fallback path,
so UEFI (`ovmf`) with an EFI disk and no Secure Boot keys; the two disks are
SCSI on one VirtIO SCSI controller each (`virtio-scsi-single`), found by
label, so their order does not matter. `import-from` makes a new volume on
`STORAGE` and copies the file into it.

```sh
qm create VMID --name HOST --ostype l26 --machine q35 --bios ovmf \
  --efidisk0 STORAGE:1,efitype=4m,pre-enrolled-keys=0 \
  --cpu host --sockets 1 --cores 8 --memory 14336 --balloon 8192 \
  --scsihw virtio-scsi-single \
  --scsi0 STORAGE:0,import-from=local:import/HOST-system.qcow2,discard=on,ssd=1,iothread=1 \
  --scsi1 STORAGE:0,import-from=local:import/HOST-home.qcow2,discard=on,ssd=1,iothread=1 \
  --boot order=scsi0 \
  --net0 virtio,bridge=BRIDGE,tag=TAG \
  --serial0 socket --agent enabled=1 --onboot 1
qm resize VMID scsi0 64G
qm resize VMID scsi1 200G
rm /var/lib/vz/import/HOST-system.qcow2 /var/lib/vz/import/HOST-home.qcow2
qm config VMID
```

`--memory` and `--balloon` are the most and the least it gets: Proxmox takes
memory back down to the balloon's size when the node runs short. `--cpu host`
gives it the node's own CPU; a VM that is to move to a node with another CPU
takes a named model such as `x86-64-v3` instead. The two sizes are a ceiling
on a thin pool, not a reservation; the home volume holds the repositories,
the agents' state and Podman's images.

## 4. Start it and find it

```sh
qm start VMID
qm agent VMID ping                               # once the guest agent runs
qm guest cmd VMID network-get-interfaces         # the address it took
qm guest exec VMID -- cat /etc/ssh/ssh_host_ed25519_key.pub
```

The last line is the host key sshd made at its first start: put it in a
known-hosts file before the first `ssh`, instead of trusting whatever answers.
`qm terminal VMID` shows the serial console, where the kernel writes too.

## 5. Deploy to it

As root, with a key of `ravnix.server.deployKeys`, from an address of
`ravnix.server.deployFrom` (`hosts/server/deploy.nix` says why root, and
why only from there):

```sh
NIX_SSHOPTS="-o ControlPath=none" \
  nixos-rebuild switch --flake PRIVATE_FLAKE#HOST --target-host root@ADDRESS
nix copy --no-check-sigs --to ssh-ng://root@ADDRESS PATH
```

Whoever holds the deploy key can deploy, and that is every process that
runs as you on the deploying machine. The best deploy key is one on a
security key that wants its PIN as well (`ssh-keygen -t ed25519-sk -O
verify-required`): every login then waits for a touch and the PIN. The
server insists on the PIN: a security key's line in root's keys carries
`verify-required`, so sshd takes only a signature made after the PIN, one
PIN per login, and a security key made without that flag does not log in.
On its own, nixos-rebuild opens one connection for the whole deploy (a
ControlMaster, a socket in your temporary directory) and runs every step
through it, so the deploy takes one touch, and while it runs any process
of yours can use the socket as root on the server without one.
`NIX_SSHOPTS="-o ControlPath=none"` turns that off: nixos-rebuild puts
NIX_SSHOPTS before its own `-o` options, and ssh takes the first value of
an option. A deploy then opens six connections, six touches and six PINs
(one copy and five commands on the server, counted in
`tests/server/deploy-login-vm.nix` with `--store-path`). A `Host` entry cannot turn it off, because ssh reads
the command line before its configuration file.

A path you built yourself carries no signature the server trusts, so `nix
copy` needs `--no-check-sigs`, which Nix honors for a user it trusts, and
on the server that is root alone. Trusting the account would not be a fix,
and neither would turning `require-sigs` off, which lets every user add
unsigned paths; the server's assertions refuse both. `nixos-rebuild`
copies with `nix-copy-closure`, which needs no such
flag for root. Both run without a terminal and without forwarding, as the
deploy key's `restrict` wants (`tests/server/deploy-login-vm.nix`).

The account cannot deploy: it has no sudo without a password, and Nix does
not trust it. A `Host` entry in `~/.ssh/config` that logs in as root with
the deploy key, and only that key, keeps the commands short:

```
Host HOST-deploy
  HostName ADDRESS
  User root
  IdentityFile ~/.ssh/HOST-deploy
  IdentitiesOnly yes
```

Then `--target-host HOST-deploy` and `ssh-ng://HOST-deploy`. `ADDRESS`
has to be the address whose route ends in one of `deployFrom`: sshd sees
the last hop's address, so through a router that masquerades it sees the
router.

The first deploy installs the host's own toplevel, without the image's
module, and that changes neither the boot loader nor a file system
(`tests/server/images.nix`, and `tests/server/image-boot.nix` on a running
VM).

## Growing a disk later

`qm resize VMID scsi0 +20G` (or `scsi1`), then reboot: the partition and the
file system follow at boot.
