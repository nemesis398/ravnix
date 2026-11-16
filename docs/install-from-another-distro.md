# Install Nix on another distribution

Ravnix is a NixOS flake, so building it needs Nix. On a machine that still runs another distribution, install Nix first, evaluate and build the flake there, and move to NixOS later. This page covers a systemd distribution with SELinux enforcing, such as Fedora. It installs upstream Nix with the Determinate Nix Installer, which handles SELinux and keeps a receipt for the uninstall. The uninstall removes most of what the install adds. This page lists what it leaves behind and what to restore.

The install writes no partition, filesystem or boot entry. `/nix` becomes a plain directory on the root filesystem, and the disk layout stays as it was.

The sections after the install are for the move itself: a file of your home that ravnix takes over on the laptop, `~/.ssh/config`, and the state that the flake does not hold and that you copy or set up once after the first boot: the keyring, the NetworkManager profiles and root's atuin login.

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

- Without `home-manager.backupFileExtension` or `home-manager.backupCommand` in your private flake, the switch stops before it changes anything. The `home-manager-<you>` unit fails with `Existing file '/home/<you>/.ssh/config' would be clobbered`.
- With `home-manager.backupFileExtension`, the switch renames the file to `~/.ssh/config.<extension>`. It logs a warning first (`Existing file ... is in the way of ..., will be moved to ...`), and the warning is in the journal of the `home-manager-<you>` unit, not on the terminal where you ran the switch. From then on nothing reads the renamed file.
- If `~/.ssh/config.<extension>` exists already, the switch stops again, with `Existing file '/home/<you>/.ssh/config.<extension>' would be clobbered by backing up '/home/<you>/.ssh/config'`, and the file stays where it is. Move the old backup away, or set `home-manager.overwriteBackup = true`, which replaces it.
- With `home-manager.backupCommand`, the switch runs that command with the file's path as its argument, in place of the rename (and ahead of `backupFileExtension`, if you set both). The command has to move or copy the file itself. If it fails, the switch says so and goes on, and the new `~/.ssh/config` replaces whatever is left.
- A `~/.ssh/config` that is a symlink is never backed up, whichever of these you set. Unless it points into a home-manager generation, the switch stops with `would be clobbered`. Remove the link first, after you have kept what it points to.

Whichever way you go, the hosts that file named lose their settings. That matters most for the git hosts. A block that says `IdentityAgent none` and names the security key's handle keeps the agent of `SSH_AUTH_SOCK`, rbw's, away from that host. Without the block, ssh offers the host every key of that agent.

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

## After the laptop's first switch: a tap instead of the password

With `ravnix.security.u2f.enable = true` in your `me.nix`, the laptop asks your security key first at the login screen, the lock screen, sudo, su, polkit and a console login (`modules/desktop/u2f.nix`). A tap logs you in, and the password keeps working. Without the key, the password prompt comes at once. With the key plugged in and not touched, it comes when the key gives up waiting.

sudo asks on your screen before it waits for the key. A small popup names the command, the user and where the sudo came from: a terminal on the laptop, or a program without a terminal. Choose Allow, and the key blinks for the touch. Deny, Esc, or 30 seconds without an answer skip the tap, and sudo asks for the password as before. Nothing pops up while the screen is locked, while no key is plugged in, before you have a mapping, or for a command too long to show whole. A sudo over ssh never reaches the key: it is refused with one line in the journal (`journalctl -t ravnix-tap-ask`), and polkit refuses pkexec and run0 from there before it asks anything. On the laptop that ssh is the server's laptop-access link, whose gate runs no sudo in the first place (below), so this is a tripwire for the case the gate rules out.

This is consent against a mistaken touch, not a defense against a hostile program of yours: a program that runs as you can step outside the ssh session and answer the popup itself. It cannot touch the key. The server's link runs no such program. Its key on the laptop runs a gate (`tools/ravnix-laptop-gate`) that answers `ping`, `facts`, `battery`, `charge-mode` and `power` and refuses everything else, sudo included, with one line in the journal (`journalctl -t ravnix-laptop-gate`).

The key does nothing until it has a mapping in `~/.config/Yubico/u2f_keys`. The mapping is bound to the origin `pam://ravnix`, not to a host name, so one made with the same `-o` and `-i` on any machine works here as it is: copy it in. Only a mapping made with pamu2fcfg's default origin, `pam://` and the host name, has to be made again. To make one, run `pamu2fcfg` as yourself and not as root, on any machine with the key plugged in, and touch the key when it blinks. On the laptop, `pamu2fcfg` comes with the option. A key with a FIDO2 PIN asks for it here, once:

