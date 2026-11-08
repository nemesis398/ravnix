# claude-artifacts (packages/claude-artifacts): claude is a stand-in that
# prints how it was started. The script has no tests in Fedora; these are new.
{
  self,
  pkgs,
  system,
  ...
}:
pkgs.runCommand "bin-claude-artifacts"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.gnused
      pkgs.python3
    ];
    CLAUDE_ARTIFACTS_UNDER_TEST = "${self.packages.${system}.claude-artifacts}/bin/claude-artifacts";
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    bash ${../../packages/claude-artifacts/tests/claude-artifacts.test.sh}
    touch "$out"
  ''
