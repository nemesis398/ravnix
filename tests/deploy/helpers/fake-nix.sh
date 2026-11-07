#!/usr/bin/env bash
# A stand-in for nix in tests/deploy/nix-builder-start.nix, for start.sh's
# install_tools, run through a wrapper that names the path it stands for
# in FAKE_NIX_AS. It logs each call as "FAKE_NIX_AS ARGS" to $FAKE_NIX_LOG.
# `nix profile add --profile P REFS...` makes a store path under
# $FAKE_NIX_STORE with every tool start.sh needs, a wrapper of this file
# among them as bin/nix, and links P to it through a generation link, as Nix
# does. With FAKE_NIX_FAIL set, profile add fails the way a failed download
# does.
set -euo pipefail
echo "${FAKE_NIX_AS:?} $*" >>"${FAKE_NIX_LOG:?}"
case ${1:-} in
  --version)
    echo "nix (Nix) fake"
    ;;
  profile)
    [ "$2" = add ] && [ "$3" = --profile ] || exit 2
    profile=$4
    if [ -n "${FAKE_NIX_FAIL:-}" ]; then
      echo "error: unable to download 'https://github.com/…': HTTP error 404" >&2
      exit 1
    fi
    out=$(mktemp -d "${FAKE_NIX_STORE:?}/profile.XXXXXX")
    mkdir "$out/bin"
    for tool in nix-daemon sshd ssh-keygen harmonia-cache; do
      printf '#!%s\nexit 0\n' "$BASH" >"$out/bin/$tool"
      chmod +x "$out/bin/$tool"
    done
    printf '#!%s\nFAKE_NIX_AS=%s exec %s %s "$@"\n' "$BASH" "$out/bin/nix" "$BASH" "$0" >"$out/bin/nix"
    chmod +x "$out/bin/nix"
    ln -sfn -- "$out" "$profile-1-link"
    ln -sfn -- "$(basename -- "$profile")-1-link" "$profile"
    ;;
  *)
    exit 2
    ;;
esac
