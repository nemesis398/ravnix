# ravnix-tap-ask: asks on the laptop's own screen, in a fuzzel popup, before
# sudo waits for a tap on the security key (README.md). pam_exec runs it as
# root; it runs fuzzel as the user through setpriv, and the build puts both
# store paths into the binary, so it needs nothing on PATH.
{
  buildOdinTool,
  pkgs,
  lib,
  ...
}:
buildOdinTool {
  name = "ravnix-tap-ask";
  src = ./.;
  tests = ./tests;
  bench = ./bench;
  odinFlags = [
    "-define:FUZZEL=${lib.getExe pkgs.fuzzel}"
    "-define:SETPRIV=${lib.getExe' pkgs.util-linux "setpriv"}"
  ];
  # The bench decides on the system in bench/root, without the popup: a user
  # with a mapping and a key, a few hundred processes to look through for a
  # lock screen and an ssh login, and no Wayland socket.
  benchArgs = [
    "--dry-run"
    "--root"
    "root"
    "--parent"
    "4242"
    "--user"
    "alice"
  ];
}
