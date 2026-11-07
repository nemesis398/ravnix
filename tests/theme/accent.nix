# The accent is one value per host. A user sets it once in me.nix, which
# reaches NixOS through nixosModules.options, and home-manager inside NixOS
# takes the host's accent as its default, so the NixOS and the home-manager
# half cannot draw in two colors.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  eval = import ../options/helpers/eval.nix { inherit lib self; };

  # A NixOS host with home-manager and the user alice: host modules go to
  # NixOS, user modules to home-manager.
  hostOf =
    {
      host ? [ ],
      user ? [ ],
    }:
    (inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        inputs.home-manager.nixosModules.home-manager
        {
          system.stateVersion = "26.05";
          users.users.alice.isNormalUser = true;
          home-manager = {
            useGlobalPkgs = true;
            users.alice = {
              imports = [ self.homeModules.theme ] ++ user;
              home = {
                username = "alice";
                homeDirectory = "/home/alice";
                stateVersion = "26.05";
              };
            };
          };
        }
      ]
      ++ host;
    }).config;

  homeOf = c: c.home-manager.users.alice;
  failedOf = c: map (a: a.message) (lib.filter (a: !a.assertion) (homeOf c).assertions);

  # Only the NixOS accent is set; the home-manager side says nothing.
  teal = hostOf {
    host = [
      self.nixosModules.theme
      { ravnix.theme.accent = "teal"; }
    ];
  };
  # The same through the options module me.nix goes into.
  viaOptions = hostOf {
    host = [
      self.nixosModules.options
      { ravnix.theme.accent = "sky"; }
    ];
  };
  # A host that never heard of ravnix.theme.
  bare = hostOf { };
  # The two sides set the same value, and different ones.
  agree = hostOf {
    host = [
      self.nixosModules.theme
      { ravnix.theme.accent = "teal"; }
    ];
    user = [ { ravnix.theme.accent = "teal"; } ];
  };
  differ = hostOf {
    host = [
      self.nixosModules.theme
      { ravnix.theme.accent = "teal"; }
    ];
    user = [ { ravnix.theme.accent = "sky"; } ];
  };

  # me.nix on its own, against the options module the template's check uses.
  me = eval [ { ravnix.theme.accent = "teal"; } ];

  failures =
    lib.optional ((homeOf teal).ravnix.theme.roles.accent != "#94e2d5")
      "home-manager in a NixOS host with accent teal draws in ${(homeOf teal).ravnix.theme.roles.accent}"
    ++ lib.optional (
      (homeOf teal).catppuccin.accent != "teal"
    ) "catppuccin/nix in that host has the accent ${(homeOf teal).catppuccin.accent}"
    ++ lib.optional (
      failedOf teal != [ ]
    ) "the single accent fails an assertion: ${toString (failedOf teal)}"
    ++ lib.optional (
      (homeOf viaOptions).ravnix.theme.roles.accent != "#89dceb"
    ) "an accent set through nixosModules.options does not reach home-manager"
    ++ lib.optional (
      (homeOf bare).ravnix.theme.roles.accent != "#cba6f7"
    ) "home-manager in a host without the ravnix options does not default to mauve"
    ++ lib.optional (
      failedOf agree != [ ]
    ) "the same accent on both sides fails: ${toString (failedOf agree)}"
    ++ lib.optional (
      lib.length (failedOf differ) != 1
    ) "two accents in one host do not fail exactly one assertion"
    ++ lib.optional (
      failedOf differ != [ ] && !lib.hasInfix "one accent per host" (lib.head (failedOf differ))
    ) "the divergent accent's message does not say there is one accent per host"
    ++ lib.optional (
      me.config.ravnix.theme.accent != "teal" || me.config.ravnix.theme.roles.accent != "#94e2d5"
    ) "me.nix cannot set the accent through nixosModules.options";
in
pkgs.runCommand "theme-accent" { } (
  if failures == [ ] then
    ''
      touch $out
    ''
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
