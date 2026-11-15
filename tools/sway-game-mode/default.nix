# sway-game-mode: holds Sway in mode "game" while a game window has focus
# (README.md). It speaks Sway's IPC protocol itself, over the socket in
# $SWAYSOCK, and needs nothing at run time but glibc.
{ buildOdinTool, ... }:
buildOdinTool {
  name = "sway-game-mode";
  src = ./.;
  tests = ./tests;
  bench = ./bench;
  # The bench is the run that finds no Sway: `--leave` on a socket that is
  # not there says so and exits 0. A run with a Sway needs a compositor,
  # which the bench has not; the unit tests run the whole conversation
  # against a stand-in server, and tests/desktop/sway-game-mode.nix against
  # a real headless Sway.
  benchArgs = [
    "--leave"
    "--socket"
    "no-sway-here"
  ];
}
