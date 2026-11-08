#!/bin/bash
#
# machine-facts: print the volatile state of this laptop as a Markdown block.
#
# WHY THIS EXISTS
#   A skill used to state facts like "the system lives on nvme1n1" and
#   "the NVIDIA driver is 595.80" as prose. Prose cannot notice that the kernel
#   renumbered the NVMe devices, that another OS was replaced by Windows, or
#   that an update bumped the driver. By 2026-07-25 every one of those had
#   drifted, and the disk line had drifted into a foot-gun: it named the live
#   root disk as the one that was safe to wipe.
#
#   So: anything a command can answer is not written down. It is DERIVED, here,
#   on demand. The Obsidian note keeps the things a command cannot answer
#   (decisions, scar tissue, open items) and carries this block as a generated,
#   timestamped snapshot between HTML-comment markers.
#
#   Everything here is READ-ONLY against the system. The only file this can
#   write is the note, and only between its markers.
#
# Usage:
#   machine-facts              # print the Markdown block to stdout
#   machine-facts --write      # refresh the block inside the Obsidian note
#   machine-facts --check      # exit 1 if the note's block is stale (drift detector)
#   machine-facts --diff       # show what --write would change
#
# Env:
#   MACHINE_NOTE   the note --write, --check and --diff work on. There is no
#                  default: ravnix sets it from ravnix.scripts.machineFacts.note.
#
# `sudo -n` is used opportunistically for efibootmgr/blkid. Without it those
# rows degrade to "(needs sudo)" rather than failing; the script never prompts.
#
set -uo pipefail   # deliberately NOT -e: report per-section and keep going

NOTE="${MACHINE_NOTE:-}"
BEGIN='<!-- machine-facts:begin -->'
END='<!-- machine-facts:end -->'
# Readings that change minute to minute (battery %, dGPU power state, disk usage).
# They belong in the snapshot but must NEVER trigger --check, or the drift
# detector cries wolf every few minutes and stops being believed.
VBEGIN='<!-- volatile:begin -->'
VEND='<!-- volatile:end -->'

have()  { command -v "$1" >/dev/null 2>&1; }
s()     { sudo -n "$@" 2>/dev/null; }          # opportunistic sudo, never prompts
# efibootmgr reads /sys/firmware/efi/efivars, which is world-readable here, so
# try it UNPRIVILEGED first and only then fall back to sudo. Measured 2026-08-23:
# the sudo-only path silently degraded the boot entries to a "(needs sudo)"
# placeholder in the note on every run from a shell with no sudo timestamp,
# which is every agent shell and every `!` command. That is data loss, not a
# missing nice-to-have: the real Windows/Limine/Linux entries were overwritten.
efi()   { efibootmgr 2>/dev/null || s efibootmgr; }
warn()  { printf '> [!warning] %s\n> %s\n\n' "$1" "$2"; }

# ── disk identity, derived, never hardcoded ────────────────────────────────
# Walk / -> LUKS mapper -> partition -> whole disk, so the answer is true today
# rather than true on the day someone wrote it down.
root_disk() {
    # --nofsroot is load-bearing: without it findmnt appends the btrfs subvolume
    # ("/dev/mapper/luks-…[/root]"), which is not a block device, so lsblk fails
    # and the whole THIS-INSTALL marker silently never fires.
    # -l (list) is load-bearing too: the default tree output prefixes the last
    # line with box-drawing characters ("└─nvme0n1") that `tr -d ' '` does not
    # strip, so the comparison below never matches.
    local src; src=$(findmnt -no SOURCE --nofsroot / 2>/dev/null)
    lsblk -nslo NAME "$src" 2>/dev/null | tail -1 | tr -d ' '
}

by_id() {   # stable name for a whole disk; prefer the model_serial form
    local dev=$1 p
    for p in /dev/disk/by-id/nvme-*; do
        [[ "$p" == *_* ]] || continue          # skip nvme-eui.*
        [[ "$(readlink -f "$p")" == "/dev/$dev" ]] && { basename "$p"; return; }
    done
    echo "(no by-id)"
}

disk_role() {   # what is actually ON a disk, read off its filesystems, not remembered
    local dev=$1 fs
    fs=$(lsblk -nlo FSTYPE "/dev/$dev" 2>/dev/null | grep -v '^$' | sort -u | paste -sd, | sed 's/,/, /g')
    case "$fs" in
        *ntfs*)                        echo "Windows (${fs})" ;;
        *crypto_LUKS*|*btrfs*|*ext4*)  echo "Linux (${fs})"   ;;
        "")                            echo "empty / unpartitioned" ;;
        *)                             echo "$fs" ;;
    esac
}

