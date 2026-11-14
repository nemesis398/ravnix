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
      # A key that must hold a table and holds something else (`muninn = 14`
      # where `[targets.nas.hosts.muninn]` belongs) is reported, and nothing
      # below it is read.
      table =
        where: value: check:
        if builtins.isAttrs value then check value else [ "${where} is not a table" ];
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
      # A host's numbers: its own where it has them, the target's otherwise.
      checkHost =
        name: target: host:
        let
          where = "targets.${name}.hosts.${host}";
        in
        table where target.hosts.${host} (
          own:
          checkCounts where own false
          ++ lib.optional (own ? hosts) "${where}.hosts is not a key of the file"
          ++ allZero where (target // own)
        );
      checkTarget =
        name: target:
        checkCounts "targets.${name}" target true
        ++ allZero "targets.${name}" target
        ++ lib.optionals (target ? hosts) (
          table "targets.${name}.hosts" target.hosts (
            hosts: lib.concatMap (checkHost name target) (lib.attrNames hosts)
          )
        );
      checkTargets =
        given:
        map (name: "targets.${name} is missing") (lib.subtractLists (lib.attrNames given) targets)
        ++ map (name: "targets.${name} is not a target ravnix backs up to") (
          lib.subtractLists targets (lib.attrNames given)
        )
        ++ lib.concatMap (name: table "targets.${name}" given.${name} (checkTarget name)) (
          lib.intersectLists targets (lib.attrNames given)
        );
    in
    # ravnix-retention refuses a key beside targets, so the build does too:
    # a file it refuses would only fail later, in the prune job.
    map (key: "${key} is not a key of the file") (lib.remove "targets" (lib.attrNames toml))
    ++ table "targets" (toml.targets or { }) checkTargets;
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
