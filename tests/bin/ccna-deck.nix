# ccna-deck (packages/ccna-deck): what it builds from a fixture vault and what
# it refuses. The script has no tests in Fedora; these are new.
{
  self,
  pkgs,
  system,
  ...
}:
pkgs.runCommand "bin-ccna-deck"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.python3
    ];
    CCNA_DECK_UNDER_TEST = "${self.packages.${system}.ccna-deck}/bin/ccna-deck";
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    bash ${../../packages/ccna-deck/tests/ccna-deck.test.sh}
    touch "$out"
  ''
