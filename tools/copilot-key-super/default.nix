# copilot-key-super: the IdeaPad Pro 5 16AHP9's Copilot key as a plain
# second Super (README.md). modules/hardware/ideapad-pro-5-16ahp9/keys.nix
# runs it as a service.
{ buildOdinTool, ... }:
buildOdinTool {
  name = "copilot-key-super";
  src = ./.;
  tests = ./tests;
  bench = ./bench;
  # The bench translates a recorded stream of typing with Copilot presses.
  benchArgs = [ "--filter" ];
  benchStdin = "typing.events";
}
