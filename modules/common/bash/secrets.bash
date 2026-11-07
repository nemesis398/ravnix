# shellcheck shell=bash
# _ravnix_secrets and _ravnix_claude_bin are assigned by bash.nix, before this
# file.
# shellcheck disable=SC2154
# ai-unlock and claude, ported from the Fedora .bashrc and changed in two
# respects.
#
# First, the file the Fedora one sourced (a loader of its own that a human
# wrote, with its variable names in it) is gone. Which variable comes from
# which Bitwarden item is ravnix.shell.secretEnv, and bash.nix writes it as
# the indexed array
#
#   _ravnix_secrets=('NAME=item name' ...)
#
# in name order. The names are checked to hold no "=". This file only reads it.
#
# Second, a secret goes into one process and no other. Fedora's ai-unlock
# exported every token into the shell it ran in, and every new shell loaded
# them again while the vault was unlocked, so every program started from a
# shell had them for as long as the shell lived, and kept them after rbw
# locked again. Now `ai-unlock` only unlocks, and `claude` (below) reads the
# items when Claude Code starts and puts them into the environment of that one
# process: Claude Code and the programs it starts see them, nothing else does.
#
# A secret is read with `rbw get` at the moment it is needed, goes into the
# environment as a plain value, and is never evaluated, written to a file,
# printed, put on a command line (where `ps` would show it) or kept in a shell
# variable that outlives the call. tests/common/helpers/functions.test.bash
# sources this file on its own, with stand-ins for rbw and claude.

