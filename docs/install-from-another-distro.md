# Install Nix on another distribution

Ravnix is a NixOS flake, so building it needs Nix. On a machine that still runs another distribution, install Nix first, evaluate and build the flake there, and move to NixOS later. This page covers a systemd distribution with SELinux enforcing, such as Fedora. It uses the Determinate Nix Installer, which handles SELinux and keeps a receipt for the uninstall. The uninstall removes most of what the install adds. This page lists what it leaves behind and what to restore.

The install writes no partition, filesystem or boot entry. `/nix` becomes a plain directory on the root filesystem, and the disk layout stays as it was.

## Before you install

Record the disk layout, so that you can compare it afterward:

```sh
lsblk -o NAME,MODEL,SERIAL,PARTUUID,FSTYPE > lsblk-before.txt
```

## Install

```sh
curl --proto '=https' --tlsv1.2 -sSfL https://install.determinate.systems/nix |
  DETSYS_IDS_TELEMETRY=disabled sh -s -- install linux --no-confirm
```

| Part | Why |
| --- | --- |
| `DETSYS_IDS_TELEMETRY=disabled` | Switches off the telemetry of the installer and of the other Determinate tools. The installer passes it on when it re-runs itself under `sudo`. Its own flag `--diagnostic-endpoint ""` is no substitute: in version 3.24.2 an empty value falls back to the default endpoint |
| `install linux` | Names the planner for a mutable Linux system, so the installer does not have to guess |
| `--no-confirm` | Runs without a prompt. Drop it to read the plan and answer yes |

The script downloads a pinned installer (3.24.2 when this page was written) and asks for `sudo` itself. To read the script before it runs, save it and start it by hand:

```sh
curl --proto '=https' --tlsv1.2 -sSfL https://install.determinate.systems/nix -o nix-install.sh
less nix-install.sh
DETSYS_IDS_TELEMETRY=disabled sh nix-install.sh install linux --no-confirm
```

Downloading the script and the installer means connecting to `install.determinate.systems`. That is the download, not telemetry.

The installer installs Determinate Nix by default: Nix 2.35 at that version, with flakes already on. Add `--prefer-upstream-nix` to ask for upstream Nix instead. The installer calls that choice unsupported, and it was not tried here. Any Nix from 2.30 on is enough for ravnix.

## Turn the telemetry of the daemon off

Determinate's own guide, <https://docs.determinate.systems/guides/telemetry/>, says what its tools collect: operating system version and hardware properties such as CPU and RAM, preferred language and timezone, which features are on, the version in use, whether you are logged in to FlakeHub (an anonymous device ID is then linked to your account), and crash reports, which go to Sentry by default. It says that the data never includes derivation names, store paths, store path hashes or build results. It also says that turning telemetry off turns off Determinate's tooling for rolling out features, so some features may not reach you.

The daemon starts once during the install, before any switch below exists, so that first run may have sent its check-in already. Set the switches now:

```sh
sudo install -d /etc/determinate /etc/systemd/system/nix-daemon.service.d
sudo tee /etc/determinate/config.json <<'EOF'
{
  "telemetry": {
    "sentry": {
      "endpoint": null
    }
  }
}
EOF
sudo tee /etc/systemd/system/nix-daemon.service.d/telemetry-off.conf <<'EOF'
[Service]
Environment=DETSYS_IDS_TELEMETRY=disabled
Environment=NIX_SENTRY_ENDPOINT=
EOF
sudo systemctl daemon-reload
sudo systemctl restart nix-daemon.service
```

| Switch | Effect |
| --- | --- |
| `DETSYS_IDS_TELEMETRY=disabled` | No telemetry. The daemon logs `Telemetry is disabled` when it starts |
| `NIX_SENTRY_ENDPOINT=` and `telemetry.sentry.endpoint` set to `null` | No crash reports. The daemon deletes `/etc/nix/sentry-endpoint` at the restart, and the `nix` command reads that file, so the command needs no variable of its own |

Both are documented in the guide above and in the Determinate Nixd configuration reference. The drop-in survives upgrades of the unit file. When you run `determinate-nixd` by hand (for example `upgrade`), set `DETSYS_IDS_TELEMETRY=disabled` for that command too.

The first daemon run and the installer leave local ID files behind. Remove them, and expect the installer to write them again whenever you run it (it sends nothing from them while the switch is set):

```sh
rm -r ~/.local/state/systems.determinate.detsys-ids-client
sudo rm -r /root/.local/state/systems.determinate.detsys-ids-client
rm -r ~/.cache/nix/sentry
sudo rm -r /root/.cache/nix/sentry
```

A path that is not there makes `rm` complain, which is fine. The daemon also writes `/nix/var/determinate/identity.json` with fresh random IDs at every start, even with telemetry off. That file stays local and goes away with `/nix`.

Check the result:

```sh
systemctl show nix-daemon.service -p Environment   # DETSYS_IDS_TELEMETRY=disabled NIX_SENTRY_ENDPOINT=
sudo journalctl -u nix-daemon.service -b | grep 'Telemetry is disabled'
ls /etc/nix/sentry-endpoint ~/.local/state/systems.determinate.detsys-ids-client   # No such file or directory, twice
```

These switches do not cover two contacts, and neither is telemetry in Determinate's sense:

