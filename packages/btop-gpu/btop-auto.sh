#!/bin/sh
# btop-auto — launches `btop-gpu` (both GPUs shown) if the NVIDIA dGPU is
# already awake, otherwise plain `btop` (iGPU only, the battery-safe default).
#
# The dGPU runtime_status is read straight from sysfs via the nvidia driver's
# own device list, never hardcoding a PCI address (bus IDs are found by driver
# binding, the same "don't hardcode, auto-detect" rule waybar's GPU helpers
# follow). Reading runtime_status does NOT wake the card; only nvidia-smi (or
# any NVML query, which is what shown_gpus="amd nvidia" triggers inside btop)
# does. So a game already running via prime-run (dGPU active) gets the dual
# view automatically, and an idle dGPU (suspended) is left alone exactly like
# plain btop already leaves it.
set -u

status_file=
for f in /sys/bus/pci/drivers/nvidia/0000:*/power/runtime_status; do
    # An unmatched glob stays literal, so the first name is only a file if it exists.
    [ -e "$f" ] && status_file=$f
    break
done

if [ -n "$status_file" ] && [ "$(cat "$status_file" 2>/dev/null)" = "active" ]; then
    exec btop-gpu "$@"
fi
exec btop "$@"
