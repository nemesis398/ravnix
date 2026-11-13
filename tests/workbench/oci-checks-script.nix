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
#   - It refuses a container that is not the throwaway project's.
{ pkgs, ... }:
let
  script = ./oci/docker-checks.sh;
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
    case "$*" in
    "readlink /proc/1/exe") echo /nix/store/00000000000000000000000000000000-systemd-262/lib/systemd/systemd ;;
    "cat /proc/1/cgroup") echo "0::/init.scope" ;;
    *"systemctl is-system-running") echo running ;;
    esac
    exit 0
  '';
  # The loops of the script wait five seconds between tries; here a try is
  # a call of the fake, and the waits are not.
  fakeSleep = pkgs.writeShellScript "sleep" "exit 0";
in
pkgs.runCommand "workbench-oci-checks-script" { } ''
  status=0
  fail() {
    echo "FAIL: $*" >&2
    status=1
  }
  mkdir bin
  cp ${fakeDocker} bin/docker
  cp ${fakeSleep} bin/sleep
  export PATH=$PWD/bin:$PATH
  run() { # NAME [VAR=VALUE ...]: the script against a fresh fake, its output in NAME.out
    local name=$1
    shift
    mkdir "$name"
    if env FAKE_DIR="$PWD/$name" "$@" bash ${script} ravnix-muninn-test-muninn-1 /nix/store/odin 1 >"$name.out" 2>&1; then
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

  # The key: it goes where the image's sshd reads keys, as root, and out again.
  keys=/etc/ssh/authorized_keys.d/alice
  grep -q "tee -a $keys\$" booting/exec.log || fail "the login key is not put into $keys: $(grep -n 'authorized_keys' booting/exec.log)"
  grep -q "sed -i .* $keys\$" booting/exec.log || fail "the login key is not taken out of $keys at the end"
  [ "$(grep -n "tee -a $keys\$" booting/exec.log | cut -d: -f1)" -lt "$(grep -n "sed -i .* $keys\$" booting/exec.log | cut -d: -f1 | tail -1)" ] ||
    fail "the key is taken out of $keys before it is put in"

  # Another container: nothing is run in it.
  run other FAKE_PROJECT=someone-else
  [ "$(cat other.status)" = 2 ] || fail "a container of another project was not refused (status $(cat other.status))"
  [ ! -e other/exec.log ] || fail "the script ran commands in a container of another project: $(cat other/exec.log)"

  [ "$status" = 0 ] || { cat booting.out >&2; exit 1; }
  touch "$out"
''
