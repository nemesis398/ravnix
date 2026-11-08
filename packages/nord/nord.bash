#!/usr/bin/env bash
# nord: the NordVPN tunnel as a plain NetworkManager WireGuard profile
# (NordLynx), with no Nord app and no daemon. The reasons for every setting
# are below.
#
# WHY NOT THE OFFICIAL APP. Since 5.0 its nftables firewall drops everything
# that is not on its own tunnel while connected, kill switch on or off, and
# that includes NetBird (wt0) and NetBird's own underlay traffic.
#
# HOW IT COEXISTS WITH NETBIRD. NetBird's policy rules (105, 110) sit ahead of
# the pair NM adds for a full-tunnel WireGuard profile (an even priority around
# 31000), so the mesh, the home LAN through a NetBird routing peer and
# NetBird's split-DNS domain stay on wt0, and everything else goes to Nord.
# One extra rule, priority 120, sends NetBird's own marked packets (fwmark
# 0x1bd00: management, signal, relay, ICE, its WireGuard socket) out the
# normal way instead of through Nord, so the mesh stays direct.
#   Never at home: DNS would move to Nord and local names stop resolving.
#   Never with a NetBird exit node: the two default routes would nest.
#
# WHAT THE PROFILE SETS, AND WHY:
#   allowed-ips 0.0.0.0/0;::/0  Nord is IPv4-only; ::/0 makes NM route IPv6
#                               into the tunnel too, where it dies, instead of
#                               leaking out of the Wi-Fi on dual-stack networks.
#   dns-search ~. at priority -50  NM's automatic "~." heuristic does not work
#                               with WireGuard's policy routing (a FIXME in
#                               nm-dns-manager.c), so without this every query
#                               still goes to the hotel's resolver. resolved
#                               picks the longest routing domain, so NetBird's
#                               own domain on wt0 still wins.
#   fwmark 0xca6c (51820)       pins the mark and the table instead of a random
#                               pick, outside NetBird's 0x1bd00 range. Write it
#                               in hex: nmcli reads "51820" as 0x51820.
#   ipv6.method link-local      the import sets "disabled", and then NM installs
#                               no IPv6 half of the tunnel at all. With only a
#                               link-local address, IPv6 to the internet has no
#                               usable source and fails at once, so apps fall
#                               back to IPv4 inside the tunnel.
#   autoconnect no              manual on purpose: captive portals need the
#                               tunnel down until the login is done.
#   keepalive 25                Nord's own client value; one packet per 25 s
#                               while up, which keeps hotel NAT mappings alive.
# While the profile is up, a dead server black-holes traffic rather than
# leaking it. There is no kill switch beyond that, by design.
#
# THE SECRET. The private key is system-owned (private-key-flags 0) in NM's
# root-only keyfile, like the Wi-Fi passwords, so the tunnel comes up even
# with Bitwarden locked. `setup` fetches it ONCE from Nord's API with an access
# token, the same endpoint Nord's own Linux client calls; Nord tolerates that
# but does not document it for manual use. Neither the token nor the key
# appears on a command line: the token reaches curl on its standard input, and
# the key reaches NM through a 0600 wg-quick file that is deleted at once.
#
# Usage:
#   nord                 # status, one line
#   nord up | down | toggle
#   nord refresh         # least-loaded recommended German server; re-up if on
#   nord setup           # one time: build the profile (see below)
#
# `setup` reads the access token from the Bitwarden item named in TOKEN_ITEM.
# Make it in Nord Account (NordVPN, Set up NordVPN manually, Access token),
# store it there, run `nord setup`, then REVOKE the token in Nord Account and
# delete the item: the key does not change when the token goes. The key item
# gets its `used by: nord` field in the web vault, because rbw cannot set
# custom fields. The token item is read by name only because it lives for
# minutes; a lasting item is read by UUID.
#
# In ravnix the three personal values below come from ravnix.vpn.nord
# (countryId, tokenItem, keyItem), baked in when the package is built. The
# environment overrides them (NORD_COUNTRY_ID, NORD_TOKEN_ITEM, NORD_KEY_ITEM),
# which is also how the command is used without ravnix.

set -uo pipefail

