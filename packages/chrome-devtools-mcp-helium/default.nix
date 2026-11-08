# The Chrome DevTools MCP server driving a headless Helium whose built-in
# uBlock Origin is switched off, carried over from the Fedora setup (its
# commit c76dfe0, stow/bin-chrome-devtools-mcp-helium) as a
# writeShellApplication. The script is chrome-devtools-mcp-helium.sh, whose
# header holds the root cause that makes the wrapper necessary; README.md says
# what changed from the original, and tests/ has the shell tests, which
# tests/common/chrome-devtools-mcp-helium.nix runs.
#
# The server is the package chrome-devtools-mcp and the browser is Helium
# (packages/helium), both from ravnix, so the wrapper runs neither npx nor a
# browser the host happens to have. Both are arguments of the script as store
# paths. The Claude Code module (modules/common/chrome-devtools-mcp.nix)
# declares the wrapper as the MCP server `chrome-devtools`.
{
  lib,
  writeShellApplication,
  replaceVars,
  coreutils,
  # The packages of ravnix: chrome-devtools-mcp and helium are two.
  ravnix,
}:
writeShellApplication {
  name = "chrome-devtools-mcp-helium";
  # The wrapper brings the tools it uses (mktemp, rm, mkdir), and finds nothing
  # else on the caller's PATH.
  runtimeInputs = [ coreutils ];
  text = builtins.readFile (
    replaceVars ./chrome-devtools-mcp-helium.sh {
      server = lib.getExe ravnix.chrome-devtools-mcp;
      browser = lib.getExe ravnix.helium;
    }
  );
  meta = {
    description = "The Chrome DevTools MCP server on a headless Helium, with a fresh profile per launch";
    license = lib.licenses.agpl3Plus;
    platforms = [ "x86_64-linux" ];
    mainProgram = "chrome-devtools-mcp-helium";
  };
}
