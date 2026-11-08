# claude-bg, carried over from Fedora's bin-claude-bg with its tests: claude
# and rbw are stubs that log their calls, and a fake /proc holds the
# supervisors, so no real session is touched. The secrets file of the Fedora
# script is the secret table of ravnix.shell.secretEnv now, read with rbw get,
# and the cases for that are new.
{
  self,
  pkgs,
  system,
  ...
}:
pkgs.runCommand "bin-claude-bg"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
    ];
    CLAUDE_BG_UNDER_TEST = "${self.packages.${system}.claude-bg}/bin/claude-bg";
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    bash ${../../packages/claude-bg/tests/claude-bg.test.sh}
    touch "$out"
  ''
