# The terminal glue's two commands (../terminal.nix): ravnix-terminal, which
# the main key runs, and ravnix-connection, the main connection. A data file
# of the glue module, which lib/import-dir.nix does not import (there is no
# default.nix here): terminal.nix builds the commands with the real programs,
# and tests/glue/terminal-scripts.nix with stand-ins for them. Each command
# is the Bash beside this file, with every @name@ filled in as a shell word,
# packaged by writeShellApplication, so shellcheck runs over it at build
# time.
#
#   import ./terminal/scripts.nix {
#     inherit lib pkgs;
#     sockets = [ "ravnix-link.sock" ... ];  # forwarded, by name
#     openssh = ...;                         # the ssh herdr runs
#     # for the tests' stand-ins, absolute paths:
#     herdr = ...; ssh = ...; sleep = ...;
#   }
#   => { terminal = <derivation>; connection = <derivation>; }
{
  lib,
  pkgs,
  sockets,
  openssh ? pkgs.openssh,
  alias ? "ravnix-server",
  herdr ? lib.getExe pkgs.herdr,
  ssh ? lib.getExe' openssh "ssh",
  sleep ? lib.getExe' pkgs.coreutils "sleep",
}:
let
  word = value: lib.escapeShellArg (toString value);
  fill =
    values: file:
    lib.replaceStrings (map (n: "@${n}@") (lib.attrNames values)) (lib.attrValues values) (
      builtins.readFile file
    );
in
{
  terminal = pkgs.writeShellApplication {
    name = "ravnix-terminal";
    # herdr --remote runs ssh itself, from PATH.
    runtimeInputs = [ openssh ];
    text = fill {
      herdr = word herdr;
      sleep = word sleep;
      alias = word alias;
    } ./ravnix-terminal.bash;
    meta.mainProgram = "ravnix-terminal";
  };

  connection = pkgs.writeShellApplication {
    name = "ravnix-connection";
    runtimeInputs = [ pkgs.coreutils ];
    text = fill {
      ssh = word ssh;
      sleep = word sleep;
      alias = word alias;
      sockets = lib.escapeShellArgs sockets;
    } ./ravnix-connection.bash;
    meta.mainProgram = "ravnix-connection";
  };
}
