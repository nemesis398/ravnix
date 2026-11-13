# Handy 0.10.0, the offline speech-to-text app, on nixpkgs' recipe for 0.9.8.
#
# huginn takes Handy's settings over from Fedora, which runs 0.10.0: the
# Qwen3-ASR model, the post-processing provider and `--toggle-post-process`
# are 0.10.0's. nixpkgs has 0.9.8, so this is nixpkgs' package with the
# version, the source and the two dependency hashes (cargo's vendor directory
# and the frontend's node_modules) of 0.10.0, and two changes 0.10.0 asks for:
#
#   - ONNX Runtime is gone: 0.10.0's Cargo.lock has no `ort` any more, so its
#     library and the two ORT_* variables are dropped (as Handy's own flake
#     does).
#   - The wrapper no longer sets WEBKIT_DISABLE_DMABUF_RENDERER=1. 0.10.0
#     picks the renderer itself from the WebKitGTK it is linked against
#     (src-tauri/src/webkit_renderer.rs) and skips that choice whenever the
#     variable is set. On WebKitGTK 2.54 (nixpkgs has 2.54.1) it picks
#     WEBKIT_DMABUF_RENDERER_FORCE_SHM=1, because 2.54 repaints only the
#     damaged region and the DMA-BUF-disabled path then draws the recording
#     overlay as a half-transparent ghost. Handy's own flake leaves the
#     variable out for the same reason, and so does Fedora's vendor RPM.
#
# Everything else is nixpkgs' recipe as it is: the wrapper with the updater
# off, the ALSA plugin directory, the Vulkan build of transcribe-cpp, the
# patched tray library, and the tests. A bump changes the version and the
# three hashes, and has to re-check what tests/desktop/handy.nix asserts about
# the source (the flags, the forwarding, SIGUSR2, the worker's process name,
# the PulseAudio client name, the model catalog).
#
# Once nixpkgs has 0.10.0 or later, this override would force 0.10.0 onto a
# newer recipe; evaluation stops then and asks for the directory to go.
{
  lib,
  fetchFromGitHub,
  handy,
}:
lib.throwIf (lib.versionAtLeast handy.version "0.10.0")
  "packages/handy: nixpkgs has Handy ${handy.version} now; drop packages/handy and let handy-launch take nixpkgs' handy again"
  handy.overrideAttrs
  (
    finalAttrs: prev: {
      version = "0.10.0";

      src = fetchFromGitHub {
        owner = "cjpais";
        repo = "Handy";
        tag = "v${finalAttrs.version}";
        hash = "sha256-PnL2le8URBs4I3pv9DKh+JLDII20xtDkJEUJghLToXQ=";
      };

      # buildRustPackage reads the hash and the source from finalAttrs, so the
      # vendor directory follows these two.
      cargoHash = "sha256-1ae7U/uEa11R0RC6nZthqBVsxojQsGduiiFQlIrHUZA=";

      buildInputs = lib.filter (p: lib.getName p != "onnxruntime") prev.buildInputs;

      env = removeAttrs prev.env [
        "ORT_LIB_LOCATION"
        "ORT_PREFER_DYNAMIC_LINK"
      ];
      ortLibLocation = null;

      # nixpkgs' gappsWrapperArgs without WEBKIT_DISABLE_DMABUF_RENDERER (see
      # the header). Evaluation fails when nixpkgs changes the line, so a newer
      # recipe is looked at and not silently kept.
      preFixup =
        let
          line = "--set WEBKIT_DISABLE_DMABUF_RENDERER 1\n";
        in
        lib.throwIfNot (lib.hasInfix line prev.preFixup)
          "packages/handy: nixpkgs' Handy no longer sets WEBKIT_DISABLE_DMABUF_RENDERER as this override expects; look at its preFixup again"
          (builtins.replaceStrings [ line ] [ "" ] prev.preFixup);

      passthru = prev.passthru // {
        # The frontend's node_modules is fetched with a hash of its own; its
        # source and version are finalAttrs' already. nixpkgs keeps one hash per
        # system; this is x86_64-linux's only, the one system ravnix builds
        # (flake.nix), and another system would fail on the hash.
        frontendDeps = prev.passthru.frontendDeps.overrideAttrs {
          outputHash = "sha256-2RCuoJpQeg3JN4JqlKvzO4KMz6n7rNXnsb9IyWt9law=";
        };
      };
    }
  )
