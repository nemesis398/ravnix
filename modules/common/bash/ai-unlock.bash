# shellcheck shell=bash
# _ravnix_secret_env is assigned by bash.nix, before this file.
# shellcheck disable=SC2154
# ai-unlock and the loader behind it, ported from the Fedora .bashrc and
# changed in one respect: the file the Fedora one sourced (a loader of its own
# that a human wrote, with its variable names in it) is gone. Which variable
# comes from which Bitwarden item is ravnix.shell.secretEnv, and bash.nix
# writes it as the associative array
#
#   declare -A _ravnix_secret_env=([NAME]='item name' ...)
#
# This file only reads it. A secret is read with `rbw get` at the moment it is
# needed, goes into the environment as a plain value, and is never evaluated,
# written to a file or printed. tests/common/helpers/functions.test.bash
# sources this file on its own, with a stand-in rbw.

# _ravnix_read_secrets [warn]: exports every secret of _ravnix_secret_env that
# rbw can read, and leaves their names, in order, in _ravnix_loaded. With an
# argument it says on stderr which items rbw could not read.
_ravnix_read_secrets() {
    local name item value
    _ravnix_loaded=()
    ((${#_ravnix_secret_env[@]})) || return 0
    while IFS= read -r name; do
        item=${_ravnix_secret_env[$name]}
        if value=$(rbw get -- "$item" 2>/dev/null); then
            export "$name=$value"
            _ravnix_loaded+=("$name")
        elif [[ -n ${1-} ]]; then
            printf 'ai-unlock: %s: rbw cannot read the item "%s"\n' "$name" "$item" >&2
        fi
    done < <(printf '%s\n' "${!_ravnix_secret_env[@]}" | LC_ALL=C sort)
}

# _ravnix_load_secrets: what every new shell does when ravnix.shell.secretEnv
# names secrets: load them, but only when the vault is already unlocked, so a
# new terminal never opens a pinentry prompt, and quietly when it is not or
# when rbw is not there at all.
_ravnix_load_secrets() {
    command -v rbw >/dev/null 2>&1 || return 0
    rbw unlocked >/dev/null 2>&1 || return 0
    _ravnix_read_secrets
    unset _ravnix_loaded
}

# ai-unlock: unlock the Bitwarden vault and load the secrets of
# ravnix.shell.secretEnv into THIS shell, before launching claude. rbw-agent
# then stays unlocked (lock_timeout in rbw's config, 1h), so terminals opened
# afterwards load the secrets on their own.
#
# The `rbw sync` is load-bearing: `rbw unlock` only decrypts the LOCAL database
# and `rbw get` only reads it, so neither ever contacts the server. Without the
# sync, a token rotated in the web vault stays invisible here until rbw-agent's
# own sync_interval (1h) happens to fire, and ai-unlock cheerfully re-exports
# the dead one.
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
# shellcheck disable=SC2016 # the backticks are part of rbw's message
ai-unlock() {
    local out db
    if ! out=$(rbw sync 2>&1); then
        if [[ $out == *'missing field `access_token`'* ]]; then
            db="${XDG_CACHE_HOME:-$HOME/.cache}/rbw/$(rbw config show |
                jq -r '(.base_url | @uri) + ":" + .email').json"
            rbw stop-agent
            mv -- "$db" "$db.stale-$(date +%F-%H%M%S)" &&
                printf 'ai-unlock: the vault server rejected the refresh token, logging in again\n' >&2
        else
            printf '%s\nai-unlock: rbw sync failed, using the cached vault copy\n' "$out" >&2
        fi
    fi
    rbw unlock || return 1
    if ((${#_ravnix_secret_env[@]} == 0)); then
        printf 'ai-unlock: unlocked. ravnix.shell.secretEnv names no secrets to load.\n'
        return 0
    fi
    _ravnix_read_secrets warn
    if ((${#_ravnix_loaded[@]} == 0)); then
        unset _ravnix_loaded
        printf 'ai-unlock: unlocked, but no secret could be read.\n' >&2
        return 1
    fi
    printf 'Secrets loaded:'
    printf ' %s' "${_ravnix_loaded[@]}"
    printf '\n'
    unset _ravnix_loaded
}
