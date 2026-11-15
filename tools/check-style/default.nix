# check-style: the style check (README.md), ported from scripts/check-style.sh.
# The shared Mermaid theme the check compares init blocks against is the one
# of this flake, docs/mermaid-theme.json, named at build time; the variable
# RAVNIX_MERMAID_THEME replaces it.
{ buildOdinTool, lib, ... }:
buildOdinTool {
  name = "check-style";
  src = ./.;
  tests = ./tests;
  bench = ./bench;
  odinFlags = [
    "-define:MERMAID_THEME=${../../docs/mermaid-theme.json}"
    # Only the tests read it: the repository's own style document.
    "-define:STYLE_DOC=${../../docs/style.md}"
  ];
  # The bench judges a tree of small files, one in each kind.
  benchArgs = [ "tree" ];
  meta = {
    description = "The style check: what docs/style.md forbids and a program can see";
    license = lib.licenses.agpl3Plus;
  };
}
