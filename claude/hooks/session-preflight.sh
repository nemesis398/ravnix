#!/usr/bin/env bash
# session-preflight.sh: SessionStart hook (claude/README.md). Looks for two
# things that go wrong quietly and otherwise surface in the middle of the
# work: Nextcloud conflicted copies, and a NetBird mesh that is down or about
# to go down.
#
# Why it warns and never blocks: a SessionStart hook cannot block (exit 2 or
# "decision": "block" turns into an error the model never sees). With
# findings it prints one JSON object: systemMessage is one line for the user,
# hookSpecificOutput.additionalContext is the detail for the model, kept
# under Claude Code's 10,000 character limit for hook context. With nothing to
# report it prints nothing. It exits 0 whatever happens.
#
# Runtime: Claude Code runs the SessionStart hooks in parallel, so this one is
# free while it stays well under a second. It starts one find, one netbird
# status, a jq or three and a date, about 30 ms when it was measured, half of
# them netbird's. Only a netbird that hangs costs more, 4 s at most.
#
# Its values come from the ravnix skill values, the JSON file that
# RAVNIX_SKILL_VALUES names, else ${XDG_CONFIG_HOME:-~/.config}/ravnix/
# skill-values.json, which the ravnix module renders from
# ravnix.claude.skillValues:
#   nextcloud.root         the tree to scan for conflicted copies; without it
#                          (and without PREFLIGHT_NEXTCLOUD_ROOT, which wins
#                          over it) nothing is scanned
#   vault.root             a notes vault in that tree, whose copies are
#                          counted as "vault" and come with the vault's rule
#   vault.rule             that rule, a sentence or two on how the vault may
#                          be changed; without it the rule is to change
#                          nothing in the vault without the user's go-ahead
#   netbird.managementUrl  the management server the peer must be enrolled
#                          with; without it no server counts as wrong
#   netbird.whenDown       what fails while the mesh is down, told with every
#                          warning that the mesh is or goes down
# A value that is missing or not a string counts as not set. Without jq the
# values cannot be read, and only PREFLIGHT_NEXTCLOUD_ROOT is.
#
# Conflicted copies: the Nextcloud client makes one when this machine and the
# server both changed a file, named
#   <base> (conflicted copy YYYY-MM-DD HHMMSS)<.ext>
# with the marker at the end for a dotfile or a name without an extension.
# The client recognizes one by a substring of the name: "_conflict-" (its old
# naming), "(conflicted copy" or "(case clash from". This hook uses the same
# test, so a note named conflict-resolution.md is not one. The copy holds this
# machine's version and is never uploaded; the original holds the server's.
# Deleting the copy stays local, deleting the original reaches every device,
# which is why the context spells out which side is which. The scan skips
# .git, node_modules, __pycache__ and .claude/worktrees.
#
# NetBird: a service that only the mesh reaches fails, often with a
# misleading error, while the mesh is down; netbird.whenDown says how. A
# peer's SSO session ends 24 h after its last login, and while the peer is
# connected only `netbird login --extend` moves that end: `netbird up`, even
# after `netbird down`, keeps the old one (both measured with NetBird 0.79).
# So the hook warns when the management server is not connected, when the
# peer is enrolled with another server or never was, and when the session
# ends within 2 h; a session that has already ended counts as not connected.
# A setup-key peer has no end, and its sessionExpiresAt is empty or Go's zero
# time. Output the hook cannot read gets a mild "cannot tell" note, never an
# alarm. Without netbird installed the check is skipped.
#
# No set -e or -u: any probe may fail, and the hook must still exit 0.

max_listed=20      # conflicted copies named in the context; the rest are counted
max_context=9000   # characters of context; Claude Code's limit is 10,000
now=$EPOCHSECONDS

cf_short="" cf_detail="" nb_short="" nb_detail=""

have_jq=""
type -P jq >/dev/null && have_jq=1

