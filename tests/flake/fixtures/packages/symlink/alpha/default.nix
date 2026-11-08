# A fixture for tests/flake/packages.nix; never imported by the flake.
{ runCommand }: runCommand "alpha" { } "echo alpha > $out"
