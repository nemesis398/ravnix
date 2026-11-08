# ghostty-float (packages/ghostty-float) starts ghostty with the Wayland class
# that the compositor's rule floats, passes every further argument on whole, and
# returns ghostty's exit status. The stand-in ghostty prints what it was given.
{ pkgs, ... }:
let
  fakeGhostty = pkgs.writeShellScriptBin "ghostty" ''
    for a in "$@"; do printf '[%s]' "$a"; done
    echo
    exit "''${GHOSTTY_EXIT:-0}"
  '';
  float = pkgs.callPackage ../../packages/ghostty-float { ghostty = fakeGhostty; };
in
pkgs.runCommand "desktop-ghostty-float" { } ''
  failed=0
  fail() { printf 'FAIL: %s\n' "$*"; failed=1; }
  run() { ${float}/bin/ghostty-float "$@"; }

  [ "$(run)" = "[--class=com.mitchellh.ghostty.float]" ] || fail "no arguments: $(run)"
  [ "$(run -e yazi)" = "[--class=com.mitchellh.ghostty.float][-e][yazi]" ] || fail "-e yazi: $(run -e yazi)"
  # The class comes first, so an argument cannot take its place, and what
  # follows keeps its words: spaces, empty arguments, a leading dash, `--`.
  [ "$(run -e "bluetui --x" "" -- -z)" = "[--class=com.mitchellh.ghostty.float][-e][bluetui --x][][--][-z]" ] \
    || fail "arguments are mangled: $(run -e "bluetui --x" "" -- -z)"
  GHOSTTY_EXIT=3 ${float}/bin/ghostty-float && fail "the exit status of ghostty is lost" || [ $? = 3 ] || fail "the exit status is changed"
  # The valid-GTK-id rule: dotted, lowercase, no hyphen.
  grep -q -- '--class=com[.]mitchellh[.]ghostty[.]float' ${float}/bin/ghostty-float || fail "the class is not the one the compositor rule names"

  [ "$failed" = 0 ] && touch $out || exit 1
''
