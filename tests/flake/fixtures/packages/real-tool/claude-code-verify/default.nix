# A fixture for tests/flake/packages.nix: a package named like the tool
# tools/claude-code-verify of this repository; never imported.
{ runCommand }: runCommand "claude-code-verify" { } "echo not the tool > $out"
