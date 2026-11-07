# The convention every test in this repository relies on: each
# tests/<area>/<name>.nix becomes the check <area>-<name>
# (lib/discover-checks.nix). This test runs the discovery on the fixture trees
# in ./fixtures, which, being in a subdirectory of an area, are no checks
# themselves.
{ pkgs, lib, ... }:
let
  discover = import ../../lib/discover-checks.nix { inherit lib; };
  fixtures = ./fixtures;
  tree = discover (fixtures + "/tree");
  collision = builtins.tryEval (builtins.attrNames (discover (fixtures + "/collision")));
  stray = builtins.tryEval (builtins.attrNames (discover (fixtures + "/stray")));
  missing = discover (fixtures + "/no-such-directory");

  failures =
    lib.optional (builtins.attrNames tree != [ "alpha-one" "beta-two-words" ])
      "expected the checks alpha-one and beta-two-words (no .md, nothing in a subdirectory of an area), found: ${toString (builtins.attrNames tree)}"
    ++ lib.optional (
      tree ? alpha-one && tree.alpha-one != fixtures + "/tree/alpha/one.nix"
    ) "alpha-one does not point at alpha/one.nix"
    ++ lib.optional collision.success "a-b/c.nix and a/b-c.nix both give a-b-c, and the discovery did not refuse it"
    ++ lib.optional stray.success "x.nix directly in the tests directory would never run, and the discovery did not refuse it"
    ++ lib.optional (missing != { }) "a missing tests directory gave checks";
in
pkgs.runCommand "flake-discover-checks" { } (
  if failures == [ ] then
    "touch $out"
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
