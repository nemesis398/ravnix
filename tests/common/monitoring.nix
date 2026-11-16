# The host's monitoring (modules/common/monitoring.nix and
# modules/common/monitoring-scripts.nix), without a VM:
#
# - The evaluated home-manager configuration: nothing without
#   ravnix.monitoring, not even a stub of ravnix-backup; with it the agent's
#   unit with the hub's address, its key as a file, the system name,
#   DISABLE_SSH, LISTEN on loopback, GPU_COLLECTOR when the machine names
#   one and none when it does not, a restart that waits longer each time
#   and never gives up; the heartbeat's oneshot and its 15-minute timer
#   without Persistent=, whose 75 and no-network statuses are no failure;
#   the check's oneshot, its daily timer with Persistent=, and OnSuccess= on
#   the backup; the check refused without ravnix.backup.nas and with its
#   secrets in the root-only file.
# - No secret in the store: the stand-in for rbw reads its items from files
#   of the build, and none of their values is in the units, the programs or
#   anything they refer to.
# - The agent's start, with a stand-in for the agent and with the real one:
#   a locked vault (75, no agent), an item rbw cannot read, a token with a
#   blank or two lines (refused, not shown); the token on the agent's
#   standard input and in neither its environment nor its arguments, a
#   TOKEN from outside dropped; the real agent reads it from there, and
#   with the hub out of reach it keeps running and trying.
# - The heartbeat, against a stand-in for Uptime Kuma: `up` with the uptime,
#   `down` naming the units that are not active, nothing while the vault is
#   locked; Kuma out of reach and a 404, each with curl's status, the first
#   no failure of the unit and the second one; push URLs that are empty,
#   two lines, with a blank or a quote, or no URL, refused without being
#   shown; the URL never on curl's command line.
# - The check, against a real rest-server with the compose file's flags
#   (append-only, private repositories) and the host's login: no snapshot,
#   a stale one with a fresh one of another host beside it, and a fresh
#   one, each pushed and the first two as a notification too; no lock left
#   in the repository; a locked vault, garbage from restic (no JSON, no
#   list, a snapshot without a time, a time that is no time), the NAS out
#   of reach, each pushing nothing; Kuma out of reach after a fresh
#   snapshot is still 0.
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
  scriptsOf = import ../../modules/common/monitoring-scripts.nix { inherit lib pkgs; };
  backupScriptOf = import ../../modules/common/backup-script.nix { inherit lib pkgs; };

  build = "/build";
  home = "${build}/home";
  restPort = 8011;
  kumaPort = 8012;
  closedPort = 8013;
  compose = ../../deploy/compose/restic/docker-compose.yaml;

  # What the vault holds: rbw reads it from files of the build, so no value
  # is in the store.
  fakeRbw =
    (pkgs.writeShellScriptBin "rbw" ''
      echo "rbw $*" >>"$FAKE_RBW_LOG"
      # A read that standard input could answer: rbw would hand it to its
      # pinentry, or wait on a terminal.
      if [ "$1" = get ] && IFS= read -r -t 1 line && [ -n "$line" ]; then
        echo "rbw $* with standard input" >>"$FAKE_RBW_LOG"
      fi
      case "$1" in
        unlocked | unlock) [ ! -e "$FAKE_RBW_LOCKED" ] ;;
        get)
          shift
          [ "$1" = -- ] && shift
          if [ -f "$FAKE_RBW_ITEMS/$1" ]; then cat "$FAKE_RBW_ITEMS/$1"; else
            echo "rbw: no item: $1" >&2
            exit 1
          fi ;;
        *) exit 2 ;;
      esac
    '')
    // {
      version = "1.14.0";
    };
  rbw = "${fakeRbw}/bin/rbw";

  beszel = {
    hubUrl = "https://hub.example";
    # A key of the right form; the real agent below gets one made in the
    # build.
    hubKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMadeUpForTheTestMadeUpForTheTestMadeUpXy";
    tokenItem = "Beszel - token (test)";
    systemName = "huginn";
  };
  kuma = {
    pushUrlItem = "Kuma - push (test)";
    units = [
      "a.service"
      "b@x.service"
    ];
  };
  backupAge.pushUrlItem = "Kuma - backup push (test)";
  nas = {
    host = "huginn";
    passwordItem = "Restic - huginn repository";
    loginItem = "Restic - huginn login";
  };
  registered = {
    ravnix.hosts.nas.address = lib.mkForce "127.0.0.1";
    ravnix.services.restic-server = {
      enable = true;
      host = "nas";
      port = restPort;
    };
  };

  configWith =
    monitoring: backup:
    (hm [
      {
        home.homeDirectory = lib.mkForce home;
        programs.rbw.package = lib.mkForce fakeRbw;
        ravnix.monitoring = monitoring;
        ravnix.backup.nas = lib.mkForce backup;
      }
      registered
    ]).config;
  on = configWith {
    inherit beszel kuma backupAge;
    gpuCollector = "amd_sysfs";
  } nas;
  noGpu = configWith { inherit beszel; } null;
  off = (hm [ ]).config;
  # The refusals, as a host build makes them: home-manager throws its own
  # failed assertions at once, NixOS lists them (home-manager's among them).
  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };
  refusalsWith =
    backup:
    let
      os = inputs.nixpkgs.lib.nixosSystem {
        inherit system;
        modules = hostModules ++ [
          self.nixosModules.common
          registered
          {
            networking.hostName = "huginn";
            ravnix.monitoring = { inherit backupAge; };
            ravnix.backup.nas = lib.mkForce backup;
          }
        ];
      };
    in
    map (a: a.message) (lib.filter (a: !a.assertion) os.config.assertions);
  withoutNas = refusalsWith null;
  withFile = refusalsWith (nas // { secrets = "file"; });

  services = on.systemd.user.services;
  timers = on.systemd.user.timers;
  agentUnit = services.beszel-agent;
  kumaUnit = services.kuma-push;
  checkUnit = services.backup-age-check;
  env = agentUnit.Service.Environment;
  unitFile = name: on.xdg.configFile."systemd/user/${name}".source;
  unitFiles = map unitFile [
    "beszel-agent.service"
    "kuma-push.service"
    "kuma-push.timer"
    "backup-age-check.service"
    "backup-age-check.timer"
  ];

  # The programs as the tests run them: the module's own where nothing
  # needs a stand-in, the same builder with stand-ins elsewhere.
  fakeAgent = pkgs.writeShellScript "fake-beszel-agent" ''
    printf '%s\n' "$@" >"$FAKE_AGENT/args"
    env >"$FAKE_AGENT/env"
    cat -- "$TOKEN_FILE" >"$FAKE_AGENT/token"
  '';
  fakeSystemctl = pkgs.writeShellScript "fake-systemctl" ''
    # fake-systemctl --user is-active --quiet -- UNIT, or reset-failed
    echo "systemctl $*" >>"$FAKE_SYSTEMCTL_LOG"
    for unit in $FAKE_INACTIVE; do [ "$unit" = "''${!#}" ] && exit 3; done
    exit 0
  '';
  # curl as the scripts run it, with its arguments written down first.
  loggingCurl = pkgs.writeShellScriptBin "curl" ''
    printf '%s\n' "$@" >>"$FAKE_CURL_ARGS"
    echo -- >>"$FAKE_CURL_ARGS"
    # A network that fails the way $FAKE_CURL_EXIT says.
    if [ -n "''${FAKE_CURL_EXIT:-}" ]; then exit "$FAKE_CURL_EXIT"; fi
    exec ${pkgs.curl}/bin/curl "$@"
  '';
  fakeNotify = pkgs.writeShellScript "fake-notify-send" ''
    printf '%s\n' "$*" >>"$FAKE_NOTIFY"
  '';
  # restic that prints what $FAKE_RESTIC_OUT holds, for the garbage.
  fakeRestic = pkgs.writeShellScriptBin "restic" ''
    if [ -n "''${FAKE_RESTIC_AGE:-}" ]; then
      # Just after a second starts, so the check's clock reads the same
      # second: the snapshot is FAKE_RESTIC_AGE seconds old to it.
      while [ "$(date +%N)" -gt 200000000 ]; do sleep 0.05; done
      t=$(date -u -d "@$(($(date +%s) - FAKE_RESTIC_AGE))" +%Y-%m-%dT%H:%M:%SZ)
      printf '[{"time": "%s", "hostname": "huginn"}]\n' "$t"
    else
      cat "$FAKE_RESTIC_OUT"
    fi
  '';
  scripts = scriptsOf {
    inherit rbw;
    agent = fakeAgent;
    curl = loggingCurl;
    systemctl = fakeSystemctl;
    notifySend = fakeNotify;
  };
  nasValue = on.ravnix.backup.nas;
  backupScript = backupScriptOf {
    cfg = nasValue;
    inherit rbw home;
  };
  checkWith =
    restic:
    (scriptsOf {
      inherit rbw;
      curl = loggingCurl;
      notifySend = fakeNotify;
      restic = if restic == null then pkgs.restic else restic;
      listTimeout = 5;
    }).backupAgeCheck
      {
        inherit (backupAge) pushUrlItem;
        maxAgeDays = 3;
        nas = nasValue;
        backup = backupScript;
      };
  agentStart = scripts.beszelAgent { inherit (beszel) tokenItem; };
  kumaPush = scripts.kumaPush { inherit (kuma) pushUrlItem units; };
  check = checkWith null;
  garbageCheck = checkWith fakeRestic;
  closure = pkgs.closureInfo {
    rootPaths = unitFiles ++ [
      agentStart
      kumaPush
      check
      (lib.head (lib.splitString " " (toString agentUnit.Service.ExecStart)))
    ];
  };

  failures =
    lib.optional (lib.any (n: off.systemd.user.services ? ${n}) [
      "beszel-agent"
      "kuma-push"
      "backup-age-check"
      "ravnix-backup"
    ]) "without ravnix.monitoring there is a monitoring unit or a stub of ravnix-backup"
    ++ lib.optional (lib.any (n: off.systemd.user.timers ? ${n}) [
      "kuma-push"
      "backup-age-check"
    ]) "without ravnix.monitoring there is a monitoring timer"
    ++ lib.optional (noGpu.systemd.user.services ? kuma-push) "the agent alone brings the heartbeat"
    ++ lib.optional (noGpu.systemd.user.services ? backup-age-check) "the agent alone brings the check"
    # The agent.
    ++ map (want: "the agent's environment lacks ${want}: ${builtins.toJSON env}") (
      lib.filter (want: !lib.elem want env) [
        "HUB_URL=https://hub.example"
        "SYSTEM_NAME=huginn"
        "DISABLE_SSH=true"
        "LISTEN=127.0.0.1:45876"
        "DATA_DIR=%S/beszel-agent"
        "GPU_COLLECTOR=amd_sysfs"
      ]
    )
    ++ lib.optional (lib.any (lib.hasPrefix "GPU_COLLECTOR=") noGpu.systemd.user.services.beszel-agent.Service.Environment) "without a collector of the machine's the unit names one"
    ++ lib.optional (
      !lib.any (lib.hasPrefix "KEY_FILE=${builtins.storeDir}/") env
    ) "the hub's key is not a file in the store"
    ++ lib.optional (lib.any (
      e: lib.hasPrefix "KEY=" e || lib.hasPrefix "TOKEN" e
    ) env) "the unit sets KEY or TOKEN itself"
    ++ lib.optional (
      agentUnit.Service.Restart != "on-failure"
    ) "the agent is not started again after a failure"
    ++ lib.optional (
      agentUnit.Service.RestartSteps or null == null
      || agentUnit.Service.RestartMaxDelaySec or null != "5min"
    ) "the agent's restarts do not wait longer each time, up to 5 minutes"
    ++ lib.optional (
      agentUnit.Unit.StartLimitIntervalSec or null != 0
    ) "the agent gives up after a few starts while the vault is locked"
    ++ lib.optional (agentUnit.Service ? StateDirectory) "the agent's unit has a StateDirectory="
    ++ lib.optional (
      agentUnit.Install.WantedBy != [ "default.target" ]
    ) "the agent is not started with the user's manager"
    # The heartbeat.
    ++ lib.optional (kumaUnit.Service.Type != "oneshot") "the heartbeat is not a oneshot"
    ++ lib.optional (
      kumaUnit.Service.SuccessExitStatus != "6 7 28 35 52 56 60 75"
    ) "the heartbeat's calm statuses are not 6 7 28 35 52 56 60 75"
    ++ lib.optional (kumaUnit.Service.TimeoutStartSec or null != "2min") "the heartbeat has no start timeout of 2 minutes"
    ++ lib.optional (checkUnit.Service.TimeoutStartSec or null != "5min") "the check has no start timeout of 5 minutes"
    ++ lib.optional (checkUnit.Service.SuccessExitStatus or null != "69 75") "the check's calm statuses are not 69 75 (the NAS out of reach, the vault locked)"
    ++ lib.optional (
      !lib.hasSuffix "/bin/kuma-push" (toString kumaUnit.Service.ExecStart)
    ) "the heartbeat's unit does not run kuma-push"
    ++ lib.optional (
      timers.kuma-push.Timer != {
        OnStartupSec = "1min";
        OnUnitActiveSec = "900s";
        AccuracySec = "10s";
      }
    ) "the heartbeat's timer is not Fedora's: ${builtins.toJSON timers.kuma-push.Timer}"
    ++ lib.optional (
      timers.kuma-push.Install.WantedBy != [ "timers.target" ]
    ) "the heartbeat's timer is not started"
    # The check.
    ++ lib.optional (checkUnit.Service.Type != "oneshot") "the check is not a oneshot"
    ++ lib.optional (checkUnit.Service ? Restart) "the check is started again"
    ++ lib.optional (
      !lib.hasSuffix "/bin/backup-age-check" (toString checkUnit.Service.ExecStart)
    ) "the check's unit does not run backup-age-check"
    ++ lib.optional (
      timers.backup-age-check.Timer != {
        OnStartupSec = "3min";
        OnCalendar = "daily";
        Persistent = true;
      }
    ) "the check's timer is not Fedora's: ${builtins.toJSON timers.backup-age-check.Timer}"
    ++ lib.optional (
      services.ravnix-backup.Unit.OnSuccess or null != [ "backup-age-check.service" ]
    ) "a successful backup does not start the check"
    ++ lib.optional (
      (services.ravnix-backup.Service.ExecStart or [ ]) == [ ]
    ) "the backup's unit lost its ExecStart"
    ++ lib.optional (
      !lib.any (lib.hasInfix "ravnix.backup.nas is not") withoutNas
    ) "the check without a backup is not refused: ${builtins.toJSON withoutNas}"
    ++ lib.optional (
      !lib.any (lib.hasInfix "secrets = \"rbw\"") withFile
    ) "the check with the backup's secrets in the file is not refused: ${builtins.toJSON withFile}";
in
pkgs.runCommand "common-monitoring"
  {
    nativeBuildInputs = [
      pkgs.restic
      pkgs.restic-rest-server
      pkgs.mkpasswd
      pkgs.curl
      pkgs.yq-go
      pkgs.python3
      pkgs.openssh
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
        mkdir -p ${home}
        export HOME=${home}
        export FAKE_RBW_LOG=${build}/rbw.log FAKE_RBW_LOCKED=${build}/locked FAKE_RBW_ITEMS=${build}/items
        export FAKE_CURL_ARGS=${build}/curl.args FAKE_NOTIFY=${build}/notify FAKE_AGENT=${build}/agent
        export FAKE_SYSTEMCTL_LOG=${build}/systemctl.log
        : >"$FAKE_SYSTEMCTL_LOG"
        # A user's curlrc that would print every request, the token in its
        # path among it, to the journal.
        mkdir -p ${home}/.config
        echo verbose | tee ${home}/.curlrc >${home}/.config/.curlrc
        export XDG_CONFIG_HOME=${home}/.config
        mkdir -p "$FAKE_RBW_ITEMS" "$FAKE_AGENT"
        item() { printf '%s\n' "$2" >"$FAKE_RBW_ITEMS/$1"; }
        locked() { touch "$FAKE_RBW_LOCKED"; }
        unlocked() { rm -f "$FAKE_RBW_LOCKED"; }
        # run NAME PROGRAM...: its status in $status, its stderr in NAME.err.
        # Standard input has an answer waiting, as a terminal might.
        run() {
          local name=$1
          shift
          status=0
          "$@" >${build}/$name.out 2>${build}/$name.err < <(echo typed-answer) || status=$?
        }
        calm_of() { echo " $(sed -n 's/^SuccessExitStatus=//p' "$1") "; }
        token=beszel-token-secret-1f3a
        kuma_token=kuma-token-secret-7c2e
        age_token=age-token-secret-9b4d
        item ${lib.escapeShellArg beszel.tokenItem} "$token"
        item ${lib.escapeShellArg kuma.pushUrlItem} "http://127.0.0.1:${toString kumaPort}/api/push/$kuma_token"
        item ${lib.escapeShellArg backupAge.pushUrlItem} "http://127.0.0.1:${toString kumaPort}/api/push/$age_token"
        item ${lib.escapeShellArg nas.passwordItem} repository-secret-5e6f
        item ${lib.escapeShellArg nas.loginItem} login-secret-8a9b

        # No secret anywhere in the store paths of the units and programs.
        printf '%s\n' "$token" "$kuma_token" "$age_token" repository-secret-5e6f login-secret-8a9b >${build}/secrets
        [ "$(wc -l <${closure}/store-paths)" -gt 5 ] || fail "the closure is too small to be the programs'"
        if found=$(xargs grep -rlF -f ${build}/secrets <${closure}/store-paths); then fail "a secret is in $found"; fi

        # Kuma.
        kuma_log=${build}/kuma.log
        python3 ${./helpers/kuma-server.py} ${toString kumaPort} "$kuma_log" ${build}/kuma.code &
        for _ in $(seq 100); do
          curl -s -o /dev/null http://127.0.0.1:${toString kumaPort}/ready && break
          sleep 0.1
        done
        : >"$kuma_log"
        beats() { wc -l <"$kuma_log"; }

        # The agent's start.
        locked
        run agent-locked ${agentStart}/bin/ravnix-beszel-agent
        [ "$status" = 75 ] || fail "with the vault locked the agent's start exited $status, not 75"
        grep -q 'vault is locked' ${build}/agent-locked.err || fail "the locked start does not say why: $(cat ${build}/agent-locked.err)"
        [ ! -e "$FAKE_AGENT/env" ] || fail "with the vault locked the agent was started"
        unlocked
        # The agent reads a line that starts with # as a comment, and would
        # connect without a token.
        for bad in "bad-word-1 bad-word-2" "$(printf 'bad-line-1\nbad-line-2')" "" "#bad-commented-token"; do
          printf '%s\n' "$bad" >"$FAKE_RBW_ITEMS/"${lib.escapeShellArg beszel.tokenItem}
          run agent-bad ${agentStart}/bin/ravnix-beszel-agent
          [ "$status" = 1 ] || fail "the token '$bad' gave $status, not 1"
          [ ! -e "$FAKE_AGENT/env" ] || fail "the token '$bad' started the agent"
          if [ -n "$bad" ] && grep -qF -- "$bad" ${build}/agent-bad.err; then fail "the refusal shows the token"; fi
        done
        rm "$FAKE_RBW_ITEMS/"${lib.escapeShellArg beszel.tokenItem}
        run agent-missing ${agentStart}/bin/ravnix-beszel-agent
        [ "$status" = 1 ] || fail "an item rbw cannot read gave $status, not 1"
        grep -qF ${lib.escapeShellArg beszel.tokenItem} ${build}/agent-missing.err || fail "the failure does not name the item"
        item ${lib.escapeShellArg beszel.tokenItem} "$token"
        [ ! -s "$FAKE_SYSTEMCTL_LOG" ] || fail "a start that did not reach the agent reset its restarts: $(cat "$FAKE_SYSTEMCTL_LOG")"
        TOKEN=stale BESZEL_AGENT_TOKEN=stale BESZEL_AGENT_TOKEN_FILE=/nowhere \
          KEY=stale-key BESZEL_AGENT_KEY=stale-key BESZEL_AGENT_HUB_URL=http://stale.example BESZEL_AGENT_ANY=stale \
          run agent ${agentStart}/bin/ravnix-beszel-agent --an-argument
        [ "$status" = 0 ] || fail "the agent's start failed ($status): $(cat ${build}/agent.err)"
        [ "$(cat "$FAKE_AGENT/token")" = "$token" ] || fail "the agent read '$(cat "$FAKE_AGENT/token")' from TOKEN_FILE, not the token"
        grep -qx 'TOKEN_FILE=/dev/stdin' "$FAKE_AGENT/env" || fail "TOKEN_FILE is not the agent's standard input"
        if grep -qE '^(BESZEL_AGENT_)?TOKEN(_FILE)?=(stale|/nowhere)' "$FAKE_AGENT/env"; then fail "a TOKEN from outside reached the agent"; fi
        if grep -qE '^(KEY=|BESZEL_AGENT_)' "$FAKE_AGENT/env"; then fail "a KEY or BESZEL_AGENT_ variable from outside reached the agent: $(grep -E '^(KEY=|BESZEL_AGENT_)' "$FAKE_AGENT/env")"; fi
        grep -qx 'systemctl --user reset-failed beszel-agent.service' "$FAKE_SYSTEMCTL_LOG" ||
          fail "the start that reached the agent did not reset its restarts: $(cat "$FAKE_SYSTEMCTL_LOG")"
        if grep -qF -- "$token" "$FAKE_AGENT/env" "$FAKE_AGENT/args"; then fail "the token is in the agent's environment or arguments"; fi
        [ "$(cat "$FAKE_AGENT/args")" = --an-argument ] || fail "the agent's arguments are not passed on: $(cat "$FAKE_AGENT/args")"

        # The real agent, as its unit starts it, with a hub that is not there.
        ssh-keygen -q -t ed25519 -N "" -f ${build}/hub
        (
          ${lib.concatMapStringsSep "\n" (e: "export ${lib.escapeShellArg e}") (
            lib.filter (e: !(lib.hasPrefix "DATA_DIR=" e || lib.hasPrefix "KEY_FILE=" e)) env
          )}
          export HUB_URL=http://127.0.0.1:${toString closedPort} KEY_FILE=${build}/hub.pub DATA_DIR=${build}/agent-data
          run real-agent timeout 5 ${(toString agentUnit.Service.ExecStart)}
          [ "$status" = 124 ] || fail "the real agent stopped ($status) with the hub out of reach: $(cat ${build}/real-agent.err)"
        ) || exit 1
        grep -q 'WebSocket connection failed' ${build}/real-agent.err || fail "the real agent did not try the hub: $(cat ${build}/real-agent.err)"
        if grep -qi 'must set TOKEN\|Error creating WebSocket' ${build}/real-agent.err; then fail "the real agent got no token: $(cat ${build}/real-agent.err)"; fi
        [ -s ${build}/agent-data/fingerprint ] || fail "the real agent wrote no fingerprint to DATA_DIR"

        # The heartbeat.
        run kuma ${kumaPush}/bin/kuma-push
        [ "$status" = 0 ] || fail "the beat failed ($status): $(cat ${build}/kuma.err)"
        IFS=$'\t' read -r path beat msg < <(tail -n 1 "$kuma_log")
        [ "$path" = "/api/push/$kuma_token" ] || fail "the beat went to $path"
        [ "$beat" = up ] || fail "the beat with every unit active says $beat"
        [[ $msg =~ ^up\ [0-9]+s,\ load\ [0-9.]+$ ]] || fail "the beat's message is '$msg'"
        FAKE_INACTIVE="b@x.service" run kuma-down ${kumaPush}/bin/kuma-push
        [ "$status" = 0 ] || fail "the down beat failed ($status)"
        IFS=$'\t' read -r path beat msg < <(tail -n 1 "$kuma_log")
        [ "$beat" = down ] && [ "$msg" = "failed: b@x.service" ] || fail "an inactive unit gives '$beat' '$msg'"
        if grep -qF -- "$kuma_token" "$FAKE_CURL_ARGS"; then fail "the push URL is on curl's command line: $(cat "$FAKE_CURL_ARGS")"; fi
        n=$(beats)
        locked
        run kuma-locked ${kumaPush}/bin/kuma-push
        [ "$status" = 75 ] || fail "with the vault locked the beat exited $status, not 75"
        [ "$(beats)" = "$n" ] || fail "a locked vault sent a beat"
        unlocked
        calm=$(calm_of ${unitFile "kuma-push.service"})
        [[ $calm == *" 75 "* ]] || fail "75 is a failure of the heartbeat's unit: $calm"
        # A network that drops, resolves nothing, times out, breaks the TLS
        # handshake, answers nothing, resets, or a captive portal's
        # certificate: curl's status, and no failure of the unit.
        for code in 6 7 28 35 52 56 60; do
          FAKE_CURL_EXIT=$code run kuma-flaky ${kumaPush}/bin/kuma-push
          [ "$status" = "$code" ] || fail "curl's $code gave $status"
          [[ $calm == *" $code "* ]] || fail "curl's $code fails the heartbeat's unit ($calm)"
        done
        echo 404 >${build}/kuma.code
        run kuma-404 ${kumaPush}/bin/kuma-push
        [ "$status" = 22 ] || fail "a 404 gave $status, not curl's 22"
        [[ $calm != *" $status "* ]] || fail "a 404 is no failure of the unit"
        rm ${build}/kuma.code
        good_url=$(cat "$FAKE_RBW_ITEMS/"${lib.escapeShellArg kuma.pushUrlItem})
        item ${lib.escapeShellArg kuma.pushUrlItem} "http://127.0.0.1:${toString closedPort}/api/push/$kuma_token"
        run kuma-away ${kumaPush}/bin/kuma-push
        [ "$status" = 7 ] || fail "Kuma out of reach gave $status, not curl's 7"
        [[ $calm == *" $status "* ]] || fail "Kuma out of reach fails the unit"
        grep -q 'did not reach' ${build}/kuma-away.err || fail "the beat does not say it did not arrive"
        n=$(beats)
        # Kuma shows the URL with its own query (?status=up&msg=OK&ping=),
        # which the beat's would follow.
        for bad in "" "$(printf '%s\n%s' "$good_url" "$good_url")" "$good_url x" "$good_url\"" "ftp://h/x" "not-a-url" \
          "$good_url?status=up&msg=OK&ping=" "$good_url#part"; do
          printf '%s\n' "$bad" >"$FAKE_RBW_ITEMS/"${lib.escapeShellArg kuma.pushUrlItem}
          run kuma-bad ${kumaPush}/bin/kuma-push
          [ "$status" = 1 ] || fail "the push URL '$bad' gave $status, not 1"
          if grep -qF -- "$kuma_token" ${build}/kuma-bad.err; then fail "the refusal shows the push URL"; fi
        done
        [ "$(beats)" = "$n" ] || fail "a bad push URL sent a beat"
        item ${lib.escapeShellArg kuma.pushUrlItem} "$good_url"

        # The check, against the NAS's rest-server.
        data=${build}/data
        mkdir -p "$data"
        echo "huginn:$(mkpasswd -m bcrypt login-secret-8a9b)" >${build}/htpasswd
        RESTIC_PASSWORD=repository-secret-5e6f restic init -q --repo "$data/huginn"
        mapfile -t flags < <(yq '.services.rest-server.command[]' ${compose})
        args=()
        for flag in "''${flags[@]}"; do
          case "$flag" in
            --path=/data) args+=("--path=$data") ;;
            --htpasswd-file=/etc/rest-server/htpasswd) args+=("--htpasswd-file=${build}/htpasswd") ;;
            --listen=*) args+=("--listen=127.0.0.1:${toString restPort}") ;;
            *) args+=("$flag") ;;
          esac
        done
        [[ " ''${args[*]} " == *" --append-only "* ]] || fail "the compose file's rest-server is not append-only: ''${args[*]}"
        rest-server "''${args[@]}" >${build}/server.log 2>&1 &
        server=$!
        for _ in $(seq 100); do
          curl -s -o /dev/null http://127.0.0.1:${toString restPort}/ && break
          sleep 0.1
        done
        local_repo() { RESTIC_PASSWORD=repository-secret-5e6f restic --repo "$data/huginn" --no-cache "$@"; }
        mkdir -p ${build}/src && echo x >${build}/src/x
        snapshot() { # HOST, AGE in hours
          local_repo backup -q --host "$1" --time "$(date -d "-$2 hours" '+%Y-%m-%d %H:%M:%S')" ${build}/src
        }
        last_beat() { IFS=$'\t' read -r path beat msg < <(tail -n 1 "$kuma_log"); }
        notes() { wc -l <"$FAKE_NOTIFY" 2>/dev/null || echo 0; }

        run age-empty ${check}/bin/backup-age-check
        [ "$status" = 1 ] || fail "no snapshot gave $status, not 1: $(cat ${build}/age-empty.err)"
        last_beat
        [ "$path" = "/api/push/$age_token" ] || fail "the check pushed to $path"
        [ "$beat" = down ] && [ "$msg" = "no snapshot of huginn on the NAS" ] || fail "no snapshot gives '$beat' '$msg'"
        [ "$(notes)" = 1 ] || fail "no snapshot made no notification"

        snapshot huginn 100
        snapshot muninn 1
        run age-stale ${check}/bin/backup-age-check
        [ "$status" = 1 ] || fail "a stale snapshot gave $status, not 1: $(cat ${build}/age-stale.err)"
        last_beat
        [ "$beat" = down ] && [[ $msg == "the newest snapshot of huginn is 4 days old ("*"), more than the 3 allowed" ]] ||
          fail "a stale snapshot beside another host's fresh one gives '$beat' '$msg'"
        [ "$(notes)" = 2 ] || fail "a stale snapshot made no notification"

        snapshot huginn 2
        run age-fresh ${check}/bin/backup-age-check
        [ "$status" = 0 ] || fail "a fresh snapshot gave $status: $(cat ${build}/age-fresh.err)"
        last_beat
        [ "$beat" = up ] && [[ $msg == "the newest snapshot of huginn is 2 h old ("*")" ]] || fail "a fresh snapshot gives '$beat' '$msg'"
        grep -qF "$msg" ${build}/age-fresh.out || fail "the check does not print its result"
        [ "$(notes)" = 2 ] || fail "a fresh snapshot made a notification"
        [ -z "$(ls -A "$data/huginn/locks")" ] || fail "the check left a lock in the repository"
        # A repository that takes no lock, as while the NAS prunes: the
        # check reads it all the same.
        chmod a-w "$data/huginn/locks"
        run age-nolock ${check}/bin/backup-age-check
        chmod u+w "$data/huginn/locks"
        [ "$status" = 0 ] || fail "the check needs a lock in the repository ($status): $(cat ${build}/age-nolock.err)"
        # A repository password that does not open it: no network trouble,
        # so a failure of the unit.
        item ${lib.escapeShellArg nas.passwordItem} wrong-password
        run age-wrong ${check}/bin/backup-age-check
        item ${lib.escapeShellArg nas.passwordItem} repository-secret-5e6f
        [ "$status" = 1 ] || fail "a wrong repository password gave $status, not 1"
        grep -q 'could not list' ${build}/age-wrong.err || fail "a wrong repository password is not said: $(cat ${build}/age-wrong.err)"
        if grep -qF -- "$age_token" "$FAKE_CURL_ARGS"; then fail "the check's push URL is on curl's command line"; fi

        n=$(beats)
        locked
        rbw_calls=$(wc -l <"$FAKE_RBW_LOG")
        run age-locked ${check}/bin/backup-age-check
        [ "$status" = 75 ] || fail "with the vault locked the check exited $status, not 75"
        grep -q 'vault is locked' ${build}/age-locked.err || fail "the locked check does not say why"
        if tail -n +$((rbw_calls + 1)) "$FAKE_RBW_LOG" | grep -q '^rbw get'; then fail "the locked check asked rbw for an item"; fi
        unlocked

        export FAKE_RESTIC_OUT=${build}/restic.out
        for garbage in '{not json' '{"a": 1}' '[{"id": "x"}]' '[{"time": 5}]' '[{"time": "yesterday-ish"}]' '[1]'; do
          printf '%s\n' "$garbage" >"$FAKE_RESTIC_OUT"
          run age-garbage ${garbageCheck}/bin/backup-age-check
          [ "$status" = 1 ] || fail "restic's '$garbage' gave $status, not 1"
          grep -q 'not what restic writes' ${build}/age-garbage.err || fail "restic's '$garbage' is not called garbage: $(cat ${build}/age-garbage.err)"
        done
        [ "$(beats)" = "$n" ] || fail "garbage from restic pushed something: $(tail -n 1 "$kuma_log")"
        # maxAgeDays to the second: as old as allowed is too old.
        FAKE_RESTIC_AGE=259200 run age-edge ${garbageCheck}/bin/backup-age-check
        [ "$status" = 1 ] || fail "a snapshot exactly 3 days old gave $status, not 1"
        FAKE_RESTIC_AGE=259199 run age-edge ${garbageCheck}/bin/backup-age-check
        [ "$status" = 0 ] || fail "a snapshot a second younger than 3 days gave $status, not 0"
        printf '[]\n' >"$FAKE_RESTIC_OUT"
        run age-none ${garbageCheck}/bin/backup-age-check
        [ "$status" = 1 ] || fail "an empty list from restic gave $status"
        last_beat
        [ "$beat" = down ] || fail "an empty list from restic pushed '$beat'"
        n=$(beats)

        item ${lib.escapeShellArg backupAge.pushUrlItem} "http://127.0.0.1:${toString closedPort}/api/push/$age_token"
        run age-away ${check}/bin/backup-age-check
        [ "$status" = 0 ] || fail "Kuma out of reach after a fresh snapshot gave $status"
        grep -q 'did not reach' ${build}/age-away.err || fail "the check does not say its result did not arrive"
        item ${lib.escapeShellArg backupAge.pushUrlItem} "http://127.0.0.1:${toString kumaPort}/api/push/$age_token"

        kill "$server"
        wait "$server" 2>/dev/null || true
        started=$(date +%s)
        run age-nas ${check}/bin/backup-age-check
        [ "$status" = 69 ] || fail "the NAS out of reach gave $status, not 69"
        [[ $(calm_of ${unitFile "backup-age-check.service"}) == *" 69 "* ]] || fail "the NAS out of reach fails the check's unit"
        (($(date +%s) - started < 30)) || fail "the check waited $(($(date +%s) - started)) s for the NAS, not its 5"
        grep -q 'did not answer within 5 s' ${build}/age-nas.err || fail "the check does not say the NAS did not answer: $(cat ${build}/age-nas.err)"
        [ "$(beats)" = "$n" ] || fail "the check pushed something without an answer: $(tail -n 3 "$kuma_log")"

        # Across every run: curl read no curlrc (-q first), no token reached
        # a message, and rbw never had standard input to read.
        awk 'NR == 1 || prev == "--" { if ($0 != "-q") bad = 1 } { prev = $0 } END { exit bad }' "$FAKE_CURL_ARGS" ||
          fail "curl was run without -q first: $(head -n 3 "$FAKE_CURL_ARGS")"
        if found=$(grep -lF -e "$kuma_token" -e "$age_token" -e "$token" ${build}/*.err); then fail "a token is in the messages of $found"; fi
        if grep -q 'with standard input' "$FAKE_RBW_LOG"; then fail "rbw had standard input: $(grep 'with standard input' "$FAKE_RBW_LOG")"; fi

        touch $out
      ''
  )
