#!/usr/bin/env bash
# A stand-in for nix in tests/deploy/nix-builder-start.nix, for start.sh's
# install_tools, run through a wrapper that names the path it stands for
# in FAKE_NIX_AS. It logs each call as "FAKE_NIX_AS ARGS" to $FAKE_NIX_LOG.
#
# `nix profile add --profile P REF#nix REF#openssh REF#harmonia` makes one
# package directory per attribute under $FAKE_NIX_STORE, named after REF
# and the attribute, with that package's tools in bin/, and a profile whose
# bin/ links to them, linked from P through a generation link, as Nix does.
# Its nix is a wrapper of this file. `nix eval --raw REF#ATTR --apply EXPR`
# prints what start.sh asks for: the attribute's version and its package
# directory. The tools print the versions eval names, as the real ones do.
#
# Each variable below makes one thing go wrong, the way it would for real:
#   FAKE_NIX_FAIL=1         profile add fails like a failed download
#   FAKE_NIX_MISSING=TOOL   the profile lacks TOOL (a package renamed it)
#   FAKE_NIX_BROKEN=TOOL    TOOL is there but does not start (a library is
#                           missing)
#   FAKE_NIX_SKEW=ATTR      ATTR's tools report another version than eval
#   FAKE_NIX_FOREIGN=ATTR   ATTR's tools in the profile come from another
#                           package than the one eval names
#   FAKE_NIX_EVAL_FAIL=1    eval fails
set -euo pipefail
echo "${FAKE_NIX_AS:?} $*" >>"${FAKE_NIX_LOG:?}"
store=${FAKE_NIX_STORE:?}

version_of() { # attr
  case $1 in
    nix) echo 2.99.1 ;;
    openssh) echo 10.99p1 ;;
    harmonia) echo 3.99.0 ;;
    *) return 1 ;;
  esac
}
tools_of() { # attr
  case $1 in
    nix) echo nix nix-daemon ;;
    openssh) echo sshd ssh-keygen ;;
    harmonia) echo harmonia-cache ;;
  esac
}
package_dir() { # ref attr
  echo "$store/$(printf %s "$1" | cksum | cut -d' ' -f1)-$2"
}

# Writes TOOL of a package with VERSION into DIR/bin.
make_tool() { # dir tool version
  local file=$1/bin/$2
  if [ "${FAKE_NIX_BROKEN:-}" = "$2" ]; then
    printf '#!%s\necho "%s: error while loading shared libraries: libfake.so.1" >&2\nexit 127\n' "$BASH" "$2" >"$file"
  else
    # shellcheck disable=SC2016 # $1 and $CONFIG_FILE are the written tool's.
    case $2 in
      nix)
        printf '#!%s\nFAKE_NIX_AS=%s FAKE_NIX_VERSION=%s exec %s %s "$@"\n' "$BASH" "$file" "$3" "$BASH" "$0" >"$file"
        ;;
      nix-daemon)
        printf '#!%s\n[ "$1" = --version ] && echo "nix-daemon (Nix) %s"\n' "$BASH" "$3" >"$file"
        ;;
      sshd)
        printf '#!%s\n[ "$1" = -V ] && echo "OpenSSH_%s, OpenSSL fake" >&2\n' "$BASH" "$3" >"$file"
        ;;
      ssh-keygen)
        printf '#!%s\necho "usage: ssh-keygen [-q] ..." >&2\nexit 1\n' "$BASH" >"$file"
        ;;
      harmonia-cache)
        printf '#!%s\necho "Error: Config(ReadFile { path: \\"$CONFIG_FILE\\" })" >&2\nexit 1\n' "$BASH" >"$file"
        ;;
    esac
  fi
  chmod +x "$file"
}

make_package() { # dir attr version
  local tool
  [ -d "$1" ] && return 0
  mkdir -p "$1/bin"
  for tool in $(tools_of "$2"); do
    make_tool "$1" "$tool" "$3"
  done
}

case ${1:-} in
  --version)
    echo "nix (Nix) ${FAKE_NIX_VERSION:-2.0-image}"
    ;;
  profile)
    [ "$2" = add ] && [ "$3" = --profile ] || exit 2
    profile=$4
    shift 4
    if [ -n "${FAKE_NIX_FAIL:-}" ]; then
      echo "error: unable to download 'https://github.com/…': HTTP error 404" >&2
      exit 1
    fi
    out=$(mktemp -d "$store/profile.XXXXXX")
    mkdir "$out/bin"
    for installable in "$@"; do
      ref=${installable%#*}
      attr=${installable##*#}
      version=$(version_of "$attr") || exit 2
      [ "${FAKE_NIX_SKEW:-}" != "$attr" ] || version=0.0-skewed
      dir=$(package_dir "$ref" "$attr")
      [ "${FAKE_NIX_FOREIGN:-}" != "$attr" ] || dir=$store/foreign-$attr
      [ -z "${FAKE_NIX_BROKEN:-}" ] || dir=$dir-broken
      make_package "$dir" "$attr" "$version"
      for tool in $(tools_of "$attr"); do
        [ "${FAKE_NIX_MISSING:-}" = "$tool" ] || ln -s "$dir/bin/$tool" "$out/bin/$tool"
      done
    done
    ln -sfn -- "$out" "$profile-1-link"
    ln -sfn -- "$(basename -- "$profile")-1-link" "$profile"
    ;;
  eval)
    [ "$2" = --raw ] && [ "$4" = --apply ] && [ "$#" = 5 ] || exit 2
    if [ -n "${FAKE_NIX_EVAL_FAIL:-}" ]; then
      echo "error: cannot evaluate $3" >&2
      exit 1
    fi
    ref=${3%#*}
    attr=${3##*#}
    dir=$(package_dir "$ref" "$attr")
    [ -z "${FAKE_NIX_BROKEN:-}" ] || dir=$dir-broken
    # Nix reports progress on stderr, as it does for a pin it unpacks again.
    echo "unpacking '$ref' into the Git cache..." >&2
    printf '%s %s' "$(version_of "$attr")" "$dir"
    ;;
  *)
    exit 2
    ;;
esac
