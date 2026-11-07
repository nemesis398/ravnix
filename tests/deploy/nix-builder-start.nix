# deploy/compose/nix-builder/start.sh, without a container:
#
# - It checks the variables from .env before it touches anything, and
#   refuses a bad one with a message naming it: an empty key, a key with a
#   second line (one line more in authorized_keys), a key behind options
#   (`restrict ssh-ed25519 …` would replace the forced command's options), a
#   key whose body is not base64, a cache key name with a colon or none at
#   all, a garbage-collection size Nix would not read, and a nixpkgs pin that
#   is no flake reference. `start.sh --check-env` runs only that part.
# - Past the check it refuses to run anywhere but as root in the container
#   the compose file starts, which sets NIX_BUILDER_CONTAINER=1: a build user
#   on the builder, inside that very container, is refused as well.
# - Its steps, sourced and pointed at a scratch tree: links from /etc into
#   the store become files and the store stays as it was; a link into a store
#   path the volume lacks (the image tag changed) is refused by name; a rerun
#   adds no account twice; the build users join the group with the KVM
#   device's gid, a new one or one that exists, once; an image without build
#   users is refused; a signing key with another name than
#   NIX_CACHE_KEY_NAME is refused; nix.conf replaces its link without
#   writing through it.
# - The probe of the egress rule, against real loopback ports: a connect that
#   gets no answer in time is what the rule's DROP looks like, and passes; one
#   that connects or is refused got an answer, and fails, naming the target.
#   The targets are probed at once. `start.sh --probe` runs only that, and
#   checks only its own variables, so the health check can call it.
# - The gate, with the probe and the services stubbed: harmonia starts at
#   once, sshd and the daemon only once the rule holds; probes that fail
#   NIX_BUILDER_PROBE_FAILURES times in a row stop everything with exit 1,
#   so Docker restarts the container into the gate again; TERM ends the wait;
#   harmonia dying during the wait ends it with exit 1.
# - Installing the tools, with a fake nix: the image's Nix installs only the
#   first time, after that the pinned Nix installs its successor; the same
#   pin installs nothing; a failed install keeps the old tools and their pin,
#   and fails the start only when there are no old tools.
# - The compose file's default nixpkgs pin is the one in ravnix's flake.lock,
#   so the builder runs the Nix and tools the checks ran against.
#
# What only the container can show is in tests/services/nix-builder.md.
{ pkgs, lib, ... }:
let
  lock = builtins.fromJSON (builtins.readFile ../../flake.lock);
  rev = lock.nodes.${lock.nodes.root.inputs.nixpkgs}.locked.rev;
  compose = builtins.readFile ../../deploy/compose/nix-builder/docker-compose.yaml;
  pin = "github:NixOS/nixpkgs/${rev}";
  # One default, used by every service that needs nixpkgs, and it is the pin.
  defaults = lib.length (lib.splitString "NIX_BUILDER_NIXPKGS:-" compose) - 1;
  pinned = defaults == 1 && lib.hasInfix "NIX_BUILDER_NIXPKGS:-${pin}}" compose;
