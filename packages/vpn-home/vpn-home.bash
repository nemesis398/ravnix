#!/usr/bin/env bash
# vpn-home: the switch of the home VPN gateway, a NordVPN tunnel that a Wi-Fi
# of the family network is routed through.
#   vpn-home on | off | status
# The token is read from Bitwarden and reaches curl on stdin, never on a
# command line. The gateway admits calls from its management network only.
#
# In ravnix the gateway and the token item come from ravnix.vpn.home (apiUrl,
# tokenItem), baked in when the package is built. The environment overrides
# them (VPN_HOME_API, VPN_HOME_TOKEN_ITEM), which is also how the command is
# used without ravnix.
set -euo pipefail

# The values ravnix.vpn.home holds, written in when the package is built (a
# shell word each; empty without ravnix). The environment wins.
baked_api=@apiUrl@
baked_token_item=@tokenItem@
API="${VPN_HOME_API:-$baked_api}"
ITEM_ID="${VPN_HOME_TOKEN_ITEM:-$baked_token_item}"

case "${1:-status}" in
    on|off) method=POST; path=/$1 ;;
    status) method=GET; path=/status ;;
    *) echo "usage: vpn-home on|off|status" >&2; exit 2 ;;
esac
[ -n "$API" ] && [ -n "$ITEM_ID" ] || { echo "vpn-home: no gateway or token item: set ravnix.vpn.home (or VPN_HOME_API and VPN_HOME_TOKEN_ITEM)" >&2; exit 1; }
token=$(rbw get "$ITEM_ID") || { echo "vpn-home: rbw could not read the switch token (vault locked?)" >&2; exit 1; }
printf 'header = "Authorization: Bearer %s"\n' "$token" \
    | curl -fsS -m 10 -X "$method" -K - "$API$path" | jq .
