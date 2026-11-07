# The modules of the flake carry a key, so that a host and a private flake can
# both import one and get a single copy. Every key has the same shape,
# "ravnix/SET.NAME" (homeModules.theme is "ravnix/homeModules.theme"); a
# different spelling is a module that can be loaded twice beside one that is
# spelled the usual way.
{
  self,
  pkgs,
  lib,
  ...
}:
let
  keyed =
    lib.concatMap (set: lib.mapAttrsToList (name: module: { inherit set name module; }) self.${set})
      [
        "homeModules"
        "nixosModules"
      ];
  # A module that is a path has no key of its own, and is told apart by the
  # path.
  withKey = lib.filter (e: builtins.isAttrs e.module && e.module ? key) keyed;

  failures =
    map (e: "${e.set}.${e.name} has the key ${e.module.key}, not ravnix/${e.set}.${e.name}") (
      lib.filter (e: e.module.key != "ravnix/${e.set}.${e.name}") withKey
    )
    # The ones that matter here must be among the keyed.
    ++ map (n: "homeModules.${n} has no key") (
      lib.filter (n: !(lib.any (e: e.set == "homeModules" && e.name == n) withKey)) [
        "theme"
        "common"
        "claude-code"
        "claude-skills"
      ]
    );
in
pkgs.runCommand "flake-module-keys" { } (
  if failures == [ ] then
    "touch $out"
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
