# The wrapper of the Chrome DevTools MCP server (packages/chrome-devtools-mcp-
# helium), in the sandbox: its shell tests (packages/chrome-devtools-mcp-
# helium/tests/wrapper.test.sh) against stand-ins for the server and the
# browser, and then the real package: the wrapper that is built with the real
# server and the real Helium names exactly those store paths, runs no npx,
# starts the real server (which answers --version), and leaves no profile
# behind.
{
  self,
  pkgs,
  lib,
  system,
  ...
}:
let
  dir = ../../packages/chrome-devtools-mcp-helium;

  # The stand-ins: a server that logs what it was given (tests/stub-server.sh)
  # and a browser that is only an executable file.
  stubServer = pkgs.writeShellScriptBin "chrome-devtools-mcp" (builtins.readFile (dir + "/tests/stub-server.sh"));
  stubBrowser = pkgs.writeShellScriptBin "helium" "exit 0";
  stubbed = pkgs.callPackage dir {
    ravnix = {
      chrome-devtools-mcp = stubServer;
      helium = stubBrowser;
    };
  };

  real = self.packages.${system}.chrome-devtools-mcp-helium;
  server = self.packages.${system}.chrome-devtools-mcp;
  helium = self.packages.${system}.helium;

  src = lib.fileset.toSource {
    root = ../..;
    fileset = lib.fileset.unions [
      ../../scripts/tests/lib.sh
      (dir + "/tests")
    ];
  };
in
pkgs.runCommand "common-chrome-devtools-mcp-helium"
  {
    nativeBuildInputs = [ pkgs.jq ];
    inherit src;
  }
  ''
    cp -r "$src" src
    chmod -R u+w src
    # The sandbox has no /usr/bin/env.
    patchShebangs src >/dev/null
    export HOME="$TMPDIR"

    echo "==> the shell tests, against stand-ins"
    UNDER_TEST=${lib.getExe stubbed} DEFAULT_BROWSER=${lib.getExe stubBrowser} \
      bash src/packages/chrome-devtools-mcp-helium/tests/wrapper.test.sh

    echo "==> the real wrapper"
    failed=0
    fail() { printf 'FAIL: %s\n' "$*"; failed=1; }
    wrapper=${lib.getExe real}

    grep -qF -- '${lib.getExe server}' "$wrapper" || fail "the wrapper does not run the server of the package"
    grep -qF -- '${lib.getExe helium}' "$wrapper" || fail "the wrapper does not default to the Helium of the package"
    # (The header says what it does not do, so only the code is read.)
    if grep -v '^[[:space:]]*#' "$wrapper" | grep -q 'npx'; then fail "the wrapper runs npx"; fi
    for flag in --headless --no-usage-statistics --no-performance-crux --executablePath --userDataDir; do
      grep -qF -- "$flag" "$wrapper" || fail "the wrapper does not pass $flag"
    done

    # The real server starts from the wrapper (--version answers before it
    # looks for a browser), with a stand-in browser, and the profile is gone.
    mkdir -p run tmp
    printf '#!/bin/sh\nexit 0\n' > browser
    chmod +x browser
    got=$(env -i PATH=/nonexistent TMPDIR="$PWD/tmp" XDG_RUNTIME_DIR="$PWD/run" \
      CHROME_DEVTOOLS_HELIUM="$PWD/browser" "$wrapper" --version 2>&1) || fail "the real server did not start: $got"
    case $got in
      *${server.version}*) ;;
      *) fail "the real server does not answer with ${server.version}: $got" ;;
    esac
    [ -z "$(ls -A tmp)" ] || fail "the real server's run left a profile: $(ls tmp)"

    [ "$failed" = 0 ] && touch $out || exit 1
  ''
