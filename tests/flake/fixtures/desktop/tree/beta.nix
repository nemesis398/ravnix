# A fixture for tests/flake/desktop-imports.nix: a module that declares an
# option and sets it, so the test sees whether it was imported.
{ lib, ... }:
{
  options.fixture.beta = lib.mkOption { type = lib.types.str; };
  config.fixture.beta = "beta.nix";
}
