#!/usr/bin/env bash
# The nix-firewall service of docker-compose.yaml: keeps the builder's egress
# rule in the host's firewall. Builds on the builder run without the Nix
# sandbox, so this keeps them off the LAN. From the project's subnet
# (NIX_BUILDER_SUBNET), traffic to 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16
# and 100.64.0.0/10, and to the host itself, is dropped; replies to
# connections that came in stay allowed, and the internet stays reachable.
#
# Two chains of its own hold the rule, and a jump to each sits first in
# DOCKER-USER (traffic the host forwards) and in INPUT (traffic for the host
# itself). A NAS rewrites both chains (UGOS puts its own rules into them), so
# the script checks every NIX_FIREWALL_INTERVAL seconds (10 by default) and
# repairs what is missing, changed, or no longer first. A check that finds
# everything in place changes nothing.
#
#   firewall.sh            check and repair forever (the service's command)
#   firewall.sh --once     check and repair once
#   firewall.sh --check    exit 0 when the rule is in place, change nothing
#                          (the service's health check)
#   firewall.sh --remove   take the rule out again (the rollback)
#
# Every error ends the script, and the service's restart policy runs it
# again. Two copies at once can leave a rule twice; the next check takes
# the second copy out.
#
# IPTABLES names the iptables to call, iptables-nft by default: it must be
# the backend the host's Docker uses (`iptables-nft -S FORWARD` lists the
# jump to DOCKER-USER when it is).
set -euo pipefail
shopt -s inherit_errexit

ipt=${IPTABLES:-iptables-nft}
subnet=${NIX_BUILDER_SUBNET:-}
interval=${NIX_FIREWALL_INTERVAL:-10}
out_chain=RAVNIX-NIX-BUILDER-OUT
in_chain=RAVNIX-NIX-BUILDER-IN
blocked=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10)
changed=no
dry=no

say() { echo "firewall.sh: $*"; }
die() {
  echo "firewall.sh: $*" >&2
  exit 1
}

check_env() {
  local octet prefix address=0 host
  local part='(0|[1-9][0-9]{0,2})'
  local re="^$part\\.$part\\.$part\\.$part/([1-9][0-9]?)\$"
  [[ $subnet =~ ^[0-9.]+/[0-9]+$ ]] ||
    die "NIX_BUILDER_SUBNET must be an IPv4 subnet such as 10.0.200.0/24, not '$subnet'"
  [[ $subnet =~ $re ]] ||
    die "NIX_BUILDER_SUBNET must be four numbers and a prefix, none with a leading zero (which tools read as octal), not '$subnet'"
  for octet in "${BASH_REMATCH[@]:1:4}"; do
    [ "$octet" -le 255 ] || die "NIX_BUILDER_SUBNET has a number over 255: '$subnet'"
    address=$((address * 256 + octet))
  done
  prefix=${BASH_REMATCH[5]}
  [ "$prefix" -ge 8 ] && [ "$prefix" -le 30 ] ||
    die "NIX_BUILDER_SUBNET's prefix must be /8 to /30, not /$prefix"
  host=$((address & ((1 << (32 - prefix)) - 1)))
  [ "$host" = 0 ] ||
    die "NIX_BUILDER_SUBNET '$subnet' has host bits set; iptables would list it under its network address, and the check would never match"
  [[ $interval =~ ^[1-9][0-9]{0,3}$ ]] && [ "$interval" -le 3600 ] ||
    die "NIX_FIREWALL_INTERVAL must be 1 to 3600 seconds, not '$interval'"
}

# What each chain of ours must hold, as `iptables -S` prints it.
want_out() {
  echo "-N $out_chain"
  echo "-A $out_chain -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN"
  local net
  for net in "${blocked[@]}"; do
    echo "-A $out_chain -d $net -j DROP"
  done
}
want_in() {
  echo "-N $in_chain"
  echo "-A $in_chain -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN"
  echo "-A $in_chain -j DROP"
}

# Makes CHAIN hold what WANT prints, when it does not already.
sync_chain() { # chain want
  local chain=$1 want have line
  local -a rule
  want=$("$2")
  have=$("$ipt" -S "$chain" 2>/dev/null) || have=""
  [ "$have" != "$want" ] || return 0
  changed=yes
  [ "$dry" = no ] || return 0
  "$ipt" -N "$chain" 2>/dev/null || "$ipt" -F "$chain"
  while IFS= read -r line; do
    case $line in
      "-A $chain "*)
        read -ra rule <<<"${line#"-A $chain "}"
        "$ipt" -A "$chain" "${rule[@]}"
        ;;
    esac
  done <<<"$want"
}

# Makes RULE the first rule of PARENT, and the only copy of it there.
first_rule() { # parent rule...
  local parent=$1 lines copies
  shift
  local wanted="-A $parent $*"
  mapfile -t lines < <("$ipt" -S "$parent")
  copies=$(printf '%s\n' "${lines[@]}" | grep -cxF -- "$wanted" || true)
  [ "${lines[1]:-}" = "$wanted" ] && [ "$copies" = 1 ] && return 0
  changed=yes
  [ "$dry" = no ] || return 0
  while "$ipt" -C "$parent" "$@" 2>/dev/null; do
    "$ipt" -D "$parent" "$@"
  done
  "$ipt" -I "$parent" 1 "$@"
}

apply() {
  "$ipt" -S DOCKER-USER >/dev/null 2>&1 ||
    die "there is no DOCKER-USER chain in $ipt: Docker's firewall is not up yet, or the host's Docker uses another backend (IPTABLES)"
  changed=no
  sync_chain "$out_chain" want_out
  sync_chain "$in_chain" want_in
  first_rule DOCKER-USER -s "$subnet" -j "$out_chain"
  first_rule INPUT -s "$subnet" -j "$in_chain"
}

remove() {
  local parent chain
  for parent in DOCKER-USER:"$out_chain" INPUT:"$in_chain"; do
    chain=${parent#*:}
    parent=${parent%%:*}
    while "$ipt" -C "$parent" -s "$subnet" -j "$chain" 2>/dev/null; do
      "$ipt" -D "$parent" -s "$subnet" -j "$chain"
    done
    if "$ipt" -S "$chain" >/dev/null 2>&1; then
      "$ipt" -F "$chain"
      "$ipt" -X "$chain"
    fi
  done
  say "removed the rule for $subnet"
}

report() {
  if [ "$changed" = yes ]; then
    say "put the rule for $subnet in place"
  else
    say "the rule for $subnet is in place"
  fi
}

main() {
  check_env
  command -v "$ipt" >/dev/null || die "$ipt is not installed (IPTABLES)"
  case ${1:-} in
    --remove)
      remove
      ;;
    --check)
      dry=yes
      apply
      [ "$changed" = no ] || die "the rule for $subnet is not in place"
      say "the rule for $subnet is in place"
      ;;
    --once)
      apply
      report
      ;;
    "")
      trap 'exit 0' TERM INT
      say "keeping the rule for $subnet, checked every ${interval}s"
      apply
      report
      while :; do
        sleep "$interval" &
        wait $!
        apply
        [ "$changed" = no ] || say "put the rule for $subnet back in place"
      done
      ;;
    *)
      die "unknown argument '$1'; use --once, --check, --remove or nothing"
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
