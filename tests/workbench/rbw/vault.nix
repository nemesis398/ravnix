# The stand-in vault of tests/workbench/rbw.nix, built by ./make-vault.py:
# $out/db.json is rbw's local copy of it, and $out/NAME.pub the public half of
# each SSH key in it. `spec` is what make-vault.py reads.
{ pkgs, spec }:
pkgs.runCommand "rbw-stub-vault"
  {
    nativeBuildInputs = [ (pkgs.python3.withPackages (p: [ p.cryptography ])) ];
    spec = builtins.toJSON spec;
    passAsFile = [ "spec" ];
  }
  ''
    PYTHONDONTWRITEBYTECODE=1 python3 -I ${./make-vault.py} "$specPath" "$out"
  ''
