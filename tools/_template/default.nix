# The template for a new Odin tool (tools/README.md). It is built and checked
# like every tool, as template-tests and template-bench, so it keeps working
# as the toolchain moves; its directory starts with "_", so it is no package.
{ buildOdinTool, ... }:
buildOdinTool {
  name = "template";
  src = ./.;
  tests = ./tests;
  bench = ./bench;
  # The bench counts the words of bench/input.txt.
  benchArgs = [ "input.txt" ];
}
