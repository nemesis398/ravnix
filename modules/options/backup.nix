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

  # A path in the home: `~`, `~/a/b`, or an absolute path, without a
  # trailing slash, and without empty, `.` or `..` components.
  homePath =
    types.addCheck (types.strMatching "(~|~/[^[:cntrl:]]*[^/[:cntrl:]]|/[^[:cntrl:]]*[^/[:cntrl:]])") (
      p:
      let
        parts = lib.splitString "/" p;
      in
      !lib.any (c: c == "." || c == "..") parts && !lib.elem "" (lib.tail parts)
    )
    // {
      description = "path: `~`, `~/a/b` or `/a/b`, without a trailing slash, `//`, `.` or `..`";
    };

  # A restic exclude pattern. `!` is restic's way back in, and the module
  # writes it from `keep`, where it can put the pattern in the order restic
  # needs; written here it is too easy to get wrong (backup.nix says how).
  excludePattern = types.strMatching "[^![:cntrl:]][^[:cntrl:]]*" // {
    description = "restic exclude pattern, not starting with `!` (use keep)";
  };

  # The NAS's rest-server (deploy/compose/restic), placed like every service
  # in ravnix.services, so a new address of the NAS is a change of one line.
  server = config.ravnix.services.restic-server or null;
  noServer = "ravnix.backup.nas is set, but no rest-server is registered: set ravnix.services.restic-server = { enable = true; host = \"<the NAS in ravnix.hosts>\"; port = <its RESTIC_PORT>; } (deploy/compose/restic)";
  backup = config.ravnix.backup.nas;
  hosts = config.ravnix.hosts;

  # nullOr, but a null gives way to a value instead of conflicting with it.
  # substSubModules is how the module system rebuilds a type that holds a
  # submodule, so it must make this type again, not a plain nullOr.
  nullGivesWay =
    elem:
    types.nullOr elem
    // {
      merge =
        loc: defs:
        let
          values = lib.filter (d: d.value != null) defs;
        in
        if values == [ ] then null else elem.merge loc values;
      substSubModules = m: nullGivesWay (elem.substSubModules m);
    };

  nas = types.submodule (sub: {
    options = {
      repository = mkOption {
        type = types.str;
        readOnly = true;
        # One name for all three: the snapshots' host, the repository's
        # path and, with the server's --private-repos, the login's user.
        default = if server != null && server.enable then "rest:${server.url}/${sub.config.host}/" else throw noServer;
        defaultText = lib.literalExpression ''"rest:''${ravnix.services.restic-server.url}/''${host}/"'';
        description = ''
          The host's repository on the NAS's rest-server, over the LAN (or
          NetBird's route to it), derived from ravnix.services.restic-server
          and `host`. Read-only.
        '';
      };

      host = mkOption {
        type = types.strMatching "[A-Za-z0-9][A-Za-z0-9_-]{0,62}" // {
          description = "host name: letters, digits, - and _, at most 63";
        };
        example = "huginn";
        description = ''
          The host's one name at the NAS: the host name the snapshots carry
          (restic's `--host`), whatever the machine is called at the moment,
          the path of its repository, and its login's user name at the
          rest-server. The NAS's jobs and the retention file's
          `[targets.<target>.hosts.<host>]` know the host by it, and it
          must be unique in the estate's Internxt repository.
        '';
      };

      passwordItem = mkOption {
        type = types.strMatching "[^\n]+";
        example = "Restic - huginn repository";
        description = ''
          The Bitwarden item whose password is the repository's password.
          restic asks rbw for it (`--password-command`) at each run; it is in
          no file, no unit and no environment.
        '';
      };

      loginItem = mkOption {
        type = types.strMatching "[^\n]+";
        example = "Restic - huginn rest-server login";
        description = ''
          The Bitwarden item whose password is the host's login at the
          rest-server (its line in `htpasswd`, whose user is `host`). rbw
          reads it at each run, and restic gets it in the environment of its
          own process.
        '';
      };

      paths = mkOption {
        type = types.nonEmptyListOf homePath;
        default = [ "~" ];
        description = ''
          What is backed up. A path under one of `exclude` is not a way back
          in: restic would back up the bare directory and nothing in it.
          Use `keep` for that.
        '';
      };

      exclude = mkOption {
        type = types.listOf excludePattern;
        default = [ ];
        example = [
          "~/Nextcloud"
          "~/Git"
          "*.iso"
        ];
        description = ''
          What is left out, as restic exclude patterns; a leading `~` is the
          home. `~/.cache` and every directory with a CACHEDIR.TAG are left
          out always. Leave out what another copy holds already: a synced
          folder, the repositories a forge has.
        '';
      };

      keep = mkOption {
        type = types.listOf homePath;
        default = [ ];
        example = [ "~/Nextcloud/notes" ];
        description = ''
          Paths inside an entry of `exclude` that are backed up all the
          same, with everything below them. Each must lie inside an entry
          of `paths` and inside an `exclude` entry that is a plain path,
          without `*`, `?` or `[`. A `*`, `?`, `[` or `\` in a kept path is
          that character, not a wildcard.
        '';
      };

      onCalendar = mkOption {
        type = types.nonEmptyStr;
        default = "daily";
        example = "*-*-* 02:00";
        description = "When the backup runs, as systemd's OnCalendar. A missed run is made up after boot, and a failed one is tried again after 30 minutes.";
      };
    };
  });
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

  options.ravnix.backup.nas = mkOption {
    # A null gives way to a value: me.nix says null, and the module of the
    # host that backs up sets its own beside it, without lib.mkForce. Two
    # values are merged as the submodule merges them.
    type = nullGivesWay nas;
    default = null;
    description = ''
      This host's backup to the NAS: restic, as the user, to the NAS's
      rest-server, which takes new snapshots and refuses to delete any
      (`--append-only`). Pruning is the NAS's job, by the retention file;
      the NAS also copies every host's snapshots to Internxt, so no host
      needs that credential. null: the host makes no backup. Set it in
      the module of the host that backs up, never in me.nix, which every
      host reads.
    '';
  };

  # Checked only once the file is set: an unset value is reported as missing
  # by default.nix instead.
  config.assertions =
    lib.optionals options.ravnix.backup.retentionFile.isDefined (
      map (problem: {
        assertion = false;
        message = "ravnix.backup.retentionFile: ${problem}.";
      }) problems
    )
    ++ lib.optionals (backup != null) [
      {
        assertion = server != null && server.enable;
        message = "${noServer}.";
      }
      {
        # The NAS, or any machine that is not a ravnix host, may back
        # itself up under its own name into the shared Internxt
        # repository, and a prune by --host would take both for one.
        assertion = !(hosts ? ${backup.host}) || hosts.${backup.host}.runtime == "nixos";
        message = "ravnix.backup.nas.host is \"${backup.host}\", the name of ravnix.hosts.${backup.host}, which runs ${
          hosts.${backup.host}.runtime or "?"
        }: its own backups may carry that name in the shared Internxt repository, and a prune by --host would take the two for one. Choose another name.";
      }
    ];
}
