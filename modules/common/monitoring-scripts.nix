# The programs of the host's monitoring (./monitoring.nix): the Beszel
# agent's start, the Uptime Kuma heartbeat and the backup's age check. Not
# a module: it and the tests call it as
#
#   import ./monitoring-scripts.nix { inherit lib pkgs; } { rbw; ... }
#   => { beszelAgent = { tokenItem }: package;
#        kumaPush = { pushUrlItem; units }: package;
#        backupAgeCheck = { pushUrlItem; maxAgeDays; nas; backup }: package; }
#
# rbw is its program; the other programs have defaults, and a test hands in
# stand-ins. nas is ravnix.backup.nas, and backup what ./backup-script.nix
# returns for it.
#
# Every secret goes from rbw to the program that needs it through a pipe:
# the hub's token to the agent on its standard input (TOKEN_FILE=
# /dev/stdin, which the agent reads once, when it starts), a push URL to
# curl as its configuration on standard input (`-K -`), never as an
# argument, which every process of the host could read in /proc. None is
# exported, and no message prints one. While the vault is locked each
# stops with status 75 before it asks for anything (../workbench/
# unlocked.nix).
{ lib, pkgs }:
{
  rbw,
  restic ? pkgs.restic,
  curl ? pkgs.curl,
  agent ? lib.getExe' pkgs.beszel "beszel-agent",
  systemctl ? "${pkgs.systemd}/bin/systemctl",
  notifySend ? lib.getExe' pkgs.libnotify "notify-send",
  # How long the check waits for the NAS, in seconds. restic retries a
  # backend that does not answer for many minutes, and a laptop away from
  # the NAS's network would keep the check (and the machine) busy as long.
  listTimeout ? 120,
}:
let
  unlocked = what: import ../workbench/unlocked.nix { inherit rbw what; };

  # read_url ITEM sets $url to the item's password, a push URL, or stops.
  # The value is never printed: its last part is the monitor's token.
  # push STATUS MESSAGE sends one beat and returns curl's status.
  pushing = ''
    read_url() {
      local item=$1
      if ! url=$(${rbw} get -- "$item" </dev/null); then
        echo "rbw could not read the item $item" >&2
        exit 1
      fi
      if [[ -z $url ]]; then
        echo "the item $item has no password: the monitor's push URL" >&2
        exit 1
      fi
      # One line, no blank, no quote and no backslash, which curl's
      # configuration would read as the end of the value or an escape, and
      # no query or fragment: Kuma shows the URL with its own query
      # (?status=up&msg=OK&ping=), whose status the beat's would follow,
      # and Kuma would read the two as a list, not as up.
      if [[ $url == *[[:space:]\"\\?#]* || ! $url =~ ^https?://[^/]+/. ]]; then
        echo "the password of the item $item is no push URL (https://HOST/api/push/TOKEN, on one line, without the ?status=... Kuma shows after it); the value is not shown" >&2
        exit 1
      fi
    }
    # -q first: no ~/.curlrc, whose `verbose` would print the URL, token
    # and all, to the journal.
    push() {
      printf 'url = "%s"\n' "$url" |
        curl -q -fsS --max-time 20 -o /dev/null --retry 2 --retry-delay 3 \
          --get --data-urlencode "status=$1" --data-urlencode "msg=$2" -K -
    }
  '';
in
{
  # The agent, started with the hub's token from the vault. The hub's
  # address, its key and the rest come from the unit's environment.
  beszelAgent =
    { tokenItem }:
    pkgs.writeShellApplication {
      name = "ravnix-beszel-agent";
      runtimeInputs = [ ];
      text = ''
        ${unlocked "the hub's token"}
        item=${lib.escapeShellArg tokenItem}
        if ! token=$(${rbw} get -- "$item" </dev/null); then
          echo "rbw could not read the item $item" >&2
          exit 1
        fi
        # The agent skips a line that starts with # as a comment, and would
        # connect without a token.
        if [[ -z $token || $token == *[[:space:]]* || $token == "#"* ]]; then
          echo "the item $item holds no token: its password must be the hub's token, one word on one line, not starting with #" >&2
          exit 1
        fi
        # The agent takes BESZEL_AGENT_X before X, and KEY before KEY_FILE,
        # so a TOKEN, a KEY or any BESZEL_AGENT_ variable in the user
        # manager's environment would win over the unit's; none may come
        # from elsewhere.
        unset TOKEN KEY
        # (The names by expansion: the store's bash has no compgen.)
        for name in "''${!BESZEL_AGENT_@}"; do
          unset "$name"
        done
        export TOKEN_FILE=/dev/stdin
        # The vault was open: this start reaches the agent, so systemd's
        # count of restarts starts over, and a crash days later waits 10 s
        # again, not the longest wait a locked vault ran it up to. A reset
        # while the unit runs changes nothing else (measured with systemd
        # 259: after a reset from inside the run, the next wait was the
        # first step's again). Outside systemd it fails, and that is fine.
        ${systemctl} --user reset-failed beszel-agent.service 2>/dev/null || true
        exec ${agent} "$@" < <(printf '%s\n' "$token")
      '';
    };

  # The heartbeat: `up` with the uptime and the load, or `down` with the
  # watched units that are not active. A beat that does not arrive is the
  # signal, and Uptime Kuma reads it on its side; the exit status is
  # curl's, so the journal has it.
  kumaPush =
    { pushUrlItem, units }:
    pkgs.writeShellApplication {
      name = "kuma-push";
      runtimeInputs = [
        curl
        pkgs.coreutils
      ];
      text = ''
        ${unlocked "the push URL"}
        ${pushing}
        read_url ${lib.escapeShellArg pushUrlItem}
        units=(${lib.escapeShellArgs units})
        failed=""
        for unit in "''${units[@]}"; do
          ${systemctl} --user is-active --quiet -- "$unit" || failed="$failed $unit"
        done
        if [[ -n $failed ]]; then
          # A host that is up while what it runs is down is the silence
          # this beat exists to break, so it carries the units' state.
          status=down
          msg="failed:$failed"
        else
          status=up
          msg="up $(cut -d. -f1 /proc/uptime)s, load $(cut -d' ' -f1 /proc/loadavg)"
        fi
        rc=0
        push "$status" "$msg" || rc=$?
        if ((rc)); then
          echo "the beat did not reach Uptime Kuma (curl exit $rc)" >&2
        fi
        exit "$rc"
      '';
    };

  # The backup's dead man's switch: the age of the host's newest snapshot in
  # its repository on the NAS, read with restic through the backup's own
  # password command and login (read-only, --no-lock, so it writes nothing
  # to the repository), pushed as `up` or `down`. It pushes nothing when it
  # cannot tell; that silence is the monitor's to judge.
  #
  #   0   the newest snapshot is younger than maxAgeDays: `up`
  #   1   it is older, there is none, or the check could not run (restic
  #       refused, its answer unreadable, an item missing): `down` for the
  #       first two, nothing for the rest
  #   69  the NAS did not answer within listTimeout (EX_UNAVAILABLE): the
  #       laptop is away from it, nothing
  #   75  the vault is locked: nothing
  #
  # This is more than the thin glue AGENTS.md rule 4 allows in Bash: it
  # checks restic's JSON, turns RFC 3339 times into seconds, applies the
  # threshold and picks one of three outcomes, the kind of judgement the
  # backup's retention logic was ported to Odin for (tools/ravnix-retention),
  # which this departs from. The maintainer accepted it as Bash glue on
  # 2026-11-16 ("Keep Bash, it's glue"): the logic is small, and every
  # branch is tested against a real rest-server and stand-ins
  # (tests/common/monitoring.nix).
  backupAgeCheck =
    {
      pushUrlItem,
      maxAgeDays,
      nas,
      backup,
    }:
    pkgs.writeShellApplication {
      name = "backup-age-check";
      runtimeInputs = [
        restic
        curl
        pkgs.jq
        pkgs.coreutils
      ];
      text = ''
        ${backup.readLogin}
        ${pushing}
        read_url ${lib.escapeShellArg pushUrlItem}
        host=${lib.escapeShellArg nas.host}
        max_days=${toString maxAgeDays}
        export RESTIC_REPOSITORY=${lib.escapeShellArg nas.repository}
        export RESTIC_PASSWORD_COMMAND=${backup.password}
        listed=0
        json=$(RESTIC_REST_USERNAME=$host RESTIC_REST_PASSWORD=$login \
          timeout ${toString listTimeout} restic --no-lock snapshots --json --host "$host") || listed=$?
        if ((listed == 124)); then
          echo "the NAS did not answer within ${toString listTimeout} s, so restic could not list the snapshots of $host in $RESTIC_REPOSITORY; nothing was pushed" >&2
          exit 69
        elif ((listed)); then
          echo "restic could not list the snapshots of $host in $RESTIC_REPOSITORY (exit $listed); nothing was pushed" >&2
          exit 1
        fi
        unset login
        # Each snapshot's time, as seconds; restic writes RFC 3339 with the
        # offset of the moment, which a comparison of the text would get
        # wrong across a change of the clocks.
        garbage() {
          echo "restic's list of the snapshots of $host is not what restic writes (a JSON list of snapshots, each with its time); nothing was pushed" >&2
          exit 1
        }
        times=$(jq -r 'if type == "array" and all(.[]; type == "object" and (.time | type) == "string")
          then .[].time else error("not a list of snapshots") end' <<<"$json" 2>/dev/null) || garbage
        if [[ -n $times ]]; then
          times=$(date -f - +%s <<<"$times" 2>/dev/null) || garbage
        fi
        now=$(date +%s)
        if [[ -z $times ]]; then
          status=down
          msg="no snapshot of $host on the NAS"
        else
          newest=$(sort -n <<<"$times" | tail -n 1)
          age=$((now - newest))
          when=$(date -d "@$newest" '+%Y-%m-%d %H:%M')
          if ((age >= max_days * 86400)); then
            status=down
            msg="the newest snapshot of $host is $((age / 86400)) days old ($when), more than the $max_days allowed"
          else
            status=up
            msg="the newest snapshot of $host is $((age / 3600)) h old ($when)"
          fi
        fi
        echo "$msg"
        rc=0
        push "$status" "$msg" || rc=$?
        if ((rc)); then
          echo "the result did not reach Uptime Kuma (curl exit $rc)" >&2
        fi
        if [[ $status == down ]]; then
          # On the desktop, a notification that stays, as Fedora's dunst
          # alert did; where no notification daemon answers, nothing.
          timeout 10 ${notifySend} -u critical -a backup "Backup problem" "$msg" 2>/dev/null || true
          exit 1
        fi
      '';
    };
}