# PCI addresses by vendor id, so nothing is hardcoded. Output is lspci's short
# form (01:00.0). Read from sysfs attributes, NEVER lspci: lspci reads config
# space, and that resumes a runtime-suspended dGPU. Measured 2026-09-17: one
# `lspci -nn` held the RTX 4050 awake for 1.5 s, and this script ran it right
# before reading the power state, so "Right now" said `active` on every run.
gpu_addr() {
    local d
    for d in /sys/bus/pci/devices/*; do
        [[ -e "$d/vendor" ]] || continue   # no PCI bus (a VM): the glob stays literal
        [[ $(<"$d/vendor") == "0x$1" && $(<"$d/class") == 0x030[02]* ]] || continue
        d=${d##*/}; echo "${d#0000:}"; return
    done
}

# ── sections ────────────────────────────────────────────────────────────────
sec_identity() {
    echo "### Identity"
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| Host | \`$(hostnamectl --static 2>/dev/null)\` |"
    # shellcheck source=/dev/null # /etc/os-release is the system's own file, not a part of this script
    echo "| OS | $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-?}") |"
    echo "| Kernel | \`$(uname -r)\` |"
    echo "| Model | $(cat /sys/class/dmi/id/product_version 2>/dev/null) (type $(cat /sys/class/dmi/id/product_name 2>/dev/null)) |"
    echo "| Firmware | $(cat /sys/class/dmi/id/bios_version 2>/dev/null) ($(cat /sys/class/dmi/id/bios_date 2>/dev/null)) |"
    echo "| CPU | $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ *//') |"
    echo "| RAM | $(free -g | awk '/^Mem:/{print $2" GiB visible"}') |"
    echo "| machine-id | \`$(cut -c1-8 /etc/machine-id)…\` |"
    echo
}

sec_disks() {
    local rd; rd=$(root_disk)
    echo "### Disks: **derived from the running system, not remembered**"
    echo
    echo "| Device | Stable name (\`/dev/disk/by-id/\`) | Model | Holds |"
    echo "|---|---|---|---|"
    local d
    for d in $(lsblk -dno NAME -e 7,11 2>/dev/null | grep -E '^nvme|^sd'); do
        local role; role=$(disk_role "$d")
        [[ "$d" == "$rd" ]] && role="**THIS INSTALL** (/ , /home, /boot)"
        # shellcheck disable=SC2016 # the backticks are Markdown, not command substitution
        printf '| `%s` | `%s` | %s | %s |\n' \
            "$d" "$(by_id "$d")" "$(lsblk -dno MODEL "/dev/$d" 2>/dev/null | sed 's/ *$//')" "$role"
    done
    echo
    echo "Root filesystem: \`$(findmnt -no FSTYPE /)\` on \`$(findmnt -no SOURCE / | sed 's/\[.*//')\`"
    echo
    warn "Address disks by their \`by-id\` name in anything destructive." \
         "The node names are a per-boot coin flip on this machine: the installed disk comes up as \`nvme0\` on one boot and \`nvme1\` on the next. The table above is true for THIS boot only. A doc that hardcodes \`nvmeXn1\` is a foot-gun."
}

sec_boot() {
    echo "### Boot chain"
    echo
    local esp esptype
    esp=$(findmnt -no SOURCE /boot 2>/dev/null)
    esptype=$(lsblk -nro PARTTYPE "$esp" 2>/dev/null | head -1)
    echo "- ESP: \`$esp\` → \`/boot\`"
    if [[ "$esptype" != "c12a7328-f81f-11d2-ba4b-00a0c93ec93b" ]]; then
        echo
        warn "The ESP has the WRONG GPT type GUID." \
"\`$esp\` is typed \`${esptype:-?}\`, and only its *label* says EFI System. \`bootctl\` cannot find an ESP. It boots today because the NVRAM entry names the PARTUUID directly; firmware auto-discovery would fail. Metadata-only fix: \`sgdisk -t <N>:ef00 /dev/disk/by-id/…\`."
    fi
    if efi >/dev/null; then
        echo "\`\`\`"
        efi | grep -E '^(BootCurrent|BootOrder)'
        # only OS loaders, and cut the trailing device-path/hex noise
        # shellcheck disable=SC1003 # '\EFI\' is a literal backslash path, not an escaped quote
        efi | grep -E '^Boot[0-9A-F]{4}\*' | grep -F '\EFI\' \
          | sed -E 's/HD\([^)]*\)//; s/(\.efi).*/\1/I' | head -6
        echo "\`\`\`"
    else
        echo "- UEFI entries: (needs sudo: run \`sudo -n true\` first)"
    fi
    echo
}

sec_gpu() {
    echo "### GPU (hybrid: Sway renders on the iGPU, dGPU is offload-only)"
    echo
    local ondisk loaded igpu dgpu
    ondisk=$(modinfo -F version nvidia 2>/dev/null)
    loaded=$(grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' /proc/driver/nvidia/version 2>/dev/null | head -1)
    igpu=$(gpu_addr 1002); dgpu=$(gpu_addr 10de)
    echo "| | |"
    echo "|---|---|"
    echo "| iGPU (renders Sway) | \`${igpu:-none}\` · \`/dev/dri/by-path/pci-0000:${igpu}-card\` → \`$(basename "$(readlink -f "/dev/dri/by-path/pci-0000:${igpu}-card" 2>/dev/null)")\` |"
    echo "| dGPU (offload only) | \`${dgpu:-none}\`, via \`prime-run\`; its power state is a live reading, see below |"
    echo "| nvidia driver (packages) | \`${ondisk:-none}\` |"
    echo "| nvidia driver (loaded) | \`${loaded:-none}\` |"
    echo
    if [[ -n "$ondisk" && -n "$loaded" && "$ondisk" != "$loaded"* && "$loaded" != "$ondisk"* ]]; then
        warn "Driver mismatch, a reboot is pending." \
"Packages are \`$ondisk\`, the loaded module is \`$loaded\`. Until you reboot, \`nvidia-smi\` fails with *Failed to initialize NVML: Driver/library version mismatch*. That is expected, not a broken install."
    fi
    echo "Load-bearing env of the running Sway (without it = black screen at boot):"
    echo "\`\`\`"
    local pid
    pid=$(pgrep -u "$(id -u)" -x sway | head -1)
    if [[ -n "$pid" ]]; then
        tr '\0' '\n' <"/proc/$pid/environ" 2>/dev/null | grep -E '^WLR_DRM_DEVICES=' || echo "(WLR_DRM_DEVICES missing!)"
    else
        echo "(sway is not running)"
    fi
    echo "\`\`\`"
    echo
}

sec_display() {
    echo "### Display"
    echo
    local sock s
    for s in /run/user/"$(id -u)"/sway-ipc.*.sock; do
        [[ -S "$s" ]] && { sock=$s; break; }
    done
    if [[ -n "${sock:-}" ]] && have swaymsg && have jq; then
        SWAYSOCK="$sock" swaymsg -t get_outputs 2>/dev/null \
          | jq -r '.[] | "- **\(.name)** \(.make) \(.model), \(.current_mode.width)x\(.current_mode.height)@\(.current_mode.refresh/1000|floor)Hz scale \(.scale) (active: \(.active))"'
    else
        echo "- (no sway IPC socket in this shell; \`export SWAYSOCK=\$(ls /run/user/$(id -u)/sway-ipc.*.sock)\`)"
    fi
    echo
    echo "kanshi profiles: $(grep -cE '^profile' "$HOME/.config/kanshi/config" 2>/dev/null) defined in \`~/.config/kanshi/config\`"
    echo
}

sec_power_net() {
    echo "### Power, network, radios"
    echo
    echo "| | |"
    echo "|---|---|"
    echo "| conservation_mode | \`$(cat /sys/bus/platform/devices/VPC2004:00/conservation_mode 2>/dev/null || echo n/a)\` (0 = charge to 100%) |"
    # The driver behind platform_profile is read, not assumed: until
    # 2026-10-03 this line claimed amd-pmf, but amd-pmf binds no device here
    # and the profile comes from ideapad-laptop (DYTC).
    echo "| platform_profile | \`$(cat /sys/firmware/acpi/platform_profile 2>/dev/null)\` of [$(cat /sys/firmware/acpi/platform_profile_choices 2>/dev/null)] · driver \`$(cat /sys/class/platform-profile/*/name 2>/dev/null | paste -sd, -)\` |"
    echo "| Wi-Fi | \`$(nmcli -t -f DEVICE,TYPE con show --active 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1}')\` · profile \`$(nmcli -t -f NAME,TYPE con show --active 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1}')\` |"
    echo "| DNS | \`$(resolvectl dns 2>/dev/null | awk 'NF>2{print $NF}' | grep -v '^$' | paste -sd' ')\` (must stay the split-horizon resolver) |"
    echo "| Bluetooth | $(rfkill list bluetooth 2>/dev/null | awk '/Soft blocked/{print ($3=="yes")?"soft-blocked":"unblocked"; exit}') |"
    echo "| Swap | $(swapon --show=NAME,SIZE --noheadings 2>/dev/null | tr -s ' ' | paste -sd, | sed 's/,/, /g') · hibernate $(grep -q 'resume=' /proc/cmdline && echo configured || echo 'NOT configured') |"
    echo
}

sec_software() {
    echo "### Software state"
    echo
    echo "- Sway config validates: \`sway -C\` exit $(WLR_BACKENDS=headless sway -C >/dev/null 2>&1; echo $?). **Judge by this exit code, not by stderr**; the headless renderer prints harmless EGL/Vulkan errors."
    echo
}

sec_now() {   # live readings: informative, but excluded from --check by design
    echo "$VBEGIN"
    echo "### Right now"
    echo
    echo "*Live readings. These change constantly and are deliberately ignored by \`machine-facts --check\`.*"
    echo
    echo "- Battery: $(cat /sys/class/power_supply/BAT0/capacity 2>/dev/null)% $(cat /sys/class/power_supply/BAT0/status 2>/dev/null)"
    echo "- dGPU power state: \`$DGPU_STATE\`. \`suspended\` when idle is the correct, battery-saving state"
    echo "- Root filesystem: $(df -h --output=used,size,pcent / | tail -1 | awk '{print $1" of "$2" ("$3" used)"}')"
    echo "- Uptime:$(uptime -p 2>/dev/null | sed 's/^up//')"
    echo
    echo "$VEND"
}

block() {
    echo "$BEGIN"
    echo "<!-- Generated by \`machine-facts --write\`. Do not hand-edit inside these markers;"
    echo "     everything here is re-derived from the running system. Put durable notes OUTSIDE. -->"
    echo
    echo "$VBEGIN"
    echo "*Snapshot taken $(date '+%Y-%m-%d %H:%M %Z'). Refresh with \`machine-facts --write\`.*"
    echo "$VEND"
    echo
    sec_identity; sec_disks; sec_boot; sec_gpu; sec_display; sec_power_net; sec_software; sec_now
    echo "$END"
}

# Drop every volatile region, so --check compares only structural facts.
structural_only() {
    awk -v vb="$VBEGIN" -v ve="$VEND" '
        $0 == vb { skip=1; next }
        $0 == ve { skip=0; next }
        !skip    { print }' "$1"
}

# ── note surgery: replace only between the markers ──────────────────────────
render_note() {   # $1 = new block file -> stdout = whole note with block swapped
    awk -v begin="$BEGIN" -v end="$END" -v blockfile="$1" '
        $0 == begin { inblock=1; while ((getline line < blockfile) > 0) print line; next }
        $0 == end   { inblock=0; next }
        !inblock    { print }
    ' "$NOTE"
}

main() {
    local mode="${1:-print}"
    # The dGPU power state is read before any section runs, because a probe that
    # wakes the card makes a later read report only the script's own wake-up.
    # `sway -C` left it asleep on 2026-09-17, but that run was mid driver update,
    # with the NVIDIA libraries refusing the old module, so it proves nothing.
    DGPU_STATE=$(cat "/sys/bus/pci/devices/0000:$(gpu_addr 10de)/power/runtime_status" 2>/dev/null || echo '?')
    case "$mode" in
    print|--print) block ;;
    --write|--check|--diff)
        [[ -n "$NOTE" ]] || { echo "no note: set MACHINE_NOTE, or ravnix.scripts.machineFacts.note" >&2; exit 2; }
        [[ -f "$NOTE" ]] || { echo "note not found: $NOTE" >&2; exit 2; }
        # shellcheck disable=SC2015 # the failure branch is meant for either grep failing
        grep -qF "$BEGIN" "$NOTE" && grep -qF "$END" "$NOTE" || {
            echo "markers not found in $NOTE, refusing to touch it." >&2
            echo "Add these two lines where the block should go:" >&2
            echo "  $BEGIN" >&2; echo "  $END" >&2; exit 2; }
        # NOT local: the EXIT trap runs after main() returns, so locals would be
        # out of scope and `set -u` would fire on the cleanup itself.
        tmp=$(mktemp); new=$(mktemp)
        trap 'rm -f "$tmp" "$new"' EXIT
        block > "$tmp"; render_note "$tmp" > "$new"
        case "$mode" in
        --write) cp "$new" "$NOTE"; echo "updated: $NOTE" ;;
        --diff)  diff -u "$NOTE" "$new" || true ;;
        --check) if diff -q <(structural_only "$NOTE") <(structural_only "$new") >/dev/null
                 then echo "note is current"; else
                     echo "DRIFT: the note no longer matches the machine. Run: machine-facts --write" >&2
                     diff -u <(structural_only "$NOTE") <(structural_only "$new") | head -40 >&2
                     exit 1; fi ;;
        esac ;;
    -h|--help) sed -n '/^# machine-facts: print/,/^set -uo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' ;;
    *) echo "unknown option: $mode (try --help)" >&2; exit 2 ;;
    esac
}

main "$@"
