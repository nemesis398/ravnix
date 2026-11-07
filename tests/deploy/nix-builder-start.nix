# deploy/compose/nix-builder/start.sh checks the variables from .env before
# it touches the container, and refuses a bad one with a message naming it:
# an empty key, a key with a second line (one line more in authorized_keys),
# a key behind options (`restrict ssh-ed25519 …` would replace the forced
# command's options), a key whose body is not base64, a cache key name with a
# colon or none at all, and a garbage-collection size that Nix would not
# read. `start.sh --check-env` runs only that part, so this check needs no
# container. The rest of the script is covered by the deployment record,
# tests/services/nix-builder.md, and by shellcheck here.
{ pkgs, ... }:
pkgs.runCommand "deploy-nix-builder-start"
  {
    script = ../../deploy/compose/nix-builder/start.sh;
    nativeBuildInputs = [ pkgs.shellcheck ];
  }
  ''
    shellcheck -s bash "$script"

    key='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnlyNotARealKeyExampleOnlyNotARealKey nix-builder'
    name=cache.example.org-1
    bash=$(command -v bash)
    failed=0

    # expect EXIT TEXT VAR=VALUE...: start.sh --check-env with only these
    # variables set exits EXIT and prints TEXT.
    expect() {
      local want=$1 text=$2 got rc=0
      shift 2
      got=$(env -i "$@" "$bash" "$script" --check-env 2>&1) || rc=$?
      if [ "$rc" != "$want" ] || [[ $got != *"$text"* ]]; then
        printf 'FAIL: %s\n  wanted exit %s and "%s", got exit %s: %s\n' "$*" "$want" "$text" "$rc" "$got"
        failed=1
      fi
    }

    expect 0 "the variables are fine" NIX_BUILDER_AUTHORIZED_KEY="$key" NIX_CACHE_KEY_NAME="$name"
    expect 0 "the variables are fine" NIX_BUILDER_AUTHORIZED_KEY="$key" NIX_CACHE_KEY_NAME="$name" \
      NIX_MIN_FREE=2000G NIX_MAX_FREE=3T
    expect 0 "the variables are fine" NIX_BUILDER_AUTHORIZED_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnlyNotARealKeyExampleOnlyNotARealKey" \
      NIX_CACHE_KEY_NAME="$name"

    expect 1 "NIX_BUILDER_AUTHORIZED_KEY is empty" NIX_CACHE_KEY_NAME="$name"
    expect 1 "NIX_BUILDER_AUTHORIZED_KEY is empty" NIX_BUILDER_AUTHORIZED_KEY= NIX_CACHE_KEY_NAME="$name"
    expect 1 "more than one line" NIX_BUILDER_AUTHORIZED_KEY="$key"$'\n'"$key" NIX_CACHE_KEY_NAME="$name"
    expect 1 "more than one line" NIX_BUILDER_AUTHORIZED_KEY="$key"$'\r' NIX_CACHE_KEY_NAME="$name"
    expect 1 "not one public key line" NIX_BUILDER_AUTHORIZED_KEY="restrict $key" NIX_CACHE_KEY_NAME="$name"
    expect 1 "not one public key line" NIX_BUILDER_AUTHORIZED_KEY='command="sh" '"$key" NIX_CACHE_KEY_NAME="$name"
    expect 1 "not one public key line" NIX_BUILDER_AUTHORIZED_KEY="ssh-ed25519 not*base64 x" NIX_CACHE_KEY_NAME="$name"
    expect 1 "not one public key line" NIX_BUILDER_AUTHORIZED_KEY="ssh-ed25519" NIX_CACHE_KEY_NAME="$name"

    expect 1 "NIX_CACHE_KEY_NAME must be" NIX_BUILDER_AUTHORIZED_KEY="$key"
    expect 1 "NIX_CACHE_KEY_NAME must be" NIX_BUILDER_AUTHORIZED_KEY="$key" NIX_CACHE_KEY_NAME="a:b"
    expect 1 "NIX_CACHE_KEY_NAME must be" NIX_BUILDER_AUTHORIZED_KEY="$key" NIX_CACHE_KEY_NAME="a b"

    expect 1 "NIX_MIN_FREE must be a size" NIX_BUILDER_AUTHORIZED_KEY="$key" NIX_CACHE_KEY_NAME="$name" NIX_MIN_FREE=lots
    expect 1 "NIX_MAX_FREE must be a size" NIX_BUILDER_AUTHORIZED_KEY="$key" NIX_CACHE_KEY_NAME="$name" NIX_MAX_FREE="1 T"
    expect 1 "NIX_MIN_FREE must be a size" NIX_BUILDER_AUTHORIZED_KEY="$key" NIX_CACHE_KEY_NAME="$name" NIX_MIN_FREE=-5G

    # Without --check-env, outside a container, it refuses before it changes
    # anything, since everything after the check rewrites /etc.
    rc=0
    got=$(env -i NIX_BUILDER_AUTHORIZED_KEY="$key" NIX_CACHE_KEY_NAME="$name" "$bash" "$script" 2>&1) || rc=$?
    if [ "$rc" != 1 ] || [[ $got != *"does not run outside a container"* ]]; then
      printf 'FAIL: start.sh outside a container: exit %s: %s\n' "$rc" "$got"
      failed=1
    fi

    [ "$failed" = 0 ]
    touch "$out"
  ''
