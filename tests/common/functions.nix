# The shell functions ported from the Fedora .bashrc (modules/common/bash/),
# run against stand-ins for the tools they call: git is real, and rbw, odin,
# sudo, xdg-open, bat and chafa log what they are given. The scenarios are in
# helpers/functions.test.bash.
{
  self,
  pkgs,
  ...
}:
pkgs.runCommand "common-functions"
  {
    nativeBuildInputs = [
      pkgs.git
      pkgs.jq
      pkgs.file
      pkgs.util-linux
      pkgs.coreutils
      pkgs.gawk
    ];
  }
  ''
    export HOME="$TMPDIR"
    bash ${self}/tests/common/helpers/functions.test.bash ${self}/modules/common/bash
    touch $out
  ''
