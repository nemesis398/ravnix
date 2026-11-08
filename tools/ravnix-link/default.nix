# ravnix-link: forwards open, notify, Obsidian's move, rename and delete, and
# orders vault commits, from the server to the laptop, through a queue on
# the server's disk while the laptop is away (README.md). The programs it
# runs come from its options; modules/glue/link.nix gives their store paths.
{ buildOdinTool, ... }:
buildOdinTool {
  name = "ravnix-link";
  src = ./.;
  tests = ./tests;
  bench = ./bench;
  # The bench reads bench/queue (400 requests of every kind, with umlauts,
  # escapes and two lines that are not requests) and bench/acked (an outcome
  # for every third), and lists what waits: the reading, the parsing and the
  # checks of a queue, without a socket or a program to run.
  benchArgs = [
    "--state"
    "."
    "status"
  ];
}
