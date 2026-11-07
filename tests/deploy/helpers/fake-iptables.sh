#!/usr/bin/env bash
# A stand-in for iptables in tests/deploy/nix-builder-firewall.nix. The filter
# table is a directory, $FAKE_IPT/chains, with one file per chain and one rule
# per line, as `iptables -S` prints it after `-A CHAIN `. Every call is
# appended to $FAKE_IPT/log first. Each call holds a lock, so concurrent calls
# are atomic, as nf_tables transactions are. With FAKE_IPT_FAIL=OP, every
# call of that operation fails.
set -euo pipefail
dir=${FAKE_IPT:?}
exec 9>>"$dir/lock"
flock 9
echo "$*" >>"$dir/log"

op=${1:-}
chain=${2:-}
shift $(($# < 2 ? $# : 2))
file=$dir/chains/$chain

fail() { # status message
  echo "iptables: $2" >&2
  exit "$1"
}
[ "${FAKE_IPT_FAIL:-}" != "$op" ] || fail 4 "$op fails, as FAKE_IPT_FAIL says"

builtin_chain() {
  case $1 in
    INPUT | FORWARD | OUTPUT) return 0 ;;
  esac
  return 1
}
need_chain() { [ -e "$file" ] || fail 1 "No chain/target/match by that name."; }
# A -j target must be a verdict or a chain that exists.
check_target() {
  local previous="" word
  for word in "$@"; do
    if [ "$previous" = -j ]; then
      case $word in
        ACCEPT | DROP | RETURN | REJECT) ;;
        *) [ -e "$dir/chains/$word" ] || fail 2 "Couldn't load target \`$word'" ;;
      esac
    fi
    previous=$word
  done
}

case $op in
  -S)
    need_chain
    if builtin_chain "$chain"; then echo "-P $chain ACCEPT"; else echo "-N $chain"; fi
    while IFS= read -r rule; do echo "-A $chain $rule"; done <"$file"
    ;;
  -N)
    [ ! -e "$file" ] || fail 1 "Chain already exists."
    : >"$file"
    ;;
  -F)
    need_chain
    : >"$file"
    ;;
  -X)
    need_chain
    ! builtin_chain "$chain" || fail 2 "Can't delete built-in chain."
    [ ! -s "$file" ] || fail 1 "Directory not empty."
    ! grep -rqE -- "-j $chain( |\$)" "$dir/chains" || fail 1 "Too many links."
    rm -- "$file"
    ;;
  -A)
    need_chain
    check_target "$@"
    echo "$*" >>"$file"
    ;;
  -I)
    need_chain
    position=$1
    shift
    check_target "$@"
    {
      head -n $((position - 1)) "$file"
      echo "$*"
      tail -n +"$position" "$file"
    } >"$file.new"
    mv -- "$file.new" "$file"
    ;;
  -C)
    need_chain
    grep -qxF -- "$*" "$file" || fail 1 "Bad rule (does a matching rule exist in that chain?)."
    ;;
  -D)
    need_chain
    line=$(grep -nxF -- "$*" "$file" | head -n 1 | cut -d: -f1 || true)
    [ -n "$line" ] || fail 1 "Bad rule (does a matching rule exist in that chain?)."
    sed "${line}d" "$file" >"$file.new"
    mv -- "$file.new" "$file"
    ;;
  *)
    fail 2 "the fake does not know '$op'"
    ;;
esac
