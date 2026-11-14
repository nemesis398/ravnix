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
# And the interface is in the theme of the system (theme.nix): the build
# appends a block of CSS made from ravnix.theme to Handy's theme.css, sets the
# four radius tokens of App.css to 0, makes the overlay's surface opaque and
# the primary button's text the background color. The CSS is the frontend, so
# it is embedded in the program, and a change of accent rebuilds Handy. With
# the default accent the block is the same text and the build the same
# derivation.
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
  writeText,
  handy,
  # { palette, roles, font } of config.ravnix.theme; the desktop module passes the
  # host's. Null is the theme module's own default (Mocha, the Mauve accent).
  theme ? null,
}:
let
  css = import ./theme.nix {
    inherit lib;
    theme = if theme == null then import ../../lib/default-theme.nix { inherit lib; } else theme;
  };
  themeCss = writeText "handy-theme.css" css.css;
  overlayCss = writeText "handy-overlay-theme.css" css.overlayCss;

  # Run in the unpacked source, by postPatch and by tests/desktop/handy-theme.nix.
  # Every substitution fails when its text is not found, so a newer Handy that
  # moved one stops the build instead of going unthemed. The radius tokens are
  # Tailwind's in App.css's @theme; the button text is the primary variant's.
  themePatch = ''
    cat ${themeCss} >> src/styles/theme.css
    cat ${overlayCss} >> src/overlay/RecordingOverlay.css
    substituteInPlace src/App.css \
      --replace-fail '--radius-panel: 16px;' '--radius-panel: 0;' \
      --replace-fail '--radius-card: 12px;' '--radius-card: 0;' \
      --replace-fail '--radius-control: 10px;' '--radius-control: 0;' \
      --replace-fail '--radius-chip: 6px;' '--radius-chip: 0;'
    substituteInPlace src/components/ui/Button.tsx \
      --replace-fail '"text-white bg-background-ui' '"text-background bg-background-ui'
  '';
in
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

      # Handy in the theme of the system. The frontend's node_modules
      # (passthru.frontendDeps) is fetched from the same source and is not
      # touched by this.
      postPatch = prev.postPatch + themePatch;

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
        inherit themeCss overlayCss themePatch;
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
