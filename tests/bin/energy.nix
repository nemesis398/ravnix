# energy, the laptop's energy menu and its watcher (packages/energy): a copy
# of the script whose charger file and charge-mode point into the sandbox
# runs against stubs for everything it talks to (the profile daemon on the
# bus, Sway, fuzzel, the bus monitors, keep-awake, Waybar, systemd), so no
# real setting changes; then the package's command and its PATH. The VM test
# hardware-power sets the tuned profiles through the real menu.
{
  self,
  pkgs,
  system,
  ...
}:
pkgs.runCommand "bin-energy"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.diffutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.gnused
      pkgs.jq
    ];
    SOURCE = ../../packages/energy/energy.sh;
    PACKAGE = self.packages.${system}.energy;
    TEST_LIB = ../../scripts/tests/lib.sh;
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    bash ${../../packages/energy/tests/energy.test.sh}
    touch "$out"
  ''
