# tests/workbench/oci/docker-checks.sh, run against a fake docker: what the
# script itself does, which no image is needed to show.
#
#   - It waits for the system before it looks at PID 1. A container that was
#     just made (docker compose up -d, a container made again) first runs the
#     image's entrypoint and stage 2, where /run/current-system and with it
#     the PATH of `docker exec` are not there yet, and PID 1 is in the
#     namespace's root cgroup until systemd moves itself into /init.scope.
#     The fake answers the way such a container did on the Docker host in
#     round 2 (readlink not found, then PID 1 in 0::/, then a bus that is not
#     there) for its first calls, and as a running system after them. With a
#     system that never comes up, the wait ends and the script says so.
#   - The key it logs in with goes where the image's sshd reads keys
#     (/etc/ssh/authorized_keys.d/USER: hosts/server/deploy.nix lets sshd read
#     keys from the configuration alone), and is taken out again at the end.
#     That this is the file the image's sshd reads is the check workbench-oci's.
#     It goes only into the file the system made: root's, mode 444, with the
#     configuration's key in it. A missing file, or one without that key, is
#     a failure and gets no key, since `tee -a` would make the file and the
#     login would pass with no key of the configuration in the container.
#   - A key in the home is refused, and that counts only when the key was
#     made and is in ~/.ssh/authorized_keys: the refusal of a key that is not
#     there proves nothing.
#   - Every probe that waits on a network ends within its bound: the probe of
#     a published port, the one of a container's name on a podman network,
#     and the banner of the published sshd port. Here the first and the last
#     meet a listener that takes the connection and never answers, and the
#     second a container that never ends; the script must report each as a
#     failure, quickly, and not hang.
#   - It refuses a container that is not the throwaway project's.
{ pkgs, ... }:
let
  script = ./oci/docker-checks.sh;
  me = import ../../templates/default/me.nix;
  # What the system writes for the template's user: its signing key, and the
  # laptop's key the way modules/glue/terminal.nix gives it.
  keysFile = pkgs.writeText "alice-keys" ''
    ${me.ravnix.user.signingKey}
    restrict,port-forwarding,pty ${me.ravnix.serverAccess.publicKey}
  '';
  otherKeys = pkgs.writeText "other-keys" ''
    ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAISomeOtherKeyOfNobody x@example.org
  '';
  # One call of the fake at a time is assumed: the script's one pipe of two
  # calls (the key into tee) comes long after the boot point of every case,
  # so the counter's read and write do not race where it matters.
  fakeDocker = pkgs.writeShellScript "docker" ''
    # docker inspect: the label of the project; docker exec: the container.
    case "$1" in
    inspect) echo "''${FAKE_PROJECT:-ravnix-muninn-test}"; exit 0 ;;
    exec) shift ;;
    *) echo "fake docker: unexpected $*" >&2; exit 1 ;;
    esac
    [ "$1" != -i ] || { shift; cat > "$FAKE_DIR/stdin.$$"; }
    shift # the container
    n=$(( $(cat "$FAKE_DIR/count" 2>/dev/null || echo 0) + 1 ))
    echo "$n" > "$FAKE_DIR/count"
    echo "$*" >> "$FAKE_DIR/exec.log"
    [ ! -e "$FAKE_DIR/stdin.$$" ] || { sed 's/^/  stdin: /' "$FAKE_DIR/stdin.$$" >> "$FAKE_DIR/exec.log"; rm "$FAKE_DIR/stdin.$$"; }
    up=''${BOOTED_AFTER:-2}
    if [ "$n" -le "$up" ]; then
      if [ "$n" -lt "$up" ]; then
        # stage 2 has not activated the system: nothing on the PATH
        echo "OCI runtime exec failed: exec failed: unable to start container process: exec: \"$1\": executable file not found in \$PATH" >&2
        exit 127
      fi
      # activated, and systemd is not up yet
      case "$*" in
      "cat /proc/1/cgroup") echo "0::/" ;;
      *systemctl*) echo "Failed to connect to system scope bus via local transport: No such file or directory" >&2; exit 1 ;;
      esac
      exit 0
    fi
    keys=/etc/ssh/authorized_keys.d/alice
    case "$*" in
    "readlink /proc/1/exe") echo /nix/store/00000000000000000000000000000000-systemd-262/lib/systemd/systemd ;;
    "cat /proc/1/cgroup") echo "0::/init.scope" ;;
    *"systemctl is-system-running") echo running ;;
    # the file of the configuration's keys, as the system made it, or not
    *"stat -c %F %U %a $keys")
      if [ -n "''${FAKE_KEYS_MISSING:-}" ]; then
        echo "stat: cannot statx '$keys': No such file or directory" >&2
        exit 1
      fi
      echo "''${FAKE_KEYS_STAT:-regular file root 444}" ;;
    *"cat $keys")
      [ -z "''${FAKE_KEYS_MISSING:-}" ] || exit 1
      cat "''${FAKE_KEYS:-${keysFile}}" ;;
    # the key for the home: made and added only with FAKE_HOME=1; sshd refuses
    # it either way, as it refuses a key that is not there
    *"cut -d"*"id_home.pub"*) [ -z "''${FAKE_HOME:-}" ] || echo AAAAC3NzaC1lZDI1NTE5AAAAIHomeKeyOfTheTest ;;
    *"cat ~/.ssh/authorized_keys"*) [ -z "''${FAKE_HOME:-}" ] || echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHomeKeyOfTheTest ravnix-docker-checks" ;;
    *"test -s ~/.ssh/id_home"*) [ -n "''${FAKE_HOME:-}" ] ;;
    *"-i ~/.ssh/id_home "*) echo "alice@127.0.0.1: Permission denied (publickey)." ;;
    # the probes of the Podman phase: run here for real, as the -c string
    # of su, with a podman that never ends
    *"/dev/tcp/127.0.0.1/18080"* | *"ravnix-checks-srv:8080"*)
      [ -z "''${FAKE_PROBES:-}" ] || exec bash -c "''${!#}" ;;
    esac
  '';
  # The loops of the script wait five seconds between tries; here a try is
  # a call of the fake, and the waits are not. A podman that is asked to run
  # something hangs (the real sleep, by its path).
  fakeSleep = pkgs.writeShellScript "sleep" "exit 0";
  fakePodman = pkgs.writeShellScript "podman" "exec ${pkgs.coreutils}/bin/sleep 1000";
