# The script the install runs: what `disko --mode destroy,format,mount
# --argstr device DEV hosts/laptop/disko.nix` evaluates, for the by-id path
# the disk guard prints. It must touch that disk and nothing else, and lay out
# a 1 GiB ESP and a LUKS2 volume named cryptroot holding btrfs with the
# subvolumes @, @home, @nix and @log, compressed with zstd, and no swap. The
# layout refuses a device that is not a /dev/disk/by-id path, so a kernel
# name such as /dev/nvme0n1 never reaches it. Nothing here runs the script;
# tests/laptop/disko.nix does, in a VM.
{
  inputs,
  pkgs,
  lib,
  ...
}:
let
  layout = ../../hosts/laptop/disko.nix;
  device = "/dev/disk/by-id/nvme-Example_SSD_1TB_EXAMPLE0SERIAL";

  # The disko CLI's own evaluation: it imports cli.nix with the mode, the
  # layout file as diskoFile and every --argstr as an argument.
  cli =
    mode: args:
    import "${inputs.disko}/cli.nix" (
      {
        inherit pkgs mode;
        diskoFile = layout;
      }
      // args
    );
  script = cli "destroy,format,mount" { inherit device; };

  # What the layout does with a device argument: the string it hands disko,
  # or an error.
  accepts = dev: (builtins.tryEval (builtins.deepSeq (import layout { device = dev; }) true)).success;
  refused = [
    "/dev/nvme0n1"
    "/dev/nvme1n1"
    "/dev/sda"
    "nvme0n1"
    "/dev/disk/by-id/"
    "/dev/disk/by-id/../../nvme0n1"
    "/dev/disk/by-id/nvme-x/../../../nvme0n1"
    "/dev/disk/by-partlabel/disk-huginn-luks"
    "/dev/disk/by-uuid/0000-0000"
    "/dev/mapper/cryptroot"
    ""
  ];
  failures =
    lib.optional (!accepts device) "the layout refuses the by-id path ${device}"
    ++ map (dev: "the layout accepts ${builtins.toJSON dev}, which is no by-id path") (
      lib.filter accepts refused
    )
    ++ lib.optional (
      (builtins.tryEval (builtins.deepSeq (import layout { }) true)).success
    ) "the layout evaluates without a device";
in
pkgs.runCommand "laptop-disko-script"
  {
    nativeBuildInputs = [ pkgs.ripgrep ];
    inherit device;
    failures = lib.concatStringsSep "\n" failures;
  }
  ''
    fail() { echo "laptop-disko-script: $*" >&2; status=1; }
    status=0
    [ -z "$failures" ] || fail "$failures"
    s=$(echo ${script}/bin/*)
    [ -f "$s" ] || fail "the CLI's destroy,format,mount gave no script"
    echo "the script: $s"

    # The confirmation lists the disks it wipes: exactly this one.
    listed=$(rg -o --no-filename '^\s*for dev in (.*); do$' -r '$1' "$s" | sort -u)
    [ "$listed" = "'$device'" ] || [ "$listed" = "$device" ] ||
      fail "it wipes $listed, not only $device"

    # Every device path in its code (its comments aside) is the disk, a
    # partition of it by its label, the LUKS mapping, or /dev/null; never a
    # kernel name.
    others=$(rg -v '^\s*#' "$s" | rg -o '/dev/[A-Za-z0-9_./-]+' | sort -u |
      rg -v -x -F -e "$device" -e /dev/disk/by-partlabel/disk-huginn-ESP \
        -e /dev/disk/by-partlabel/disk-huginn-luks -e /dev/mapper/cryptroot -e /dev/null || true)
    [ -z "$others" ] || fail "it names other devices: $others"

    # The layout.
    rg -q -F -- "--new=1:0:+1G" "$s" || fail "no 1 GiB first partition"
    rg -q -F -- "--typecode=1:EF00" "$s" || fail "the first partition is no ESP"
    rg -q -F -- "--new=2:0:-0" "$s" || fail "the second partition does not take the rest"
    rg -q -F -- 'mkfs.vfat' "$s" || fail "no vfat on the ESP"
    rg -q -e 'luksFormat "/dev/disk/by-partlabel/disk-huginn-luks" --type luks2' "$s" || fail "no LUKS2 on the second partition"
    rg -q -F -- 'cryptsetup open "/dev/disk/by-partlabel/disk-huginn-luks" "cryptroot"' "$s" || fail "the LUKS volume is not opened as cryptroot"
    rg -q -F -- 'mkfs.btrfs "/dev/mapper/cryptroot"' "$s" || fail "no btrfs in the LUKS volume"
    for sub in @ @home @nix @log; do
      rg -q -F -- "SUBVOL_ABS_PATH=\"\$MNTPOINT/$sub\"" "$s" || fail "no subvolume $sub"
      rg -q -F -- "-o compress=zstd -o subvol=$sub" "$s" || fail "$sub is not mounted with compress=zstd"
    done
    for mnt in / /home /nix /var/log /boot; do
      rg -q -F -- "\"/mnt$mnt\"" "$s" || fail "nothing is mounted at /mnt$mnt"
    done
    if rg -q -e 'mkswap|swapon' "$s"; then fail "it makes swap"; fi
    # The passphrase is asked for, never taken from a file.
    rg -q -F -- 'Enter password for /dev/disk/by-partlabel/disk-huginn-luks' "$s" || fail "it does not ask for the passphrase"

    [ "$status" = 0 ] && touch "$out"
    exit "$status"
  ''
