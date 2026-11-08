# A fixture for tests/flake/packages.nix; never imported by the flake.
# Takes a sibling the way a ravnix package does: from `ravnix`.
{ runCommand, ravnix }:
runCommand "beta" { } "echo beta after $(cat ${ravnix.alpha}) > $out"
