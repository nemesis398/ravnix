# searx, carried over from Fedora's bin-searx with its tests: a fake SearXNG
# on the loopback interface answers the real script (the package, with only
# the tools its package gives it), so what goes over the wire and how the
# answer is cut down are checked without the network. The tests are in
# packages/searx/tests; the URL is no longer built in, and the cases for the
# skill value that takes its place are new.
{
  self,
  pkgs,
  system,
  ...
}:
pkgs.runCommand "bin-searx"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.curl
      pkgs.gnugrep
      pkgs.jq
      pkgs.python3
    ];
    SEARX_UNDER_TEST = "${self.packages.${system}.searx}/bin/searx";
  }
  ''
    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"
    bash ${../../packages/searx/tests/searx.test.sh}
    touch "$out"
  ''
