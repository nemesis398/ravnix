#!/usr/bin/env bash
# chrome-devtools-mcp-helium: the Chrome DevTools MCP server, driving a
# headless Helium whose built-in uBlock Origin is switched off.
#
#   chrome-devtools-mcp-helium [SERVER-ARGS...]
#
# Claude Code starts it over stdio as the user-scope MCP server
# chrome-devtools (modules/common/chrome-devtools-mcp.nix). SERVER-ARGS go to
# the server after the fixed ones. The server and the browser are the store
# paths below; nothing is fetched or run through npx.
#
# Why uBO has to go (debugged on Fedora, 2026-11-07). Helium loads its own uBO
# (component id blockjmkbacgjkknlgpkjjiijinjdanf) into every profile, and no
# flag keeps it out: puppeteer passes --disable-extensions and
# --disable-component-extensions-with-background-pages, and uBO still runs.
# While uBO starts, it records the requests a tab makes before its listeners
# are ready, and once its filter lists are loaded it reloads those tabs
# (js/vapi-background-ext.js, unsuspendAllRequests). The server launches the
# browser on its first tool call and navigates at once, so the reload lands on
# the navigation the server waits for: navigate_page fails with
# net::ERR_ABORTED and new_page hangs. Setting suspendUntilListsAreLoaded to
# false is not enough, because two more paths reload (js/traffic.js,
# js/storage.js) and which runs first varies from launch to launch. With uBO
# off, every probe passed. It also keeps an ad blocker out of the traces and
# network lists, which should show a page the way its users see it.
#
# Why a fresh profile per launch. Every Claude Code session starts its own
# server, and a second browser on a shared profile fails with "The browser is
# already running for <dir>". So each launch makes a profile in a temporary
# directory (below) whose Preferences mark uBO as switched off by the user
# (disable_reasons [1]), which Helium honors from the first start, and removes
# it when the server exits. The directory name carries the wrapper's PID, so a
# launch removes the profiles of wrappers that were killed before they could
# clean up.
#
# Where the profile goes, and the TMPDIR of the server and the browser. The
# first of TMPDIR, XDG_RUNTIME_DIR and /tmp that is a writable directory with
# a short path. Chromium puts its singleton socket in TMPDIR, as
# .org.chromium.Chromium.XXXXXX/SingletonSocket, and a socket path is limited
# to 107 characters, so a TMPDIR over about 60 makes the browser exit at once,
# which the server reports as "Target closed". The wrapper does not rely on
# the caller's TMPDIR being short, as the Fedora wrapper did: it says why on
# stderr when it passes over one, and gives that directory to the server as
# TMPDIR, so the browser cannot be handed a long one. Profiles in a directory
# the wrapper passed over this time are not swept.
#
# Telemetry: --no-usage-statistics stops Google's usage statistics, and
# --no-performance-crux keeps trace URLs away from the CrUX API. The server's
# own check for a newer version (it asks the npm registry in a detached
# process) is off as well, since Nix decides the version.
#
# CHROME_DEVTOOLS_HELIUM overrides the browser (default: Helium of ravnix).

set -euo pipefail

readonly SERVER=@server@
readonly DEFAULT_BROWSER=@browser@
readonly UBO=blockjmkbacgjkknlgpkjjiijinjdanf
readonly PREFIX=chrome-devtools-helium.
readonly TMP_MAX=60

browser=${CHROME_DEVTOOLS_HELIUM:-$DEFAULT_BROWSER}

if [[ ! -f $browser || ! -x $browser ]]; then
    echo "chrome-devtools-mcp-helium: there is no browser at $browser" >&2
    exit 1
fi

tmp=
for candidate in "TMPDIR=${TMPDIR:-}" "XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-}" "fallback=/tmp"; do
    path=${candidate#*=}
    [[ -n $path ]] || continue
    if [[ ${#path} -gt $TMP_MAX ]]; then
        reason="more than $TMP_MAX characters, too long for Chromium's singleton socket"
    elif [[ ! -d $path || ! -w $path ]]; then
        reason="no writable directory"
    else
        tmp=$path
        break
    fi
    echo "chrome-devtools-mcp-helium: not using $candidate: $reason" >&2
done
if [[ -z $tmp ]]; then
    echo "chrome-devtools-mcp-helium: no writable directory with a short path for the profile (TMPDIR, XDG_RUNTIME_DIR, /tmp)" >&2
    exit 1
fi
export TMPDIR=$tmp

# Nix decides which version runs.
export CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS=1

# Remove the profiles of wrappers that are gone. kill -0 also fails for a PID
# that now belongs to another user, and the directory is ours either way.
for old in "$tmp/$PREFIX"*; do
    [[ -d $old && -O $old ]] || continue
    pid=${old##*/"$PREFIX"}
    pid=${pid%%.*}
    if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        continue
    fi
    rm -rf -- "$old"
done

profile=$(mktemp -d "$tmp/$PREFIX$$.XXXXXX")
trap 'rm -rf -- "$profile"' EXIT
mkdir -- "$profile/Default"
printf '{"extensions":{"settings":{"%s":{"disable_reasons":[1]}}}}\n' "$UBO" \
    >"$profile/Default/Preferences"

# In the background so a stop signal can be passed on and the profile still
# removed. Without <&0 a background job reads /dev/null instead of the
# MCP stream.
"$SERVER" --executablePath "$browser" --userDataDir "$profile" \
    --headless --no-usage-statistics --no-performance-crux "$@" <&0 &
server=$!
trap 'kill -TERM "$server" 2>/dev/null || true' TERM INT HUP

# A trapped signal ends a wait early, so wait until the server is really gone.
status=0
wait "$server" || status=$?
while kill -0 "$server" 2>/dev/null; do
    status=0
    wait "$server" || status=$?
done
exit "$status"
