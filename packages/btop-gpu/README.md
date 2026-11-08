# btop-gpu and btop-auto

`btop-gpu` runs btop with both GPUs shown, from a copy of its configuration
that it writes to a temporary directory; `btop-auto` chooses between that
and plain `btop` by the power state of the discrete GPU, so the monitor does
not wake a card that sleeps. POSIX `sh`, carried over from Fedora's
`bin-btop-gpu` (AGENTS.md, rule 4).

Installed on the laptop by `modules/desktop/scripts.nix`. `btop` is the
user's profile's (`programs.btop`) and is looked up on the `PATH`, so it is the
btop with the user's configuration.

## Personal values

None.

## Changes from the original

- `btop-gpu` names `/run/opengl-driver/lib` in `LD_LIBRARY_PATH` for the btop
  it starts: btop loads NVML (`libnvidia-ml.so.1`) at run time, and on NixOS
  the driver's libraries are there and in no loader cache;
- `btop-auto` finds the NVIDIA runtime status file with a glob loop where
  the original used `ls ... | head` (shellcheck SC2012);
- a comment that named a memory note is gone.

## Left out

Nothing.

## Tests

`tests/btop-gpu.test.sh`, the check `bin-btop-gpu`: `btop` is a stand-in that
prints its configuration and environment. Covers the generated
configuration, the cleanup of the temporary directory, the choice by power
state with and without the file, and the library path.

## Findings not fixed

- The NVML path is unverified on hardware: the build sandbox has no NVIDIA
  card. If `btop-gpu` shows no NVIDIA panel on the laptop, check that
  `/run/opengl-driver/lib/libnvidia-ml.so.1` exists (`hardware.graphics`
  with the NVIDIA driver).
