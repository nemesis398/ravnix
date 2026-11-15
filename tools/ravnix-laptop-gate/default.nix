# ravnix-laptop-gate: the forced command of the server's key on the laptop
# (modules/glue/laptop-access.nix). It reads SSH_ORIGINAL_COMMAND, runs one
# of a fixed list of read-only calls, and refuses every other command with
# exit 77 and one line in the journal (README.md). The one program it runs,
# machine-facts, is put into the binary by its store path, so it needs
# nothing on PATH. A tool's default.nix must not read pkgs.ravnix
# (tools/README.md), so machine-facts is built here from its directory.
#
# machineFacts is the program behind the verb `facts`, for the VM test's
# stand-in; anything else takes the default.
{
  buildOdinTool,
  pkgs,
  lib,
  machineFacts ? lib.getExe (pkgs.callPackage ../../packages/machine-facts { }),
  ...
}:
buildOdinTool {
  name = "ravnix-laptop-gate";
  src = ./.;
  tests = ./tests;
  bench = ./bench;
  odinFlags = [ "-define:MACHINE_FACTS=${machineFacts}" ];
  # The bench answers `battery` from the sysfs of bench/root: an IdeaPad's
  # battery and AC, beside the other supplies a laptop shows.
  benchArgs = [
    "--root"
    "root"
    "--command"
    "battery"
  ];
}
