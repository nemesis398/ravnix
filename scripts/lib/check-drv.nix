# The derivation of one check, which the gate's flake step builds with
# nix build DRV^* (scripts/check.sh), so the check is evaluated once.
# nix flake check refuses a check that is no derivation; nix build would
# take a path or a string with store context, and pass a check that tests
# nothing. tests/flake/gate-check-drv.nix tests this guard.
check:
if builtins.isAttrs check && (check.type or null) == "derivation" then
  check.drvPath
else
  throw "the check is ${
    if builtins.isAttrs check then "an attribute set" else builtins.typeOf check
  }, not a derivation, which nix flake check requires of a check"
