# Evaluates ravnix's options module with the given modules, the way a host
# does, without the rest of NixOS: nixpkgs' generic assertions module stands
# in for the NixOS one. Being in a subdirectory of an area, this file is no
# check itself (lib/discover-checks.nix).
#
#   eval = import ./helpers/eval.nix { inherit lib self; };
#   (eval [ module ... ]).failed   the messages of the failed assertions
#   (eval [ module ... ]).ok       the config, or the throw NixOS would raise
{ lib, self }:
modules:
let
  evaluated = lib.evalModules {
    modules = [
      lib.genericModules.assertions
      self.nixosModules.options
    ]
    ++ modules;
  };
  failed = map (a: a.message) (lib.filter (a: !a.assertion) evaluated.config.assertions);
in
{
  inherit (evaluated) config options;
  inherit failed;
  # What a host build does with failed assertions: refuse, naming each one.
  ok =
    if failed == [ ] then
      evaluated.config
    else
      throw "Failed assertions:\n${lib.concatMapStrings (m: "- ${m}\n") failed}";
  # Whether every value evaluates: each type check runs when a value is read.
  values = builtins.tryEval (builtins.deepSeq evaluated.config.ravnix true);
}
