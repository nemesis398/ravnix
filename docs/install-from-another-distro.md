# Install Nix on another distribution

Ravnix is a NixOS flake, so building it needs Nix. On a machine that still runs another distribution, install Nix first, evaluate and build the flake there, and move to NixOS later. This page covers a systemd distribution with SELinux enforcing, such as Fedora. It installs upstream Nix with the Determinate Nix Installer, which handles SELinux and keeps a receipt for the uninstall. The uninstall removes most of what the install adds. This page lists what it leaves behind and what to restore.

The install writes no partition, filesystem or boot entry. `/nix` becomes a plain directory on the root filesystem, and the disk layout stays as it was.

The last section is for the move itself: a file of your home that ravnix takes over on the laptop, `~/.ssh/config`.

## Why upstream Nix and not Determinate Nix

Run without `--prefer-upstream-nix`, the same installer installs Determinate Nix. Determinate's own guide, <https://docs.determinate.systems/guides/telemetry/>, lists what its tools collect: operating system and hardware properties, language and timezone, which features are on, the version, whether you are logged in to FlakeHub, and Sentry crash reports. `DETSYS_IDS_TELEMETRY=disabled` and a null Sentry endpoint turn that off, and they also turn off Determinate's feature rollout.

Those switches leave other contacts with the vendor, measured on Fedora with version 3.24.2:

- The daemon opens one short TLS connection to `install.determinate.systems` at every start. It also probes the cloud metadata address 169.254.169.254 for about 18 seconds.
- `nix.conf` lists the vendor's cache `install.determinate.systems` as a substituter with priority 39, ahead of `cache.nixos.org` at 40. It sees the hash of every store path Nix looks up.
- The default flake registry comes from `install.determinate.systems`, and a bare `nixpkgs` resolves through `flakehub.com`.

Upstream Nix has none of this: no extra daemon, the substituter is `cache.nixos.org`, and the registry comes from `channels.nixos.org`. The installer binary is still Determinate's, so it keeps its own report, which the steps below switch off.

## Before you install

Record the disk layout, so that you can compare it afterward:

```sh
lsblk -o NAME,MODEL,SERIAL,PARTUUID,FSTYPE > lsblk-before.txt
```

Write the Nix configuration. The installer is told to skip its own `nix.conf` (see the table below), so this file is the whole configuration:

```sh
sudo install -d -m 0755 /etc/nix
sudo tee /etc/nix/nix.conf <<EOF
build-users-group = nixbld
experimental-features = nix-command flakes
max-jobs = auto
trusted-users = root $USER
EOF
```

Builds on a remote machine and extra binary caches need a trusted user. A trusted user can do anything the daemon can, so list only an account you own.

## Install

```sh
curl --proto '=https' --tlsv1.2 -sSfL https://install.determinate.systems/nix |
  DETSYS_IDS_TELEMETRY=disabled sh -s -- install linux --prefer-upstream-nix --skip-nix-conf --no-confirm
```

| Part | Why |
| --- | --- |
| `DETSYS_IDS_TELEMETRY=disabled` | Switches off the installer's report to Determinate Systems. The installer passes it on when it re-runs itself under `sudo`. Its own flag `--diagnostic-endpoint ""` is no substitute: in version 3.24.2 an empty value falls back to the default endpoint |
| `install linux` | Names the planner for a mutable Linux system, so the installer does not have to guess |
| `--prefer-upstream-nix` | Installs upstream Nix instead of Determinate Nix. The installer calls this choice unsupported, but the plan and the install work as described here |
| `--skip-nix-conf` | Does not write `/etc/nix/nix.conf`. According to the installer source (3.24.2), its file for upstream Nix would also trust the FlakeHub cache and its keys and set a Determinate upgrade URL. You wrote the file in the step before |
| `--no-confirm` | Runs without a prompt. Drop it to read the plan and answer yes |

The script downloads a pinned installer (3.24.2 when this page was written) from `install.determinate.systems`, and the installer fetches Nix 2.35.4 from `releases.nixos.org`. It asks for `sudo` itself. To read the script before it runs, save it and start it by hand:

```sh
curl --proto '=https' --tlsv1.2 -sSfL https://install.determinate.systems/nix -o nix-install.sh
less nix-install.sh
DETSYS_IDS_TELEMETRY=disabled sh nix-install.sh install linux --prefer-upstream-nix --skip-nix-conf --no-confirm
```

The installer writes a local ID file even when the switch is set, and sends nothing from it. Delete it:

```sh
rm -r ~/.local/state/systems.determinate.detsys-ids-client
sudo rm -r /root/.local/state/systems.determinate.detsys-ids-client
```

A path that is not there makes `rm` complain, which is fine.

## What it changes

Everything outside `/nix` that the installer touches:

| Where | What |
| --- | --- |
| `/nix` | The store and its state. A directory on the existing filesystem, with a copy of the installer and its receipt at `/nix/nix-installer` and `/nix/receipt.json` |
| `/etc/systemd/system/` | Symlinks `nix-daemon.service` and `nix-daemon.socket` into the Nix profile, enabled and started |
| `/etc/nix/nix.conf` | Yours. The installer skips it |
| `/etc/tmpfiles.d/nix-daemon.conf` | A symlink into the Nix profile |
| Shell profiles | A block that sources the Nix profile, added to `/etc/bashrc`, and new files `/etc/bash.bashrc`, `/etc/profile.d/nix.sh`, `/etc/zshrc`, `/etc/zsh/zshrc` and `/usr/share/fish/vendor_conf.d/nix.fish` |
| Users and group | Group `nixbld` (GID 30000) and 32 build users `nixbld1` to `nixbld32` (UID 30001 to 30032), all without a shell |
| SELinux | The policy module `nix`, loaded from `/usr/share/selinux/packages/nix.pp` |
| Your home and `/root` | `/root/.nix-profile` and `/root/.nix-defexpr`, and the ID directory named above. Nix creates `~/.cache/nix` on first use |