```sh
mkdir -p ~/.config/Yubico
pamu2fcfg -o pam://ravnix -i pam://ravnix > ~/.config/Yubico/u2f_keys
chmod 600 ~/.config/Yubico/u2f_keys
```

The file must be yours and writable by you alone. pam_u2f refuses a mapping that another user owns, but it only warns about one that others may write, and whoever can write the file can add a key of their own.

Until that file exists, every prompt asks for the password as before. If you set `ravnix.security.u2f.origin` to another value, use that value after `-o` and `-i`. Test the tap with `sudo -k; sudo true` in a terminal before you lock the screen, and keep a second terminal with a root shell open until it works.

A tap hands PAM no password, so the login keyring stays locked after a tap login, and the first application that wants a secret asks for its password. The next section opens it after every login.

## After the laptop's first login: the keyring for a YubiKey tap

When you log in at the greeter with your password, PAM hands it to gnome-keyring, and the login keyring opens. Helium keeps its cookie key there ("Chromium Safe Storage"), so it starts without asking. A YubiKey tap gives PAM no password, and the keyring stays locked. With `ravnix.desktop.keyring.autoUnlock.enable = true` in your private flake, the user service `ravnix-keyring-unlock` opens it after every login, before Helium starts, with the keyring's password kept as a systemd credential of your user. The keyring itself stays encrypted on the disk, but it now opens for whoever can log in as you, with a tap as well. The credential is encrypted for this machine: its TPM2 when it has one, the host key in `/var/lib/systemd/`, the machine ID, your UID and your user name. A copy of the file is of no use on another machine or to another user.

The keyring gets a password of its own, one that is not your login password. PAM created the keyring with your login password, and every program that runs as you can decrypt the credential again with `systemd-creds --user decrypt`, as it can read every secret of the unlocked keyring. With its own password, the credential gives such a program nothing it could not read already. With your login password, it would give it the password that sudo asks for. A password login still works afterward: PAM's attempt with your login password fails, and the service unlocks the keyring. So no login unlocks it with the keyring's own password, and you will not type that password again. Keep it in your password manager: you need it to redo the setup, and without it every item of the keyring is lost.

So make it there first: a new item in Bitwarden, its password from Bitwarden's generator, in bwm or the web vault (Vaultwarden refuses `rbw add`). Name the item in `ravnix.desktop.keyring.autoUnlock.rbwItem`, next to `enable = true`, and switch. Then run one command once on the laptop, in a terminal of the graphical session, with the vault unlocked (`rbw unlock`, or `ai-unlock`):

```sh
ravnix-keyring-unlock setup
```

It reads the new password from the item through rbw, asks once for the keyring's current password (your login password, unless you gave the keyring another one) with the input masked, one asterisk per character, changes the keyring's password to the item's on the running gnome-keyring, stores it as the credential `~/.config/credstore.encrypted/ravnix-keyring-login`, and checks that the keyring opens with what the credential holds. Nothing is copied or pasted, and no password stands on a command line or in your shell's history. A wrong current password changes nothing, and an item that holds your login password is refused: pam_unix's `unix_chkpwd` checks it, which leaves one failed password check in the journal. If the setup stops halfway, run it again: when the keyring has the item's password already, it asks for nothing and only stores the credential.

The next login with a tap opens the keyring. What the service did is one line in `journalctl --user -u ravnix-keyring-unlock`: it unlocked the keyring, found it unlocked already (a password login), found no credential, or warns that the password does not unlock the keyring. In every case but the first it changes nothing.

Run the setup again whenever the credential no longer decrypts: after the TPM was cleared (a firmware update or a firmware reset can clear a firmware TPM), after a reinstall, and on a new machine. Until you do, a tap leaves the keyring locked. After a change of the keyring's password the journal warns that the stored one does not unlock the keyring; when the credential no longer decrypts, the service fails with systemd's decryption error, and `systemctl --user --failed` lists it. To turn the unlock off without a rebuild, delete `~/.config/credstore.encrypted/ravnix-keyring-login`.

The manual way, without the setup command: change the keyring's password to one of its own yourself, then store it with these two lines. `systemd-ask-password` asks for it with the input masked (press Tab first to show nothing at all):

```sh
mkdir -p -m 0700 ~/.config/credstore.encrypted
systemd-ask-password -n 'Login keyring password:' |
  systemd-creds --user encrypt --name=ravnix-keyring-login - \
    ~/.config/credstore.encrypted/ravnix-keyring-login
```

