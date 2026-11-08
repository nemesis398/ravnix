# ravnix-disk-guard

Picks the one disk an installer may write, and refuses when there is not
exactly one, or when it is in use. The disk is named by its model and its
serial, as the private flake gives them in `ravnix.laptop.diskModel` and
`ravnix.laptop.diskSerial`, and the guard prints its `/dev/disk/by-id`
path, which names it the same way. It never names a disk by a kernel name
such as `nvme0n1`: the kernel numbers NVMe disks in the order they answer,
and that order can change from one boot to the next (AGENTS.md, rule 2).
The guard itself writes nothing, anywhere.

```sh
ravnix-disk-guard --model MODEL --serial SERIAL [--print-device]
                  [--lsblk-json FILE] [--by-id DIR]
```

It runs `lsblk -J -o NAME,MODEL,SERIAL,MOUNTPOINTS,TYPE`, from util-linux's
store path built into the binary and with nothing in its environment but
`LC_ALL=C`, and decides:

1. **One disk.** Exactly one whole disk (type `disk`) has the model and the
   serial, compared exactly, after the white space lsblk may pad them with.
   A partition, a loop device or an optical drive with the same values is
   not a candidate. None, or two disks with both values, refuses.
2. **Not in use.** Nothing on the disk is mounted (swap included), and
   nothing on it is anything but a partition: an open LUKS volume, LVM, RAID
   or any other mapping the kernel holds refuses.
3. **Its link.** In `/dev/disk/by-id`, a link names the serial when the
   serial stands in its name between an underscore and the name's end, an
   underscore or `-part`, as udev writes `nvme-<model>_<serial>`,
   `nvme-<model>_<serial>_<namespace>` and `-partN` after either. Every such
   link must point at the disk, or at one of its partitions for a `-partN`
   link; one that points anywhere else means udev and lsblk disagree, and
   refuses. Of the links that name the whole disk, the first by name is the
   one printed: the one without the namespace when both exist.

| Exit | Means |
| --- | --- |
| 0 | the disk is found and free; its by-id path is printed |
| 1 | no single disk: none or more than one matches, lsblk fails or prints no device list (a missing field, malformed JSON, nothing at all), or the links cannot be read, name no link for the disk, or disagree with lsblk |
| 2 | the disk is in use: something on it is mounted, or a mapping holds it |
| 3 | bad usage: a missing or repeated option, an empty value, a model or serial with surrounding white space or a control character, or a device name as an argument |

Only exit 0 prints anything on standard output. With `--print-device`, that
is the path alone, for `dev=$(...)`, and the verdict, which names the
kernel name of the moment, goes to standard error; without it the verdict
goes to standard output. A refusal names the disks lsblk lists with their
models, and says of each whether its serial is the one asked for, without
printing any other disk's serial.

`--lsblk-json FILE` reads lsblk's output from a file instead of running
lsblk, and `--by-id DIR` reads the links from another directory; the tests
and the bench use both. Neither decides on the live system, so each one
used says so on standard error, one line each and before anything is read,
where whoever passed one by mistake sees it first:

```
ravnix-disk-guard: --lsblk-json: the disks are read from "FILE", not from lsblk on the live system
ravnix-disk-guard: --by-id: the links are read from "DIR", not from /dev/disk/by-id on the live system
```

The name is quoted, so the line stays one line whatever it holds. `--by-id
/dev/disk/by-id`, with or without a trailing slash, reads the live links and
prints no line.

## How the install uses it

Task 3.5 runs disko only on the path the guard printed, and only when it
exited 0, in the same shell:

```sh
dev=$(ravnix-disk-guard --model "$MODEL" --serial "$SERIAL" --print-device) || exit
disko --mode destroy,format,mount --argstr device "$dev" hosts/laptop/disko.nix
```

`hosts/laptop/disko.nix` takes nothing but a `/dev/disk/by-id` path. Task
3.5's QEMU passthrough script is to refuse to start while the guard exits 2,
since the disk is then mounted on the host.

## What protects the disk to keep

The guard is one of four layers:

1. **The guard** names the target by model and serial, refuses it while it
   is in use, and prints no kernel name.
