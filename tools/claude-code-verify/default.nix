# claude-code-verify: proves that a Claude Code binary is the one Anthropic
# released, by its sha256 against the release manifest (README.md). The tool
# fetches the manifest through curl, whose store path is built in, so it
# needs nothing on PATH.
{
  buildOdinTool,
  pkgs,
  lib,
  ...
}:
buildOdinTool {
  name = "claude-code-verify";
  src = ./.;
  tests = ./tests;
  bench = ./bench;
  odinFlags = [ "-define:CURL=${lib.getExe pkgs.curl}" ];
  # The bench verifies bench/binary against bench/manifest.json: the hash and
  # the manifest's parse, without the network.
  benchArgs = [
    "--manifest"
    "manifest.json"
    "binary"
    "1.0.0"
  ];
}