CON=nord
IFACE=wg-nord
FWMARK=0xca6c          # = 51820; nmcli reads this property as hex
NETBIRD_MARK=0x1bd00
NORD_DNS="103.86.96.100,103.86.99.100"
API=https://api.nordvpn.com/v1

# The values ravnix.vpn.nord holds, written in when the package is built (a
# shell word each; empty without ravnix). The environment wins.
baked_country_id=@countryId@
baked_token_item=@tokenItem@
baked_key_item=@keyItem@
COUNTRY_ID="${NORD_COUNTRY_ID:-$baked_country_id}"   # Nord's id of the country, 81 is Germany
TOKEN_ITEM="${NORD_TOKEN_ITEM:-$baked_token_item}"
KEY_ITEM="${NORD_KEY_ITEM:-$baked_key_item}"

notify() { command -v notify-send >/dev/null 2>&1 && notify-send -a "NordVPN" "$@"; }
die() { echo "nord: $*" >&2; exit 1; }

have_profile() { nmcli -t -f NAME connection show 2>/dev/null | grep -qxF "$CON"; }
is_up() { [ "$(nmcli -g GENERAL.STATE connection show "$CON" 2>/dev/null)" = activated ]; }

# Least-loaded recommended WireGuard server: "hostname station public_key".
recommend() {
  curl -fsS --max-time 15 -G "$API/servers/recommendations" \
      --data-urlencode "filters[country_id]=$COUNTRY_ID" \
      --data-urlencode "filters[servers_technologies][identifier]=wireguard_udp" \
      --data-urlencode "limit=1" \
    | jq -r '.[0] | [.hostname, .station,
        (.technologies[] | select(.identifier == "wireguard_udp")
           | .metadata[] | select(.name == "public_key") | .value)] | join(" ")'
}

peer_spec() { # peer_spec PUBKEY STATION
  printf '%s endpoint=%s:51820 allowed-ips=0.0.0.0/0;::/0 persistent-keepalive=25' "$1" "$2"
}

# Nord's own check of whether traffic leaves through Nord.
protected() {
  curl -fsS --max-time 8 "$API/helpers/ips/insights" 2>/dev/null | jq -r '.protected // empty'
}

status() {
  if ! have_profile; then echo "nord: no profile yet (run: nord setup)"; return; fi
  local ep
  ep=$(nmcli -g wireguard.peers connection show "$CON" 2>/dev/null | grep -o 'endpoint=[^ ]*' | cut -d= -f2 | tr -d '\134')
  if is_up; then echo "nord: on via ${ep:-?}"; else echo "nord: off (server ${ep:-?})"; fi
}

up() {
  have_profile || die "no profile yet (run: nord setup)"
  if ! out=$(nmcli --wait 20 connection up "$CON" 2>&1); then
    notify "NordVPN failed to start" "$out"; die "$out"
  fi
  # NM calls a WireGuard profile activated without any handshake, so ask Nord
  # whether traffic actually leaves through it.
  if [ "$(protected)" = true ]; then
    notify "NordVPN on" "$(status)"; status
  else
    notify -u critical "NordVPN up, but traffic is not protected" "Try: nord refresh"
    echo "nord: up, but Nord does not see the traffic as protected; try: nord refresh" >&2
    return 1
  fi
}

down() {
  is_up || { echo "nord: already off"; return 0; }
  nmcli connection down "$CON" >/dev/null && notify "NordVPN off" && echo "nord: off"
}

# The country is the one value every server request needs.
need_country() {
  [ -n "$COUNTRY_ID" ] || die "no country id: set ravnix.vpn.nord.countryId (or NORD_COUNTRY_ID)"
}

refresh() {
  have_profile || die "no profile yet (run: nord setup)"
  need_country
  local rec host station pub
  rec=$(recommend) || die "could not ask Nord's API for a server"
  read -r host station pub <<<"$rec"
  [ -n "$pub" ] || die "Nord's API returned no WireGuard server"
  nmcli connection modify "$CON" wireguard.peers "$(peer_spec "$pub" "$station")" || die "could not set the peer"
  echo "nord: server is now $host ($station)"
  if is_up; then up; fi
}