# The skill values, one line each. Control characters become spaces, so a
# value cannot add lines to the context.
nc_value="" vault_root="" vault_note="" mesh_url="" down_note=""
values=${RAVNIX_SKILL_VALUES:-${XDG_CONFIG_HOME:-$HOME/.config}/ravnix/skill-values.json}
if [[ -n $have_jq && -f $values && -r $values ]]; then
    { IFS= read -r nc_value; IFS= read -r vault_root; IFS= read -r vault_note
      IFS= read -r mesh_url; IFS= read -r down_note; } < <(
        jq -r 'def text(f): ((f)? | strings) // "" | gsub("[[:cntrl:]]"; " ");
            text(.nextcloud.root), text(.vault.root), text(.vault.rule),
            text(.netbird.managementUrl), text(.netbird.whenDown)' \
            "$values" 2>/dev/null </dev/null
    )
fi

root=${PREFLIGHT_NEXTCLOUD_ROOT:-$nc_value}
root=${root%/}
vault_root=${vault_root%/}
mesh_url=${mesh_url%/}

login_note="Its SSO login opens in the user's browser, so ask the user to run it."

# --- conflicted copies ---------------------------------------------------------

# is_conflict <name>: true when the name carries one of the client's markers.
is_conflict() {
    case $1 in
        *_conflict-* | *'(conflicted copy'* | *'(case clash from'*) return 0 ;;
    esac
    return 1
}

