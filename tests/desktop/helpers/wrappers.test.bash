#!/usr/bin/env bash
# Tests for the `nord` and `vpn-home` commands, run against stand-ins for
# nmcli, curl, rbw and notify-send (fake-*.sh), which record what they were
# called with and answer from files in FAKE_DIR. The commands come from
# packages/nord and packages/vpn-home, built with the stand-ins as their
# tools. The environment names them:
#
#   NORD             nord, built with country 77, token item "tok item" and
#                    key item "key item"
#   NORD_UNBAKED     nord, built with none of the three
#   VPN_HOME         vpn-home, built with gateway http://gateway.test:8080
#                    and token item "home item"
#   VPN_HOME_UNBAKED vpn-home, built with neither
#
#   bash tests/desktop/helpers/wrappers.test.bash
#
# It prints PASS or FAIL per test and exits non-zero if any test failed.

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/tests/lib.sh
. "$here/../../../scripts/tests/lib.sh"

: "${NORD:?}" "${NORD_UNBAKED:?}" "${VPN_HOME:?}" "${VPN_HOME_UNBAKED:?}"

# What the stand-in Nord API answers, and what the commands must not leak.
key="SENTINEL+NORDLYNX+KEY+0123456789abcdefghijklm="
pub="PUBKEYAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="
peers="$pub endpoint=192.0.2.10:51820 allowed-ips=0.0.0.0/0\;::/0 persistent-keepalive=25"

fresh() {
	rm -rf -- "${scratch:?}/fake" "${scratch:?}/cache"
	mkdir -p "$scratch/fake" "$scratch/cache"
	export FAKE_DIR="$scratch/fake" XDG_CACHE_HOME="$scratch/cache" HOME="$scratch"
	unset NORD_COUNTRY_ID NORD_TOKEN_ITEM NORD_KEY_ITEM VPN_HOME_API VPN_HOME_TOKEN_ITEM
}

# The state files of the stand-ins.
fake() { touch "$FAKE_DIR/$1"; }
log() { cat "$FAKE_DIR/$1.log" 2>/dev/null || true; }
has_log() { # has_log NAME TEXT: the call log of NAME holds TEXT
	[[ "$(log "$1")" == *"$2"* ]] || {
		echo "  expected the $1 calls to contain '$2', got: $(log "$1")"
		return 1
	}
}
lacks_log() {
	[[ "$(log "$1")" != *"$2"* ]] || {
		echo "  expected the $1 calls not to contain '$2', got: $(log "$1")"
		return 1
	}
}
profile_exists() { echo nord >"$FAKE_DIR/profile"; }
profile_with_server() {
	profile_exists
	printf '%s\n' "$peers" >"$FAKE_DIR/peers"
}
nord_api() {
	cat >"$FAKE_DIR/recommend.json" <<JSON
[{"hostname":"de1.example","station":"192.0.2.10","technologies":[
  {"identifier":"openvpn_udp","metadata":[{"name":"public_key","value":"WRONG"}]},
  {"identifier":"wireguard_udp","metadata":[{"name":"public_key","value":"$pub"}]}]}]
JSON
	echo "{\"nordlynx_private_key\":\"$key\"}" >"$FAKE_DIR/credentials.json"
	echo '{"protected":true}' >"$FAKE_DIR/insights.json"
}

# --- nord: status ---------------------------------------------------------

it_nord_status_says_there_is_no_profile() {
	fresh
	capture "$NORD"
	expect_status 0
	expect_out "nord: no profile yet (run: nord setup)"
}

it_nord_status_shows_the_server_when_off() {
	fresh
	profile_with_server
	capture "$NORD" status
	expect_status 0
	[[ "$out" == "nord: off (server 192.0.2.10:51820)" ]] || { echo "  got: $out"; return 1; }
}

it_nord_status_shows_the_server_when_on() {
	fresh
	profile_with_server
	fake up
	capture "$NORD" status
	expect_status 0
	[[ "$out" == "nord: on via 192.0.2.10:51820" ]] || { echo "  got: $out"; return 1; }
}

it_nord_status_survives_a_profile_without_peers() {
	fresh
	profile_exists
	capture "$NORD" status
	expect_status 0
	expect_out "nord: off (server ?)"
}

# --- nord: up, down, toggle ----------------------------------------------