# _ravnix_rbw_db: where rbw keeps its local copy of the vault for the account
# it is configured with. The name is rbw's own (src/dirs.rs of rbw 1.15): the
# server as written in its config, or "default" when there is none, with the
# control characters, "/", "%", ":" and every byte that is not ASCII written
# as %XX, then ":" and the email as it is, in the cache directory of the
# profile (rbw-PROFILE when RBW_PROFILE is set, else rbw). Fails when rbw's
# configuration cannot be read.
_ravnix_rbw_db() {
    local config url email encoded='' ch code i
    config=$(rbw config show 2>/dev/null) || return 1
    url=$(jq -r '.base_url // "default"' <<<"$config") || return 1
    email=$(jq -r '.email // empty' <<<"$config") || return 1
    [[ -n $email ]] || return 1
    # Byte by byte: the locale must not join the bytes of one character.
    local LC_ALL=C
    for ((i = 0; i < ${#url}; i++)); do
        ch=${url:i:1}
        printf -v code '%d' "'$ch"
        if ((code < 32 || code > 126)) || [[ $ch == [/%:] ]]; then
            printf -v ch '%%%02X' "$code"
        fi
        encoded+=$ch
    done
    printf '%s/rbw%s/%s:%s.json\n' "${XDG_CACHE_HOME:-$HOME/.cache}" "${RBW_PROFILE:+-$RBW_PROFILE}" "$encoded" "$email"
}

# ai-unlock: unlock the Bitwarden vault, so that `claude` can read its
# secrets. rbw-agent then stays unlocked (lock_timeout in rbw's config, 1h).
#
# The `rbw sync` is load-bearing: `rbw unlock` only decrypts the LOCAL database
# and `rbw get` only reads it, so neither ever contacts the server. Without the
# sync, a token rotated in the web vault stays invisible here until rbw-agent's
# own sync_interval (1h) happens to fire, and claude starts with the dead one.
#
# It is deliberately NOT in the && chain: syncing needs the vault server to be
# reachable. A failed sync must degrade to "use the cached copy", not to "load
# nothing". It runs BEFORE the unlock, because a sync needs only the tokens in
# the cache, not the master password, and that order keeps every path to one
# prompt.
#
# The one sync failure it repairs is a rejected refresh token, which rbw
# misreports as "missing field `access_token`". Vaultwarden's refresh tokens
# live 30 days and are replaced on every refresh, but rbw 1.13.2 keeps only the
# one from the login (upstream PR doy/rbw#378), so sync died exactly 30 days
# after each login. `rbw login` is a no-op while that token sits in the cache,
# so the cache is moved aside, and `rbw unlock` then logs in, syncs and
# unlocks behind the same single prompt. Any other sync error, an unreachable
# server included, leaves the cache alone. If rbw ever rewords the message, the
# match misses and this degrades to the cached copy.
#
# The moved copy holds the encrypted vault, its key derivation parameters and
# the dead tokens, so it does not stay: once an unlock has worked and left a
# cache of its own, the copies of this account are deleted. A failed login
# leaves them, since they are all there is until a login works.
# shellcheck disable=SC2016 # the backticks are part of rbw's message
ai-unlock() {
    local - out db
    set +a
    db=$(_ravnix_rbw_db) || db=''
    if ! out=$(rbw sync 2>&1); then
        if [[ $out == *'missing field `access_token`'* ]]; then
            rbw stop-agent
            if [[ -n $db && -e $db ]]; then
                mv -- "$db" "$db.stale-$(date +%F-%H%M%S)" &&
                    printf 'ai-unlock: the vault server rejected the refresh token, logging in again\n' >&2
            fi
        else
            printf '%s\nai-unlock: rbw sync failed, using the cached vault copy\n' "$out" >&2
        fi
    fi
    rbw unlock || return 1
    if [[ -n $db && -e $db ]]; then
        rm -f -- "$db".stale-*
    fi
    if ((${#_ravnix_secrets[@]} == 0)); then
        printf 'ai-unlock: unlocked. ravnix.shell.secretEnv names no secrets for claude to load.\n'
        return 0
    fi
    local entry names=()
    for entry in "${_ravnix_secrets[@]}"; do
        names+=("${entry%%=*}")
    done
    printf 'ai-unlock: unlocked. claude reads %s from the vault when it starts.\n' "${names[*]}"
}

# claude [ARGUMENTS]: Claude Code, with the secrets of ravnix.shell.secretEnv
# in its environment and in nobody else's. It is a function and not a script
# on PATH, for this reason: the package that home-manager puts on PATH is
# `claude` for every program (a launcher, `ssh host claude`, an editor), and a
# script of the same name would have to stand in front of it everywhere; the
# function covers what a person types in an interactive bash and leaves the
# rest as it is.
#
#   - Which claude it starts is _ravnix_claude_bin, when bash.nix sets it:
#     the absolute path of the claude in home-manager's profile, which holds
#     the package programs.claude-code installs (the build the gate verified
#     against the release manifest). A profile path and not a store path,
#     because a shell reads it once and lives for days: the profile follows
#     every switch, where a store path would keep the shell on the build it
#     started with, and fail with 127 once that is collected. Every branch
#     below starts that path and no other, the secrets' and every fallback's:
#     another claude earlier on the PATH (a native install in ~/.local/bin,
#     say) gets neither the secrets nor the command. If that file is not
#     there or not executable, that is an error like any missing command, and
#     the vault is not read for it. Empty (Claude Code is off, or has no
#     package), it starts the first claude on the PATH, as before.
#   - Inside Claude Code (CLAUDECODE is set) it adds nothing. Claude Code
#     copies the user's shell functions into the shells it starts, so this
#     function is there too, and it must not read the vault again for every
#     command an agent runs: the environment Claude Code runs with is
#     already the one it was started with.
#   - With the vault locked it starts claude without the secrets and says
#     which variables are missing and what unlocks them. It never asks for a
#     password itself, so `claude --version` in a script does not stop at a
#     prompt.
#   - Otherwise a subshell reads every item, one `rbw get` each, and only then
#     exports all the values at once and replaces itself with the real claude
#     (`exec`). Exporting last matters: an `rbw get` is a child process, and
#     one started after an export would carry the values read before it. The
#     values live in the subshell's variables for the length of the loop, are
#     passed by `export` and not on a command line, so `ps` does not show
#     them, and the subshell is gone, with its variables, when claude runs;
#     the interactive shell never held one. Standard input is /dev/null for
#     rbw, so a program that reads it cannot take what is piped into claude.
#   - It does not trace. `set -x` prints every command with its words
#     expanded, `value=...` and `export NAME=...` among them, to stderr or to
#     the file BASH_XTRACEFD names, where a terminal's scrollback or a log
#     would keep the secret. xtrace is off from the first line of the
#     function (the trace shows only `set +a +x +T` itself), so what PS4 or
#     BASH_XTRACEFD say does not matter, and `local -` gives the caller's
#     `set -x` back when the function returns. Functrace is off for the same
#     reason: a DEBUG trap the caller has under `set -T` would run inside the
#     subshell, where the values are.
# shellcheck disable=SC2120 # arguments are for the caller to give
claude() {
    # The options as they were when the function returns. Not allexport: with
    # `set -a` in the caller every variable below would be exported. Not
    # xtrace: it would print the secrets (see above). Not functrace: with
    # `set -T` a DEBUG trap of the caller is inherited by the subshell below
    # and runs before each of its commands, with the values in reach.
    local - bin launch
    set +a +x +T
    # bin is the file to start with the secrets, empty when there is none;
    # launch is the command for every start without them. With a configured
    # binary launch is that path itself, so a missing one fails as a command
    # that is not there, and no other claude takes its place.
    if [[ -n ${_ravnix_claude_bin-} ]]; then
        bin=$_ravnix_claude_bin
        [[ -f $bin && -x $bin ]] || bin=
        launch=("$_ravnix_claude_bin")
    else
        bin=$(type -P claude) || bin=
        launch=(command claude)
    fi
    if [[ -n ${CLAUDECODE-} ]] || ((${#_ravnix_secrets[@]} == 0)); then
        "${launch[@]}" "$@"
        return
    fi
    # Without a claude to start, there is nothing to read the vault for.
    if [[ -z $bin ]]; then
        "${launch[@]}" "$@"
        return
    fi
    if ! command -v rbw >/dev/null 2>&1 || ! rbw unlocked >/dev/null 2>&1; then
        local entry names=()
        for entry in "${_ravnix_secrets[@]}"; do
            names+=("${entry%%=*}")
        done
        printf 'claude: the vault is locked, so it starts without %s. Run ai-unlock first to give it those.\n' "${names[*]}" >&2
        "${launch[@]}" "$@"
        return
    fi
    (
        pairs=()
        for entry in "${_ravnix_secrets[@]}"; do
            name=${entry%%=*}
            item=${entry#*=}
            if value=$(rbw get -- "$item" 2>/dev/null </dev/null); then
                pairs+=("$name=$value")
            else
                printf 'claude: %s: rbw cannot read the item "%s"\n' "$name" "$item" >&2
            fi
        done
        # Only now, when no child is left to start: and never a bare `export`,
        # which would list the whole environment.
        if ((${#pairs[@]})); then
            export "${pairs[@]}"
        fi
        unset entry name item value pairs
        exec "$bin" "$@"
    )
}
