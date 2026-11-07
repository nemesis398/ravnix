#!/usr/bin/env bash
# The nix-firewall service of docker-compose.yaml: keeps the builder's egress
# rule in the host's firewall. Builds on the builder run without the Nix
# sandbox, so this keeps them off the LAN. From the project's bridge
# (NIX_BUILDER_BRIDGE) and from its subnet (NIX_BUILDER_SUBNET), traffic to
# 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 and 100.64.0.0/10, and to the
# host itself, is dropped; replies to connections that came in stay allowed,
# and the internet stays reachable.
#
# Two chains of its own hold the rule. Two jumps to each sit first in
# DOCKER-USER (traffic the host forwards) and in INPUT (traffic for the host
# itself): one for whatever arrives from the bridge, so a forged source
# address does not slip past, and one for the subnet's addresses on any
# interface. A NAS rewrites both chains (UGOS puts its own rules into them), so
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
bridge=${NIX_BUILDER_BRIDGE:-}
interval=${NIX_FIREWALL_INTERVAL:-10}
out_chain=RAVNIX-NIX-BUILDER-OUT
in_chain=RAVNIX-NIX-BUILDER-IN
blocked=(10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10)
changed=no
dry=no
what=

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
  # A Linux interface name: at most 15 characters, and none that iptables
  # would read as an option.
  [[ $bridge =~ ^[A-Za-z0-9][A-Za-z0-9_.-]{0,14}$ ]] ||
    die "NIX_BUILDER_BRIDGE must be an interface name of up to 15 letters, digits, '.', '_' and '-', not '$bridge'"
  what="$bridge and $subnet"
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

# Makes the RULEs the first rules of PARENT, in their order, each there
# once. Each RULE is one string of words, as `iptables -S` prints it after
# `-A PARENT `.
lead_rules() { # parent rule...
  local parent=$1 rule i=0
  local -a lines words rules
  shift
  rules=("$@")
  mapfile -t lines < <("$ipt" -S "$parent")
  local in_place=yes
  for rule in "${rules[@]}"; do
    i=$((i + 1))
    [ "${lines[i]:-}" = "-A $parent $rule" ] || in_place=no
    [ "$(printf '%s\n' "${lines[@]}" | grep -cxF -- "-A $parent $rule" || true)" = 1 ] || in_place=no
  done
  [ "$in_place" = no ] || return 0
  changed=yes
  [ "$dry" = no ] || return 0
  for rule in "${rules[@]}"; do
    read -ra words <<<"$rule"
    while "$ipt" -C "$parent" "${words[@]}" 2>/dev/null; do
      "$ipt" -D "$parent" "${words[@]}"
    done
  done
  for ((i = ${#rules[@]} - 1; i >= 0; i--)); do
    read -ra words <<<"${rules[i]}"
    "$ipt" -I "$parent" 1 "${words[@]}"
  done
}

# The jumps that lead PARENT into CHAIN.
jumps() { # chain
  echo "-i $bridge -j $1"
  echo "-s $subnet -j $1"
}

apply() {
  "$ipt" -S DOCKER-USER >/dev/null 2>&1 ||
    die "there is no DOCKER-USER chain in $ipt: Docker's firewall is not up yet, or the host's Docker uses another backend (IPTABLES)"
  changed=no
  sync_chain "$out_chain" want_out
  sync_chain "$in_chain" want_in
  local -a out_jumps in_jumps
  mapfile -t out_jumps < <(jumps "$out_chain")
  mapfile -t in_jumps < <(jumps "$in_chain")
  lead_rules DOCKER-USER "${out_jumps[@]}"
  lead_rules INPUT "${in_jumps[@]}"
}

remove() {
  local parent chain rule
  local -a words
  for parent in DOCKER-USER:"$out_chain" INPUT:"$in_chain"; do
    chain=${parent#*:}
    parent=${parent%%:*}
    while IFS= read -r rule; do
      read -ra words <<<"$rule"
      while "$ipt" -C "$parent" "${words[@]}" 2>/dev/null; do
        "$ipt" -D "$parent" "${words[@]}"
      done
    done < <(jumps "$chain")
    if "$ipt" -S "$chain" >/dev/null 2>&1; then
      "$ipt" -F "$chain"
      "$ipt" -X "$chain"
    fi
  done
  say "removed the rule for $what"
}

report() {
  if [ "$changed" = yes ]; then
    say "put the rule for $what in place"
  else
    say "the rule for $what is in place"
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
      [ "$changed" = no ] || die "the rule for $what is not in place"
      say "the rule for $what is in place"
      ;;
    --once)
      apply
      report
      ;;
    "")
      trap 'exit 0' TERM INT
      say "keeping the rule for $what, checked every ${interval}s"
      apply
      report
      while :; do
        sleep "$interval" &
        wait $!
        apply
        [ "$changed" = no ] || say "put the rule for $what back in place"
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
