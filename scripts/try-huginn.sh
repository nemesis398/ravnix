#!/usr/bin/env bash
# try-huginn: boots the laptop's installed system in a QEMU window, from the
# real disk, to see its boot loader, its LUKS prompt and greetd's tuigreet
# before the first native boot (Task 3.5, step 5). It is a wrapper and
# nothing else: take the lock, ask the disk guard, refuse or start QEMU.
#
#   sudo --preserve-env=WAYLAND_DISPLAY,XDG_RUNTIME_DIR,DISPLAY,XAUTHORITY \
#     try-huginn --model MODEL --serial SERIAL
#
# MODEL and SERIAL are the private flake's ravnix.laptop.diskModel and
# diskSerial, as the guard takes them; nothing about the disk is in this
# file. The script never takes a device path: the only one QEMU gets is the
# one `ravnix-disk-guard --print-device` printed, which names the disk by
# model and serial under /dev/disk/by-id (AGENTS.md, rule 2).
#
# What it does, in order, and what it refuses:
#   1. Usage: exactly --model and --serial, once each, non-empty; exit 3.
#   2. It must run as root, exit 1 otherwise. The disk's device node is
#      root's, QEMU with KVM and a raw block device needs it, and the whole
#      script runs under that one privilege instead of sudo for qemu alone:
#      the guard, the lock and the firmware copy then run as the same user
#      as the process that holds the disk, a sudo password prompt cannot
#      open a gap between the guard's re-check and QEMU's start, and there
#      is no sudo policy here to get wrong. The cost is a QEMU window opened
#      by root, which is why the line above passes the display variables.
#   3. qemu-system-x86_64 and the firmware must exist, before anything else.
#   4. One flock on /run/lock/ravnix-huginn-disk.lock, a fixed path that no
#      variable changes, and that the install takes too: its guard, disko,
#      nixos-install and systemd-cryptenroll all run in one shell that holds
#      the same lock (hosts/laptop/disko.nix). Both sides use this path. The
#      guard cannot see a disk that a process holds open, such as this very
#      VM, so the lock is what keeps the installer and a running VM apart.
#      It stays held until QEMU ends.
#   5. The guard. Exit 0 and one by-id name is the only way on. Exit 2 means a
#      partition of the disk is mounted on this system (or a LUKS volume or
#      another mapping holds it): refused, exit 2. Exit 1 (not exactly one
#      disk) and any other answer: refused, exit 1.
#   6. A writable copy of the OVMF variables in a temporary directory, never
#      the store file; it is deleted when the script ends.
#   7. The guard again, right before QEMU, and the same device: a mount since
#      the first answer refuses.
#   8. QEMU, as a child, so the temporary directory and the lock are cleaned
#      up when it ends. Its exit status is the script's.
#
# What gets written: not by this script. QEMU opens the disk as a raw drive,
# read and write, with no -snapshot and no overlay, because the guest has to
# write to its own disk: the boot loader's state, the LUKS header's
# keyslots, the journal, anything the guest does. Do not run it to look at
# a disk you want unchanged. Fedora must keep the disk unmounted for the
# whole run: nothing may mount a partition or open the LUKS volume while the
# guest runs, since two writers on one file system corrupt it, and the guard
# cannot see this VM. The run's own firmware variables live only in the
# temporary copy, so the guest's boot entries do not outlive the run: the
# disk must boot from the removable path (\EFI\BOOT\BOOTX64.EFI).
#
# The device is restricted to /dev/disk/by-id/ followed by letters, digits
# and . _ : + = @ - (starting with a letter or digit): udev's by-id names
# have no more. That keeps a space or a comma out of the one QEMU option
# that carries it ("key=value,key=value") and a leading dash out of the
# command line, whatever a broken guard prints.

set -euo pipefail
# The device name check below is a byte range, not a locale's.
export LC_ALL=C

# Replaced by the package with the store paths of OVMF's code and variables.
ovmf_code="@ovmfCode@"
ovmf_vars="@ovmfVars@"
# The install's lock too, and no variable moves it: one file, or no lock.
lock="/run/lock/ravnix-huginn-disk.lock"
by_id="/dev/disk/by-id/"

usage_text='usage: try-huginn --model MODEL --serial SERIAL
  MODEL and SERIAL are the private flake'\''s ravnix.laptop.diskModel and diskSerial.
  Run as root, with the display variables kept:
    sudo --preserve-env=WAYLAND_DISPLAY,XDG_RUNTIME_DIR,DISPLAY,XAUTHORITY try-huginn ...'

