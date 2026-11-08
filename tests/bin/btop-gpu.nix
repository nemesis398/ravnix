# btop-gpu and btop-auto (packages/btop-gpu): btop is a stand-in that copies
# the config it is started with. The scripts have no tests in Fedora; these are
# new.
{
  self,
  pkgs,
  system,
  ...
}:
let
  package = self.packages.${system}.btop-gpu;
in
pkgs.runCommand "bin-btop-gpu"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
    ];
    BTOP_GPU_UNDER_TEST = "${package}/bin/btop-gpu";
    BTOP_AUTO_UNDER_TEST = "${package}/bin/btop-auto";
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    bash ${../../packages/btop-gpu/tests/btop-gpu.test.sh}
    touch "$out"
  ''
