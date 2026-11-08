# A copy of a writeShellApplication script whose one PATH line starts with
# $STUB_PATH, so that a test can put a stand-in for a tool of the script's own
# package (date, ffmpeg, pactl) before it. writeShellApplication puts the
# package's tools in front of the PATH the script is started with, so a stub on
# that PATH would never be reached. Nothing else of the script differs, and the
# build fails if the line is not found. Being in a subdirectory of an area,
# this file is no check itself (lib/discover-checks.nix).
#
#   stubFirst = import ./helpers/stub-first.nix { inherit pkgs; };
#   ... SCRIPT = stubFirst "${package}/bin/NAME";   # run with STUB_PATH set
{ pkgs }:
script:
pkgs.runCommand "script-under-test"
  {
    nativeBuildInputs = [
      pkgs.gnugrep
      pkgs.gnused
    ];
  }
  ''
    sed 's|^export PATH="|export PATH="$STUB_PATH:|' ${script} > "$out"
    grep -qF 'export PATH="$STUB_PATH:' "$out"
    chmod +x "$out"
  ''