usage() {
	echo "try-huginn: $1" >&2
	echo "$usage_text" >&2
	exit 3
}

refuse() {
	local code="$1"
	shift
	echo "try-huginn: refused: $*" >&2
	exit "$code"
}

model=""
serial=""
have_model=0
have_serial=0
while (($# > 0)); do
	case "$1" in
	--help | -h)
		echo "$usage_text"
		exit 0
		;;
	--model | --serial)
		opt="$1"
		(($# >= 2)) || usage "$opt needs a value"
		[[ -n "$2" ]] || usage "$opt needs a value that is not empty"
		if [[ "$opt" == --model ]]; then
			((have_model == 0)) || usage "--model given twice"
			model="$2"
			have_model=1
		else
			((have_serial == 0)) || usage "--serial given twice"
			serial="$2"
			have_serial=1
		fi
		shift 2
		;;
	*) usage "unexpected argument '$1' (the disk is the guard's to name, never an argument)" ;;
	esac
done
((have_model == 1)) || usage "--model is missing"
((have_serial == 1)) || usage "--serial is missing"

[[ "$(id -u)" == 0 ]] ||
	refuse 1 "this needs root: the disk's device node is root's. Run it as" \
		"'sudo --preserve-env=WAYLAND_DISPLAY,XDG_RUNTIME_DIR,DISPLAY,XAUTHORITY try-huginn ...'"

command -v qemu-system-x86_64 >/dev/null 2>&1 || refuse 1 "qemu-system-x86_64 is not on the PATH"
command -v ravnix-disk-guard >/dev/null 2>&1 || refuse 1 "ravnix-disk-guard is not on the PATH"
[[ -r "$ovmf_code" && -r "$ovmf_vars" ]] ||
	refuse 1 "the OVMF firmware is missing ('$ovmf_code', '$ovmf_vars'): run the packaged try-huginn, not the bare script"

exec {lock_fd}<>"$lock" || refuse 1 "cannot open the lock file '$lock'"
flock -n "$lock_fd" ||
	refuse 1 "the lock '$lock' is held: the install step or another try-huginn is running"

# Asks the guard and sets $dev to the one path it prints, or refuses. The
# guard's own words (its verdict) go to this script's standard error.
pick_disk() {
	local rc=0 out
	out="$(ravnix-disk-guard --model "$model" --serial "$serial" --print-device)" || rc=$?
	case "$rc" in
	0) ;;
	1) refuse 1 "the guard found not exactly one disk with that model and serial (or could not read them)" ;;
	2) refuse 2 "a partition of that disk is in use: mounted on this system, or held open by a LUKS volume or another mapping. Unmount and close it first" ;;
	*) refuse 1 "the guard ended with exit $rc, which this script does not know as a go-ahead" ;;
	esac
	[[ -n "$out" ]] || refuse 1 "the guard printed no device"
	[[ "$out" != *$'\n'* ]] || refuse 1 "the guard printed more than one line, and a device is one line"
	[[ "$out" == "$by_id"* ]] || refuse 1 "the guard's device '$out' is not under $by_id"
	[[ "${out#"$by_id"}" =~ ^[A-Za-z0-9][A-Za-z0-9._:+=@-]*$ ]] ||
		refuse 1 "the guard's device '$out' has a name that is not a plain by-id name"
	dev="$out"
}

work="$(mktemp -d -p "${TMPDIR:-/tmp}" try-huginn.XXXXXX)"
trap 'rm -rf -- "$work"' EXIT

dev=""
pick_disk
first="$dev"

vars_copy="$work/OVMF_VARS.fd"
cp -- "$ovmf_vars" "$vars_copy"
chmod 600 -- "$vars_copy"

pick_disk
[[ "$dev" == "$first" ]] || refuse 1 "the guard's device changed between its two answers ('$first', then '$dev')"

echo "try-huginn: starting QEMU on $dev (the guest writes to it; keep it unmounted here until the window closes)" >&2

status=0
qemu-system-x86_64 \
	-name huginn \
	-machine q35 \
	-accel kvm \
	-cpu host \
	-smp 4 \
	-m 6G \
	-drive "if=pflash,format=raw,unit=0,readonly=on,file=$ovmf_code" \
	-drive "if=pflash,format=raw,unit=1,file=$vars_copy" \
	-drive "if=none,id=huginn,format=raw,cache=none,aio=native,file=$dev" \
	-device "nvme,drive=huginn,serial=huginn,bootindex=0" \
	-vga std \
	-display gtk \
	-nic user,model=virtio-net-pci || status=$?
exit "$status"
