# with-secret-env (packages/with-secret-env): rbw and the command it runs are
# stand-ins, so no vault is read. New: the helper is the one place that loads
# the secrets of ravnix.shell.secretEnv for a launcher (claude-artifacts,
# claude-bg), and what matters is what it keeps out of reach: a command line,
# a log, a trace, the environment of any process but the command.
{
  self,
  pkgs,
  system,
  ...
}:
pkgs.runCommand "bin-with-secret-env"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gnugrep
      pkgs.gnused
    ];
    WITH_SECRET_ENV_UNDER_TEST = "${self.packages.${system}.with-secret-env}/bin/with-secret-env";
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    bash ${../../packages/with-secret-env/tests/with-secret-env.test.sh}
    touch "$out"
  ''
