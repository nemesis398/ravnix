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
# already running for <dir>". So each launch makes a directory of its own
# (below) with a profile in it, whose Preferences mark uBO as switched off by
# the user (disable_reasons [1]), which Helium honors from the first start, and
# removes the directory when the server exits. The directory name carries the
# wrapper's PID, so a launch removes the directories of wrappers that were
# killed before they could clean up.
#
# What a launch gets. One private directory (mode 700), cdh.PID.XXXXXX, in the
# first usable directory of TMPDIR and the fallback (below), with two
# directories in it:
#
#   profile/   the browser's profile, with its HTTP disk cache;
#   t/         the TMPDIR of the server and the browser, empty at the start.
#
# Why a TMPDIR of its own. The server writes the files its tools make
# (screenshots, Lighthouse reports, screencasts) to chrome-devtools-mcp-XXXXXX
# directories under os.tmpdir() and never removes them, and its file tools may
# read and write below os.tmpdir(), unless the client has told it other roots:
# upload_file, and the filePath of screenshots, traces and heap snapshots. With
# the shared /tmp, or the user's runtime directory (a RAM-backed directory that
# holds the user's sockets and credentials), as that root, the files of every
# session would pile up, and a prompt-injected page could have the agent read
# what is in the root. With t/ the root is an empty private directory, and
# everything in it goes with the launch.
#
# Where the directory goes, and why it is short. The first of TMPDIR and the
# fallback (CHROME_DEVTOOLS_HELIUM_FALLBACK_TMP, default /tmp) that is a
# writable directory, not inside $XDG_RUNTIME_DIR, and short. Chromium puts its
# singleton socket under TMPDIR, as .org.chromium.Chromium.XXXXXX/
# SingletonSocket, and a socket path is limited to 108 bytes. Measured with
# Helium 0.21.1.1: a TMPDIR of 62 bytes starts, one of 63 aborts, which the
# server reports as "Target closed". The wrapper does not rely on the caller's
# TMPDIR being short, as the Fedora wrapper did: with 46 bytes for the socket,
# 21 for cdh.PID.XXXXXX/t (PIDs have up to 7 digits) and one to spare, the
# directory above must be at most 40 bytes (bytes, not characters: the length
# is taken in the C locale). It says on stderr why it passes one over.
# Directories in a place the wrapper passed over this time are not swept.
#
# The browser's sandbox is not the caller's to switch off: the bundled
# Puppeteer adds --no-sandbox when PUPPETEER_DANGEROUS_NO_SANDBOX is "true", as
# a shell rc written for another project may have it exported, so the wrapper
# unsets it. CHROME_DEVEL_SANDBOX, which points Chromium at a setuid helper
# instead of the user-namespace sandbox Helium uses, goes with it. These are
# the only variables of the server's and Puppeteer's code that bear on the
# sandbox (checked in 1.12.0 by reading every process.env access).
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
readonly PREFIX=cdh.
# 107 bytes of socket path with a spare byte, minus the singleton socket's
# 46 bytes and the 21 of /cdh.PID.XXXXXX/t.
readonly TMP_MAX=40

# The length of $1 in bytes: the limit is on bytes, and ${#1} counts characters
# in a UTF-8 locale.
bytes() {
    local LC_ALL=C
    printf '%s' "${#1}"
}

browser=${CHROME_DEVTOOLS_HELIUM:-$DEFAULT_BROWSER}

if [[ ! -f $browser || ! -x $browser ]]; then
    echo "chrome-devtools-mcp-helium: there is no browser at $browser" >&2
    exit 1
fi

runtime=
if [[ -n ${XDG_RUNTIME_DIR:-} ]]; then
    runtime=$(realpath -m -- "$XDG_RUNTIME_DIR")
fi

tmp=
for candidate in "TMPDIR=${TMPDIR:-}" "fallback=${CHROME_DEVTOOLS_HELIUM_FALLBACK_TMP:-/tmp}"; do
    path=${candidate#*=}
    [[ -n $path ]] || continue
    if (($(bytes "$path") > TMP_MAX)); then
        reason="more than $TMP_MAX bytes, too long for Chromium's singleton socket"
    elif [[ ! -d $path || ! -w $path ]]; then
        reason="no writable directory"
    elif [[ -n $runtime && ( $(realpath -m -- "$path") == "$runtime" || $(realpath -m -- "$path") == "$runtime"/* ) ]]; then
        reason="inside the runtime directory, which is RAM and holds the user's sockets and credentials"
    else
        tmp=$path
        break
    fi
    echo "chrome-devtools-mcp-helium: not using $candidate: $reason" >&2
done
if [[ -z $tmp ]]; then
    echo "chrome-devtools-mcp-helium: no usable directory for the launch (TMPDIR, then CHROME_DEVTOOLS_HELIUM_FALLBACK_TMP or /tmp)" >&2
    exit 1
fi

# Nix decides which version runs, and the sandbox stays on.
export CHROME_DEVTOOLS_MCP_NO_UPDATE_CHECKS=1
unset PUPPETEER_DANGEROUS_NO_SANDBOX CHROME_DEVEL_SANDBOX

# Remove the directories of wrappers that are gone. Only ours: stat does not
# follow a link, so a link someone else made is not taken for ours. kill -0
# also fails for a PID that now belongs to another user, and the directory is
# ours either way. A directory that cannot be removed does not stop the launch.
for old in "$tmp/$PREFIX"*; do
    [[ -d $old && $(stat -c %u -- "$old" 2>/dev/null || true) == "$EUID" ]] || continue
    pid=${old##*/"$PREFIX"}
    pid=${pid%%.*}
    if [[ $pid =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
        continue
    fi
    rm -rf -- "$old" || echo "chrome-devtools-mcp-helium: could not remove $old" >&2
done

launch=$(mktemp -d "$tmp/$PREFIX$$.XXXXXX")
trap 'rm -rf -- "$launch"' EXIT
mkdir -m 700 -- "$launch/profile" "$launch/t"
mkdir -- "$launch/profile/Default"
printf '{"extensions":{"settings":{"%s":{"disable_reasons":[1]}}}}\n' "$UBO" \
    >"$launch/profile/Default/Preferences"
export TMPDIR=$launch/t

# In the background so a stop signal can be passed on and the directory still
# removed. Without <&0 a background job reads /dev/null instead of the
# MCP stream.
"$SERVER" --executablePath "$browser" --userDataDir "$launch/profile" \
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
