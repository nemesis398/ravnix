# fix-display and panel-crtc (packages/fix-display): pgrep, loginctl, swaymsg
# and sudo are stand-ins in front of the script's own tools, and panel-crtc is
# loaded as a module against a fake DRM state, so no GPU, no Sway and no TTY is
# needed. The scripts have no tests in Fedora; these are new.
{
  self,
  pkgs,
  system,
  ...
}:
let
  stubFirst = import ./helpers/stub-first.nix { inherit pkgs; };
  package = self.packages.${system}.fix-display;
in
pkgs.runCommand "bin-fix-display"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gnused
      pkgs.python3
    ];
    FIX_DISPLAY_UNDER_TEST = stubFirst "${package}/bin/fix-display";
    PANEL_CRTC_UNDER_TEST = "${package}/bin/panel-crtc";
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    bash ${../../packages/fix-display/tests/fix-display.test.sh}
    touch "$out"
  ''
