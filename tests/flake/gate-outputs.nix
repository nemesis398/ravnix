# The gate's flake step builds each check in a nix process of its own and
# checks every other output of the flake with scripts/lib/flake-outputs.nix,
# in one evaluation that touches no check (scripts/check.sh). This test runs
# that file on made-up outputs: ones it must pass, each kind of bad output
# nix flake check refuses, and an output type it does not know, which must
# fail rather than go unchecked.
{ pkgs, lib, ... }:
let
  validate = import ../../scripts/lib/flake-outputs.nix;
  system = "x86_64-linux";
  drv = name: pkgs.runCommand name { } "touch $out";

  good = {
    checks.${system}.never-read = throw "the validator read a check";
    checks.aarch64-linux.other = throw "the validator read a check of another system";
    packages.${system} = {
      a = drv "gate-outputs-a";
      b = drv "gate-outputs-b";
    };
    # Another system's packages are omitted, as nix flake check omits them.
    packages.aarch64-linux.c = throw "the validator read another system's package";
    overlays.default = final: prev: { };
    overlays.underscored = _final: _prev: { };
    overlays.blank = _: _: { };
    nixosModules.set = {
      imports = [ ];
    };
    nixosModules.function = { ... }: { };
    nixosModules.path = ./fixtures/tree;
    homeModules.set = { };
    templates.default = {
      path = ./fixtures/tree;
      description = "a template";
    };
    templates.welcome = {
      path = ./fixtures/tree;
      description = "a template";
      welcomeText = "hello";
    };
  };
  passed = validate system good;

  # Each bad output on its own beside the good ones, and the problem it must
  # be named by.
  bad = {
    "a package that is no derivation" = {
      outputs.packages.${system}.x = 5;
      says = "packages.${system}.x is a number, not a derivation";
    };
    "a package that throws" = {
      outputs.packages.${system}.x = throw "broken";
      says = "packages.${system}.x throws";
    };
    "a package whose derivation throws" = {
      outputs.packages.${system}.x = pkgs.runCommand "x" { y = throw "inner"; } "";
      says = "packages.${system}.x throws";
    };
    "packages that are no attribute set" = {
      outputs.packages = 5;
      says = "packages is a number, not an attribute set";
    };
    "a system's packages that are no attribute set" = {
      outputs.packages.${system} = [ ];
      says = "packages.${system} is a list, not an attribute set";
    };
    "checks that are no attribute set" = {
      outputs.checks.${system} = "x";
      says = "checks.${system} is a string, not an attribute set";
    };
    "an overlay that is no function" = {
      outputs.overlays.x = { };
      says = "overlays.x is an attribute set, not a function";
    };
    "an overlay with a set pattern" = {
      outputs.overlays.x = { ... }: { };
      says = "overlays.x does not take an argument named final";
    };
    "an overlay whose argument is named otherwise" = {
      outputs.overlays.x = self: super: { };
      says = "overlays.x does not take an argument named final";
    };
    "an overlay that throws" = {
      outputs.overlays.x = throw "broken";
      says = "overlays.x throws";
    };
    "a NixOS module that is a number" = {
      outputs.nixosModules.x = 5;
      says = "nixosModules.x is a number, not a module";
    };
    "a NixOS module that is a string" = {
      outputs.nixosModules.x = "./x.nix";
      says = "nixosModules.x is a string, not a module";
    };
    "a module path that does not exist" = {
      outputs.nixosModules.x = ./fixtures/no-such-module.nix;
      says = "nixosModules.x is the path";
    };
    "a home-manager module that throws" = {
      outputs.homeModules.x = throw "broken";
      says = "homeModules.x throws";
    };
    "a template without a description" = {
      outputs.templates.x.path = ./fixtures/tree;
      says = "templates.x lacks the attribute description";
    };
    "a template without a path" = {
      outputs.templates.x.description = "x";
      says = "templates.x lacks the attribute path";
    };
    "a template whose path does not exist" = {
      outputs.templates.x = {
        path = ./fixtures/no-such-template;
        description = "x";
      };
      says = "templates.x.path is the path";
    };
    "a template whose description is no string" = {
      outputs.templates.x = {
        path = ./fixtures/tree;
        description = 5;
      };
      says = "templates.x.description is a number, not a string";
    };
    "a template with an attribute nix flake check refuses" = {
      outputs.templates.x = {
        path = ./fixtures/tree;
        description = "x";
        extra = 1;
      };
      says = "templates.x has the attribute extra";
    };
    "a template that throws" = {
      outputs.templates.x = throw "broken";
      says = "templates.x throws";
    };
    "an output type it does not know" = {
      outputs.apps.${system}.x = { };
      says = "flake output apps is no output the flake step knows";
    };
    "an old name of a known output" = {
      outputs.overlay = final: prev: { };
      says = "flake output overlay is no output the flake step knows";
    };
  };

  judged = lib.mapAttrs (
    _: case:
    let
      result = validate system (good // case.outputs);
    in
    {
      inherit (case) says;
      inherit (result) problems;
      named = lib.any (lib.hasInfix case.says) result.problems;
      # The report a bad output makes is a throw, so the gate's nix eval fails.
      reported = (builtins.tryEval result.report).success;
    }
  ) bad;

  failures =
    lib.optional (passed.problems != [ ])
      "good outputs were refused: ${lib.concatStringsSep "; " passed.problems}"
    ++ lib.optional (!(builtins.tryEval passed.report).success) "the report of good outputs throws"
    ++ lib.concatMap (
      name:
      let
        j = judged.${name};
      in
      lib.optional (!j.named)
        "${name}: expected a problem saying \"${j.says}\", got: ${lib.concatStringsSep "; " j.problems}"
      ++ lib.optional j.reported "${name}: the report did not throw"
    ) (lib.attrNames judged)
    ++
      map (want: "the summary of good outputs lacks \"${want}\": ${passed.summary}")
        (
          lib.filter (want: !(lib.hasInfix want passed.summary)) [
            "packages.${system}: 2 derivations"
            "overlays: 3 overlays"
            "nixosModules: 3 modules"
            "homeModules: 1 module"
            "templates: 2 templates"
            "checks.${system}: 1 check"
            "omitted, not ${system}: checks.aarch64-linux, packages.aarch64-linux"
          ]
        );
in
pkgs.runCommand "flake-gate-outputs" { } (
  if failures == [ ] then
    "touch $out"
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