in
pkgs.runCommand "workbench-oci-checks-script" { nativeBuildInputs = [ pkgs.socat ]; } ''
  status=0
  fail() {
    echo "FAIL: $*" >&2
    status=1
  }
  mkdir bin
  cp ${fakeDocker} bin/docker
  cp ${fakeSleep} bin/sleep
  cp ${fakePodman} bin/podman
  export PATH=$PWD/bin:$PATH
  run() { # NAME [VAR=VALUE ...]: the script against a fresh fake, its output in NAME.out
    local name=$1
    shift
    mkdir "$name"
    if env FAKE_DIR="$PWD/$name" "$@" timeout 300 bash ${script} ravnix-muninn-test-muninn-1 /nix/store/odin "''${PORT:-1}" ''${MODE:-} >"$name.out" 2>&1; then
      echo 0 >"$name.status"
    else
      echo $? >"$name.status"
    fi
  }

  # A container that was just made: two calls in stage 2, then the system.
  run booting BOOTED_AFTER=2
  grep -qxF 'PASS: PID 1 is /nix/store/00000000000000000000000000000000-systemd-262/lib/systemd/systemd' booting.out ||
    fail "a container that boots after the script starts: PID 1 was looked at before the system was up: $(grep 'PID 1' booting.out)"
  grep -qxF 'PASS: PID 1 is in 0::/init.scope, in the container'"'"'s own cgroup namespace' booting.out ||
    fail "a container that boots after the script starts: PID 1's cgroup was read before systemd moved into it: $(grep 'PID 1 is in' booting.out)"
  grep -q 'executable file not found' booting.out &&
    fail "a check ran in stage 2, before the PATH was there: $(grep 'executable file not found' booting.out)"
  # It does wait: the first calls were the system's state, asked again.
  [ "$(head -3 booting/exec.log | grep -c 'systemctl is-system-running')" = 3 ] ||
    fail "the script did not begin by waiting for the system: $(head -3 booting/exec.log)"

  # A system that never comes up: the wait ends, and the script says so.
  run never BOOTED_AFTER=100000
  grep -q '^FAIL: the system is ' never.out || fail "a system that never came up was not reported: $(tail -3 never.out)"
  grep -q '^SUMMARY: ' never.out || fail "the script did not finish with a system that never came up"

  # The key: it goes where the image's sshd reads keys, as root, and out
  # again, after the file was shown to be the one the system made.
  keys=/etc/ssh/authorized_keys.d/alice
  grep -q "^PASS: $keys is root's, mode 444, and holds the configuration's key" booting.out ||
    fail "the file of the configuration's keys was not checked before the test key went in: $(grep "$keys" booting.out)"
  grep -q "tee -a $keys\$" booting/exec.log || fail "the login key is not put into $keys: $(grep -n 'authorized_keys' booting/exec.log)"
  grep -q "sed -i .* $keys\$" booting/exec.log || fail "the login key is not taken out of $keys at the end"
  [ "$(grep -n "tee -a $keys\$" booting/exec.log | cut -d: -f1)" -lt "$(grep -n "sed -i .* $keys\$" booting/exec.log | cut -d: -f1 | tail -1)" ] ||
    fail "the key is taken out of $keys before it is put in"

  # A file the system did not make, or made otherwise, or without the
  # configuration's key: a failure, and no key goes in.
  check_keys_refused() { # NAME
    grep -q "^FAIL: $keys is not the configuration's" "$1.out" ||
      fail "$1: a file of keys that is not the system's was not reported: $(grep "$keys" "$1.out")"
    grep -q "tee -a $keys\$" "$1/exec.log" &&
      fail "$1: the test key went into a file of keys that is not the system's"
    grep -q '^PASS: ssh with a key' "$1.out" && fail "$1: the login passed without the configuration's file"
    return 0
  }
  run missing BOOTED_AFTER=0 FAKE_KEYS_MISSING=1
  check_keys_refused missing
  run nokey BOOTED_AFTER=0 FAKE_KEYS=${otherKeys}
  check_keys_refused nokey
  run mode BOOTED_AFTER=0 "FAKE_KEYS_STAT=regular file alice 644"
  check_keys_refused mode

  # The key in the home: refused, and that counts only when it is there.
  run home BOOTED_AFTER=0 FAKE_HOME=1
  grep -q '^PASS: a key in ~/.ssh/authorized_keys is refused' home.out ||
    fail "a key in the home that sshd refused was not reported as refused: $(grep 'authorized_keys' home.out)"
  grep -q '^PASS: a key in ~/.ssh/authorized_keys is refused' booting.out &&
    fail "the refusal of a key that was never put into the home passed"
  grep -q '^FAIL: the key for ~/.ssh/authorized_keys was not made or not added' booting.out ||
    fail "a key that was never put into the home was not reported: $(grep 'authorized_keys' booting.out)"

  # Probes that meet a peer that never answers: each ends within its bound
  # (one second here, through the script's RAVNIX_PROBE_TIMEOUT), and is a
  # failure. The listeners take connections and keep them open, silent.
  socat TCP-LISTEN:18080,bind=127.0.0.1,reuseaddr,fork SYSTEM:'${pkgs.coreutils}/bin/sleep 1000' &
  web=$!
  socat TCP-LISTEN:18022,bind=127.0.0.1,reuseaddr,fork SYSTEM:'${pkgs.coreutils}/bin/sleep 1000' &
  ssh=$!
  for _ in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/18080 && exec 4<>/dev/tcp/127.0.0.1/18022) 2>/dev/null && break; ${pkgs.coreutils}/bin/sleep 0.1; done
  began=$SECONDS
  PORT=18022 MODE=podman run silent BOOTED_AFTER=0 FAKE_PROBES=1 RAVNIX_PROBE_TIMEOUT=1
  took=$((SECONDS - began))
  kill "$web" "$ssh" 2>/dev/null || true
  [ "$(cat silent.status)" != 124 ] || fail "a probe hung: the script was stopped after 300 s"
  [ "$took" -lt 200 ] || fail "the probes took $took s with a bound of one second each"
  grep -q '^FAIL: podman run -p' silent.out || fail "a published port that never answers was not reported: $(grep -- '-p\|18080' silent.out)"
  grep -q '^FAIL: podman network' silent.out || fail "a name probe that never ends was not reported: $(grep 'network' silent.out)"
  grep -q '^FAIL: the published port gives' silent.out || fail "an ssh port that never answers was not reported: $(grep 'published port' silent.out)"

  # The same probes against peers that answer: they pass, so the bound and
  # the quoting around them leave the probe itself working.
  socat TCP-LISTEN:18080,bind=127.0.0.1,reuseaddr,fork SYSTEM:'echo HTTP/1.0 200 OK; echo; echo ravnix-checks-ok' &
  web=$!
  socat TCP-LISTEN:18022,bind=127.0.0.1,reuseaddr,fork SYSTEM:'echo SSH-2.0-OpenSSH_fake; ${pkgs.coreutils}/bin/sleep 1000' &
  ssh=$!
  for _ in $(seq 1 50); do (exec 3<>/dev/tcp/127.0.0.1/18080 && exec 4<>/dev/tcp/127.0.0.1/18022) 2>/dev/null && break; ${pkgs.coreutils}/bin/sleep 0.1; done
  PORT=18022 MODE=podman run answering BOOTED_AFTER=0 FAKE_PROBES=1 RAVNIX_PROBE_TIMEOUT=1
  kill "$web" "$ssh" 2>/dev/null || true
  grep -q '^PASS: a published port of a rootless container' answering.out || fail "a published port that answers was not seen: $(grep -- 'podman run -p' answering.out)"
  grep -q '^PASS: the published port answers from the host: SSH-2.0-OpenSSH_fake' answering.out || fail "an ssh port that answers was not seen: $(grep 'published port' answering.out)"

  # Another container: nothing is run in it.
  run other FAKE_PROJECT=someone-else
  [ "$(cat other.status)" = 2 ] || fail "a container of another project was not refused (status $(cat other.status))"
  [ ! -e other/exec.log ] || fail "the script ran commands in a container of another project: $(cat other/exec.log)"

  [ "$status" = 0 ] || { cat booting.out >&2; exit 1; }
  touch "$out"
''
