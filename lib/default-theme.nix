# The theme module evaluated alone: ravnix.theme with the defaults (Mocha, the
# Mauve accent), for a package that takes the host's theme as an argument and
# builds from this one when it gets none. The module sets `assertions`, which
# only NixOS and home-manager declare, so it is declared here.
{ lib }:
(lib.evalModules {
  modules = [
    ../modules/theme/options.nix
    {
      options.assertions = lib.mkOption {
        type = lib.types.listOf lib.types.unspecified;
        default = [ ];
      };
    }
  ];
}).config.ravnix.theme