## Verify

Open a new shell, or run `. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh`, then:

```sh
nix --version                    # nix (Nix) 2.35.4 or newer, with no "Determinate"
nix config show substituters     # https://cache.nixos.org/
nix config show flake-registry   # https://channels.nixos.org/flake-registry.json
nix run nixpkgs#hello            # Hello, world!
nix config show trusted-users    # root and your user name
nix store info --store daemon    # Trusted: 1
getenforce                       # Enforcing
sudo ausearch -m avc -ts recent  # <no matches>
systemctl list-units 'nix*' 'determinate*'   # nix-daemon.service and nix-daemon.socket only
```

A bare `nixpkgs` resolves through the global registry to nixpkgs-unstable. A flake with a lock file does not use the registry again. The legacy `<nixpkgs>` stays unset until you add `extra-nix-path = nixpkgs=flake:nixpkgs` to `nix.conf`.

To confirm that no disk changed, compare the layout with the file you wrote before the install:

```sh
lsblk -o NAME,MODEL,SERIAL,PARTUUID,FSTYPE | diff lsblk-before.txt -   # no output
```

Removable media can make the diff differ. A partition or filesystem on an internal disk must not.

## Uninstall

```sh
sudo env DETSYS_IDS_TELEMETRY=disabled /nix/nix-installer uninstall
```

The uninstaller has its own report, which is on by default, so pass the switch here too. The command prints its plan and asks before it removes anything. It follows the receipt in `/nix/receipt.json`. It removes the daemon units, the SELinux module, the shell profile hooks, the build users and group, and all of `/nix`, store included. Anything you built and want to keep must be copied out first.

On Fedora it also removes `/etc/tmpfiles.d` when that directory is empty. The `systemd` package owns it, and the Nix symlink was the only thing in it, so it goes. Put it back, with the label it had:

```sh
test -d /etc/tmpfiles.d || { sudo install -d -m 0755 /etc/tmpfiles.d && sudo restorecon -F /etc/tmpfiles.d; }
rpm -V systemd | grep tmpfiles   # no output
```

The receipt does not cover the files below, so the uninstall leaves them. Remove what is there:

```sh
sudo rm -r /etc/nix
rm -r ~/.local/state/systems.determinate.detsys-ids-client ~/.cache/nix
sudo rm -r /root/.local/state/systems.determinate.detsys-ids-client /root/.cache/nix /root/.nix-defexpr
sudo rm /root/.nix-profile
```

Also delete `~/.nix-profile`, `~/.nix-defexpr` and `~/.local/state/nix` if they exist. Then check that nothing is left:

```sh
ls /nix                                              # No such file or directory
ls /etc/nix                                          # No such file or directory
systemctl list-unit-files 'nix-daemon*'              # none listed
getent group nixbld; getent passwd | grep '^nixbld'  # no output
sudo semodule -l | grep -x nix                       # no output
sudo grep -rl /nix/var/nix/profiles/default /etc /usr/share/fish   # no output
ls /etc/bashrc.rpmnew                                # No such file or directory
```

The grep path appears in all six shell hooks, the fish one included. If `/etc/bashrc.rpmnew` exists, a `setup` update arrived while the Nix block sat in `/etc/bashrc`. Merge it and remove the block by hand. Last, log out and back in, because the open session still carries the `PATH` and `NIX_*` variables that the hooks set, and run the `lsblk` comparison again.

## Before the laptop's first switch: your `~/.ssh/config`

On the laptop, home-manager writes `~/.ssh/config`. It begins with the block that reaches the server, for the main terminal key and the main connection (`modules/glue/terminal.nix`). home-manager does not replace a file it did not write, so a `~/.ssh/config` that is already in your home, from this distribution or from a backup you restore, gets in the way:

- Without `home-manager.backupFileExtension` in your private flake, the switch stops with `Existing file '/home/<you>/.ssh/config' is in the way`.
- With it, the switch renames the file to `~/.ssh/config.<extension>` and says nothing. From then on nothing reads it.

Either way, the hosts that file named lose their settings. That matters most for the git hosts. A block that says `IdentityAgent none` and names the security key's handle keeps the agent of `SSH_AUTH_SOCK`, Bitwarden's, away from that host. Without the block, ssh offers the host every key of that agent.

Before the first switch, move each block into your private flake, as `programs.ssh.matchBlocks` of the laptop's home-manager configuration:

```nix
home-manager.users.alice.programs.ssh.matchBlocks."github.com" = {
  user = "git";
  identityFile = "~/.ssh/keys/github-sk";
  identitiesOnly = true;
  extraOptions.IdentityAgent = "none";
};
```

Record what ssh makes of each host before the switch, with `ssh -G HOST > HOST.before`, and compare it afterward with `ssh -G HOST | diff HOST.before -`. Then remove the old file, or move it out of `~/.ssh`, and switch.
