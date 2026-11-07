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
    nativeBuildInputs = [ pkgs.shellcheck ];
  }
  ''
    ${lib.optionalString (!pinned) ''
      echo "FAIL: docker-compose.yaml has ${toString defaults} defaults for NIX_BUILDER_NIXPKGS, not one that is ${pin}, the nixpkgs of flake.lock" >&2
      exit 1
    ''}
    shellcheck -s bash "$script"

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
    ok=(NIX_BUILDER_AUTHORIZED_KEY="$key" NIX_CACHE_KEY_NAME="$name" NIX_BUILDER_NIXPKGS="$pin")

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
        export NIX_BUILDER_ETC=$1/etc NIX_BUILDER_VAR=$1/var NIX_BUILDER_STATE=$1/state NIX_BUILDER_RUN=$1/run
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

    [ "$failed" = 0 ]
    touch "$out"
  ''