in
pkgs.runCommand "deploy-nix-builder-start"
  {
    script = ../../deploy/compose/nix-builder/start.sh;
    fakeNix = ./helpers/fake-nix.sh;
    listeners = ./helpers/listeners.py;
    nativeBuildInputs = [
      pkgs.shellcheck
      pkgs.python3
    ];
  }
  ''
    ${lib.optionalString (!pinned) ''
      echo "FAIL: docker-compose.yaml has ${toString defaults} defaults for NIX_BUILDER_NIXPKGS, not one that is ${pin}, the nixpkgs of flake.lock" >&2
      exit 1
    ''}
    shellcheck -s bash "$script" "$fakeNix"

    key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnlyNotARealKeyExampleOnlyNotARealKey nix-builder'
    name=cache.example.org-1
    pin=${pin}
    bash=$(command -v bash)
    failed=0
    fail() {
      printf 'FAIL: %s\n' "$*"
      failed=1
    }

    # expect EXIT TEXT VAR=VALUE...: start.sh --check-env with only these
    # variables set exits EXIT and prints TEXT.
    expect() {
      local want=$1 text=$2 got rc=0
      shift 2
      got=$(env -i "$@" "$bash" "$script" --check-env 2>&1) || rc=$?
      if [ "$rc" != "$want" ] || [[ $got != *"$text"* ]]; then
        fail "$*: wanted exit $want and \"$text\", got exit $rc: $got"
      fi
    }
    probes="192.0.2.1:2224 198.51.100.1:53"
    ok=(NIX_BUILDER_AUTHORIZED_KEY="$key" NIX_CACHE_KEY_NAME="$name" NIX_BUILDER_NIXPKGS="$pin" NIX_BUILDER_PROBES="$probes")

    expect 0 "the variables are fine" "''${ok[@]}"
    expect 0 "the variables are fine" "''${ok[@]}" NIX_MIN_FREE=2000G NIX_MAX_FREE=3T
    expect 0 "the variables are fine" "''${ok[@]}" \
      NIX_BUILDER_AUTHORIZED_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnlyNotARealKeyExampleOnlyNotARealKey"

    expect 1 "NIX_BUILDER_AUTHORIZED_KEY is empty" NIX_CACHE_KEY_NAME="$name" NIX_BUILDER_NIXPKGS="$pin"
    expect 1 "NIX_BUILDER_AUTHORIZED_KEY is empty" "''${ok[@]}" NIX_BUILDER_AUTHORIZED_KEY=
    expect 1 "more than one line" "''${ok[@]}" NIX_BUILDER_AUTHORIZED_KEY="$key"$'\n'"$key"
    expect 1 "more than one line" "''${ok[@]}" NIX_BUILDER_AUTHORIZED_KEY="$key"$'\r'
    expect 1 "not one public key line" "''${ok[@]}" NIX_BUILDER_AUTHORIZED_KEY="restrict $key"
    expect 1 "not one public key line" "''${ok[@]}" NIX_BUILDER_AUTHORIZED_KEY='command="sh" '"$key"
    expect 1 "not one public key line" "''${ok[@]}" NIX_BUILDER_AUTHORIZED_KEY="ssh-ed25519 not*base64 x"
    expect 1 "not one public key line" "''${ok[@]}" NIX_BUILDER_AUTHORIZED_KEY="ssh-ed25519"

    expect 1 "NIX_CACHE_KEY_NAME must be" "''${ok[@]}" NIX_CACHE_KEY_NAME=
    expect 1 "NIX_CACHE_KEY_NAME must be" "''${ok[@]}" NIX_CACHE_KEY_NAME="a:b"
    expect 1 "NIX_CACHE_KEY_NAME must be" "''${ok[@]}" NIX_CACHE_KEY_NAME="a b"

    expect 1 "NIX_BUILDER_NIXPKGS must be a flake reference" "''${ok[@]}" NIX_BUILDER_NIXPKGS=
    expect 1 "NIX_BUILDER_NIXPKGS must be a flake reference" "''${ok[@]}" NIX_BUILDER_NIXPKGS="$pin#hello"
    expect 1 "NIX_BUILDER_NIXPKGS must be a flake reference" "''${ok[@]}" NIX_BUILDER_NIXPKGS="$pin x"
    expect 1 "NIX_BUILDER_NIXPKGS must be a flake reference" "''${ok[@]}" NIX_BUILDER_NIXPKGS='github:a/b\c'

    expect 1 "NIX_MIN_FREE must be a size" "''${ok[@]}" NIX_MIN_FREE=lots
    expect 1 "NIX_MAX_FREE must be a size" "''${ok[@]}" NIX_MAX_FREE="1 T"
    expect 1 "NIX_MIN_FREE must be a size" "''${ok[@]}" NIX_MIN_FREE=-5G

    # Past the check: never outside its container, never as another user.
    # This build runs as a build user, so the second case also stands for a
    # build on the builder, inside the container that sets the marker.
    refuse() { # text VAR=VALUE...
      local text=$1 got rc=0
      shift
      got=$(env -i "$@" "$bash" "$script" 2>&1) || rc=$?
      if [ "$rc" != 1 ] || [[ $got != *"$text"* ]]; then
        fail "start.sh with $*: wanted exit 1 and \"$text\", got exit $rc: $got"
      fi
    }
    refuse "it does not run outside that container" "''${ok[@]}"
    refuse "it does not run outside that container" "''${ok[@]}" NIX_BUILDER_CONTAINER=yes
    # Its roots point into scratch, in case a root build ever got this far.
    if [ "$EUID" = 0 ]; then
      fail "this check runs as root, so it cannot show that start.sh refuses another uid"
    else
      refuse "must run as root, not as uid" "''${ok[@]}" NIX_BUILDER_CONTAINER=1 \
        NIX_BUILDER_ETC="$TMPDIR/none/etc" NIX_BUILDER_VAR="$TMPDIR/none/var" \
        NIX_BUILDER_RUN="$TMPDIR/none/run" NIX_BUILDER_STATE="$TMPDIR/none/state"
    fi

    # A scratch tree that looks like the image: /etc links into its store.
    fixture() {
      local root base f
      root=$(mktemp -d "$TMPDIR/tree.XXXXXX")
      base=$root/store/abc-base-system/etc
      mkdir -p "$root/etc/nix" "$root/var" "$root/state/cache" "$base/nix"
      printf '%s\n' \
        "root:x:0:0:System administrator:/root:$bash" \
        "nobody:x:65534:65534:Unprivileged account:/var/empty:/sbin/nologin" \
        "nixbld1:x:30001:30000:Nix build user 1:/var/empty:/bin/false" \
        "nixbld2:x:30002:30000:Nix build user 2:/var/empty:/bin/false" >"$base/passwd"
      printf '%s\n' "nixbld:x:30000:nixbld1,nixbld2" "nobody:x:65534:nobody" "root:x:0:root" >"$base/group"
      : >"$base/shadow"
      echo "the image's nix.conf" >"$base/nix/nix.conf"
      chmod 0444 "$base"/passwd "$base"/group "$base"/shadow "$base"/nix/nix.conf
      for f in passwd group shadow; do ln -s "$base/$f" "$root/etc/$f"; done
      ln -s "$base/nix/nix.conf" "$root/etc/nix/nix.conf"
      echo "$root"
    }
    # step ROOT CODE: runs CODE with start.sh's functions and its roots in ROOT.
    step() {
      (
        export NIX_BUILDER_ETC=$1/etc NIX_BUILDER_VAR=$1/var NIX_BUILDER_STATE=$1/state NIX_BUILDER_RUN=$1/run \
          NIX_BUILDER_PROFILES=$1/profiles
        # shellcheck source=/dev/null
        source "$script"
        eval "$2"
      ) 2>&1
    }
    count() { cut -d: -f1 "$2" | grep -cxF -- "$1" || true; }

    t=$(fixture)
    step "$t" copy_etc_links >/dev/null || fail "copy_etc_links failed on links into the store"
    for f in passwd group shadow; do
      if [ -L "$t/etc/$f" ] || ! cmp -s "$t/etc/$f" "$t/store/abc-base-system/etc/$f"; then
        fail "/etc/$f is not a copy of the image's file"
      fi
    done
    step "$t" 'add_accounts; add_accounts' >/dev/null || fail "add_accounts failed"
    for n in nix-builder sshd harmonia; do
      for f in passwd group shadow; do
        [ "$(count "$n" "$t/etc/$f")" = 1 ] || fail "$n is in /etc/$f $(count "$n" "$t/etc/$f") times after a rerun"
      done
    done
    [ "$(wc -l <"$t/store/abc-base-system/etc/passwd")" = 4 ] || fail "adding accounts changed the store's passwd"

    t=$(fixture)
    rm -r "$t/store/abc-base-system"
    got=$(step "$t" copy_etc_links) && fail "a link into a missing store path was copied"
    [[ $got == *"the image tag changed after the first start"* ]] || fail "a dangling /etc link: $got"

    t=$(fixture)
    step "$t" 'copy_etc_links; add_build_users_to_group 104; add_build_users_to_group 104' >/dev/null ||
      fail "add_build_users_to_group failed on a new gid"
    grep -qx 'kvm:x:104:nixbld1,nixbld2' "$t/etc/group" || fail "no kvm group for gid 104: $(grep ':104:' "$t/etc/group")"
    [ "$(grep -c ':104:' "$t/etc/group")" = 1 ] || fail "gid 104 is in /etc/group more than once"

    for existing in 'render:x:104:' 'render:x:104:alice'; do
      t=$(fixture)
      step "$t" copy_etc_links >/dev/null
      echo "$existing" >>"$t/etc/group"
      step "$t" 'add_build_users_to_group 104; add_build_users_to_group 104' >/dev/null ||
        fail "add_build_users_to_group failed with $existing"
      case $existing in
        *:) want="$existing""nixbld1,nixbld2" ;;
        *) want="$existing,nixbld1,nixbld2" ;;
      esac
      grep -qx "$want" "$t/etc/group" || fail "with $existing, wanted $want, got $(grep ':104:' "$t/etc/group")"
      grep -q '^kvm:' "$t/etc/group" && fail "with $existing, a second group for gid 104 was added"
    done

    t=$(fixture)
    step "$t" copy_etc_links >/dev/null
    grep -v '^nixbld' "$t/etc/passwd" >"$t/passwd" && mv "$t/passwd" "$t/etc/passwd"
    got=$(step "$t" 'add_build_users_to_group 104') && fail "an image without build users passed"
    [[ $got == *"the image has no nixbld users"* ]] || fail "no build users: $got"

    t=$(fixture)
    echo 'other-1:bm90IGEga2V5' >"$t/state/cache/secret-key"
    got=$(NIX_CACHE_KEY_NAME="$name" step "$t" check_sign_key_name) && fail "a signing key with another name passed"
    [[ $got == *"is named 'other-1', not NIX_CACHE_KEY_NAME '$name'"* ]] || fail "key name mismatch: $got"
    echo "$name:bm90IGEga2V5" >"$t/state/cache/secret-key"
    NIX_CACHE_KEY_NAME="$name" step "$t" check_sign_key_name >/dev/null || fail "a signing key with the right name was refused"

    t=$(fixture)
    NIX_MIN_FREE=2000G NIX_MAX_FREE=2500G step "$t" 'write_nix_conf yes' >/dev/null || fail "write_nix_conf failed"
    grep -qx "the image's nix.conf" "$t/store/abc-base-system/etc/nix/nix.conf" ||
      fail "writing nix.conf wrote through its link into the store"
    [ -L "$t/etc/nix/nix.conf" ] && fail "nix.conf is still a link"
    grep -qx 'system-features = kvm nixos-test big-parallel benchmark' "$t/etc/nix/nix.conf" || fail "no kvm features with kvm"
    grep -qx 'min-free = 2000G' "$t/etc/nix/nix.conf" || fail "no min-free"
    grep -qx 'max-free = 2500G' "$t/etc/nix/nix.conf" || fail "no max-free"
    step "$t" 'write_nix_conf no' >/dev/null
    grep -qx 'system-features = big-parallel benchmark' "$t/etc/nix/nix.conf" || fail "kvm features without kvm"
    grep -q 'min-free' "$t/etc/nix/nix.conf" && fail "min-free without NIX_MIN_FREE"

    # The probe's variables.
    expect 0 "the variables are fine" "''${ok[@]}" NIX_BUILDER_PROBES=192.0.2.1:1 \
      NIX_BUILDER_PROBE_TIMEOUT=0.5 NIX_BUILDER_PROBE_INTERVAL=0.2 NIX_BUILDER_PROBE_FAILURES=1
    expect 1 "NIX_BUILDER_PROBES must be" "''${ok[@]}" NIX_BUILDER_PROBES=
    for bad in 192.0.2.1 192.0.2.1:0 192.0.2.1:65536 192.0.2.300:53 host.example:53 "192.0.2.1:53;x" \
      "[2001:db8::1]:53" 192.0.2.01:53 192.0.2.1:053 "192.0.2.1:53 -x" $'192.0.2.1:53\n198.51.100.1:53'; do
      expect 1 "NIX_BUILDER_PROBES must be" "''${ok[@]}" NIX_BUILDER_PROBES="$bad"
    done
    for bad in 0 0.0 abc -1 1e3 31 " 2"; do
      expect 1 "NIX_BUILDER_PROBE_TIMEOUT must be" "''${ok[@]}" NIX_BUILDER_PROBE_TIMEOUT="$bad"
    done
    for bad in 0 abc 3601 1,5; do
      expect 1 "NIX_BUILDER_PROBE_INTERVAL must be" "''${ok[@]}" NIX_BUILDER_PROBE_INTERVAL="$bad"
    done
    for bad in 0 1.5 x 101; do
      expect 1 "NIX_BUILDER_PROBE_FAILURES must be" "''${ok[@]}" NIX_BUILDER_PROBE_FAILURES="$bad"
    done

    # The probe against real ports. --probe needs nothing but its own
    # variables, so the health check can run it.
    python3 -I "$listeners" >"$TMPDIR/ports" &
    listeners_pid=$!
    for _ in $(seq 100); do
      [ -s "$TMPDIR/ports" ] && break
      sleep 0.1
    done
    read -r accepting refusing silent <"$TMPDIR/ports"
    probe() { # exit text targets
      local want=$1 text=$2 got rc=0
      got=$(env -i PATH="$PATH" NIX_BUILDER_PROBES="$3" NIX_BUILDER_PROBE_TIMEOUT=1 "$bash" "$script" --probe 2>&1) || rc=$?
      if [ "$rc" != "$want" ] || [[ $got != *"$text"* ]]; then
        fail "--probe of $3: wanted exit $want and \"$text\", got exit $rc: $got"
      fi
    }
    probe 0 "the egress rule holds" "127.0.0.1:$silent"
    probe 1 "127.0.0.1:$accepting answered" "127.0.0.1:$accepting"
    probe 1 "127.0.0.1:$refusing answered" "127.0.0.1:$refusing"
    probe 1 "127.0.0.1:$accepting answered" "127.0.0.1:$silent 127.0.0.1:$accepting"
    got=$(env -i PATH="$PATH" NIX_BUILDER_PROBES="127.0.0.1:$silent 127.0.0.1:$accepting" NIX_BUILDER_PROBE_TIMEOUT=1 \
      "$bash" "$script" --probe 2>&1) || true
    [[ $got == *"127.0.0.1:$silent answered"* ]] && fail "a silent target was named as answering: $got"
    begin=$(date +%s%N)
    probe 0 "the egress rule holds" "127.0.0.1:$silent 127.0.0.1:$silent 127.0.0.1:$silent"
    took=$((($(date +%s%N) - begin) / 1000000))
    [ "$took" -lt 2500 ] || fail "three silent targets took $took ms with a 1 s timeout: they were probed one after another"
    probe 1 "NIX_BUILDER_PROBES must be" "127.0.0.1"
    kill "$listeners_pid"

    # The gate, with the probe stubbed by a file: the rule holds while it
    # exists. The services are sleeps that stand in for them.
    holds=$TMPDIR/rule-holds
    gate() { # root [interval]: runs run_services in the background, its pid in root/pid
      local root=$1 interval=''${2:-0.1}
      mkdir -p "$root/profiles/ravnix/bin"
      printf '#!%s\necho "nix (Nix) fake"\n' "$bash" >"$root/profiles/ravnix/bin/nix"
      chmod +x "$root/profiles/ravnix/bin/nix"
      NIX_BUILDER_PROBES=192.0.2.1:1 NIX_BUILDER_PROBE_INTERVAL=$interval NIX_BUILDER_PROBE_FAILURES=3 step "$root" "
        echo \$BASHPID >'$root/pid'
        silent() { [ -e '$holds' ]; }
        start_harmonia() { sleep 1000 & pids+=(\$!); echo harmonia >>'$root/order'; }
        start_builder() { sleep 1000 & pids+=(\$!); echo \$! >'$root/builder'; echo builder >>'$root/order'; }
        run_services" >"$root/log" &
    }
    until_true() { # seconds code: CODE succeeds within SECONDS
      local i
      for i in $(seq $(($1 * 10))); do
        eval "$2" && return 0
        sleep 0.1
      done
      return 1
    }

    t=$(fixture)
    rm -f "$holds"
    gate "$t"
    runner=$!
    until_true 5 'grep -q "waiting for the egress rule" "$t/log"' || fail "the gate did not wait: $(cat "$t/log")"
    sleep 0.5
    [ "$(cat "$t/order")" = harmonia ] || fail "before the rule held, these started: $(cat "$t/order")"
    touch "$holds"
    until_true 5 'grep -q "running nix (Nix) fake" "$t/log"' || fail "the gate did not open: $(cat "$t/log")"
    [ "$(cat "$t/order")" = "$(printf 'harmonia\nbuilder')" ] || fail "start order: $(cat "$t/order")"
    sleep 0.5
    kill -0 "$runner" 2>/dev/null || fail "the builder stopped while the rule held: $(cat "$t/log")"
    rm -f "$holds"
    rc=0
    timeout 10 tail --pid="$runner" -f /dev/null || fail "the builder kept running without the rule"
    wait "$runner" || rc=$?
    [ "$rc" = 1 ] || fail "the builder exited $rc when the rule went, not 1"
    [ "$(grep -c "failed a probe" "$t/log")" = 3 ] || fail "not three failed probes before the stop: $(cat "$t/log")"
    grep -q "the egress rule no longer holds" "$t/log" || fail "no stop message: $(cat "$t/log")"
    kill -0 "$(cat "$t/builder")" 2>/dev/null && fail "the daemon and sshd stand-in still runs after the stop"

    # Probes that fail now and then, but never three times in a row.
    t=$(fixture)
    touch "$holds"
    gate "$t"
    runner=$!
    until_true 5 'grep -q "running nix (Nix) fake" "$t/log"' || fail "the gate did not open: $(cat "$t/log")"
    for _ in 1 2 3; do
      rm -f "$holds"
      until_true 5 'grep -q "failed a probe (1 of 3" "$t/log"' || true
      sleep 0.15
      touch "$holds"
      sleep 0.3
    done
    kill -0 "$runner" 2>/dev/null || fail "single failed probes stopped the builder: $(cat "$t/log")"
    kill -TERM "$(cat "$t/pid")"
    rc=0
    wait "$runner" || rc=$?
    [ "$rc" = 0 ] || fail "TERM while running gave exit $rc"

    # TERM while it waits at the gate, between two probes a minute apart.
    t=$(fixture)
    rm -f "$holds"
    gate "$t" 60
    runner=$!
    until_true 5 'grep -q "waiting for the egress rule" "$t/log"' || fail "the gate did not wait"
    sleep 0.3
    kill -TERM "$(cat "$t/pid")"
    rc=0
    timeout 4 tail --pid="$runner" -f /dev/null || fail "TERM did not end the wait at the gate within 4 s"
    wait "$runner" || rc=$?
    [ "$rc" = 0 ] || fail "TERM at the gate gave exit $rc"
    grep -q builder "$t/order" && fail "the builder started after TERM at the gate"

    # harmonia dying while the builder waits at the gate.
    t=$(fixture)
    rm -f "$holds"
    mkdir -p "$t/profiles/ravnix/bin"
    NIX_BUILDER_PROBES=192.0.2.1:1 NIX_BUILDER_PROBE_INTERVAL=0.1 step "$t" "
      silent() { [ -e '$holds' ]; }
      start_harmonia() { sleep 0.3 & pids+=(\$!); }
      start_builder() { echo builder >>'$t/order'; }
      run_services" >"$t/log" &
    runner=$!
    rc=0
    timeout 10 tail --pid="$runner" -f /dev/null || fail "the gate kept waiting after harmonia died"
    wait "$runner" || rc=$?
    [ "$rc" = 1 ] || fail "harmonia dying at the gate gave exit $rc"
    grep -q "harmonia exited" "$t/log" || fail "no message for harmonia dying: $(cat "$t/log")"

    # Installing the tools, with a fake nix as the image's.
    t=$(fixture)
    mkdir -p "$t/profiles/default/bin" "$t/fake-store"
    printf '#!%s\nFAKE_NIX_AS=bootstrap exec %s %s "$@"\n' "$bash" "$bash" "$fakeNix" >"$t/profiles/default/bin/nix"
    chmod +x "$t/profiles/default/bin/nix"
    export FAKE_NIX_LOG=$t/nix.log FAKE_NIX_STORE=$t/fake-store
    install() { NIX_BUILDER_NIXPKGS=$1 step "$t" install_tools; }
    leftover() { find "$t/profiles" -maxdepth 1 -name 'ravnix-*' | grep -q .; }

    got=$(install github:a/b/1) || fail "a first install failed: $got"
    grep -qxF "bootstrap profile add --profile $t/profiles/ravnix-next github:a/b/1#nix github:a/b/1#openssh github:a/b/1#harmonia" "$t/nix.log" ||
      fail "the first install did not run on the image's nix: $(cat "$t/nix.log")"
    [ "$(cat "$t/state/tools-pin")" = github:a/b/1 ] || fail "no pin stamp after the first install"
    first=$(readlink -f "$t/profiles/ravnix")
    [ -x "$first/bin/nix-daemon" ] || fail "the first install left no tools in $t/profiles/ravnix"
    leftover && fail "the first install left links behind: $(ls "$t/profiles")"

    : >"$t/nix.log"
    install github:a/b/1 >/dev/null || fail "a start with the same pin failed"
    [ -s "$t/nix.log" ] && fail "a start with the same pin installed again: $(cat "$t/nix.log")"

    got=$(install github:a/b/2) || fail "an update failed: $got"
    grep -q "^$first/bin/nix profile add --profile $t/profiles/ravnix-next github:a/b/2#nix" "$t/nix.log" ||
      fail "the update did not run on the pinned nix: $(cat "$t/nix.log")"
    second=$(readlink -f "$t/profiles/ravnix")
    [ "$second" != "$first" ] || fail "the update did not switch the tools"
    [ "$(cat "$t/state/tools-pin")" = github:a/b/2 ] || fail "the update did not stamp its pin"

    got=$(FAKE_NIX_FAIL=1 install github:a/b/3) || fail "a failed update stopped the start: $got"
    [[ $got == *"keeping the tools of github:a/b/2"* ]] || fail "a failed update said: $got"
    [ "$(readlink -f "$t/profiles/ravnix")" = "$second" ] || fail "a failed update changed the tools"
    [ "$(cat "$t/state/tools-pin")" = github:a/b/2 ] || fail "a failed update changed the pin stamp"
    leftover && fail "a failed update left links behind: $(ls "$t/profiles")"

    t2=$(fixture)
    mkdir -p "$t2/profiles/default/bin"
    cp "$t/profiles/default/bin/nix" "$t2/profiles/default/bin/nix"
    got=$(FAKE_NIX_FAIL=1 NIX_BUILDER_NIXPKGS=github:a/b/1 step "$t2" install_tools) && fail "a failed first install passed"
    [[ $got == *"no tools to fall back to"* ]] || fail "a failed first install said: $got"
    unset FAKE_NIX_LOG FAKE_NIX_STORE

    [ "$failed" = 0 ]
    touch "$out"
  ''
