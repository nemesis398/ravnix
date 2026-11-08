# ravnix-notify: posts a message to the Matrix room of a topic (README.md).
# It sends the request with curl, whose store path the build puts into the
# binary, so it needs nothing on PATH; Odin's core has no TLS, and a
# homeserver is reached over https. The tests run the real curl against a
# homeserver on a loopback port, which is why the same define reaches them.
{
  buildOdinTool,
  pkgs,
  lib,
  ...
}:
buildOdinTool {
  name = "ravnix-notify";
  src = ./.;
  tests = ./tests;
  bench = ./bench;
  odinFlags = [ "-define:CURL=${lib.getExe pkgs.curl}" ];
  # The bench renders a message of every kind of Markdown that bench/message.md
  # holds into the request that would be sent, and sends nothing: it needs
  # neither rbw, nor curl, nor a network.
  benchArgs = [
    "--config"
    "config.json"
    "--dry-run"
    "--topic"
    "builds"
    "-"
  ];
  benchStdin = "message.md";
}
