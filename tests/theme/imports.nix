# The theme modules can be imported more than once into one configuration:
# nixosModules.common hands homeModules.theme to every home-manager user as a
# shared module, and a host or a test may import it again. The module system
# keeps one copy of a module that has a key, so catppuccin/nix is loaded once;
# without a key every import loads its function module again and defines
# catppuccin.sources once more.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  hm = import ./helpers/hm.nix {
    inherit
      self
      inputs
      pkgs
      lib
      ;
  };

  # Whether reading the theme, the catppuccin settings and the generated
  # configs of a configuration fails.
  evaluates =
    c:
    (builtins.tryEval (
      builtins.deepSeq [
        c.ravnix.theme.roles
        c.catppuccin.flavor
        c.catppuccin.accent
        c.programs.ghostty.settings
        c.programs.fuzzel.settings
        c.services.dunst.settings
      ] true
    )).success;

  # The helper imports homeModules.theme already; these add it once and twice
  # more. A copy of catppuccin/nix shows as a definition of catppuccin.sources.
  copies = modules: lib.length (hm modules).options.catppuccin.sources.definitions;
  once = [ ];
  twice = [ self.homeModules.theme ];
  thrice = [
    self.homeModules.theme
    self.homeModules.theme
  ];

  # A NixOS host that gives home-manager the theme as a shared module, as
  # nixosModules.common does, while the user imports it too, and that imports
  # the NixOS theme and the options twice.
  system' = (
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = [
        inputs.home-manager.nixosModules.home-manager
        self.nixosModules.theme
        self.nixosModules.theme
        self.nixosModules.options
        {
          imports = [ self.nixosModules.options ];
          system.stateVersion = "26.05";
          users.users.alice.isNormalUser = true;
          home-manager = {
            useGlobalPkgs = true;
            sharedModules = [ self.homeModules.theme ];
            users.alice = {
              imports = [ self.homeModules.theme ];
              home = {
                username = "alice";
                homeDirectory = "/home/alice";
                stateVersion = "26.05";
              };
            };
          };
          ravnix.theme.accent = "teal";
        }
      ];
    }
  );
  host = system'.config;
  user = host.home-manager.users.alice;
  # The options of the user's configuration, to count the copies in it.
  userOptions = system'.options.home-manager.users.valueMeta.attrs.alice.configuration.options;

  failures =
    lib.optional (!evaluates (hm once).config) "homeModules.theme alone does not evaluate"
    ++ lib.optional (!evaluates (hm twice).config) "homeModules.theme imported twice does not evaluate"
    ++ lib.optional (
      !evaluates (hm thrice).config
    ) "homeModules.theme imported three times does not evaluate"
    ++
      lib.concatMap
        (
          modules:
          lib.optional (
            copies modules != 1
          ) "homeModules.theme loads catppuccin/nix ${toString (copies modules)} times, not once"
        )
        [
          once
          twice
          thrice
        ]
    ++ lib.optional (
      !evaluates user
    ) "homeModules.theme as a shared module and a user import does not evaluate"
    ++
      lib.optional (lib.length userOptions.catppuccin.sources.definitions != 1)
        "a shared module and a user import load catppuccin/nix ${toString (lib.length userOptions.catppuccin.sources.definitions)} times, not once"
    ++ lib.optional (
      user.ravnix.theme.roles.accent != "#94e2d5"
    ) "the shared and the imported theme do not follow the host's accent"
    ++ lib.optional (
      !(builtins.tryEval (builtins.deepSeq host.ravnix.theme.roles true)).success
    ) "nixosModules.theme and nixosModules.options, imported twice, do not evaluate";
in
pkgs.runCommand "theme-imports" { } (
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
