# The convention every Odin tool relies on: each tools/<dir>/default.nix is
# the tool <dir>, with the package <dir> and the checks <dir>-tests and
# <dir>-bench, and a directory whose name starts with "_" gets its checks but
# no package (lib/discover-tools.nix). This test runs the discovery on the
# fixture trees in ./fixtures/discover with a stand-in for buildOdinTool, so
# it tests the finding and naming alone, without building anything.
{ pkgs, lib, ... }:
let
  discover = import ../../lib/discover-tools.nix { inherit lib; };
  fixtures = ./fixtures/discover;
  args = {
    buildOdinTool =
      { name, ... }:
      {
        inherit name;
        package = "package-${name}";
        checks = {
          "${name}-tests" = "tests-${name}";
          "${name}-bench" = "bench-${name}";
        };
      };
  };
  run = tree: discover (fixtures + "/${tree}") args;
  # Whether evaluating the value fails, deeply enough to reach every check.
  refused = value: !(builtins.tryEval (builtins.deepSeq value value)).success;

  tree = run "tree";
  missing = run "no-such-directory";

  failures =
    lib.optional (builtins.attrNames tree.packages != [ "alpha" ])
      "expected the one package alpha (_hidden is no package, README.md no tool), found: ${toString (builtins.attrNames tree.packages)}"
    ++ lib.optional (
      builtins.attrNames tree.checks != [
        "alpha-bench"
        "alpha-tests"
        "hidden-bench"
        "hidden-tests"
      ]
    ) "expected the checks alpha-bench, alpha-tests, hidden-bench and hidden-tests, found: ${toString (builtins.attrNames tree.checks)}"
    ++ lib.optional (
      tree.checks ? alpha-tests && tree.checks.alpha-tests != "tests-alpha"
    ) "alpha-tests is not the check that alpha's buildOdinTool returned"
    ++ lib.optional (
      tree.packages ? alpha && tree.packages.alpha != "package-alpha"
    ) "the package alpha is not the one that alpha's buildOdinTool returned"
    ++ lib.optional (!refused (run "missing-file")) "a tool directory without default.nix was not refused"
    ++ lib.optional (!refused (run "clash")) "x and _x both give the tool x, and the discovery did not refuse it"
    ++ lib.optional (!refused (run "stray")) "y.nix directly in the tools directory is no tool, and the discovery did not refuse it"
    ++ lib.optional (!refused (run "symlink"))
      "the symlink beta to the tool alpha is no tool, and the discovery did not refuse it"
    ++ lib.optional (!refused (run "misnamed"))
      "tools/foo/default.nix names its tool bar, and the discovery did not refuse it"
    ++ lib.optional (!refused (run "not-a-tool"))
      "tools/foo/default.nix returns no buildOdinTool result, and the discovery did not refuse it"
    ++ lib.optional (missing != {
      packages = { };
      checks = { };
    }) "a missing tools directory gave packages or checks";
in
pkgs.runCommand "odin-discover-tools" { } (
  if failures == [ ] then
    "touch $out"
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
