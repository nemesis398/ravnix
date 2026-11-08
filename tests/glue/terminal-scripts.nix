# The terminal glue's two commands (modules/glue/terminal/), ravnix-terminal
# and ravnix-connection, built by their own modules/glue/terminal/scripts.nix
# with stand-ins for herdr, ssh and sleep (helpers/terminal-stand-in.sh), and
# tested in helpers/terminal.test.bash: when each attaches or connects again,
# how long each waits, what each says and how often, what each refuses, and
# what each does without its program. tests/glue/reconnect.nix runs them
# with the real programs, in VMs.
{
  self,
  pkgs,
  lib,
  ...
}:
let
  standIn = pkgs.writeShellScript "terminal-stand-in" (
    builtins.readFile ./helpers/terminal-stand-in.sh
  );
  # One stand-in per program, which tells it what it stands in for.
  as = name: "${pkgs.writeShellScriptBin name ''exec ${standIn} ${name} "$@"''}/bin/${name}";

  build =
    args:
    import ../../modules/glue/terminal/scripts.nix (
      {
        inherit lib pkgs;
        sockets = [
          "ravnix-link.sock"
          "sk-agent.sock"
        ];
        herdr = as "herdr";
        ssh = as "ssh";
        sleep = as "sleep";
      }
      // args
    );
  plain = build { };
in
pkgs.runCommand "glue-terminal-scripts"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
    ];
    TERMINAL = lib.getExe plain.terminal;
    TERMINAL_NOHERDR = lib.getExe (build { herdr = "/no/such/herdr"; }).terminal;
    CONNECTION = lib.getExe plain.connection;
    CONNECTION_NOSSH = lib.getExe (build { ssh = "/no/such/ssh"; }).connection;
    CONNECTION_ODD = lib.getExe
      (build {
        sockets = [
          "odd name.sock"
          "it's.sock"
        ];
      }).connection;
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    bash ${self}/tests/glue/helpers/terminal.test.bash
    touch "$out"
  ''
