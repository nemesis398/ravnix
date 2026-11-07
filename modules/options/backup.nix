# How many backups each target keeps, in one file a person can read
# without knowing Nix.
{
  config,
  lib,
  options,
  ...
}:
let
  inherit (lib) mkOption types;
  file = config.ravnix.backup.retentionFile;

  targets = [
    "nas"
    "internxt"
  ];
  counts = [
    "daily"
    "weekly"
    "monthly"
    "yearly"
  ];
  isCount = v: builtins.isInt v && v >= 0;

  # What is wrong with the file, as messages naming the key.
  problems =
    let
      toml = builtins.fromTOML (builtins.readFile file);
      given = toml.targets or { };
      # A host's numbers: its own where it has them, the target's otherwise.
      checkCounts =
        where: numbers: required:
        lib.concatMap (
          key:
          if !(numbers ? ${key}) then
            lib.optional required "${where} has no ${key}"
          else
            lib.optional (!isCount numbers.${key}) "${where}.${key} is not a whole number of 0 or more"
        ) counts
        ++ map (key: "${where}.${key} is not a key of the file") (
          lib.subtractLists (counts ++ [ "hosts" ]) (lib.attrNames numbers)
        );
      allZero =
        where: numbers:
        lib.optional (lib.all (
          key: (numbers.${key} or 1) == 0
        ) counts) "${where} keeps nothing, so a prune would delete every snapshot";
      checkTarget =
        name:
        let
          t = given.${name};
          hosts = t.hosts or { };
        in
        checkCounts "targets.${name}" t true
        ++ allZero "targets.${name}" t
        ++ lib.concatLists (
          lib.mapAttrsToList (
            host: own:
            let
              where = "targets.${name}.hosts.${host}";
            in
            checkCounts where own false
            ++ lib.optional (own ? hosts) "${where}.hosts is not a key of the file"
            ++ allZero where (t // own)
          ) hosts
        );
    in
    map (name: "targets.${name} is missing") (lib.subtractLists (lib.attrNames given) targets)
    ++ map (name: "targets.${name} is not a target ravnix backs up to") (
      lib.subtractLists targets (lib.attrNames given)
    )
    ++ lib.concatMap checkTarget (lib.intersectLists targets (lib.attrNames given));
in
{
  options.ravnix.backup.retentionFile = mkOption {
    # A Nix path, so the file is in the store and pure evaluation can read
    # it; an absolute path in a string would not be.
    type = types.addCheck types.path builtins.isPath // {
      description = "Nix path, such as ./backups.toml";
    };
    example = lib.literalExpression "./backups.toml";
    description = ''
      A TOML file with the snapshots each target keeps: `[targets.nas]` and
      `[targets.internxt]`, each with `daily`, `weekly`, `monthly` and
      `yearly`, and optional `[targets.<target>.hosts.<host>]` tables for a
      host that keeps a different number. Whatever falls outside it is
      pruned. Give it as a Nix path (`./backups.toml`), not a string.
    '';
  };

  # Checked only once the file is set: an unset value is reported as missing
  # by default.nix instead.
  config.assertions = lib.optionals options.ravnix.backup.retentionFile.isDefined (
    map (problem: {
      assertion = false;
      message = "ravnix.backup.retentionFile: ${problem}.";
    }) problems
  );
}
