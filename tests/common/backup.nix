# The host's backup to the NAS (modules/common/backup.nix), without a VM:
#
# - The exclude patterns (modules/common/backup-excludes.nix): an excluded
#   directory with a path kept inside it becomes the steps restic needs, in
#   restic's order, for one level and for several, for two kept paths in
#   one directory and for a kept path inside another; the other excludes
#   follow unchanged; a glob character in a kept path or the home is escaped,
#   so it names that folder and no other. A kept path inside no plain
#   exclude or outside every backup path, and a backup path inside an
#   exclude, are refused by name.
# - The evaluated home-manager configuration: no unit and no timer without
#   ravnix.backup.nas; with it, a oneshot unit that restarts after a failure
#   but not after restic's exit 3, and a timer; the problems above as
#   assertions that home-manager refuses; the repository derived from the
#   registered rest-server and the host name; and no secret, `forget`,
#   `prune` or `init` in the script.
# - The script itself, run against a real rest-server on loopback with the
#   flags of deploy/compose/restic (`--append-only --private-repos` and the
#   logins), and a stand-in for rbw:
#   the snapshot carries the host name of the option, not the machine's,
#   and so do the repository's path and the login's user; the carved-back
#   folders are in it with everything below, one of them with brackets in
#   its name, and the rest of the excluded directory, ~/.cache and a
#   CACHEDIR.TAG directory are not; a second run adds a snapshot; the
#   host's login cannot forget it, and cannot read another host's
#   repository; with the vault locked the run exits 75 and starts no
#   restic; with a login item without a password it says so.
#
# With ravnix.backup.nas.secrets = "file" (the root-only file, for a host
# that backs up unattended): on NixOS a system unit and timer that run the
# backup under a UID of its own (DynamicUser), never the login user's,
# reading the home through CAP_DAC_READ_SEARCH alone, with restic's cache in
# its CacheDirectory; the file reaches it through LoadCredential, its path
# is asserted, and a root step refuses it unless it is root's, mode 600;
# no user unit, no rbw and no secret anywhere in the unit or the script;
# home-manager alone refuses the choice. The same script, run against the
# same rest-server with $CREDENTIALS_DIRECTORY and $CACHE_DIRECTORY as
# systemd sets them, as a process that does not own the home's files: with
# only CAP_DAC_READ_SEARCH it backs up a file its owner cannot read (mode
# 200), with its mode and owner, and without the capability it cannot; it
# asks rbw nothing, and without the credential, with it unreadable, or
# without one of its two lines, it fails with one line. The root step
# passes a root-owned file of mode 600 and refuses another owner or mode
# with one line. The setup command that the option's description and the
# compose file's README show (the same text in both) writes a file of mode
# 600 that the root step passes; a locked vault, an item rbw cannot get
# and one without a password leave the old file as it was, nothing beside
# it, and fail.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  hm = import ./helpers/hm.nix {
    inherit
      self
      inputs
      pkgs
      lib
      ;
  };
  excludesOf = import ../../modules/common/backup-excludes.nix { inherit lib; };

  # The sandbox's build directory (sandbox-build-dir), where the home of the
  # run is; the check fails at once when the build runs elsewhere.
  build = "/build";
  home = "${build}/home";
  # The port the compose file's rest-server listens on in its container.
  port = 8000;
  compose = ../../deploy/compose/restic/docker-compose.yaml;

  repository = "rest:http://127.0.0.1:${toString port}/huginn/";
  nas = {
    host = "huginn";
    passwordItem = "Restic - huginn repository";
    loginItem = "Restic - huginn login";
    exclude = [
      "~/Nextcloud"
      "*.iso"
    ];
    keep = [
      "~/Nextcloud/notes"
      "~/Nextcloud/[2024] notes"
    ];
  };

  # The version only answers rbw.nix's check for an agent that serves SSH.
  fakeRbw =
    (pkgs.writeShellScriptBin "rbw" ''
      # A stand-in for rbw: the vault is locked when $FAKE_RBW_LOCKED exists,
      # and every call is logged without its secret.
      echo "rbw $*" >>"$FAKE_RBW_LOG"
      case "$1" in
        unlocked | unlock) [ ! -e "$FAKE_RBW_LOCKED" ] ;;
        get)
          case "$*" in
            "get -- Restic - huginn login") cat "$FAKE_RBW_LOGIN" ;;
            "get -- Restic - huginn repository") echo repository-secret ;;
            *) echo "rbw: no item: $*" >&2; exit 1 ;;
          esac ;;
        *) exit 2 ;;
      esac
    '')
    // {
      version = "1.14.0";
    };

  configWith =
    value:
    (hm [
      {
        home.homeDirectory = lib.mkForce home;
        programs.rbw.package = lib.mkForce fakeRbw;
        ravnix.backup.nas = lib.mkForce value;
      }
      registered
    ]).config;
  # The rest-server in the registry, on the template's NAS, here on loopback.
  registered = {
    ravnix.hosts.nas.address = lib.mkForce "127.0.0.1";
    ravnix.services.restic-server = {
      enable = true;
      host = "nas";
      inherit port;
    };
  };
  on = configWith nas;
  off = (hm [ ]).config;
  # home-manager refuses a configuration whose assertions fail, as a host
  # build does; the message is the one problemsOf gives, checked below.
  refused = value: !(builtins.tryEval (builtins.seq (configWith value).home.packages true)).success;

  # The host as NixOS builds it, with the secrets in the root-only file.
  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };
  user = (import ../../templates/default/me.nix).ravnix.user.username;
  nixosEval =
    value:
    inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = hostModules ++ [
        self.nixosModules.common
        registered
        {
          networking.hostName = "huginn";
          users.users.${user}.home = lib.mkForce home;
          ravnix.backup.nas = lib.mkForce value;
        }
      ];
    };
  nixosWith = value: (nixosEval value).config;
  # The command that writes the root-only file, as ravnix.backup.nas.secretsFile
  # documents it, and as step 5 of the compose file's README shows it, indented
  # into its list.
  setupDoc =
    ((nixosEval nas).options.ravnix.backup.nas.type.nestedTypes.elemType.getSubOptions [ ])
    .secretsFile.description;
  setupCommand =
    let
      parts = lib.splitString "```sh\n" setupDoc;
    in
    if lib.length parts < 2 then "" else lib.head (lib.splitString "\n```" (lib.elemAt parts 1));
  readmeCommand = lib.concatMapStringsSep "\n" (line: if line == "" then "" else "   " + line) (
    lib.splitString "\n" setupCommand
  );
  setupScript = pkgs.writeText "setup.sh" setupCommand;
  # sudo, for the setup command: the build user is the only user there is.
  fakeSudo = pkgs.writeShellScriptBin "sudo" ''
    if [ "$1" = -v ]; then exit 0; fi
    exec "$@"
  '';
  secretsFile = "/var/lib/ravnix/backup-secrets";
  fileOs = nixosWith (nas // { secrets = "file"; });
  rbwOs = nixosWith nas;
  fileUnit = fileOs.systemd.services.ravnix-backup or null;
  fileTimer = fileOs.systemd.timers.ravnix-backup or null;
  fileHome = fileOs.home-manager.users.${user};
  fileScript = fileUnit.serviceConfig.ExecStart or "";
  envOf = unit: toString (unit.serviceConfig.Environment or [ ]) + toString (lib.attrValues (unit.environment or { }));

  service = on.systemd.user.services.ravnix-backup;
  timer = on.systemd.user.timers.ravnix-backup;
  backup = lib.findFirst (p: (p.name or "") == "ravnix-backup") null on.home.packages;
  script = backup.text or "";

  patternsOf =
    args:
    (excludesOf (
      {
        home = "/h";
        paths = [ "~" ];
        exclude = [ ];
        keep = [ ];
        always = [ ];
      }
      // args
    )).patterns;
  problemsOf =
    args:
    (excludesOf (
      {
        home = "/h";
        paths = [ "~" ];
        exclude = [ ];
        keep = [ ];
        always = [ ];
      }
      // args
    )).problems;

  patternCases = [
    {
      what = "one level";
      args = {
        exclude = [ "~/N" ];
        keep = [ "~/N/a" ];
      };
      want = [
        "/h/N/*"
        "!/h/N/a"
      ];
    }
    {
      what = "three levels";
      args = {
        exclude = [ "~/N" ];
        keep = [ "~/N/a/b/c" ];
      };
      want = [
        "/h/N/*"
        "!/h/N/a"
        "/h/N/a/*"
        "!/h/N/a/b"
        "/h/N/a/b/*"
        "!/h/N/a/b/c"
      ];
    }
    {
      what = "two kept paths in one directory, and the other excludes after them";
      args = {
        exclude = [
          "*.iso"
          "~/N"
          "~/Git"
        ];
        keep = [
          "~/N/a/x"
          "~/N/b"
        ];
      };
      want = [
        "/h/N/*"
        "!/h/N/a"
        "!/h/N/b"
        "/h/N/a/*"
        "!/h/N/a/x"
        "*.iso"
        "/h/Git"
      ];
    }
    {
      what = "a kept path inside another";
      args = {
        exclude = [ "~/N" ];
        keep = [
          "~/N/a/b"
          "~/N/a"
        ];
      };
      want = [
        "/h/N/*"
        "!/h/N/a"
      ];
    }
    {
      what = "an exclude inside another, both above the kept path";
      args = {
        exclude = [
          "~/N/a"
          "~/N"
        ];
        keep = [ "~/N/a/b" ];
      };
      want = [
        "/h/N/*"
        "!/h/N/a"
        "/h/N/a/*"
        "!/h/N/a/b"
      ];
    }
    {
      what = "an exclude inside a kept path";
      args = {
        exclude = [
          "~/N"
          "~/N/a/.trash"
        ];
        keep = [ "~/N/a" ];
      };
      want = [
        "/h/N/*"
        "!/h/N/a"
        "/h/N/a/.trash"
      ];
    }
    {
      what = "glob characters in a kept path and in the home";
      args = {
        home = "/h[1]";
        exclude = [ "~/N" ];
        keep = [ "~/N/[a] b*?\\c" ];
      };
      want = [
        "/h\\[1]/N/*"
        "!/h\\[1]/N/\\[a] b\\*\\?\\\\c"
      ];
    }
    {
      what = "the home's glob characters in an exclude, the user's own kept";
      args = {
        home = "/h*";
        exclude = [ "~/*.iso" ];
      };
      want = [ "/h\\*/*.iso" ];
    }
    {
      what = "absolute paths";
      args = {
        exclude = [ "/srv/x" ];
        keep = [ "/srv/x/y" ];
      };
      want = [
        "/srv/x/*"
        "!/srv/x/y"
      ];
    }
  ];

  problemCases = [
    {
      what = "a kept path inside no exclude";
      args.keep = [ "~/N/a" ];
      want = "ravnix.backup.nas.keep has /h/N/a";
    }
    {
      what = "a kept path inside a wildcard only";
      args = {
        exclude = [ "~/N*" ];
        keep = [ "~/Nx/a" ];
      };
      want = "ravnix.backup.nas.keep has /h/Nx/a";
    }
    {
      what = "a backup path inside an exclude";
      args = {
        paths = [
          "~"
          "~/N/a"
        ];
        exclude = [ "~/N" ];
      };
      want = "ravnix.backup.nas.paths has /h/N/a, which exclude leaves out (/h/N)";
    }
    {
      what = "a kept path outside every backup path";
      args = {
        paths = [ "~/Documents" ];
        exclude = [ "~/N" ];
        keep = [ "~/N/a" ];
      };
      want = "ravnix.backup.nas.keep has /h/N/a, which is inside no entry of paths";
    }
    {
      what = "a kept path inside what is left out always";
      args = {
        always = [ "~/.cache" ];
        keep = [ "~/.cache/k" ];
      };
      want = "ravnix.backup.nas.keep has /h/.cache/k, which is inside /h/.cache, which is left out always";
    }
    {
      what = "a backup path that is an exclude";
      args = {
        paths = [ "~/N" ];
        exclude = [ "~/N" ];
      };
      want = "ravnix.backup.nas.paths has /h/N";
    }
  ];

  failures =
    lib.concatMap (
      c:
      let
        got = patternsOf c.args;
      in
      lib.optional (
        got != c.want
      ) "patterns for ${c.what}: got ${builtins.toJSON got}, want ${builtins.toJSON c.want}"
    ) patternCases
    ++ lib.concatMap (
      c:
      lib.optional (
        !lib.any (lib.hasPrefix c.want) (problemsOf c.args)
      ) "no problem for ${c.what}: got ${builtins.toJSON (problemsOf c.args)}"
    ) problemCases
    ++ lib.optional (
      problemsOf {
        paths = [
          "~"
          "~/N/a"
        ];
        exclude = [ "~/N" ];
        keep = [ "~/N/a" ];
      } != [ ]
    ) "a backup path that is also kept is refused"
    ++ lib.optional (
      problemsOf { inherit (nas) exclude keep; } != [ ]
    ) "the test's own values have problems"
    ++ lib.optional (
      off.systemd.user.services ? ravnix-backup
    ) "without ravnix.backup.nas there is a backup unit"
    ++ lib.optional (
      off.systemd.user.timers ? ravnix-backup
    ) "without ravnix.backup.nas there is a backup timer"
    ++ lib.optional (backup == null) "ravnix-backup is not in home.packages"
    ++ lib.optional (service.Service.Type != "oneshot") "the unit is not a oneshot"
    ++ lib.optional (service.Service.Restart != "on-failure") "a failed backup is not tried again"
    ++ lib.optional (service.Service.RestartPreventExitStatus != "3") "restic's exit 3 is retried"
    ++ lib.optional (timer.Timer.OnCalendar != "daily") "the timer is not daily by default"
    ++ lib.optional (!timer.Timer.Persistent) "a missed backup is not made up"
    ++ lib.optional (timer.Install.WantedBy != [ "timers.target" ]) "the timer is not started"
    ++ lib.optional (
      !refused (nas // { keep = [ "~/Elsewhere/x" ]; })
    ) "a stray kept path is not refused"
    ++ lib.optional (
      !refused (nas // { paths = [ "~/Nextcloud/other" ]; })
    ) "a backup path inside an exclude is not refused"
    ++ lib.optional (!refused (nas // { keep = [ "~/.cache/k" ]; })) "a kept path inside ~/.cache is not refused"
    ++ lib.optional (
      patternsOf {
        always = [ "~/.cache" ];
        exclude = [ "~/N" ];
        keep = [ "~/N/a" ];
      } != [
        "/h/N/*"
        "!/h/N/a"
        "/h/.cache"
      ]
    ) "what is left out always is not an exclude of its own"
    ++ map (word: "the script says ${word}") (
      lib.filter (word: lib.hasInfix word script) [
        "forget"
        "prune"
        "init "
        "restic unlock"
        "login-secret"
        "repository-secret"
      ]
    )
    ++ lib.optional (
      !lib.hasInfix "--host huginn" script
    ) "the script does not pin the snapshot's host"
    ++ lib.optional (
      !lib.hasInfix "RESTIC_REPOSITORY=${repository}" script
    ) "the script's repository is not the registered rest-server's, at the host's path"
    ++ lib.optional (lib.hasInfix "--field" script) "the script reads the login's user name from the item"
    ++ lib.optional (
      !lib.hasInfix "RESTIC_REST_USERNAME=huginn" script
    ) "the login's user is not the host name"
    # The root-only file.
    ++ lib.optional (!refused (nas // { secrets = "file"; })) "home-manager alone takes secrets = \"file\", which needs a system unit"
    ++ lib.optional (rbwOs.systemd.services ? ravnix-backup) "with rbw there is a system unit as well"
    ++ lib.optional (fileUnit == null) "with the file there is no system unit"
    ++ lib.optional (fileTimer == null) "with the file there is no system timer"
    ++ lib.optional (
      fileHome.systemd.user.services ? ravnix-backup || fileHome.systemd.user.timers ? ravnix-backup
    ) "with the file the user unit or timer is still there"
    ++ lib.optional (lib.any (p: (p.name or "") == "ravnix-backup") fileHome.home.packages) "with the file ravnix-backup is on the user's PATH, where it cannot read the file"
    ++ lib.optionals (fileUnit != null) (
      lib.optional (fileUnit.serviceConfig.User or null == user) "the system unit runs as the login user ${user}, who could read the credential"
      ++ lib.optional (!(fileUnit.serviceConfig.DynamicUser or false)) "the system unit does not run under a UID of its own"
      ++ lib.optional (
        fileUnit.serviceConfig.AmbientCapabilities or null != [ "CAP_DAC_READ_SEARCH" ]
      ) "the system unit's ambient capabilities are not CAP_DAC_READ_SEARCH alone"
      ++ lib.optional (
        fileUnit.serviceConfig.CapabilityBoundingSet or null != [ "CAP_DAC_READ_SEARCH" ]
      ) "the system unit's bounding set is not CAP_DAC_READ_SEARCH alone"
      ++ lib.optional (fileUnit.serviceConfig.CacheDirectory or null != "ravnix-backup") "restic's cache is not the unit's CacheDirectory"
      ++ lib.optional (
        !lib.hasPrefix "+" (toString (fileUnit.serviceConfig.ExecStartPre or ""))
        || !lib.hasSuffix " ${secretsFile}" (toString (fileUnit.serviceConfig.ExecStartPre or ""))
      ) "no root step checks the owner and mode of ${secretsFile}"
      ++ lib.optional (
        fileUnit.serviceConfig.LoadCredential or null != [ "ravnix-backup:${secretsFile}" ]
      ) "the system unit does not load ${secretsFile} as the credential ravnix-backup: ${builtins.toJSON (fileUnit.serviceConfig.LoadCredential or null)}"
      ++ lib.optional (
        fileUnit.unitConfig.AssertPathExists or null != secretsFile
      ) "the system unit does not assert that ${secretsFile} exists"
      ++ lib.optional (fileUnit.serviceConfig.Type or null != "oneshot") "the system unit is not a oneshot"
      ++ lib.optional (fileUnit.serviceConfig.Restart or null != "on-failure") "the system unit does not try again"
      ++ lib.optional (fileUnit.serviceConfig.RestartPreventExitStatus or null != "3") "the system unit retries restic's exit 3"
      ++ lib.optional (lib.hasInfix "PASSWORD" (envOf fileUnit)) "the system unit's environment names a password"
    )
    ++ lib.optional (setupCommand == "") "ravnix.backup.nas.secretsFile shows no setup command"
    ++ lib.optional (
      !lib.hasInfix readmeCommand (builtins.readFile ../../deploy/compose/restic/README.md)
    ) "the compose file's README does not show the setup command of ravnix.backup.nas.secretsFile"
    ++ lib.optionals (fileTimer != null) (
      lib.optional (fileTimer.timerConfig.OnCalendar or null != "daily") "the system timer is not daily"
      ++ lib.optional (!(fileTimer.timerConfig.Persistent or false)) "the system timer does not make up a missed run"
      ++ lib.optional (fileTimer.wantedBy or [ ] != [ "timers.target" ]) "the system timer is not started"
    );
in
pkgs.runCommand "common-backup"
  {
    nativeBuildInputs = [
      pkgs.restic
      pkgs.restic-rest-server
      pkgs.mkpasswd
      pkgs.jq
      pkgs.curl
      pkgs.yq-go
      pkgs.util-linux
    ];
  }
  (
    if failures != [ ] then
      ''
        printf 'FAIL: %s\n' ${lib.escapeShellArgs failures} >&2
        exit 1
      ''
    else
      ''
        fail() { echo "FAIL: $*" >&2; exit 1; }
        [ "$PWD" = ${build} ] || fail "the build runs in $PWD, not in ${build}, where the test's home is"

        # The home: a folder taken back from an excluded directory, the rest
        # of it, a cache, a CACHEDIR.TAG directory, a wildcard's file.
        mkdir -p ${home}/Nextcloud/notes/deep ${home}/Nextcloud/other ${home}/.cache/x \
          ${home}/project/target ${home}/doc "${home}/Nextcloud/[2024] notes" "${home}/Nextcloud/2 notes"
        echo y >"${home}/Nextcloud/[2024] notes/y"
        echo n >"${home}/Nextcloud/2 notes/n"
        echo a >${home}/Nextcloud/notes/a
        echo b >${home}/Nextcloud/notes/deep/b
        echo o >${home}/Nextcloud/other/o
        echo t >${home}/Nextcloud/top
        echo c >${home}/.cache/x/c
        printf 'Signature: 8a477f597d28d172789f06886806bc55\n' >${home}/project/target/CACHEDIR.TAG
        echo built >${home}/project/target/built
        echo d >${home}/doc/d
        echo i >${home}/doc/disk.iso
        export HOME=${home}

        # The server, as deploy/compose/restic runs it, and its logins.
        data=${build}/data
        mkdir -p "$data"
        {
          echo "huginn:$(mkpasswd -m bcrypt login-secret)"
          echo "muninn:$(mkpasswd -m bcrypt other-secret)"
        } >${build}/htpasswd
        # The repositories are made beside the server, as on the NAS.
        RESTIC_PASSWORD=repository-secret restic init -q --repo "$data/huginn"
        RESTIC_PASSWORD=muninn-secret restic init -q --repo "$data/muninn"
        # The compose file's own flags, with its two container paths here.
        mapfile -t flags < <(yq '.services.rest-server.command[]' ${compose})
        args=()
        for flag in "''${flags[@]}"; do
          case "$flag" in
            --path=/data) args+=("--path=$data") ;;
            --htpasswd-file=/etc/rest-server/htpasswd) args+=("--htpasswd-file=${build}/htpasswd") ;;
            --listen=:${toString port}) args+=("--listen=127.0.0.1:${toString port}") ;;
            *) args+=("$flag") ;;
          esac
        done
        [ "''${#args[@]}" -ge 5 ] || fail "the compose file's command has $((''${#args[@]})) flags"
        rest-server "''${args[@]}" >${build}/server.log 2>&1 &
        server=$!
        for _ in $(seq 100); do
          curl -s -o /dev/null http://127.0.0.1:${toString port}/ && break
          sleep 0.1
        done

        export FAKE_RBW_LOG=${build}/rbw.log FAKE_RBW_LOCKED=${build}/locked FAKE_RBW_LOGIN=${build}/login
        echo login-secret >"$FAKE_RBW_LOGIN"
        ${backup}/bin/ravnix-backup || fail "the backup failed: $(cat ${build}/server.log)"
        ${backup}/bin/ravnix-backup || fail "the second backup failed"

        local_repo() { RESTIC_PASSWORD=repository-secret restic --repo "$data/huginn" --no-cache "$@"; }
        [ "$(local_repo snapshots --json | jq length)" = 2 ] || fail "two runs did not make two snapshots"
        [ "$(local_repo snapshots --json | jq -r '.[].hostname' | sort -u)" = huginn ] ||
          fail "the snapshots carry another host name: $(local_repo snapshots --json | jq -r '.[].hostname')"
        listing=$(local_repo ls latest | sed 's|^${home}||')
        for kept in /Nextcloud/notes/a /Nextcloud/notes/deep/b "/Nextcloud/[2024] notes/y" /doc/d /project; do
          grep -qxF "$kept" <<<"$listing" || fail "$kept is not in the snapshot: $listing"
        done
        for gone in /Nextcloud/other /Nextcloud/top "/Nextcloud/2 notes" /.cache /project/target/built /doc/disk.iso; do
          if grep -qxF "$gone" <<<"$listing"; then fail "$gone is in the snapshot"; fi
        done

        # The host appends and never deletes, and reads no other repository.
        export RESTIC_REST_USERNAME=huginn RESTIC_REST_PASSWORD=login-secret RESTIC_PASSWORD=repository-secret
        id=$(local_repo snapshots --json | jq -r '.[0].short_id')
        if restic --repo ${repository} --no-cache forget "$id" >${build}/forget.log 2>&1; then
          fail "the host's login forgot a snapshot: $(cat ${build}/forget.log)"
        fi
        [ "$(local_repo snapshots --json | jq length)" = 2 ] || fail "a snapshot is gone after the refused forget"
        if restic --repo rest:http://127.0.0.1:${toString port}/muninn/ --no-cache snapshots >/dev/null 2>&1; then
          fail "huginn's login reads muninn's repository"
        fi
        unset RESTIC_REST_USERNAME RESTIC_REST_PASSWORD RESTIC_PASSWORD

        # A locked vault: exit 75, and no restic.
        touch "$FAKE_RBW_LOCKED"
        status=0
        ${backup}/bin/ravnix-backup 2>${build}/locked.log || status=$?
        [ "$status" = 75 ] || fail "with the vault locked the backup exited $status, not 75"
        grep -q 'vault is locked' ${build}/locked.log || fail "the locked run does not say why: $(cat ${build}/locked.log)"
        [ "$(local_repo snapshots --json | jq length)" = 2 ] || fail "a locked run made a snapshot"
        rm "$FAKE_RBW_LOCKED"

        # A login item without a password.
        : >"$FAKE_RBW_LOGIN"
        status=0
        ${backup}/bin/ravnix-backup 2>${build}/nologin.log || status=$?
        [ "$status" = 1 ] || fail "a login without a password exited $status"
        grep -q 'has no password' ${build}/nologin.log || fail "the run does not say the login lacks a password: $(cat ${build}/nologin.log)"

        # rbw was asked for the items by name, and the repository password
        # through --password-command.
        grep -qx 'rbw get -- Restic - huginn repository' "$FAKE_RBW_LOG" || fail "the repository password did not come from rbw"
        # The root-only file, as systemd hands it over: $CREDENTIALS_DIRECTORY
        # with the credential ravnix-backup in it.
        fileScript=${fileScript}
        fileCheck=${lib.removeSuffix " ${secretsFile}" (lib.removePrefix "+" (toString (fileUnit.serviceConfig.ExecStartPre or "")))}
        [ -x "$fileScript" ] || fail "the system unit's ExecStart is not a program: $fileScript"
        if grep -q rbw "$fileScript"; then fail "the file's script runs rbw"; fi
        rbw_calls=$(wc -l <"$FAKE_RBW_LOG")
        creds=${build}/credentials
        mkdir -p "$creds"
        printf 'repository=repository-secret\nlogin=login-secret\n' >"$creds/ravnix-backup"
        # The unit's own UID owns none of the home: here a process that is
        # root in a user namespace, with every capability dropped but the
        # one the unit keeps, and a file the owner cannot read either (mode
        # 200: restic's JSON leaves out a mode of 0).
        echo locked >${home}/doc/locked
        chmod 200 ${home}/doc/locked
        only() { # CAPS, then the command
          caps=$1
          shift
          unshare -r setpriv --inh-caps=-all$caps --ambient-caps=-all$caps --bounding-set=-all$caps -- "$@"
        }
        status=0
        only "" env CREDENTIALS_DIRECTORY="$creds" CACHE_DIRECTORY=${build}/cache-none "$fileScript" 2>${build}/nocap.log || status=$?
        [ "$status" = 3 ] || fail "without CAP_DAC_READ_SEARCH the run exited $status, not 3 (a file it could not read): $(cat ${build}/nocap.log)"
        only ",+dac_read_search" env CREDENTIALS_DIRECTORY="$creds" CACHE_DIRECTORY=${build}/cache-file "$fileScript" ||
          fail "the backup from the file, with CAP_DAC_READ_SEARCH alone, failed: $(cat ${build}/server.log)"
        [ "$(local_repo snapshots --json | jq length)" = 4 ] || fail "the backup from the file made no snapshot"
        [ "$(local_repo dump latest ${home}/doc/locked)" = locked ] || fail "the file of mode 200 is not in the snapshot"
        meta=$(local_repo ls --json latest ${home}/doc/locked | jq -c 'select(.path == "${home}/doc/locked") | [.mode, .uid]')
        [ "$meta" = "[$((8#200)),$(only "" stat -c %u ${home}/doc/locked)]" ] || fail "the file's mode and owner are not kept: $meta"
        [ -n "$(ls -A ${build}/cache-file)" ] || fail "restic's cache is not in CACHE_DIRECTORY"
        chmod 600 ${home}/doc/locked
        [ "$(wc -l <"$FAKE_RBW_LOG")" = "$rbw_calls" ] || fail "the backup from the file asked rbw"
        one_line_failure() { # WHAT, then the command
          what=$1
          shift
          status=0
          "$@" 2>${build}/file.log || status=$?
          [ "$status" = 1 ] || fail "$what: exit $status, not 1"
          [ "$(wc -l <${build}/file.log)" = 1 ] || fail "$what: not one line: $(cat ${build}/file.log)"
          grep -q ${secretsFile} ${build}/file.log || fail "$what: the line does not name the file: $(cat ${build}/file.log)"
        }
        one_line_failure "no credential" env -u CREDENTIALS_DIRECTORY "$fileScript"
        chmod 000 "$creds/ravnix-backup"
        one_line_failure "an unreadable credential" env CREDENTIALS_DIRECTORY="$creds" "$fileScript"
        chmod 600 "$creds/ravnix-backup"
        printf 'repository=repository-secret\n' >"$creds/ravnix-backup"
        one_line_failure "a credential without the login" env CREDENTIALS_DIRECTORY="$creds" "$fileScript"
        printf 'login=login-secret\n' >"$creds/ravnix-backup"
        one_line_failure "a credential without the repository password" env CREDENTIALS_DIRECTORY="$creds" "$fileScript"
        [ "$(local_repo snapshots --json | jq length)" = 4 ] || fail "a failed run from the file made a snapshot"

        # The root step: root's file, mode 600, and nothing else.
        [ -x "$fileCheck" ] || fail "the root step is not a program: $fileCheck"
        secrets=${build}/secrets-file
        printf 'repository=x\nlogin=y\n' >"$secrets"
        chmod 600 "$secrets"
        only "" "$fileCheck" "$secrets" || fail "the root step refuses a file of root's with mode 600"
        for case in "owner:600:" "root:644:only"; do
          IFS=: read -r who mode wrap <<<"$case"
          chmod "$mode" "$secrets"
          status=0
          if [ -n "$wrap" ]; then
            only "" "$fileCheck" "$secrets" 2>${build}/check.log || status=$?
          else
            "$fileCheck" "$secrets" 2>${build}/check.log || status=$?
          fi
          [ "$status" = 1 ] || fail "the root step passes a file of $who with mode $mode (exit $status)"
          [ "$(wc -l <${build}/check.log)" = 1 ] && grep -q "$secrets" ${build}/check.log ||
            fail "the root step's refusal is not one line naming the file: $(cat ${build}/check.log)"
        done
        [ "$(wc -l <"$FAKE_RBW_LOG")" = "$rbw_calls" ] || fail "a failed run from the file fell back to rbw"

        # The setup command, as documented, with the default path moved into
        # the build directory and the template's item names: it writes the
        # file, mode 600, that the run and the root step take; a locked
        # vault, an item rbw cannot get or one without a password leave the
        # file as it was and nothing beside it, and the command fails.
        setup=${build}/setup
        sed -e "s|/var/lib/ravnix|$setup/ravnix|g" \
          -e 's|<passwordItem>|${nas.passwordItem}|' -e 's|<loginItem>|${nas.loginItem}|' \
          ${setupScript} >${build}/setup.sh
        grep -q "$setup/ravnix/backup-secrets" ${build}/setup.sh || fail "the setup command does not write ${secretsFile}"
        run_setup() {
          PATH=${fakeSudo}/bin:${fakeRbw}/bin:$PATH FAKE_RBW_LOG=${build}/setup-rbw.log bash ${build}/setup.sh 2>${build}/setup.log
        }
        printf 'repository-secret\n' >${build}/login
        FAKE_RBW_LOGIN=${build}/login FAKE_RBW_LOCKED=${build}/no-lock run_setup ||
          fail "the setup command failed: $(cat ${build}/setup.log)"
        written=$setup/ravnix/backup-secrets
        [ "$(stat -c %a "$written")" = 600 ] || fail "the setup command wrote mode $(stat -c %a "$written"), not 600"
        [ "$(stat -c %a "$setup/ravnix")" = 700 ] || fail "the setup command's directory is not mode 700"
        [ "$(cat "$written")" = "$(printf 'repository=repository-secret\nlogin=repository-secret')" ] ||
          fail "the setup command wrote something else than the two lines: $(od -c "$written" | head -5)"
        only "" "$fileCheck" "$written" || fail "the root step refuses what the setup command wrote"
        printf 'old\n' >"$written"
        for case in locked:${build}/login:${build}/lock missing:${build}/no-login:${build}/no-lock empty:${build}/empty:${build}/no-lock; do
          IFS=: read -r what login lock <<<"$case"
          : >${build}/empty
          touch ${build}/lock
          status=0
          FAKE_RBW_LOGIN=$login FAKE_RBW_LOCKED=$lock run_setup || status=$?
          [ "$status" != 0 ] || fail "the setup command succeeds with a $what login"
          [ "$(cat "$written")" = old ] || fail "the setup command replaced the file with a $what login"
          [ "$(ls -A "$setup/ravnix")" = backup-secrets ] || fail "the setup command left $(ls -A "$setup/ravnix") with a $what login"
        done

        kill "$server"
        touch $out
      ''
  )