it_nord_up_needs_a_profile() {
	fresh
	capture "$NORD" up
	expect_status 1
	expect_err "no profile yet (run: nord setup)"
	lacks_log nmcli "connection up"
}

it_nord_up_activates_and_asks_nord_whether_it_works() {
	fresh
	profile_with_server
	nord_api
	capture "$NORD" up
	expect_status 0
	expect_out "nord: on via 192.0.2.10:51820"
	has_log nmcli "--wait 20 connection up nord"
	has_log curl "/helpers/ips/insights"
	has_log notify "NordVPN on"
}

it_nord_up_fails_loudly_when_nord_does_not_see_the_traffic() {
	fresh
	profile_with_server
	nord_api
	echo '{"protected":false}' >"$FAKE_DIR/insights.json"
	capture "$NORD" up
	expect_status 1
	expect_err "Nord does not see the traffic as protected"
	has_log notify "-u critical NordVPN up, but traffic is not protected"
}

it_nord_up_treats_an_unreachable_insights_api_as_unprotected() {
	fresh
	profile_with_server
	fake curl-fails
	capture "$NORD" up
	expect_status 1
	expect_err "Nord does not see the traffic as protected"
}

it_nord_up_reports_the_error_of_networkmanager() {
	fresh
	profile_with_server
	fake up-fails
	capture "$NORD" up
	expect_status 1
	expect_err "Connection activation failed: fake"
	has_log notify "NordVPN failed to start"
	lacks_log curl "insights"
}

it_nord_down_when_off_does_nothing() {
	fresh
	profile_with_server
	capture "$NORD" down
	expect_status 0
	expect_out "nord: already off"
	lacks_log nmcli "connection down"
}

it_nord_down_without_a_profile_does_nothing() {
	fresh
	capture "$NORD" down
	expect_status 0
	expect_out "nord: already off"
}

it_nord_down_when_on_takes_the_profile_down() {
	fresh
	profile_with_server
	fake up
	capture "$NORD" down
	expect_status 0
	expect_out "nord: off"
	has_log nmcli "connection down nord"
	[[ ! -e "$FAKE_DIR/up" ]]
}

it_nord_toggle_goes_both_ways() {
	fresh
	profile_with_server
	nord_api
	capture "$NORD" toggle
	expect_status 0
	[[ -e "$FAKE_DIR/up" ]]
	capture "$NORD" toggle
	expect_status 0
	[[ ! -e "$FAKE_DIR/up" ]]
}

# --- nord: refresh --------------------------------------------------------

it_nord_refresh_asks_for_the_baked_country_and_sets_the_peer() {
	fresh
	profile_exists
	nord_api
	capture "$NORD" refresh
	expect_status 0
	expect_out "nord: server is now de1.example (192.0.2.10)"
	has_log curl "filters[country_id]=77"
	has_log curl "filters[servers_technologies][identifier]=wireguard_udp"
	has_log curl "limit=1"
	# The WireGuard key of the server, not the OpenVPN one before it.
	[[ "$(cat "$FAKE_DIR/peers")" == "$pub endpoint=192.0.2.10:51820 allowed-ips=0.0.0.0/0;::/0 persistent-keepalive=25" ]]
	lacks_log nmcli "connection up"
}

it_nord_refresh_brings_a_running_tunnel_back_up() {
	fresh
	profile_with_server
	fake up
	nord_api
	capture "$NORD" refresh
	expect_status 0
	has_log nmcli "--wait 20 connection up nord"
}

it_nord_refresh_takes_the_country_from_the_environment_when_none_is_baked() {
	fresh
	profile_exists
	nord_api
	NORD_COUNTRY_ID=33 capture "$NORD_UNBAKED" refresh
	expect_status 0
	has_log curl "filters[country_id]=33"
}

it_nord_refresh_without_any_country_says_so_and_asks_nothing() {
	fresh
	profile_exists
	nord_api
	capture "$NORD_UNBAKED" refresh
	expect_status 1
	expect_err "ravnix.vpn.nord.countryId"
	[[ -z "$(log curl)" ]]
}

it_nord_refresh_needs_a_profile() {
	fresh
	nord_api
	capture "$NORD" refresh
	expect_status 1
	expect_err "no profile yet"
}

it_nord_refresh_keeps_the_peer_when_the_api_is_down() {
	fresh
	profile_with_server
	fake curl-fails
	capture "$NORD" refresh
	expect_status 1
	expect_err "could not ask Nord's API for a server"
	[[ "$(cat "$FAKE_DIR/peers")" == "$peers" ]]
}

