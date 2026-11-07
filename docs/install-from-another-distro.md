# Install Nix on another distribution

Ravnix is a NixOS flake, so building it needs Nix. On a machine that still runs another distribution, install Nix first, evaluate and build the flake there, and move to NixOS later. This page covers a systemd distribution with SELinux enforcing, such as Fedora. It uses the Determinate Nix Installer, which handles SELinux and removes everything it added.

The install writes no partition, filesystem or boot entry. `/nix` becomes a plain directory on the root filesystem, and the disk layout stays as it was.

## Install

```sh
curl --proto '=https' --tlsv1.2 -sSfL https://install.determinate.systems/nix |
  sh -s -- install linux --no-confirm --diagnostic-endpoint ""
```

| Part | Why |
| --- | --- |
| `install linux` | Names the planner for a mutable Linux system, so the installer does not have to guess |
| `--no-confirm` | Runs without a prompt. Drop it to read the plan and answer yes |
| `--diagnostic-endpoint ""` | Switches off the installer's anonymous report to its maker |

The script downloads a pinned installer (3.24.2 when this page was written) and asks for `sudo` itself. To read it before it runs, save the script to a file with `curl -o`, look at it, then run it with `sh`.

The installer installs Determinate Nix by default: Nix 2.35 at that version, with flakes already on. Add `--prefer-upstream-nix` to ask for upstream Nix instead. The installer calls that choice unsupported, and it was not tried here. Any Nix from 2.30 on is enough for ravnix.

## What it changes

Everything outside `/nix` that the installer touches:

| Where | What |
| --- | --- |
| `/nix` | The store and its state. A directory on the existing filesystem, with a copy of the installer and its receipt at `/nix/nix-installer` and `/nix/receipt.json` |
| `/usr/local/bin/determinate-nixd` | The Determinate daemon |
| `/etc/systemd/system/` | `nix-daemon.service`, `nix-daemon.socket` and `determinate-nixd.socket`, enabled and started |
| `/etc/nix/` | `nix.conf` (managed, do not edit), `nix.custom.conf` (yours) and `sentry-endpoint` |
| `/etc/tmpfiles.d/nix-daemon.conf` | A symlink into the Nix profile |
| Shell profiles | A block that sources the Nix profile, added to `/etc/bashrc`, and new files `/etc/bash.bashrc`, `/etc/profile.d/nix.sh`, `/etc/zshrc`, `/etc/zsh/zshrc` and `/usr/share/fish/vendor_conf.d/nix.fish` |
| Users and group | Group `nixbld` (GID 30000) and 32 build users `nixbld1` to `nixbld32` (UID 30001 to 30032), all without a shell |
| SELinux | The policy module `nix`, loaded from `/usr/share/selinux/packages/nix.pp` |

Your own home directory is not touched until you run Nix. Then Nix creates `~/.cache/nix`.

Determinate Nix routes a bare `nixpkgs` on the command line (`nix run nixpkgs#hello`) to a weekly nixpkgs from FlakeHub. A flake pins its own inputs, so this changes only commands that name `nixpkgs` directly. The Determinate daemon also reports errors to Determinate Systems (the endpoint is in `/etc/nix/sentry-endpoint`). Choose upstream Nix if that is not acceptable.

## Trust your user

Builds on a remote machine and extra binary caches need a trusted user. A trusted user can do anything the daemon can, so add only an account you own:

```sh
printf 'trusted-users = root %s\n' "$USER" | sudo tee -a /etc/nix/nix.custom.conf
sudo systemctl restart nix-daemon.service
```

Put settings in `nix.custom.conf`, never in `nix.conf`: Determinate Nix replaces `nix.conf` on upgrade.

## Verify

Open a new shell, or run `. /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh`, then:

```sh
nix --version                    # 2.30 or newer
nix run nixpkgs#hello            # Hello, world!
nix config show trusted-users    # root and your user name
nix store info --store daemon    # Trusted: 1
```

To confirm that no disk changed, compare the layout before and after:

```sh
lsblk -o NAME,MODEL,SERIAL,PARTUUID,FSTYPE > lsblk-before.txt   # before the install
lsblk -o NAME,MODEL,SERIAL,PARTUUID,FSTYPE | diff lsblk-before.txt -   # after: no output
```

Removable media can make the diff differ. A partition or filesystem on an internal disk must not.

## Uninstall

```sh
sudo /nix/nix-installer uninstall
```

The command prints its plan and asks before it removes anything. It follows the receipt in `/nix/receipt.json`: it removes the daemon and its units, `determinate-nixd`, the SELinux module, the shell profile hooks, `/etc/nix/nix.conf`, the build users and group, and all of `/nix`, store included. Anything you built and want to keep must be copied out first.

Afterwards, check that nothing is left:

```sh
ls /nix                                              # No such file or directory
ls /etc/nix /usr/local/bin/determinate-nixd          # both gone
systemctl list-unit-files 'nix-daemon*' 'determinate-nixd*'   # none listed
getent group nixbld; getent passwd | grep '^nixbld'  # no output
sudo semodule -l | grep -x nix                       # no output
sudo grep -rl nix-daemon.sh /etc /usr/share/fish     # no output
```

The installer does not know about files you added yourself, so if `/etc/nix` is still there, `nix.custom.conf` is the likely reason. Remove it. The uninstall also leaves your home directory alone: delete `~/.cache/nix` and, if they exist, `~/.nix-profile`, `~/.nix-defexpr` and `~/.local/state/nix` by hand. Last, run the `lsblk` comparison again.
