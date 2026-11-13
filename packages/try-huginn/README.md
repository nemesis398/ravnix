# try-huginn

Boots the installed laptop in a QEMU window, from its real disk, to see its
boot loader, its LUKS prompt and greetd's tuigreet before the first native
boot (Task 3.5, step 5). Bash, as thin glue (AGENTS.md, rule 4): the script is
`scripts/try-huginn.sh`, with its header as the full description and its
tests in `scripts/tests/try-huginn.test.sh`, which the check `scripts-tests`
runs. This package gives it QEMU, OVMF, `flock` and `ravnix-disk-guard` as
store paths and nothing from the host's PATH.

```sh
MODEL=$(nix eval --raw PRIVATE_FLAKE#nixosConfigurations.huginn.config.ravnix.laptop.diskModel)
SERIAL=$(nix eval --raw PRIVATE_FLAKE#nixosConfigurations.huginn.config.ravnix.laptop.diskSerial)
sudo --preserve-env=WAYLAND_DISPLAY,XDG_RUNTIME_DIR,DISPLAY,XAUTHORITY \
  "$(nix build --no-link --print-out-paths .#try-huginn)/bin/try-huginn" \
  --model "$MODEL" --serial "$SERIAL"
```

The guard's arguments come from the private flake, so the guard, disko and
this script name the same disk. The script never takes a device path.

## What it refuses

| Exit | Cause |
| --- | --- |
| 3 | bad usage |
| 2 | the guard says a partition of the disk is in use (mounted here, or held by a LUKS volume or another mapping), at its first answer or at the re-check right before QEMU |
| 1 | not root; the lock is held (the install step or another run); the guard finds not exactly one disk, fails, or prints anything but one plain `/dev/disk/by-id/` name; the device changed between the two answers; QEMU, the guard or the firmware is missing |

Otherwise QEMU's own exit status.

## Why root, for the whole script

QEMU needs to open the raw device read and write, which is root's. The whole
script runs as root, and not sudo for QEMU alone, so that the guard, the lock
and the firmware copy run as the user that holds the disk, a password prompt
cannot open a gap between the guard's re-check and QEMU's start, and there is
no sudo policy to get wrong. The cost is a QEMU window opened by root on the
user's display, hence the `--preserve-env` list.

## What it writes

Nothing itself. QEMU gets the disk as a raw drive, read and write, with no
snapshot and no overlay, because the guest has to write to its own disk (the
boot loader, the LUKS keyslots, the journal). Keep the disk unmounted on the
host for the whole run. The OVMF variables are a copy in a temporary
directory, deleted at the end, so the guest's boot entries do not outlive the
run and the disk must boot from the removable path, `\EFI\BOOT\BOOTX64.EFI`.

## The lock

The script holds one `flock` on `/run/lock/ravnix-huginn-disk.lock` (or
`RAVNIX_HUGINN_LOCK`) while QEMU runs. The guard cannot see a disk that a
process holds open, such as this VM, so the install step takes the same lock
(`flock /run/lock/ravnix-huginn-disk.lock disko ...`) and neither starts
while the other runs.

## Known gaps

- The guard and the script check the disk at one moment. Something that mounts
  a partition between the re-check and QEMU's open is not seen.
- Not exercised against a real disk or a real display: the tests use stand-ins
  for the guard, QEMU and the disk. How the window behaves as root on Wayland,
  and whether the laptop's initrd finds the disk behind QEMU's NVMe
  controller, show at the first run.
- In the guest, the dGPU is absent, so one failed `systemd-modules-load`
  (`nvidia_uvm`) is expected there.
