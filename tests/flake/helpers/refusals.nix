# The shell commands that evaluate Nix expressions which must throw, and check
# what each one says. builtins.tryEval tells a throw from a value but cannot
# read the message, and a test that only sees "it failed" passes for the wrong
# reason as easily as for the right one; nix-instantiate prints the message.
# Being in a subdirectory of an area, this file is no check itself
# (lib/discover-checks.nix).
#
#   refusals { inherit lib; } [ { name; expression; messages = [ "text" ]; } ]
#
# is a script for a derivation whose nativeBuildInputs hold pkgs.nix and
# pkgs.gnugrep. It exits 1 after naming every expression that evaluated, and
# every message that lacks one of its texts.
{ lib }:
cases: ''
  export HOME=$TMPDIR NIX_STATE_DIR=$TMPDIR/state NIX_LOG_DIR=$TMPDIR/log
  status=0
  refuse() {
    local name=$1 expression=$2
    shift 2
    if nix-instantiate --eval --strict --store dummy:// --expr "$expression" >out.txt 2>err.txt; then
      echo "$name: it evaluated, and should have been refused: $(cat out.txt)" >&2
      status=1
      return
    fi
    echo "$name (refused, as it should be):"
    cat err.txt
    local text
    for text in "$@"; do
      grep -qF -- "$text" err.txt || {
        echo "$name: the message lacks: $text" >&2
        status=1
      }
    done
  }
  ${lib.concatMapStrings (case: ''
    refuse ${lib.escapeShellArg case.name} ${lib.escapeShellArg case.expression} ${lib.escapeShellArgs case.messages}
  '') cases}
  [ "$status" = 0 ]
''