it_nord_refresh_keeps_the_peer_when_the_api_answers_nothing() {
	fresh
	profile_with_server
	: >"$FAKE_DIR/recommend.json"
	capture "$NORD" refresh
	expect_status 1
	expect_err "Nord's API returned no WireGuard server"
	[[ "$(cat "$FAKE_DIR/peers")" == "$peers" ]]
}

it_nord_refresh_keeps_the_peer_when_the_api_answers_an_empty_list() {
	fresh
	profile_with_server
	echo '[]' >"$FAKE_DIR/recommend.json"
	capture "$NORD" refresh
	expect_status 1
	[[ "$(cat "$FAKE_DIR/peers")" == "$peers" ]]
}

it_nord_refresh_keeps_the_peer_when_the_api_answers_garbage() {
	fresh
	profile_with_server
	echo '<html>502 Bad Gateway</html>' >"$FAKE_DIR/recommend.json"
	capture "$NORD" refresh
	expect_status 1
	[[ "$(cat "$FAKE_DIR/peers")" == "$peers" ]]
}

it_nord_refresh_keeps_the_peer_when_the_server_has_no_wireguard() {
	fresh
	profile_with_server
	echo '[{"hostname":"x","station":"192.0.2.1","technologies":[{"identifier":"openvpn_udp","metadata":[]}]}]' >"$FAKE_DIR/recommend.json"
	capture "$NORD" refresh
	expect_status 1
	[[ "$(cat "$FAKE_DIR/peers")" == "$peers" ]]
}

# --- nord: setup ----------------------------------------------------------

it_nord_setup_builds_the_profile_the_header_promises() {
	fresh
	nord_api
	capture "$NORD" setup
	expect_status 0
	expect_out "nord: profile 'nord' ready, server de1.example (192.0.2.10)"
	expect_out "REVOKE the access token"
	expect_out "delete the Bitwarden item 'tok item'"
	# The token came from the item that was named, by rbw.
	has_log rbw "get tok item"
	# The import file holds the key, the server and the tunnel address.
	imported="$(cat "$FAKE_DIR/imported.conf")"
	[[ "$imported" == *"PrivateKey = $key"* ]]
	[[ "$imported" == *"PublicKey = $pub"* ]]
	[[ "$imported" == *"Endpoint = 192.0.2.10:51820"* ]]
	[[ "$imported" == *"Address = 10.5.0.2/32"* ]]
	[[ "$imported" == *"PersistentKeepalive = 25"* ]]
	# Every setting of the profile.
	props="$(cat "$FAKE_DIR/props")"
	for want in \
		"connection.autoconnect=no" \
		"wireguard.fwmark=0xca6c" \
		"wireguard.ip4-auto-default-route=yes" \
		"wireguard.ip6-auto-default-route=yes" \
		"ipv6.method=link-local" \
		"ipv4.dns=103.86.96.100,103.86.99.100" \
		"ipv4.dns-search=~." \
		"ipv4.dns-priority=-50" \
		"ipv6.dns-priority=-50" \
		"ipv4.routing-rules=priority 120 fwmark 0x1bd00 table 254" \
		"ipv6.routing-rules=priority 120 fwmark 0x1bd00 table 254"; do
		[[ "$props" == *"$want"* ]] || { echo "  the profile lacks $want; it has: $props"; return 1; }
	done
	[[ "$(cat "$FAKE_DIR/profile")" == nord ]]
}

it_nord_setup_takes_the_imported_profile_down_before_it_changes_it() {
	fresh
	nord_api
	capture "$NORD" setup
	expect_status 0
	# Importing activates the profile, before the DNS and the NetBird rule
	# exist: the first real run brought the tunnel up at home.
	local down modify
	down="$(grep -n 'connection down wg-nord' "$FAKE_DIR/nmcli.log" | head -1 | cut -d: -f1)"
	modify="$(grep -n 'connection modify wg-nord' "$FAKE_DIR/nmcli.log" | head -1 | cut -d: -f1)"
	[[ -n "$down" && -n "$modify" && "$down" -lt "$modify" ]] || {
		echo "  the import must go down before the modify: $(log nmcli)"
		return 1
	}
	[[ ! -e "$FAKE_DIR/up" ]]
}

