# energy, the laptop's energy menu and its watcher (tools/energy): the built
# program, with its charger file and charge-mode pointed into the sandbox,
# runs against stubs for everything it talks to (the profile daemon on the
# bus, Sway, fuzzel, the bus monitors, keep-awake, Waybar, systemd), so no
# real setting changes; then the package's store paths. This is the Bash
# suite that the Odin port had to pass; tools/energy/tests/*.odin (the check
# energy-tests) hold the rest. The VM test hardware-power sets the tuned
# profiles through the real menu.
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
      pkgs.gnugrep
      pkgs.gnused
    ];
    PACKAGE = self.packages.${system}.energy;
    TEST_LIB = ../../scripts/tests/lib.sh;
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    bash ${../../tools/energy/tests/energy.test.sh}
    touch "$out"
  ''
