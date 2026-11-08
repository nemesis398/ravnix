# machine-facts

Prints the volatile state of a laptop (identity, disks, boot chain, GPUs,
network, what is running right now) as a Markdown block, and keeps that block
of a vault note true: `--write` replaces the text between two marker lines,
`--check` and `--diff` compare it. Bash, carried over from Fedora's
`bin-machine-facts` (AGENTS.md, rule 4).

Installed on the laptop by `modules/desktop/scripts.nix`. The tools of the
session (`sway`, `swaymsg`, `nmcli`, `resolvectl`, `hostnamectl`, `sudo`) are
looked up on the `PATH`; the rest is in the package.

## Personal values

| Value | How it is read |
| --- | --- |
| the note | `MACHINE_NOTE`, which the module sets from `ravnix.scripts.machineFacts.note` (an absolute path). Fedora's default was a note of the user's vault. |

With no note, `--write`, `--check` and `--diff` say what to set and exit 2;
the plain run prints the block and needs none.

## Changes from the original

NixOS replaces what Fedora asked of its own system:

- the ESP is `/boot` (`/boot/efi` on Fedora);
- the iGPU's stable name is `/dev/dri/by-path/pci-0000:ADDR-card`, where
  Fedora had a udev symlink `/dev/dri/igpu`;
- the load-bearing environment is read from the running Sway
  (`WLR_DRM_DEVICES` in `/proc/PID/environ`), where Fedora read
  `/etc/sway/environment`;
- the Sway config check uses Sway's default config path;
- the "THIS-FEDORA-INSTALL" marker is "THIS INSTALL";
- the node-name remark no longer quotes a count of recorded boots.

Beyond that, shellcheck made these changes: `ls | head` became a glob loop
for the Sway socket (SC2012); `efi()` takes no arguments, which it never
used (SC2119, SC2120); `# shellcheck source=/dev/null` on the read of
`/etc/os-release` (SC1091), `disable=SC2016` where backticks are Markdown,
`disable=SC1003` on the literal `'\EFI\'` and `disable=SC2015` on the one
`A && B || C` whose failure branch is meant for either side. `--help` prints
the header up to `set -uo pipefail` instead of fixed line numbers, and the
PCI loop skips a glob that did not match (a VM has no PCI bus), which
printed errors before.

## Left out

The rows that exist only on Fedora: the RPM versions of `power-profiles-daemon`
and `tuned`, the Flatpak list and the count of stow packages. No NixOS
equivalent was invented in their place.

## Tests

`tests/machine-facts.test.sh`, the check `bin-machine-facts`. The sandbox is no
laptop, so the cases do not assert what the facts are but what the script does
with a note: it works only between the markers and leaves the rest byte for
byte, treats the live readings as no drift, refuses a note without markers
or with only one, and degrades to an empty value where a source cannot be read.

## Findings not fixed

- The `modinfo` row (the driver version) is unverified on NixOS: the sandbox
  has no loaded modules to ask about. If it is empty on the laptop, the
  kernel's module path is not on the `modinfo` the package brings (`kmod`).
- `efibootmgr` may need root; without `sudo -n` the UEFI row says so instead of
  printing.