2. **The layout** in `hosts/laptop/disko.nix` takes nothing but one name
   under `/dev/disk/by-id`, in udev's characters, and disko lists the one
   disk it is about to wipe and asks first.
3. **The boot loader** leaves the firmware's boot entries alone:
   `efi.canTouchEfiVariables` stays false, so a switch never rewrites the
   other system's entry.
4. **The running system** hides every other internal disk from udisks:
   `hosts/laptop/hide-other-disks.nix` gives each NVMe or SATA disk whose
   serial is not `ravnix.laptop.diskSerial`, and its partitions,
   `UDISKS_IGNORE=1`, so the desktop neither shows nor automounts it, and a
   file manager cannot format it. A USB disk still mounts. root can still
   mount the hidden disk by hand; nothing stops that but rule 2 of
   AGENTS.md.

## Tests and bench

`ravnix-disk-guard-tests` covers the laptop's layout today, the same with
the kernel names swapped (both lsblk and the links), and lsblk swapped with
links from before the swap; two disks with the model and the serial, two of
one model told apart by the serial, the model of one disk with the serial of
the other, near misses of either value, padding; a mounted partition, an
open LUKS mapping, swap, LVM, RAID, a mapping straight on the disk or two
levels down, a mounted whole disk; `[null]` mountpoints of older lsblk; a
loop device, an optical drive and a partition with the target's values;
lsblk output without the serial field (or any other), empty, `{}`, an empty
list, malformed in two dozen ways, a key twice, a NUL, two values, nesting 200 000
deep, above 4 MiB, 7 000 devices, a 1 MiB model; links with the namespace
only, absolute, near misses of the serial, files and directories that look
like links, in reverse order, a partition link pointing elsewhere, a missing
or unreadable directory, a trailing slash; the command's every exit code and
what it prints where, 17 kinds of bad usage, an lsblk that fails, is killed,
prints nothing, garbage, an empty list or more than 4 MiB, is missing or not
executable, and the columns and environment it gets; the line each test
seam prints, alone, together, in either order, before a refusal, for a name
with a newline, and its absence without a seam, for `--by-id
/dev/disk/by-id` and on bad usage; and eight threads deciding at once.

`tests/laptop/disko.nix` runs the guard and disko in a VM with two QEMU
NVMe disks of one model, and checks that the disk to keep comes out of it
bit for bit unchanged, read with O_DIRECT past the page cache. The same VM
runs the udev rule and udisks: the disk to keep and its partitions carry
`UDISKS_IGNORE=1` and udisks' `HintIgnore`, and the target and its LUKS
partition do not.

`ravnix-disk-guard-bench` decides on `bench/lsblk.json`, a laptop's list with
the two NVMe disks, two USB disks, zram and sixteen loop devices, and the
links in `bench/by-id`: the parse, the decision and the directory read.

## Known gaps

Findings that are not fixed, so nobody mistakes them for covered.

- The guard sees what lsblk sees. A disk that a process has open without a
  mount or a mapping, such as a QEMU VM that boots it through passthrough,
  is not in use to the guard, and exits 0. Do not run disko while the
  passthrough VM runs. Scanning `/proc/*/fd` as root would find such a
  process; the guard does not.
- The decision holds for the moment it is made. Something that mounts the
  disk between the guard's exit and disko's start, such as a desktop's
  automounter, is not seen, and disko's destroy step unmounts it before it
  wipes. Run disko right after the guard, as above.
- A serial that udev rewrites in the link's name (white space or a slash
  becomes `_`) is not found there, and the guard exits 1. That fails
  closed; NVMe serials are letters and digits.
- lsblk runs without a time limit. An lsblk that hangs hangs the guard,
  which has written nothing and can be interrupted.
- The guard reads all of lsblk's output before it refuses one above 4 MiB,
  so a runaway lsblk can fill memory before the refusal. The lsblk is the
  store path the build gives it.
- The bench sorts the link directory, which the file system lists in its
  own order, so the count on another file system can differ by the sort's
  few thousand instructions, well inside the 2 % the gate allows.
