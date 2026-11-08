# The activation steps of Claude Code and what they share, as one tree in
# the Nix store: the steps (sync-hooks.sh, sync-mcp.sh) and cas.sh, which they
# source from beside them, and nothing else of this directory (not the
# tests). Both modules that run a step, claude-code.nix and claude-mcp.nix,
# take it from here, so a file added to the set is added once.
{ lib }:
lib.fileset.toSource {
  root = ./.;
  fileset = lib.fileset.unions [
    ./cas.sh
    ./sync-hooks.sh
    ./sync-mcp.sh
  ];
}
