# handy

Handy 0.10.0, the offline speech-to-text app
([cjpais/Handy](https://github.com/cjpais/Handy)), built from source on
nixpkgs' recipe. nixpkgs has 0.9.8 (checked at the revision `flake.lock`
pins). The laptop shape takes Handy's settings over from an existing 0.10.0
install (`~/.local/share/com.pais.handy/`), and those settings name what only
0.10.0 has: the Qwen3-ASR model and the post-processing provider fields. The
hold-to-talk key also relies on `handy --toggle-post-process`.

Nothing installs this package by itself: `handy-launch` runs it
(`ravnix.handy`), and `modules/desktop/apps.nix` installs `handy-launch`.

## The autostart is ravnix's, and Handy's own toggle stays off

ravnix starts Handy at login through `handy-launch`'s entry,
`/etc/xdg/autostart/handy.desktop`. Handy has an autostart switch of its own
(`autostart_enabled` in `settings_store.json`, off by default), and with it on,
every start of Handy writes `~/.config/autostart/Handy.desktop` through
tauri-plugin-autostart, with `Exec=` set to the running program, which on NixOS
is `bin/.handy-wrapped` in the store. That entry skips the wrapper (no updater
switch, no ALSA plugin directory, no GIO and GStreamer paths) and
`handy-launch` (no iGPU pin, no wtype on PATH), so the NVIDIA card wakes. Its
name differs from ravnix's, so both run at login and race: when the pinned one
loses, it forwards to the unpinned one, which then shows its window. So keep
Handy's own switch off, also in settings carried over from another install;
turning it off makes Handy delete its own entry at the next start.

## What the override changes

- The version, the source and the hashes of the cargo vendor directory and of
  the frontend's `node_modules` (`passthru.frontendDeps`).
- ONNX Runtime is dropped: 0.10.0 no longer depends on `ort`.
- The wrapper no longer sets `WEBKIT_DISABLE_DMABUF_RENDERER=1`. Handy 0.10.0
  chooses the WebKit renderer itself from the WebKitGTK version
  (`src-tauri/src/webkit_renderer.rs`), and any value set in the environment
  turns that choice off. On WebKitGTK 2.54 the old setting draws the recording
  overlay as a half-transparent ghost, so Handy picks
  `WEBKIT_DMABUF_RENDERER_FORCE_SHM=1` there. Evaluation fails if nixpkgs'
  recipe stops setting the variable the way the override expects.

## What it costs

No binary cache has this Handy, so the first build, and the check
`desktop-handy` that tests against it, compile it from source: about half an
hour at cores 4. The full gate (pre-push) pays that again after every nixpkgs
bump that changes one of its inputs.

## A bump

Change `version` and the three hashes (set one to `lib.fakeHash`, build
`.#packages.x86_64-linux.handy.frontendDeps` or `.cargoDeps`, and take the hash
from the mismatch). Then build `desktop-handy`: it reads in the source what
`handy-ptt` relies on (`--toggle-post-process` forwarded to the running
instance, SIGUSR2 as the plain toggle, the transcription worker's process name
`Handy-worker`, the PulseAudio client name `cpal-pulseaudio-PID` and the
model catalog) and runs `handy --help` for the flags. A failure there means
the driver has to be looked at again, not the test.

## Findings that are not fixed

- 0.10.0 runs its transcription in a child process, which it names
  `Handy-worker`. `handy-ptt` asks `pgrep -x` for `.handy-wrapped` or `handy`,
  so the worker never matches (the check runs a decoy). A later Handy that
  renames it to `handy` would make `pgrep -o` pick whichever is older.
- Dropping `WEBKIT_DISABLE_DMABUF_RENDERER` keeps WebKit's compositor running
  on the GPU that `handy-launch` pins (Mesa through
  `__EGL_VENDOR_LIBRARY_FILENAMES`). Only huginn shows that the NVIDIA card
  stays suspended with it (Task 3.7 measures it, `packages/handy-launch`).
- The build runs Handy's cargo tests, as nixpkgs' recipe does, with the same
  two skipped.