setup() {
  have_profile && die "a profile named '$CON' exists already; use: nord refresh"
  command -v rbw >/dev/null || die "rbw is needed to read the access token"
  [ -n "$TOKEN_ITEM" ] || die "no Bitwarden item for the access token: set ravnix.vpn.nord.tokenItem (or NORD_TOKEN_ITEM)"
  need_country
  local token key rec host station pub
  token=$(rbw get "$TOKEN_ITEM") || die "no Bitwarden item '$TOKEN_ITEM' (or the vault is locked)"
  # The token goes to curl as a config line on its standard input, so that it
  # is on no command line.
  key=$(printf 'user = "token:%s"\n' "$token" | curl -fsS --max-time 20 -K - "$API/users/services/credentials" | jq -r '.nordlynx_private_key // empty')
  unset token
  [ -n "$key" ] || die "Nord's API returned no NordLynx key (token expired or wrong scope?)"
  rec=$(recommend) || die "could not ask Nord's API for a server"
  read -r host station pub <<<"$rec"
  [ -n "$pub" ] || die "Nord's API returned no WireGuard server"

  # Not /tmp, which is RAM here; and the file is gone before setup ends.
  tmp=$(mktemp -d -p "${XDG_CACHE_HOME:-$HOME/.cache}")   # global: the EXIT trap runs after setup returns
  trap 'rm -rf "${tmp:-}"' EXIT
  ( umask 077
    printf '[Interface]\nPrivateKey = %s\nAddress = 10.5.0.2/32\n\n[Peer]\nPublicKey = %s\nAllowedIPs = 0.0.0.0/0, ::/0\nEndpoint = %s:51820\nPersistentKeepalive = 25\n' \
      "$key" "$pub" "$station" >"$tmp/$IFACE.conf" )
  nmcli connection import type wireguard file "$tmp/$IFACE.conf" >/dev/null || die "NM refused the import"
  rm -f "$tmp/$IFACE.conf"
  # An imported WireGuard profile is ACTIVATED at once, before any of the
  # settings below exist (found on the first real run, 2026-10-04: the tunnel
  # came up at home with no ~. DNS and no NetBird rule). Take it down first.
  nmcli connection down "$IFACE" >/dev/null 2>&1 || true

  nmcli connection modify "$IFACE" \
      connection.id "$CON" \
      connection.autoconnect no \
      wireguard.fwmark "$FWMARK" \
      wireguard.ip4-auto-default-route yes \
      wireguard.ip6-auto-default-route yes \
      ipv6.method link-local \
      ipv4.dns "$NORD_DNS" \
      ipv4.dns-search "~." \
      ipv4.dns-priority -50 \
      ipv6.dns-priority -50 \
      ipv4.routing-rules "priority 120 fwmark $NETBIRD_MARK table 254" \
      ipv6.routing-rules "priority 120 fwmark $NETBIRD_MARK table 254" \
    || die "the profile was imported as '$IFACE' but could not be finished; fix or delete it by hand"

  # A copy of the key in Bitwarden, as the record outside this machine. rbw
  # opens $EDITOR on a temp file; this editor copies the key file over it.
  ( umask 077; printf '%s\n' "$key" >"$tmp/key" )
  unset key
  if [ -z "$KEY_ITEM" ]; then
    echo "nord: no key item named (ravnix.vpn.nord.keyItem), so no copy of the key went to Bitwarden; the NM profile has it" >&2
  elif EDITOR="cp $tmp/key" rbw add "$KEY_ITEM" >/dev/null 2>&1; then
    echo "nord: key copied to Bitwarden as '$KEY_ITEM'"
  else
    echo "nord: could not copy the key to Bitwarden; the NM profile has it" >&2
  fi
  rm -f "$tmp/key"

  echo "nord: profile '$CON' ready, server $host ($station)"
  echo "Now REVOKE the access token in Nord Account and delete the Bitwarden item '$TOKEN_ITEM'."
}

case "${1:-status}" in
  status)  status ;;
  up)      up ;;
  down)    down ;;
  toggle)  if is_up; then down; else up; fi ;;
  refresh) refresh ;;
  setup)   setup ;;
  *) echo "usage: nord [status|up|down|toggle|refresh|setup]" >&2; exit 2 ;;
esac