## After the laptop's first boot: the NetworkManager profiles

Wi-Fi and wired profiles are state, not configuration: they hold the networks' passwords, and a flake that is public must not. So the flake declares none, and you copy them over once, from the other distribution's root file system. Copy every file of `/etc/NetworkManager/system-connections/` and not only the home Wi-Fi's, except the profile `wg-nord`, which `nord setup` builds again with a fresh WireGuard key (`packages/nord/README.md`).

The other distribution's root file system is on the disk the laptop keeps, so open it read-only, by the by-id link of that disk's own partition, and write nothing to it (AGENTS.md, rule 2). On Fedora's default layout the partition is LUKS, holding a btrfs file system with the subvolume `root`. `ls -l /dev/disk/by-id/` lists the links, and `lsblk -f` shows which partition is `crypto_LUKS`. Take the link of the other disk, and never the one of huginn's own (the disk of `ravnix.laptop.diskModel` and `diskSerial`), and never a kernel name such as `/dev/nvme0n1p3`, which can be the other disk after the next boot. The disk's model and serial are in the link's name.

```sh
OLD=/dev/disk/by-id/nvme-MODEL_SERIAL-part3   # the other disk's LUKS partition
sudo cryptsetup open --readonly "$OLD" oldroot
sudo mkdir -p /mnt/old-root
sudo mount -o ro,rescue=nologreplay,subvol=root /dev/mapper/oldroot /mnt/old-root
```

`--readonly` opens the mapping read-only, and `ro,rescue=nologreplay` keeps btrfs from replaying its log, which would write. Then copy. The directory is root's alone, so the copy has no glob that your shell would expand, and the last command lets root find the files: your shell cannot list the directory, so a `*` after it stays a literal `*` and `sudo chmod 600 /etc/NetworkManager/system-connections/*` fails.

```sh
sudo install -d -m 0700 -o root -g root /etc/NetworkManager/system-connections
sudo cp -a /mnt/old-root/etc/NetworkManager/system-connections/. /etc/NetworkManager/system-connections/
sudo find /etc/NetworkManager/system-connections -type f -exec chown root:root {} + -exec chmod 600 {} +
sudo rm -f /etc/NetworkManager/system-connections/wg-nord.nmconnection
sudo nmcli connection reload
```

The owner root and the mode 0600 matter: NetworkManager ignores a file that anyone else can read. `cp -a` keeps them, and the `find` makes sure. Close the old root again before you go on:

```sh
sudo umount /mnt/old-root
sudo cryptsetup close oldroot
```

Profiles of a machine that is not this one, such as a wired connection of a docking station you no longer use, can stay out too: delete their files before the reload. A profile that names a network interface or a MAC address (`interface-name`, `mac-address` in its `[connection]` or `[wifi]` section) works on the same laptop and nowhere else. `nmcli connection show` lists what NetworkManager loaded, and `nmcli connection up NAME` joins one.

## After the laptop's first boot: root's atuin login

huginn records root's shell history in atuin and shares one timeline with your own, as the other distribution did. The configuration is in the flake (`hosts/laptop/atuin-root.nix`): root's atuin config, with the sync address of `ravnix.services.atuin`, and the init that `sudo -i`, `su -` and a root console read. What the flake cannot hold is the login to the account, which needs the account's password and its recovery key. Until you log root in, root's history is recorded and stays on the laptop.

Do it once, as yourself and not as root, in a terminal, with the vault unlocked (`ai-unlock`). Bitwarden's item for the account holds the username, the password, and the recovery key (the 24 words of `atuin key`) alone in its notes:

```sh
atuin-root-login "Atuin"
```

Give it your item's name or id. It reads the three fields through rbw, as you, because root has no vault, and hands them to the root half of itself through sudo, which asks for your password or key as it does for any command. The password and the key travel through a pipe and shell variables only: on no command line (atuin gets `-p -`, which reads the password from its standard input, and the key in `ATUIN_ENCRYPTION_KEY` for that one command), in no file but atuin's own key file, in no output and in no trace. The account's name is on atuin's command line, since it is a name and not a secret. It then runs `atuin sync` once, so root's history appears on the laptop and the laptop's in root's. If root is logged in already, atuin says so and changes nothing, so running it again is safe.

Run it again whenever root's atuin has to log in again, for instance after the account's password changed (`sudo atuin logout` first) or after a reinstall. `sudo atuin status` shows whether root is logged in.
