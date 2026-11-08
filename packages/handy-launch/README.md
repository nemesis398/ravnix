# handy-launch

Handy (nixpkgs has it, 0.9.8) started on the integrated GPU only, with its menu
entry and autostart entry. `modules/desktop/apps.nix` installs it.

The pinning is two variables, `__EGL_VENDOR_LIBRARY_FILENAMES` (Mesa's) and
`VK_DRIVER_FILES` (RADV's), taken from the host's graphics driver
(`/run/opengl-driver`). It names no GPU, so nothing depends on the numbering of
`card0` and `card1`. It is the pinning of Fedora's `handy-launch`, which exists
because WebKit's process otherwise opens `/dev/nvidia*` and keeps the RTX 4050
awake (measured on Fedora 2026-11-04).

`tests/desktop/handy.nix` runs the launcher against a stand-in Handy. The
dictation keys' driver is `handy-ptt` (its README says how it finds the wrapped
Handy).

## Findings that are not fixed

- Only the integration with the real Handy on huginn proves the dGPU stays
  `suspended` while Handy runs (Task 3.7 measures it): the check sees the
  environment the launcher builds, not the card.
- The pin assumes the host's driver set has Mesa's `radeon_icd.x86_64.json`
  (the 780M is an AMD GPU). On a laptop without one, Vulkan finds no driver and
  Handy falls back to the CPU.
- If WebKit's DMABuf renderer still opens the NVIDIA render node on huginn
  despite the two variables, the by-path fix is
  `WEBKIT_WEB_RENDER_DEVICE_FILE=/dev/dri/by-path/pci-BUS-render`, named by the
  PCI address of the 780M and never by `renderD128` or `card1`. Not needed as
  far as known; Task 3.7 measures it.
- The autostart entry (`/etc/xdg/autostart/handy.desktop`) runs only if the
  Sway session starts `xdg-desktop-autostart.target` (Task 3.2a), and the tray
  has to be ready by then, as on Fedora.