- At every start the daemon opens one short HTTPS connection to `install.determinate.systems` and sends one small request (about 140 bytes of payload; it is encrypted, so what it asks for is not visible). It also probes the cloud metadata address 169.254.169.254 for about 18 seconds, apparently to log in through a cloud identity. Outside a cloud nothing answers.
- `nix.conf` lists `https://install.determinate.systems/` as an extra substituter, so a build asks that cache about every store path it cannot find elsewhere. That reveals the hashes of the paths you build. `nix.custom.conf` cannot remove it, because `nix.conf` adds the substituter after it includes that file. A trusted user can override the list in their own config instead, with `mkdir -p ~/.config/nix && echo 'substituters = https://cache.nixos.org/' >> ~/.config/nix/nix.conf`.

## What it changes

Everything outside `/nix` that the installer touches:

| Where | What |
| --- | --- |
| `/nix` | The store and its state. A directory on the existing filesystem, with a copy of the installer and its receipt at `/nix/nix-installer` and `/nix/receipt.json` |
| `/usr/local/bin/determinate-nixd` | The Determinate daemon |
| `/etc/systemd/system/` | `nix-daemon.service`, `nix-daemon.socket` and `determinate-nixd.socket`, enabled and started |
| `/etc/nix/` | `nix.conf` (managed, do not edit), `nix.custom.conf` (yours) and, written by the daemon, `sentry-endpoint` |
| `/etc/tmpfiles.d/nix-daemon.conf` | A symlink into the Nix profile |
| Shell profiles | A block that sources the Nix profile, added to `/etc/bashrc`, and new files `/etc/bash.bashrc`, `/etc/profile.d/nix.sh`, `/etc/zshrc`, `/etc/zsh/zshrc` and `/usr/share/fish/vendor_conf.d/nix.fish` |
| Users and group | Group `nixbld` (GID 30000) and 32 build users `nixbld1` to `nixbld32` (UID 30001 to 30032), all without a shell |
| SELinux | The policy module `nix`, loaded from `/usr/share/selinux/packages/nix.pp` |
| Your home and `/root` | `~/.local/state/systems.determinate.detsys-ids-client/`, written by the installer itself, and the same under `/root`. Nix creates `~/.cache/nix` on first use, and `/root/.cache/nix` for the daemon |
| Made by you above | `/etc/determinate/config.json` and `/etc/systemd/system/nix-daemon.service.d/` |

`nix.conf` also turns on `lazy-trees` and `always-allow-substitutes`, trusts the `cache.flakehub.com` signing keys, and adds the substituter named above.

Determinate Nix routes a bare `nixpkgs` (`nix run nixpkgs#hello`, or `<nixpkgs>`) to a weekly nixpkgs from FlakeHub. A flake that names `nixpkgs` indirectly (`inputs.nixpkgs.url = "nixpkgs"`, or an input with no URL) resolves it through the same registry when it is first locked. A flake with a lock file, or one that names `github:NixOS/nixpkgs`, does not.

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

To confirm that no disk changed, compare the layout with the file you wrote before the install:

```sh
lsblk -o NAME,MODEL,SERIAL,PARTUUID,FSTYPE | diff lsblk-before.txt -   # no output
```

Removable media can make the diff differ. A partition or filesystem on an internal disk must not.

## Uninstall

```sh
sudo env DETSYS_IDS_TELEMETRY=disabled /nix/nix-installer uninstall
```

The uninstaller has its own diagnostic report, which is on by default, so pass the switch here too. The command prints its plan and asks before it removes anything. It follows the receipt in `/nix/receipt.json`. It removes the daemon and its units, `determinate-nixd`, the SELinux module, the shell profile hooks, `/etc/nix/nix.conf`, `/etc/nix/nix.custom.conf` (with your `trusted-users` line), the build users and group, and all of `/nix`, store included. Anything you built and want to keep must be copied out first.

On Fedora it also removes `/etc/tmpfiles.d` when that directory is empty. The `systemd` package owns it, and the Nix symlink was the only thing in it, so it goes. Put it back:

```sh
test -d /etc/tmpfiles.d || { sudo install -d -m 0755 /etc/tmpfiles.d && sudo restorecon /etc/tmpfiles.d; }
```

The receipt does not cover the files below, so the uninstall leaves them. Remove what is there:

```sh
sudo rm -r /etc/nix /etc/determinate /etc/systemd/system/nix-daemon.service.d
sudo systemctl daemon-reload
rm -r ~/.local/state/systems.determinate.detsys-ids-client ~/.cache/nix
sudo rm -r /root/.local/state/systems.determinate.detsys-ids-client /root/.cache/nix
```

Also delete `~/.nix-profile`, `~/.nix-defexpr` and `~/.local/state/nix` if they exist. Then check that nothing is left:

```sh
ls /nix                                              # No such file or directory
ls /etc/nix /etc/determinate /usr/local/bin/determinate-nixd   # all gone
systemctl list-unit-files 'nix-daemon*' 'determinate-nixd*'   # none listed
getent group nixbld; getent passwd | grep '^nixbld'  # no output
sudo semodule -l | grep -x nix                       # no output
sudo grep -rl /nix/var/nix/profiles/default /etc /usr/share/fish   # no output
ls /etc/bashrc.rpmnew                                # No such file or directory
```

The grep path appears in all six shell hooks, the fish one included. If `/etc/bashrc.rpmnew` exists, a `setup` update arrived while the Nix block sat in `/etc/bashrc`. Merge it and remove the block by hand. Last, log out and back in, because the open session still carries the `PATH` and `NIX_*` variables that the hooks set, and run the `lsblk` comparison again.
