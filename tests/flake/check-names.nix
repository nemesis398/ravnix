# The gate's flake step lists the checks by name before it builds each in a
# nix process of its own (scripts/check.sh), and the listing must stay
# cheap: it must evaluate no check, or it holds them all in one evaluator
# again, as nix flake check did. This test evaluates the flake's outputs a
# second time with a nixpkgs whose package set throws, and Claude Code's
# input likewise, which every check needs, and lists the checks: the names
# must come out, and be the flake's own.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  flake = import (self + "/flake.nix");
  poisoned = name: throw "listing the checks evaluated ${name}";
  outputs = flake.outputs (
    inputs
    // {
      inherit self;
      nixpkgs = inputs.nixpkgs // {
        legacyPackages = poisoned "nixpkgs.legacyPackages";
      };
      claude-code = inputs.claude-code // {
        packages = poisoned "claude-code.packages";
      };
    }
  );
  listed = builtins.tryEval (builtins.attrNames outputs.checks.${system});
  own = builtins.attrNames self.checks.${system};

  failures =
    if !listed.success then
      [ "listing the checks evaluated the package set, so it evaluates checks" ]
    else
      lib.optional (listed.value != own)
        "the names listed without the package set differ from the flake's: ${toString listed.value}"
      ++ lib.optional (!(lib.elem "flake-check-names" listed.value)) "this check is not among the names listed";
in
pkgs.runCommand "flake-check-names" { } (
  if failures == [ ] then
    "touch $out"
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
