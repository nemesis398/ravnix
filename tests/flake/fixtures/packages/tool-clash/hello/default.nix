# A fixture for tests/flake/packages.nix; never imported by the flake.
{ runCommand }: runCommand "hello" { } "echo hello > $out"
