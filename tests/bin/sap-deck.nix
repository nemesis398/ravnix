# sap-deck (packages/sap-deck): what it builds from a fixture vault and what
# it refuses. The script has no tests in Fedora; these are new.
{
  self,
  pkgs,
  system,
  ...
}:
pkgs.runCommand "bin-sap-deck"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.python3
    ];
    SAP_DECK_UNDER_TEST = "${self.packages.${system}.sap-deck}/bin/sap-deck";
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    bash ${../../packages/sap-deck/tests/sap-deck.test.sh}
    touch "$out"
  ''
