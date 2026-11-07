# Claude Code as ravnix ships it: the package of the claude-code input
# (sadjow/claude-code-nix, which a private flake passes in with `follows`),
# unchanged, with the file it was made from as passthru.download.
#
# claude-code-nix fetches Anthropic's binary and patches it with
# autoPatchelfHook, which rewrites its ELF interpreter, so the program in the
# package is no longer the file Anthropic released and never matches the
# release manifest. The gate verifies the download instead
# (tools/claude-code-verify/README.md). claude-code-nix keeps the download
# in a let of its package.nix; it is found here as the one input of the
# install phase whose derivation is named "claude", and read from that
# derivation. When their package changes so that it finds none or several,
# only .download fails, with the reason; the package itself still builds.
#
# Their wrapper sets DISABLE_AUTOUPDATER=1; tests/claude/home.nix checks
# that on every bump of the input.
{ lib }:
package:
let
  inputs = lib.attrNames (builtins.getContext (package.drvAttrs.installPhase or ""));
  downloads = lib.filter (lib.hasSuffix "-claude.drv") inputs;
  download =
    # Importing a .drv file gives its derivation, with an empty name; the
    # filter above makes it "claude".
    if lib.length downloads == 1 then
      import (lib.head downloads) // { name = "claude"; }
    else
      throw "lib/claude-code.nix: the install phase of ${package.name} uses ${toString (lib.length downloads)} derivations named claude, not one, so the download to verify is unknown; claude-code-nix has changed how it fetches the binary";
in
package.overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    inherit download;
  };
})
