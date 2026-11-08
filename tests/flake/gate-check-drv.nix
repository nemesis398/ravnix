# The gate's flake step evaluates each check's derivation with
# scripts/lib/check-drv.nix and builds that derivation (scripts/check.sh).
# nix flake check refuses a check that is no derivation, while nix build
# would take a path or a string with store context and pass a check that
# tests nothing. This test runs the guard on a derivation, which it must
# let through, and on the values nix build would accept or that are no
# check at all, which it must refuse.
{ pkgs, lib, ... }:
let
  guard = import ../../scripts/lib/check-drv.nix;
  drv = pkgs.runCommand "gate-check-drv" { } "touch $out";
  file = pkgs.writeText "gate-check-drv-file" "x";

  accepted = builtins.tryEval (guard drv);
  refused = {
    "a path" = ./fixtures/tree;
    "a string with store context" = "${file}";
    "a store path's string of a derivation" = "${drv}";
    "a plain string" = "hello";
    "an attribute set" = {
      x = 1;
    };
    "an attribute set that looks like a derivation" = {
      drvPath = drv.drvPath;
    };
    "a function" = x: x;
    "a value that throws" = throw "broken";
  };
  passed = lib.filterAttrs (_: value: (builtins.tryEval (guard value)).success) refused;

  failures =
    lib.optional (!accepted.success) "the guard refused a derivation"
    ++ lib.optional (
      accepted.success && accepted.value != drv.drvPath
    ) "the guard gave ${toString accepted.value}, not the derivation's drvPath"
    ++ map (name: "the guard let ${name} through as a check") (lib.attrNames passed);
in
pkgs.runCommand "flake-gate-check-drv" { } (
  if failures == [ ] then
    "touch $out"
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
