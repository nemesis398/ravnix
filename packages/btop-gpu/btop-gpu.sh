#!/bin/sh
# btop-gpu — btop showing BOTH GPUs: the AMD 780M iGPU and the NVIDIA RTX 4050 dGPU.
#
# The default `btop` deliberately runs shown_gpus="amd" so it never wakes the
# runtime-suspended dGPU — polling it via NVML holds the card 'active' = battery
# drain (the same reason waybar doesn't poll it). This on-demand wrapper is for
# when you actually want to inspect the dedicated GPU. It:
#   * derives a THROWAWAY config from the live ~/.config/btop/btop.conf, so it
#     inherits your current theme/layout and can never drift out of sync;
#   * overrides only shown_gpus to add nvidia;
#   * forces save_config_on_exit=false, so this throwaway can never clobber your
#     real btop settings on exit.
# The dGPU wakes while this is open and re-suspends after you quit.
# Verified safe on btop 1.4.7 — no NVML hang on the suspended card (the old
# hang was an earlier btop).
set -eu

src="${XDG_CONFIG_HOME:-$HOME/.config}/btop/btop.conf"
tmp="$(mktemp "${TMPDIR:-/tmp}/btop-gpu.XXXXXX.conf")"
trap 'rm -f "$tmp"' EXIT INT TERM HUP QUIT

if [ -r "$src" ]; then
    cp -- "$src" "$tmp"
else
    : > "$tmp"
fi

# Override just these keys in the throwaway copy (never touch $src): show both
# GPU vendors, and never save-clobber. Replace in place if present, else append.
for kv in 'shown_gpus = "amd nvidia"' 'save_config_on_exit = false'; do
    key=${kv%% *}
    if grep -q "^$key *=" "$tmp"; then
        sed -i "s|^$key *=.*|$kv|" "$tmp"
    else
        printf '%s\n' "$kv" >> "$tmp"
    fi
done

# Add dedicated, NAMED GPU boxes (the compact CPU-box view only labels them
# "GPU0/GPU1" — a dedicated box shows the card name + graph, e.g. the RTX 4050).
# Append gpu0+gpu1 to whatever box layout the live config has, so it never drifts.
if grep -q '^shown_boxes *=' "$tmp"; then
    grep -q '^shown_boxes *=.*gpu0' "$tmp" || \
        sed -i 's/^\(shown_boxes *= *".*\)"[[:space:]]*$/\1 gpu0 gpu1"/' "$tmp"
else
    printf '%s\n' 'shown_boxes = "cpu mem net proc gpu0 gpu1"' >> "$tmp"
fi

# btop loads NVML (libnvidia-ml.so.1) at run time. On NixOS the driver's libraries
# are in /run/opengl-driver/lib, which no loader cache lists, so name it.
LD_LIBRARY_PATH="/run/opengl-driver/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" btop -c "$tmp" "$@"
