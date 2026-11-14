# The host's backup to the NAS (modules/common/backup.nix), without a VM:
#
# - The exclude patterns (modules/common/backup-excludes.nix): an excluded
#   directory with a path kept inside it becomes the steps restic needs, in
#   restic's order, for one level and for several, for two kept paths in
#   one directory and for a kept path inside another; the other excludes
#   follow unchanged. A kept path inside no plain exclude, and a backup path
#   inside an exclude, are refused by name.
# - The evaluated home-manager configuration: no unit and no timer without
#   ravnix.backup.nas; with it, a oneshot unit that restarts after a failure
#   but not after restic's exit 3, and a timer; the problems above as
#   assertions that home-manager refuses; and no secret, `forget`, `prune` or `init` in the script.
# - The script itself, run against a real rest-server on loopback with the
#   flags of deploy/compose/restic (`--append-only --private-repos` and the
#   logins), and a stand-in for rbw:
#   the snapshot carries the host name of the option, not the machine's;
#   the carved-back folder is in it with everything below, the rest of the
#   excluded directory, ~/.cache and a CACHEDIR.TAG directory are not; a
#   second run adds a snapshot; the host's login cannot forget it, and
#   cannot read another host's repository; with the vault locked the run
#   exits 75 and starts no restic; with a login item without a user name it
#   says so.
{
  self,
  inputs,
  pkgs,
  lib,
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

  nas = {
    repository = "rest:http://127.0.0.1:${toString port}/huginn/";
    host = "huginn";
    passwordItem = "Restic - huginn repository";
    loginItem = "Restic - huginn login";
    exclude = [
      "~/Nextcloud"
      "*.iso"
    ];
    keep = [ "~/Nextcloud/notes" ];
  };

  # The version only answers rbw.nix's check for an agent that serves SSH.
  fakeRbw =
    (pkgs.writeShellScriptBin "rbw" ''
      # A stand-in for rbw: the vault is locked when $FAKE_RBW_LOCKED exists,
      # and every call is logged without its secret.
      echo "rbw $*" >>"$FAKE_RBW_LOG"
      case "$1" in
        unlocked) [ ! -e "$FAKE_RBW_LOCKED" ] ;;
        get)
          case "$*" in
            "get --field username -- Restic - huginn login") cat "$FAKE_RBW_USER" ;;
            "get -- Restic - huginn login") echo login-secret ;;
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
    ]).config;
  on = configWith nas;
  off = (hm [ ]).config;
  # home-manager refuses a configuration whose assertions fail, as a host
  # build does; the message is the one problemsOf gives, checked below.
  refused = value: !(builtins.tryEval (builtins.seq (configWith value).home.packages true)).success;

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
    ) "the script does not pin the snapshot's host";
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
          ${home}/project/target ${home}/doc
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

        export FAKE_RBW_LOG=${build}/rbw.log FAKE_RBW_LOCKED=${build}/locked FAKE_RBW_USER=${build}/user
        echo huginn >"$FAKE_RBW_USER"
        ${backup}/bin/ravnix-backup || fail "the backup failed: $(cat ${build}/server.log)"
        ${backup}/bin/ravnix-backup || fail "the second backup failed"

        local_repo() { RESTIC_PASSWORD=repository-secret restic --repo "$data/huginn" --no-cache "$@"; }
        [ "$(local_repo snapshots --json | jq length)" = 2 ] || fail "two runs did not make two snapshots"
        [ "$(local_repo snapshots --json | jq -r '.[].hostname' | sort -u)" = huginn ] ||
          fail "the snapshots carry another host name: $(local_repo snapshots --json | jq -r '.[].hostname')"
        listing=$(local_repo ls latest | sed 's|^${home}||')
        for kept in /Nextcloud/notes/a /Nextcloud/notes/deep/b /doc/d /project; do
          grep -qx "$kept" <<<"$listing" || fail "$kept is not in the snapshot: $listing"
        done
        for gone in /Nextcloud/other /Nextcloud/top /.cache /project/target/built /doc/disk.iso; do
          if grep -qx "$gone" <<<"$listing"; then fail "$gone is in the snapshot"; fi
        done

        # The host appends and never deletes, and reads no other repository.
        export RESTIC_REST_USERNAME=huginn RESTIC_REST_PASSWORD=login-secret RESTIC_PASSWORD=repository-secret
        id=$(local_repo snapshots --json | jq -r '.[0].short_id')
        if restic --repo ${nas.repository} --no-cache forget "$id" >${build}/forget.log 2>&1; then
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

        # A login item without a user name.
        : >"$FAKE_RBW_USER"
        status=0
        ${backup}/bin/ravnix-backup 2>${build}/nouser.log || status=$?
        [ "$status" = 1 ] || fail "a login without a user name exited $status"
        grep -q 'needs a user name and a password' ${build}/nouser.log || fail "the run does not say the login lacks a user name"

        # rbw was asked for the items by name, and the repository password
        # through --password-command.
        grep -qx 'rbw get -- Restic - huginn repository' "$FAKE_RBW_LOG" || fail "the repository password did not come from rbw"
        kill "$server"
        touch $out
      ''
  )