it_nord_setup_keeps_the_key_and_the_token_off_every_command_line() {
	fresh
	nord_api
	capture "$NORD" setup
	expect_status 0
	for name in nmcli curl rbw notify; do
		lacks_log "$name" "$key"
		lacks_log "$name" "secret-for-tok item"
	done
	# The token reaches curl on its standard input only.
	[[ "$(cat "$FAKE_DIR/curl.stdin")" == *'user = "token:secret-for-tok item"'* ]]
	# And neither is printed.
	expect_no_out "$key"
	expect_no_err "$key"
	expect_no_out "secret-for-tok item"
}

it_nord_setup_leaves_no_file_with_the_key_behind() {
	fresh
	nord_api
	capture "$NORD" setup
	expect_status 0
	[[ -z "$(ls -A "$XDG_CACHE_HOME")" ]] || { echo "  left in the cache: $(ls -A "$XDG_CACHE_HOME")"; return 1; }
}

it_nord_setup_files_a_copy_of_the_key_under_the_baked_name() {
	fresh
	nord_api
	capture "$NORD" setup
	expect_status 0
	expect_out "nord: key copied to Bitwarden as 'key item'"
	[[ "$(cat "$FAKE_DIR/rbw.added.name")" == "key item" ]]
	[[ "$(cat "$FAKE_DIR/rbw.added")" == "$key" ]]
}

it_nord_setup_files_the_key_although_visual_names_another_editor() {
	fresh
	nord_api
	# ravnix exports VISUAL=nvim, and rbw takes VISUAL before EDITOR: an editor
	# set only in EDITOR is never started. `false` stands for any editor that
	# is not the key copier.
	VISUAL=false EDITOR=false capture "$NORD" setup
	expect_status 0
	expect_out "nord: key copied to Bitwarden as 'key item'"
	[[ "$(cat "$FAKE_DIR/rbw.added")" == "$key" ]]
}

it_nord_setup_files_the_key_from_a_cache_directory_with_a_space() {
	fresh
	nord_api
	export XDG_CACHE_HOME="$scratch/cache dir"
	mkdir -p "$XDG_CACHE_HOME"
	capture "$NORD" setup
	expect_status 0
	expect_out "nord: key copied to Bitwarden as 'key item'"
	[[ "$(cat "$FAKE_DIR/rbw.added")" == "$key" ]]
	[[ -z "$(ls -A "$XDG_CACHE_HOME")" ]]
}

it_nord_setup_still_succeeds_when_the_copy_cannot_be_filed() {
	fresh
	nord_api
	fake rbw-add-fails
	capture "$NORD" setup
	expect_status 0
	expect_err "could not copy the key to Bitwarden; the NM profile has it"
	[[ -z "$(ls -A "$XDG_CACHE_HOME")" ]]
}

it_nord_setup_refuses_when_a_profile_exists() {
	fresh
	profile_exists
	nord_api
	capture "$NORD" setup
	expect_status 1
	expect_err "a profile named 'nord' exists already; use: nord refresh"
	[[ -z "$(log rbw)" ]]
}

it_nord_setup_reports_a_locked_vault_and_asks_nord_nothing() {
	fresh
	nord_api
	fake rbw-locked
	capture "$NORD" setup
	expect_status 1
	expect_err "no Bitwarden item 'tok item' (or the vault is locked)"
	[[ -z "$(log curl)" ]]
}

it_nord_setup_reads_the_token_item_from_the_environment_when_none_is_baked() {
	fresh
	nord_api
	NORD_COUNTRY_ID=33 NORD_TOKEN_ITEM="other item" NORD_KEY_ITEM="other key" capture "$NORD_UNBAKED" setup
	expect_status 0
	has_log rbw "get other item"
	[[ "$(cat "$FAKE_DIR/rbw.added.name")" == "other key" ]]
}

it_nord_setup_without_a_key_item_still_builds_the_profile_and_says_so() {
	fresh
	nord_api
	NORD_COUNTRY_ID=33 NORD_TOKEN_ITEM="other item" capture "$NORD_UNBAKED" setup
	expect_status 0
	expect_err "ravnix.vpn.nord.keyItem"
	expect_out "profile 'nord' ready"
	lacks_log rbw "add"
	[[ -z "$(ls -A "$XDG_CACHE_HOME")" ]]
}

