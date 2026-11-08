# A fixture for tests/flake/packages.nix; never imported by the flake.
{ runCommand }: runCommand "claude-code" { } "echo not claude > $out"