# conflict_base <name>: sets base to the name of the file a conflicted copy
# was made from, the way the client works it out: cut out the rightmost
# marker, so a copy of a copy yields the first copy. "(conflicted copy ...)"
# and "(case clash from ...)" end at their ")" and take the space before them
# along; the old "_conflict-<date>-<time>" ends at the next dot or at the end.
conflict_base() {
    local name=$1 marker pre keep="" rest="" len=-1
    for marker in '_conflict-' '(conflicted copy' '(case clash from'; do
        pre=${name%"$marker"*}
        if [[ $pre != "$name" ]] && ((${#pre} > len)); then
            keep=$pre len=${#pre} rest=${name:len}
        fi
    done
    [[ $rest == '('* ]] && keep=${keep% }
    if [[ $rest == '('*')'* ]]; then
        base=$keep${rest#*)}
    elif [[ $rest == *.* ]]; then
        base=$keep.${rest#*.}
    else
        base=$keep
    fi
}

check_conflicts() {
    [[ -n $root ]] || return 0
    local hits=() p rel tree n=0 list="" where="" t total state vault_rule
    local -A count=()
    local order=()
    mapfile -d '' -t hits < <(find -H "$root" \
        \( -name .git -o -name node_modules -o -name __pycache__ -o -path '*/.claude/worktrees' \) -prune \
        -o \( -name '*_conflict-*' -o -name '*(conflicted copy*' -o -name '*(case clash from*' \) -print0 \
        2>/dev/null </dev/null | LC_ALL=C sort -z)
    total=${#hits[@]}
    ((total)) || return 0

    for p in "${hits[@]}"; do
        # Counted per tree: the vault, else the first folder under the root.
        rel=${p#"$root"/}
        if [[ -n $vault_root && $p == "$vault_root"/* ]]; then
            tree=vault
        else
            case $rel in
                */*) tree=${rel%%/*} ;;
                *)   tree=${root##*/} ;;
            esac
        fi
        tree=${tree//[[:cntrl:]]/?}
        [[ -n ${count[$tree]} ]] || order+=("$tree")
        count[$tree]=$((${count[$tree]:-0} + 1))

        ((++n <= max_listed)) || continue
        conflict_base "${p##*/}"
        if [[ ! -e ${p%/*}/$base && ! -L ${p%/*}/$base ]]; then
            state="original missing: $base"
        elif is_conflict "$base"; then
            state="original: $base, itself a conflicted copy"
        else
            state="original: $base"
        fi
        # Control characters in a name could fake lines of the context.
        list+=$'\n'"- ${p//[[:cntrl:]]/?}"$'\n'"  ${state//[[:cntrl:]]/?}"
    done
    ((total > max_listed)) &&
        list+=$'\n'"- and $((total - max_listed)) more; this lists them all: find ${root//[[:cntrl:]]/?} -name '*_conflict-*' -o -name '*(conflicted copy*' -o -name '*(case clash from*'"

    for t in "${order[@]}"; do
        where+=", $t ${count[$t]}"
    done
    if ((total == 1)); then
        cf_short="1 Nextcloud conflicted copy: ${where#, }"
    else
        cf_short="$total Nextcloud conflicted copies: ${where#, }"
    fi
    vault_rule=""
    if [[ -n $vault_root ]]; then
        vault_rule=" In the vault (${vault_root//[[:cntrl:]]/?}) change nothing without the user's go-ahead."
        [[ -n $vault_note ]] && vault_rule=" In the vault (${vault_root//[[:cntrl:]]/?}): $vault_note"
    fi
    cf_detail="Nextcloud conflicted copies: $total under ${root//[[:cntrl:]]/?}, listed at the end. The Nextcloud client makes one when this machine and the server both changed a file. The conflicted copy holds this machine's version and was never uploaded; the original, in the same folder, holds the server's version. Deleting a conflicted copy stays on this machine; deleting or overwriting an original reaches every device.
Raise them with the user before you work in those trees. To resolve one, merge what the conflicted copy has and the original lacks into the original, then remove only the conflicted copy, never the original. Where the original is missing, the copy may hold the only version of that content: ask the user.$vault_rule$list"
}

# --- NetBird --------------------------------------------------------------------

# nb_unknown <why> <short why>: the mild note for output the hook cannot read.
nb_unknown() {
    nb_short="NetBird state unknown ($2)"
    nb_detail="NetBird: cannot tell whether the mesh is up: $1. Nothing is known to be wrong. If a service that only the mesh reaches fails, check \`netbird status\` first, because a mesh that is down causes exactly that."
}

# nb_down <why>: the management server is not connected.
nb_down() {
    nb_short="NetBird down: run netbird up"
    nb_detail="NetBird: this machine is off the mesh ($1).${down_note:+ $down_note} The fix is \`netbird up\`. $login_note"
}

check_netbird() {
    local out rc connected="" url="" expires="" status="" error="" first exp_at left when why fix
    type -P netbird >/dev/null || return 0
    if [[ -z $have_jq ]]; then
        nb_unknown "jq is not installed, so netbird status --json cannot be read" "no jq"
        return
    fi

    # timeout signals netbird's whole process group, so nothing it started
    # keeps the pipe open. 124 is SIGTERM after 3 s, 137 the SIGKILL a second later.
    out=$(timeout -k 1 3 netbird status --json 2>&1 </dev/null)
    rc=$?
    if ((rc == 124 || rc == 137)); then
        nb_unknown "netbird status --json did not answer within 3 s" "status timed out"
        return
    fi

    # One line per field, an empty line for a missing one or the wrong type.
    local prog='def text(f): ((f)? | strings) // "" | gsub("[[:cntrl:]]"; " ");
(((.management.connected)? | booleans | tostring) // ""),
text(.management.url), text(.sessionExpiresAt), text(.daemonStatus), text(.management.error)'
    { IFS= read -r connected; IFS= read -r url; IFS= read -r expires
      IFS= read -r status; IFS= read -r error; } <<<"$(jq -r "$prog" 2>/dev/null <<<"$out")"

    if [[ $connected != true && $connected != false ]]; then
        # Not the JSON. A peer that needs a login prints prose instead,
        # "Daemon status: NeedsLogin" and how to log in.
        if [[ $out =~ Daemon\ status:\ *([[:alpha:]]+) ]] &&
            [[ ${BASH_REMATCH[1]} == @(NeedsLogin|LoginFailed|SessionExpired) ]]; then
            status=${BASH_REMATCH[1]}
            if [[ -n $mesh_url ]]; then
                nb_short="NetBird needs a login ($status): run netbird up --management-url $mesh_url"
                fix="The fix is \`netbird up --management-url $mesh_url\`"
            else
                nb_short="NetBird needs a login ($status): run netbird up --management-url <your server>"
                fix="The fix is \`netbird up --management-url\` with the user's management server (set netbird.managementUrl in the ravnix skill values to have it named here)"
            fi
            nb_detail="NetBird: the daemon reports $status, so this machine is off the mesh: it was never enrolled, or its login ended.${down_note:+ $down_note} $fix; a bare \`netbird up\` on a machine that was never enrolled goes to NetBird's cloud at https://api.netbird.io:443, the default. $login_note"
            return
        fi
        first=${out#"${out%%[![:space:]]*}"}
        first=${first%%$'\n'*}
        first=${first//[[:cntrl:]]/ }
        if [[ -n $first ]]; then
            nb_unknown "netbird status --json printed no usable JSON (exit $rc, first line: ${first:0:160})" "status unreadable"
        else
            nb_unknown "netbird status --json printed nothing (exit $rc)" "status unreadable"
        fi
        return
    fi

    url=${url%/}
    # The same server with or without its default port.
    if [[ -n $mesh_url && -n $url && ${url%:443} != "${mesh_url%:443}" ]]; then
        nb_short="NetBird on the wrong server: ${url:0:80}"
        nb_detail="NetBird: this machine is enrolled with $url, not with $mesh_url, so it is off the mesh.${down_note:+ $down_note} The fix is \`netbird down\`, then \`netbird up --management-url $mesh_url\`. $login_note"
        return
    fi
    if [[ $connected == false ]]; then
        why="management server not connected"
        [[ -n $status ]] && why+="; daemon status ${status:0:40}"
        [[ -n $error ]] && why+="; error: ${error:0:200}"
        nb_down "$why"
        return
    fi

    # Connected. An empty expiry is a peer whose session does not end.
    [[ -n $expires ]] || return 0
    # date -d also takes "tomorrow", so only an RFC 3339 time goes to it.
    if [[ ! $expires =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}[Tt\ ][0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})$ ]] ||
        ! exp_at=$(date -d "$expires" +%s 2>/dev/null) || [[ ! $exp_at =~ ^-?[0-9]+$ ]]; then
        nb_unknown "sessionExpiresAt is \"${expires:0:60}\", which is not a time it can read, so it cannot tell when the SSO session ends" "session end unreadable"
        return
    fi
    # Go's zero time (year 1) or the epoch: no end either.
    ((exp_at > 0)) || return 0
    if ((exp_at <= now)); then
        printf -v when '%(%Y-%m-%d %H:%M %Z)T' "$exp_at"
        nb_down "its SSO session ended at $when"
        return
    fi
    ((exp_at - now <= 7200)) || return 0
    left=$(((exp_at - now + 59) / 60))
    if ((left % 60 == 0)); then
        left="$((left / 60)) h"
    elif ((left > 60)); then
        left="$((left / 60)) h $((left % 60)) min"
    else
        left="$left min"
    fi
    printf -v when '%(%H:%M)T' "$exp_at"
    nb_short="NetBird session ends at $when (in $left): run netbird login --extend"
    printf -v when '%(%H:%M %Z)T' "$exp_at"
    nb_detail="NetBird: this machine's SSO session ends at $when, in $left, and the mesh goes down with it.${down_note:+ $down_note} \`netbird login --extend\` renews the session for another 24 h without dropping the tunnel; \`netbird up\` does not, even after \`netbird down\`. $login_note"
}

# --- output --------------------------------------------------------------------

check_conflicts
check_netbird

[[ -n $cf_short || -n $nb_short ]] || exit 0

sys=$cf_short
[[ -n $nb_short ]] && sys+=${sys:+ · }$nb_short
ctx="Session preflight, a SessionStart hook, checked this machine. The user saw a one-line summary of what follows."
# NetBird first: the conflict list is last, so a cut to the limit only loses list entries.
[[ -n $nb_detail ]] && ctx+=$'\n\n'$nb_detail
[[ -n $cf_detail ]] && ctx+=$'\n\n'$cf_detail

if [[ -n $have_jq ]]; then
    jq -nc --arg sys "$sys" --arg ctx "$ctx" --argjson max "$max_context" '{
        systemMessage: $sys,
        hookSpecificOutput: {
            hookEventName: "SessionStart",
            additionalContext: (if ($ctx | length) > $max
                then $ctx[:$max] + "\n[cut here to stay under the hook context limit]"
                else $ctx end)
        }}'
else
    # Without jq, plain stdout still reaches the model as SessionStart context.
    printf '%s\n' "${ctx:0:max_context}"
fi
exit 0