it_nord_setup_without_any_token_item_says_which_option_to_set() {
	fresh
	nord_api
	capture "$NORD_UNBAKED" setup
	expect_status 1
	expect_err "ravnix.vpn.nord.tokenItem"
	[[ -z "$(log rbw)" ]]
	[[ -z "$(log curl)" ]]
}

it_nord_setup_stops_when_nord_gives_no_key() {
	fresh
	nord_api
	echo '{"message":"token expired"}' >"$FAKE_DIR/credentials.json"
	capture "$NORD" setup
	expect_status 1
	expect_err "Nord's API returned no NordLynx key"
	lacks_log nmcli "import"
}

it_nord_setup_stops_when_the_api_is_down() {
	fresh
	nord_api
	fake curl-fails
	capture "$NORD" setup
	expect_status 1
	expect_err "Nord's API returned no NordLynx key"
	lacks_log nmcli "import"
}

it_nord_setup_stops_when_the_api_has_no_server() {
	fresh
	nord_api
	echo '[]' >"$FAKE_DIR/recommend.json"
	capture "$NORD" setup
	expect_status 1
	lacks_log nmcli "import"
}

it_nord_setup_cleans_up_when_networkmanager_refuses_the_import() {
	fresh
	nord_api
	fake import-fails
	capture "$NORD" setup
	expect_status 1
	expect_err "NM refused the import"
	[[ -z "$(ls -A "$XDG_CACHE_HOME")" ]]
	[[ ! -e "$FAKE_DIR/rbw.added" ]]
}

it_nord_setup_says_what_to_do_when_the_profile_cannot_be_finished() {
	fresh
	nord_api
	fake modify-fails
	capture "$NORD" setup
	expect_status 1
	expect_err "the profile was imported as 'wg-nord' but could not be finished"
	[[ -z "$(ls -A "$XDG_CACHE_HOME")" ]]
}

# --- nord: arguments ------------------------------------------------------

it_nord_rejects_an_unknown_command() {
	fresh
	capture "$NORD" frobnicate
	expect_status 2
	expect_err "usage: nord [status|up|down|toggle|refresh|setup]"
}

# --- vpn-home -------------------------------------------------------------

home_reply() { echo '{"vpn":"on","clients":3}' >"$FAKE_DIR/home-reply.json"; }

it_vpn_home_on_posts_to_the_baked_gateway_with_the_token_on_stdin() {
	fresh
	home_reply
	capture "$VPN_HOME" on
	expect_status 0
	has_log curl "-X POST"
	has_log curl "http://gateway.test:8080/on"
	has_log rbw "get home item"
	[[ "$(cat "$FAKE_DIR/curl.stdin")" == *'Authorization: Bearer secret-for-home item'* ]]
	lacks_log curl "secret-for-home item"
	expect_no_out "secret-for-home item"
	# The answer comes back through jq.
	expect_out '"vpn": "on"'
}

it_vpn_home_off_posts_off() {
	fresh
	home_reply
	capture "$VPN_HOME" off
	expect_status 0
	has_log curl "-X POST"
	has_log curl "http://gateway.test:8080/off"
}

it_vpn_home_status_is_the_default_and_a_get() {
	fresh
	home_reply
	capture "$VPN_HOME"
	expect_status 0
	has_log curl "-X GET"
	has_log curl "http://gateway.test:8080/status"
	capture "$VPN_HOME" status
	expect_status 0
}

it_vpn_home_rejects_an_unknown_command_before_it_reads_the_token() {
	fresh
	capture "$VPN_HOME" sideways
	expect_status 2
	expect_err "usage: vpn-home on|off|status"
	[[ -z "$(log rbw)" ]]
	[[ -z "$(log curl)" ]]
}

it_vpn_home_reports_a_locked_vault_and_calls_nothing() {
	fresh
	fake rbw-locked
	capture "$VPN_HOME" on
	expect_status 1
	expect_err "vpn-home: rbw could not read the switch token (vault locked?)"
	[[ -z "$(log curl)" ]]
}

it_vpn_home_fails_when_the_gateway_does() {
	fresh
	fake curl-fails
	capture "$VPN_HOME" status
	((status != 0)) || { echo "  vpn-home succeeded against a dead gateway"; return 1; }
	[[ -z "$out" ]]
}

