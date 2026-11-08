# A fixture for tests/flake/desktop-imports.nix. It stands for the real
# modules/desktop/default.nix, which is the importing module and never imports
# itself: if the discovery returned it, evaluating the fixture would fail.
throw "fixture: default.nix imported itself"
