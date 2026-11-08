# The install's disk step, end to end, in a VM whose disks are VM images:
# the disk guard picks the disk by model and serial, disko writes the layout
# of hosts/laptop/disko.nix to the path the guard printed, and the other disk
# comes out bit for bit as it went in.
#
# The VM has two NVMe disks of one model, QEMU's, told apart by serial only,
# as two disks of one series would be. The NVMe driver probes them at the
# same time, so which one becomes nvme0n1 is up to the boot, as on the laptop
# (Review Focus 4); the test logs the names and relies on neither. The disk
# to keep holds a system like Fedora's, a partition and an open LUKS volume,
# mounted read-only, so that any write to it, by disko or anything else,
# changes its hash.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  model = "QEMU NVMe Ctrl";
  serial = "EXAMPLE0SERIAL";
  keepSerial = "KEEP0SERIAL";

  # The shape's own name for the disk, from the model and serial a private
  # flake would set: what the guard has to print.
  shape = inputs.nixpkgs.lib.nixosSystem {
    modules = [
      self.nixosModules.laptop
      ../../templates/default/me.nix
      {
        nixpkgs.hostPlatform = system;
        system.stateVersion = "26.05";
        ravnix.laptop.diskModel = lib.mkForce model;
        ravnix.laptop.diskSerial = lib.mkForce serial;
      }
    ];
  };
  device = shape.config.disko.devices.disk.huginn.device;
  keepDevice = "/dev/disk/by-id/nvme-QEMU_NVMe_Ctrl_${keepSerial}";

  # What `disko --mode destroy,format,mount --argstr device DEV
  # hosts/laptop/disko.nix` runs: the CLI builds this and runs its program.
  disko = import "${inputs.disko}/cli.nix" {
    inherit pkgs device;
    mode = "destroy,format,mount";
    diskoFile = ../../hosts/laptop/disko.nix;
  };

  guard = lib.getExe self.packages.${system}.ravnix-disk-guard;
  qemuImg = "${pkgs.qemu_test}/bin/qemu-img";
