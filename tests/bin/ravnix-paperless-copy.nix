# ravnix-paperless-copy (packages/ravnix-paperless-copy), the nightly copy of
# each owner's Paperless documents into the Archiv folders: its shell test
# (packages/ravnix-paperless-copy/tests), on scripts/tests/lib.sh, against a
# copy whose PATH starts with the test's stand-ins for curl and sleep
# (helpers/stub-first.nix). rsync, find, cp and date are the real ones, and
# every tree the test builds is under the test's scratch directory.
{
  self,
  pkgs,
  system,
  ...
}:
let
  package = self.packages.${system}.ravnix-paperless-copy;
  underTest = import ./helpers/stub-first.nix { inherit pkgs; } "${package}/bin/ravnix-paperless-copy";
in
pkgs.runCommand "bin-ravnix-paperless-copy"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.findutils
      pkgs.gnugrep
      pkgs.gnused
      # The test's own tools beyond the script's: mkfifo, diff, timeout, stat.
      pkgs.diffutils
    ];
    COPY_UNDER_TEST = underTest;
    TEST_LIB = ../../scripts/tests/lib.sh;
    # So that TZ=Europe/Berlin is a zone and not a silent UTC.
    TZDIR = "${pkgs.tzdata}/share/zoneinfo";
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    bash ${../../packages/ravnix-paperless-copy/tests/copy.test.sh}
    touch "$out"
  ''
