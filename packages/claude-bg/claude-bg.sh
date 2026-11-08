#!/usr/bin/env bash
# claude-bg: start a background Claude Code session that has its MCP tokens.
#
#   claude-bg [ARGS...]     what `claude --bg ARGS...` would do, with tokens
#
# Why it exists (spec 2026-09-18-ai-setup-rebuild.md, section 7.4, probed on
# 2026-09-25). A background session does not get the shell's environment.
# Claude Code's supervisor, `claude daemon run`, starts every session with its
# own environment, which it inherited from whichever claude command started
# it, plus a short allowlist from the dispatching command (PATH and provider
# settings, no tokens). So a `claude --bg` from a shell with the tokens still
# gives the session none, whenever the supervisor was started by a claude that
# lacked them; then coolify, plane and hostinger fail with an auth error that
# blames the token. This script:
#
#   1. unlocks rbw if it is locked (a sync first, as ai-unlock does) and has
#      with-secret-env read every item of the secret table, one `rbw get`
#      each, exporting the tokens only after the last read. The table is
#      ~/.config/ravnix/secret-env, which the ravnix module writes from
#      ravnix.shell.secretEnv: one NAME=item line per token, the item being
#      the name or id of the Bitwarden item, never a value. If one item cannot
#      be read, none of the tokens is set (all or nothing). Esc or Ctrl+C at
#      the prompt starts the session without the tokens, and a note says so;
#   2. compares every token it loaded with the running supervisor's
#      environment, and restarts a supervisor that lacks one or holds another
#      value with `claude daemon stop --any --keep-workers`. Its sessions keep
#      running, and the supervisor the next `claude --bg` starts adopts them;
#   3. runs `claude --bg ARGS...` from this environment.
#
# Isolation is left to Claude Code: in a git repository `claude --bg` moves
# into a worktree unless CLAUDE_BG_ISOLATION=none is set, which this script
# passes through untouched. Inside that worktree the session commits and pushes
# on its own. `claude --bg` also ignores --session-id (the id is the one it
# prints), rejects -p, and refuses --permission-mode auto until a foreground
# `claude --permission-mode auto` has run once on the machine (2.1.281).
#
# The logic is the remote half of the claude routing shim of the earlier
# setup, which ran it on the workstation. The shim was removed on 2026-10-03.
#
# CLAUDE_BG_PROC stands in for /proc, and CLAUDE_BG_SECRETS for
# the secret table, in the tests.

set -uo pipefail

say() { printf 'claude-bg: %s\n' "$1" >&2; }

type -P claude >/dev/null || { say "claude is not installed"; exit 127; }

secrets=${CLAUDE_BG_SECRETS:-${XDG_CONFIG_HOME:-$HOME/.config}/ravnix/secret-env}
loaded=() why=""

# Two stages, in this one file. The first makes sure rbw can be read, which may
# ask for the master password. The second is the same script started by
# with-secret-env, so that the tokens are in its environment, exported only
# after the last read (CLAUDE_BG_STAGE=2 is how it knows). The second needs the
# values to compare them with the supervisor's, and the helper hands over only
# the names it set (WITH_SECRET_ENV_LOADED) or why it set none
# (WITH_SECRET_ENV_WHY); the values are in the environment.
if [[ -z ${CLAUDE_BG_STAGE:-} ]]; then
    if ! type -P rbw >/dev/null; then
        why="rbw is not installed"
    elif [[ ! -r $secrets ]]; then
        why="there is no $secrets"
    elif ! rbw unlocked >/dev/null 2>&1; then
        say "Bitwarden is locked: unlock it for the session's tokens, or press Esc to start without them"
        # A sync needs no password, so it goes first, and a failed one
        # leaves the cached copy.
        timeout 10 rbw sync </dev/null >/dev/null 2>&1
        trap : INT
        rbw unlock || why="rbw stayed locked"
        trap - INT
    fi
    if [[ -n $why ]]; then
        exec env CLAUDE_BG_STAGE=2 CLAUDE_BG_WHY="$why" "$BASH" "$0" "$@"
    fi
    exec with-secret-env --table "$secrets" --report -- env CLAUDE_BG_STAGE=2 "$BASH" "$0" "$@"
fi
why=${CLAUDE_BG_WHY:-${WITH_SECRET_ENV_WHY:-}}
read -r -a loaded <<<"${WITH_SECRET_ENV_LOADED:-}"
unset CLAUDE_BG_STAGE CLAUDE_BG_WHY WITH_SECRET_ENV_WHY WITH_SECRET_ENV_LOADED

# The supervisor is this user's claude process started as `claude daemon
# run`, two arguments, so a prompt that mentions them does not count.
proc=${CLAUDE_BG_PROC:-/proc} sup="" senv=() stale=()
for d in "$proc"/[0-9]*; do
    [[ -O $d ]] || continue
    read -r comm 2>/dev/null <"$d/comm" || continue
    [[ $comm == claude ]] || continue
    mapfile -d '' -t a 2>/dev/null <"$d/cmdline" || continue
    if [[ ${a[1]-} == daemon && ${a[2]-} == run ]]; then
        sup=$d
        mapfile -d '' -t senv 2>/dev/null <"$d/environ"
        break
    fi
done
if [[ -n $sup ]]; then
    for n in "${loaded[@]}"; do
        found=""
        for e in "${senv[@]}"; do [[ $e == "$n=${!n}" ]] && { found=1; break; }; done
        [[ -n $found ]] || stale+=("$n")
    done
fi
if ((${#stale[@]})); then
    if claude daemon stop --any --keep-workers </dev/null >/dev/null 2>&1; then
        say "restarted Claude Code's background service, which lacked ${stale[*]}; its sessions keep running"
    else
        say "this session gets the background service's environment, which lacks ${stale[*]}: claude daemon stop --any --keep-workers failed"
    fi
fi
if [[ -n $why ]]; then
    held=()
    for e in "${senv[@]}"; do
        [[ $e =~ ^([A-Za-z0-9_]*(TOKEN|API_KEY)[A-Za-z0-9_]*)= ]] && held+=("${BASH_REMATCH[1]}")
    done
    if [[ -n $sup ]] && ((${#held[@]})); then
        say "$why; this session gets the tokens the background service holds: ${held[*]}"
    else
        say "this session starts without the tokens: $why"
    fi
fi

exec claude --bg "$@"
