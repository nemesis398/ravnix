# machine-facts (packages/machine-facts): what it does with a vault note, in a
# sandbox that is no laptop. The script has no tests in Fedora; these are new.
{
  self,
  pkgs,
  system,
  ...
}:
pkgs.runCommand "bin-machine-facts"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
    ];
    MACHINE_FACTS_UNDER_TEST = "${self.packages.${system}.machine-facts}/bin/machine-facts";
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    bash ${../../packages/machine-facts/tests/machine-facts.test.sh}
    touch "$out"
  ''