it_vpn_home_fails_when_the_gateway_answers_garbage() {
	fresh
	echo '<html>oops</html>' >"$FAKE_DIR/home-reply.json"
	capture "$VPN_HOME" status
	((status != 0)) || { echo "  vpn-home printed garbage as if it were JSON"; return 1; }
}

it_vpn_home_takes_gateway_and_item_from_the_environment_when_none_is_baked() {
	fresh
	home_reply
	VPN_HOME_API=http://other.test:9 VPN_HOME_TOKEN_ITEM="other item" capture "$VPN_HOME_UNBAKED" off
	expect_status 0
	has_log curl "http://other.test:9/off"
	has_log rbw "get other item"
}

it_vpn_home_without_any_gateway_says_which_option_to_set() {
	fresh
	home_reply
	capture "$VPN_HOME_UNBAKED" on
	expect_status 1
	expect_err "ravnix.vpn.home"
	[[ -z "$(log rbw)" ]]
	[[ -z "$(log curl)" ]]
}

tests=(
	it_nord_status_says_there_is_no_profile
	it_nord_status_shows_the_server_when_off
	it_nord_status_shows_the_server_when_on
	it_nord_status_survives_a_profile_without_peers
	it_nord_up_needs_a_profile
	it_nord_up_activates_and_asks_nord_whether_it_works
	it_nord_up_fails_loudly_when_nord_does_not_see_the_traffic
	it_nord_up_treats_an_unreachable_insights_api_as_unprotected
	it_nord_up_reports_the_error_of_networkmanager
	it_nord_down_when_off_does_nothing
	it_nord_down_without_a_profile_does_nothing
	it_nord_down_when_on_takes_the_profile_down
	it_nord_toggle_goes_both_ways
	it_nord_refresh_asks_for_the_baked_country_and_sets_the_peer
	it_nord_refresh_brings_a_running_tunnel_back_up
	it_nord_refresh_takes_the_country_from_the_environment_when_none_is_baked
	it_nord_refresh_without_any_country_says_so_and_asks_nothing
	it_nord_refresh_needs_a_profile
	it_nord_refresh_keeps_the_peer_when_the_api_is_down
	it_nord_refresh_keeps_the_peer_when_the_api_answers_nothing
	it_nord_refresh_keeps_the_peer_when_the_api_answers_an_empty_list
	it_nord_refresh_keeps_the_peer_when_the_api_answers_garbage
	it_nord_refresh_keeps_the_peer_when_the_server_has_no_wireguard
	it_nord_setup_builds_the_profile_the_header_promises
	it_nord_setup_takes_the_imported_profile_down_before_it_changes_it
	it_nord_setup_keeps_the_key_and_the_token_off_every_command_line
	it_nord_setup_leaves_no_file_with_the_key_behind
	it_nord_setup_files_a_copy_of_the_key_under_the_baked_name
	it_nord_setup_files_the_key_although_visual_names_another_editor
	it_nord_setup_files_the_key_from_a_cache_directory_with_a_space
	it_nord_setup_still_succeeds_when_the_copy_cannot_be_filed
	it_nord_setup_refuses_when_a_profile_exists
	it_nord_setup_reports_a_locked_vault_and_asks_nord_nothing
	it_nord_setup_reads_the_token_item_from_the_environment_when_none_is_baked
	it_nord_setup_without_a_key_item_still_builds_the_profile_and_says_so
	it_nord_setup_without_any_token_item_says_which_option_to_set
	it_nord_setup_stops_when_nord_gives_no_key
	it_nord_setup_stops_when_the_api_is_down
	it_nord_setup_stops_when_the_api_has_no_server
	it_nord_setup_cleans_up_when_networkmanager_refuses_the_import
	it_nord_setup_says_what_to_do_when_the_profile_cannot_be_finished
	it_nord_rejects_an_unknown_command
	it_vpn_home_on_posts_to_the_baked_gateway_with_the_token_on_stdin
	it_vpn_home_off_posts_off
	it_vpn_home_status_is_the_default_and_a_get
	it_vpn_home_rejects_an_unknown_command_before_it_reads_the_token
	it_vpn_home_reports_a_locked_vault_and_calls_nothing
	it_vpn_home_fails_when_the_gateway_does
	it_vpn_home_fails_when_the_gateway_answers_garbage
	it_vpn_home_takes_gateway_and_item_from_the_environment_when_none_is_baked
	it_vpn_home_without_any_gateway_says_which_option_to_set
)

run_tests "${tests[@]}"
