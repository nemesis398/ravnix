# A fixture for tests/flake/desktop-imports.nix. A subdirectory without a
# default.nix holds data for a module (modules/desktop/sway/config), and its
# .nix files are not imported.
throw "fixture: a .nix file below a directory without default.nix was imported"