in
pkgs.testers.runNixOSTest {
  name = "laptop-disko";
  nodes.machine = {
    virtualisation = {
      memorySize = 2048;
      cores = 2;
      # The two NVMe disks; the test makes their images before the VM starts.
      qemu.options = [
        "-drive if=none,id=keep,format=qcow2,file=$TMPDIR/keep.qcow2"
        "-device nvme,serial=${keepSerial},drive=keep"
        "-drive if=none,id=target,format=qcow2,file=$TMPDIR/target.qcow2"
        "-device nvme,serial=${serial},drive=target"
      ];
    };
    environment.systemPackages = [
      pkgs.cryptsetup
      pkgs.btrfs-progs
      pkgs.gptfdisk
      pkgs.e2fsprogs
    ];
  };

  testScript = ''
    import shlex
    import subprocess

    for name in ["keep", "target"]:
        subprocess.run(["${qemuImg}", "create", "-q", "-f", "qcow2", str(machine.state_dir / f"{name}.qcow2"), "3G"], check=True)

    machine.start()
    machine.wait_for_unit("multi-user.target")
    machine.wait_until_succeeds("test -e ${device} && test -e ${keepDevice}")

    guard = "${guard} --model ${lib.escapeShellArg model}"

    def guard_on(serial, print_device=True):
        flag = " --print-device" if print_device else ""
        status, out = machine.execute(f"{guard} --serial {serial}{flag} 2>/tmp/guard.err")
        return status, out.strip(), machine.succeed("cat /tmp/guard.err").strip()

    # ext4 would zero its inode tables in the background after the first
    # mount, a write the hash would catch.
    no_lazy_init = "-E lazy_itable_init=0,lazy_journal_init=0"

    # The disk's bytes as the disk holds them: O_DIRECT reads past the page
    # cache, which could still hold what a write has since replaced.
    def keep_hash():
        return machine.succeed("set -o pipefail; dd if=${keepDevice} iflag=direct bs=1M status=none | sha256sum")

    with subtest("the disk to keep holds a system like Fedora's, mounted read-only"):
        machine.succeed(
            "sgdisk --clear --new=1:0:+256M --typecode=1:EF00 --new=2:0:0 ${keepDevice}",
            "udevadm settle",
            f"mkfs.ext4 -q {no_lazy_init} -L keepboot ${keepDevice}-part1",
            "printf keep | cryptsetup -q luksFormat --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 ${keepDevice}-part2 -",
            "printf keep | cryptsetup open --key-file - ${keepDevice}-part2 keeproot",
            f"mkfs.ext4 -q {no_lazy_init} -L keeproot /dev/mapper/keeproot",
            "mkdir -p /srv/keep/boot /srv/keep/root",
            "mount /dev/mapper/keeproot /srv/keep/root && echo 'the running system' > /srv/keep/root/marker && umount /srv/keep/root",
            "cryptsetup close keeproot",
            "sync",
        )
        keep_before = keep_hash()
        machine.succeed(
            "printf keep | cryptsetup open --readonly --key-file - ${keepDevice}-part2 keeproot",
            "mount -o ro,noload /dev/mapper/keeproot /srv/keep/root",
            "mount -o ro,noload ${keepDevice}-part1 /srv/keep/boot",
        )

    with subtest("the guard picks the target by model and serial, whatever its kernel name"):
        status, out, err = guard_on("${serial}")
        assert status == 0, f"exit {status}: {err}"
        assert out == "${device}", f"the guard printed {out!r}, the shape names ${device}"
        dev = out
        kernel = machine.succeed(f"readlink -f {shlex.quote(dev)}").strip()
        assert machine.succeed(f"lsblk -dno SERIAL {kernel}").strip() == "${serial}", f"{dev} is {kernel}, which is not the target"
        kname = kernel.removeprefix("/dev/")
        keep_kernel = machine.succeed("readlink -f ${keepDevice}").strip()
        machine.log(f"this boot: the target is {kernel}, the disk to keep {keep_kernel}")
        assert kernel != keep_kernel

    with subtest("the guard refuses the disk to keep, in use, and a serial no disk has"):
        status, out, err = guard_on("${keepSerial}")
        assert status == 2, f"exit {status} for the disk to keep: {err}"
        assert out == "", f"it printed {out!r} for the disk to keep"
        status, out, err = guard_on("NOSUCHSERIAL")
        assert status == 1 and out == "", f"exit {status}, {out!r} for a serial no disk has"

    with subtest("disko writes the layout to the path the guard printed, after asking"):
        out = machine.succeed("echo yes | IN_DISKO_TEST=1 ${disko}/bin/disko-destroy-format-mount 2>&1")
        listed = [line.strip() for line in out.splitlines() if line.strip().startswith("- /dev/")]
        assert listed == [f"- {dev}"], f"disko asked to wipe {listed}, not only {dev}"

    with subtest("the layout: a 1 GiB ESP and LUKS2 with btrfs subvolumes, no swap"):
        parts = machine.succeed(f"lsblk -nrbo NAME,SIZE,FSTYPE,PARTLABEL,TYPE {dev}").split("\n")
        parts = [p.split(" ") for p in parts if p]
        names = [p[0] for p in parts if p[4] == "part"]
        assert names == [f"{kname}p1", f"{kname}p2"], f"partitions {names}"
        esp = next(p for p in parts if p[0] == f"{kname}p1")
        assert esp[1] == str(1024 * 1024 * 1024) and esp[2] == "vfat" and esp[3] == "disk-huginn-ESP", f"the ESP is {esp}"
        luks = next(p for p in parts if p[0] == f"{kname}p2")
        assert luks[2] == "crypto_LUKS" and luks[3] == "disk-huginn-luks", f"the second partition is {luks}"
        machine.succeed("cryptsetup luksDump /dev/disk/by-partlabel/disk-huginn-luks | grep -x 'Version:\\s*2'")
        machine.succeed("test \"$(lsblk -nro TYPE,FSTYPE /dev/mapper/cryptroot)\" = 'crypt btrfs'")
        subvols = sorted(line.split()[-1] for line in machine.succeed("btrfs subvolume list /mnt").splitlines())
        assert subvols == ["@", "@home", "@log", "@nix"], f"subvolumes {subvols}"
        for mnt, sub in [("/mnt", "/@"), ("/mnt/home", "/@home"), ("/mnt/nix", "/@nix"), ("/mnt/var/log", "/@log")]:
            fstype, options = machine.succeed(f"findmnt -no FSTYPE,OPTIONS {mnt}").split()
            options = options.split(",")
            assert fstype == "btrfs", f"{mnt} is {fstype}"
            assert f"subvol={sub}" in options, f"{mnt} is not {sub}: {options}"
            assert any(o == "compress=zstd" or o.startswith("compress=zstd:") for o in options), f"{mnt}: {options}"
        assert machine.succeed("findmnt -no FSTYPE /mnt/boot").strip() == "vfat"
        assert machine.succeed("swapon --show --noheadings").strip() == "", "there is swap"
        assert "swap" not in machine.succeed(f"lsblk -nro FSTYPE {dev}"), "a swap signature on the target"

    with subtest("the guard refuses the target while it is mounted, and after unmounting while LUKS is open"):
        status, out, err = guard_on("${serial}")
        assert status == 2 and out == "", f"exit {status}, {out!r} while mounted: {err}"
        assert "is mounted at /mnt" in err, err
        machine.succeed("umount -R /mnt")
        status, out, err = guard_on("${serial}")
        assert status == 2 and out == "", f"exit {status}, {out!r} with cryptroot open: {err}"
        assert "cryptroot" in err, err
        machine.succeed("cryptsetup close cryptroot")
        status, out, err = guard_on("${serial}")
        assert status == 0 and out == dev, f"exit {status}, {out!r} once closed: {err}"

    with subtest("the passphrase opens the volume"):
        machine.succeed("printf disko | cryptsetup open --test-passphrase --key-file - /dev/disk/by-partlabel/disk-huginn-luks")
        machine.fail("printf wrong | cryptsetup open --test-passphrase --key-file - /dev/disk/by-partlabel/disk-huginn-luks")

    with subtest("the disk to keep is bit for bit as it was"):
        machine.succeed("test \"$(cat /srv/keep/root/marker)\" = 'the running system'")
        machine.succeed("umount /srv/keep/boot /srv/keep/root", "cryptsetup close keeproot", "sync")
        keep_after = keep_hash()
        assert keep_after == keep_before, "the disk to keep changed"
  '';
}
