#!/usr/bin/env bash
# Tests for the worktree hooks: worktree-create.sh, worktree-remove.sh and
# worktree-subagent-stop.sh, one directory up.
#
# Why fixtures instead of Claude Code: a hook's whole contract is JSON on
# stdin, a path (or nothing) on stdout, and the git state it leaves. Driving
# the scripts directly lets each case build exactly the repository it needs.
# Every fixture is a main checkout cloned from a bare origin, so the base
# selection has something to fetch.
#
# pnpm, npm and uv are PATH stubs that record their argv, cwd and the corepack
# variable, so no real install runs. The hooks see a PATH of those stubs plus
# links to the tools they may use, and nothing else: that is how a missing
# tool is simulated, and a hook that starts calling an unlisted tool fails
# here first. Git runs with a sandbox config (identity, no signing, main as
# the default branch), and CLAUDE_CONFIG_DIR and XDG_STATE_HOME point into the
# sandbox, so the user's own settings and log are never read or written.
#
# Run:  bash worktree-hooks.test.sh          (exit 0 = all green)
# The sandbox lives under ${TMPDIR:-/tmp} and is removed on exit.

set -uo pipefail

SELF=$(readlink -f "$0")
HOOKS=${SELF%/*/*}
CREATE=$HOOKS/worktree-create.sh
REMOVE=$HOOKS/worktree-remove.sh
STOP=$HOOKS/worktree-subagent-stop.sh
for s in "$CREATE" "$REMOVE" "$STOP"; do
    [ -f "$s" ] || { echo "missing $s" >&2; exit 2; }
done

pass=0
fail=0
CASE=""
OUT="" ERR="" RC=0

ok()  { pass=$((pass+1)); printf '  \033[32m✓\033[0m %s\n' "$CASE"; }
bad() { fail=$((fail+1)); printf '  \033[31m✗\033[0m %s\n     %s\n' "$CASE" "$1"
        printf 'stdout: %s\nstderr (tail):\n%s\n' "$OUT" "$(tail -n 8 <<<"$ERR")" | sed 's/^/       | /'; }

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/worktree-hooks-test.XXXXXX")
trap 'rm -rf -- "$ROOT"' EXIT

# --- the sandbox -----------------------------------------------------------

SYS=$ROOT/sys STUBS=$ROOT/stubs NOPNPM=$ROOT/stubs-nopnpm
mkdir -p "$SYS" "$STUBS" "$NOPNPM" "$ROOT/claude-user" "$ROOT/state"
for t in bash sh env git jq date mkdir cp rm stat realpath timeout setsid flock cat; do
    p=$(type -P "$t") || { echo "the hooks need $t, which is not installed" >&2; exit 2; }
    ln -s "$p" "$SYS/$t"
done
# Every script a test writes starts with the bash that runs the tests: the
# Nix build sandbox has no /usr/bin/env.
for t in pnpm npm uv; do
    { printf '#!%s\n' "$BASH"; cat <<'EOF'
t=${0##*/}
printf '%s cwd=%s corepack=%s argv=%s\n' "$t" "$PWD" "${COREPACK_ENABLE_DOWNLOAD_PROMPT:-}" "$*" >>"$STUB_LOG"
echo "$t: a line on stdout that must never reach Claude"
rc=STUB_RC_$t
exit "${!rc:-0}"
EOF
    } >"$STUBS/$t"
    chmod +x "$STUBS/$t"
    [ "$t" = pnpm ] || ln -s "$STUBS/$t" "$NOPNPM/$t"
done
HOOK_PATH=$STUBS:$SYS

export GIT_CONFIG_GLOBAL=$ROOT/gitconfig GIT_CONFIG_NOSYSTEM=1
git config --file "$GIT_CONFIG_GLOBAL" user.name "Test"
git config --file "$GIT_CONFIG_GLOBAL" user.email "test@example.invalid"
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
git config --file "$GIT_CONFIG_GLOBAL" commit.gpgsign false
git config --file "$GIT_CONFIG_GLOBAL" advice.detachedHead false
export CLAUDE_CONFIG_DIR=$ROOT/claude-user XDG_STATE_HOME=$ROOT/state
export STUB_LOG=$ROOT/stub.log SETUP_OUT=$ROOT/setup.out TEARDOWN_OUT=$ROOT/teardown.out
SLEEP_BIN=$(type -P sleep) && export SLEEP_BIN
LOG=$XDG_STATE_HOME/claude-worktree-hooks.log

# The repository setup a fixture can carry: it records the four facts it is
# given, marks its place in the call order, and prints to stdout on purpose.
# shellcheck disable=SC2016  # expands when the setup runs, not here
SETUP_SCRIPT="#!$BASH"'
{ echo "pwd=$PWD"; echo "main=$WORKTREE_MAIN"; echo "path=$WORKTREE_PATH"; echo "name=$WORKTREE_NAME"; } >"$SETUP_OUT"
echo "setup cwd=$PWD" >>"$STUB_LOG"
echo "setup: a line on stdout that must never reach Claude"
[ -z "${SETUP_SLEEP:-}" ] || { : >"$SETUP_OUT.started"; exec "$SLEEP_BIN" "$SETUP_SLEEP"; }
exit "${SETUP_RC:-0}"'

# The repository teardown a fixture can carry: it records the four facts and
# whether the worktree was still checked out and registered, logs each run,
# and prints to stdout on purpose. TEARDOWN_HANG=term starts a child and waits
# for it; stubborn does the same with SIGTERM ignored, so only SIGKILL ends it.
# shellcheck disable=SC2016  # expands when the teardown runs, not here
TEARDOWN_SCRIPT="#!$BASH"'
{ echo "pwd=$PWD"; echo "main=$WORKTREE_MAIN"; echo "path=$WORKTREE_PATH"; echo "name=$WORKTREE_NAME"
  [ -f README ] && echo "checkout=intact"
  git -C "$WORKTREE_MAIN" worktree list --porcelain |
      while read -r k v; do [ "$k $v" = "worktree $WORKTREE_PATH" ] && echo "registered=yes"; done; } >"$TEARDOWN_OUT"
echo "teardown cwd=$PWD" >>"$STUB_LOG"
echo "teardown: a line on stdout that must never reach Claude"
case ${TEARDOWN_HANG:-} in
    term) "$SLEEP_BIN" 30 & echo "$!" >"$TEARDOWN_OUT.child"; wait ;;
    stubborn) trap "" TERM; "$SLEEP_BIN" 30 & echo "$!" >"$TEARDOWN_OUT.child"; wait ;;
esac
exit "${TEARDOWN_RC:-0}"'

# make_repo [file...]: a bare origin, a seed that pushed one commit to it, and
# MAIN, a clone of origin (so origin/HEAD is set). Each argument is committed
# as an empty file; FIX_SETUP=1 also commits .claude/worktree-setup, and
# FIX_TEARDOWN=1 .claude/worktree-teardown. MAIN then gets the untracked files
# .worktreeinclude is tested against.
make_repo() {
    local f
    CASE_DIR=$(mktemp -d "$ROOT/case.XXXXXX")
    O=$CASE_DIR/origin.git SEED=$CASE_DIR/seed MAIN=$CASE_DIR/main
    git init -q --bare "$O"
    git init -q "$SEED"
    printf 'fixture\n' >"$SEED/README"
    printf '%s\n' .env .envlink 'config/secret/' '*.log' 'cfg/' \
        .claude/settings.local.json .claude/worktrees/ >"$SEED/.gitignore"
    printf '%s\n' .env .envlink 'config/secret/' '*.txt' 'cfg/' \
        .claude/settings.local.json >"$SEED/.worktreeinclude"
    for f in "$@"; do
        mkdir -p "$SEED/$(dirname "$f")"
        : >"$SEED/$f"
    done
    if [ "${FIX_SETUP:-0}" = 1 ]; then
        mkdir -p "$SEED/.claude"
        printf '%s\n' "$SETUP_SCRIPT" >"$SEED/.claude/worktree-setup"
        chmod +x "$SEED/.claude/worktree-setup"
    fi
    if [ "${FIX_TEARDOWN:-0}" = 1 ]; then
        mkdir -p "$SEED/.claude"
        printf '%s\n' "$TEARDOWN_SCRIPT" >"$SEED/.claude/worktree-teardown"
        chmod +x "$SEED/.claude/worktree-teardown"
    fi
    git -C "$SEED" add -A
    git -C "$SEED" commit -q -m init
    git -C "$SEED" remote add origin "$O"
    git -C "$SEED" push -q -u origin main 2>/dev/null
    git clone -q "$O" "$MAIN"
    mkdir -p "$MAIN/config/secret" "$MAIN/.claude" "$MAIN/sub"
    printf 'SECRET=1\n' >"$MAIN/.env"
    printf '{"k":1}\n' >"$MAIN/config/secret/k.json"
    chmod 600 "$MAIN/config/secret/k.json"
    ln -s /etc/hostname "$MAIN/.envlink"
    printf 'log\n' >"$MAIN/app.log"
    printf 'not ignored\n' >"$MAIN/notes.txt"
    printf '{}\n' >"$MAIN/.claude/settings.local.json"
    : >"$STUB_LOG"
    rm -f "$SETUP_OUT" "$TEARDOWN_OUT" "$TEARDOWN_OUT.child"
}

commit_in() { # commit_in <dir> <file>: a new commit, printed as its sha
    printf '%s\n' "$RANDOM" >>"$1/$2"
    git -C "$1" add -- "$2"
    git -C "$1" commit -q -m "change $2"
    git -C "$1" rev-parse HEAD
}

# run_hook <script> <cwd> <json>: sets OUT (stdout, verbatim in $ROOT/out), ERR, RC
run_hook() {
    (cd "$2" && printf '%s' "$3" | PATH=$HOOK_PATH "$BASH" "$1" >"$ROOT/out" 2>"$ROOT/err")
    RC=$?
    OUT=$(<"$ROOT/out")
    ERR=$(<"$ROOT/err")
}

create() { # create <name> [cwd]
    local cwd=${2:-$MAIN}
    run_hook "$CREATE" "$cwd" "$(jq -nc --arg n "$1" --arg c "$cwd" \
        '{session_id:"s1",transcript_path:"/dev/null",cwd:$c,hook_event_name:"WorktreeCreate",name:$n}')"
}

remove() { # remove <worktree_path> [cwd]
    local cwd=${2:-$1}
    run_hook "$REMOVE" "$cwd" "$(jq -nc --arg p "$1" --arg c "$cwd" \
        '{session_id:"s1",transcript_path:"/dev/null",cwd:$c,hook_event_name:"WorktreeRemove",worktree_path:$p}')"
}

stop() { # stop <cwd> <agent_id>
    run_hook "$STOP" "$1" "$(jq -nc --arg c "$1" --arg a "$2" \
        '{session_id:"s1",transcript_path:"/dev/null",cwd:$c,hook_event_name:"SubagentStop",stop_hook_active:false,agent_id:$a,agent_type:"general-purpose"}')"
}

# The stop hook removes in a detached process; its log line marks the end.
wait_for_log() { # wait_for_log <text>
    local _
    for _ in $(seq 1 100); do
        grep -qF -- "$1" "$LOG" 2>/dev/null && return 0
        sleep 0.1
    done
    return 1
}

wt_path()       { printf '%s/.claude/worktrees/%s' "$MAIN" "$1"; }
head_of()       { git -C "$1" rev-parse HEAD; }
branch_exists() { git -C "$MAIN" show-ref --verify -q "refs/heads/$1"; }
branch_sha()    { git -C "$MAIN" rev-parse "refs/heads/$1"; }
registered()    { git -C "$MAIN" worktree list --porcelain | grep -qxF "worktree $1"; }
last_err()      { printf '%s\n' "$ERR" | sed '/^$/d' | tail -n 1; }

# ended <pid>: true once the process is gone or a zombie, waiting up to 2 s.
ended() {
    local _ s
    for _ in $(seq 1 20); do
        s=$(cut -d' ' -f3 "/proc/$1/stat" 2>/dev/null) || return 0
        [ "$s" = Z ] && return 0
        sleep 0.1
    done
    return 1
}

# --- create: names and output --------------------------------------------------

echo "create: names and output"

CASE="a plain name lands at .claude/worktrees/<name> on branch worktree-<name>"
make_repo
create plain
W=$(wt_path plain)
if   [ "$RC" -ne 0 ];                  then bad "expected exit 0, got $RC"
elif [ "$OUT" != "$W" ];               then bad "expected the path $W"
elif ! registered "$W";                then bad "the worktree is not registered with git"
elif [ "$(git -C "$W" symbolic-ref --short HEAD)" != worktree-plain ]; then bad "not on branch worktree-plain"
else ok; fi

CASE="a / in the name becomes + in the directory and the branch, as in the built-in"
create feat/login
W=$(wt_path feat+login)
if   [ "$RC" -ne 0 ];    then bad "expected exit 0, got $RC"
elif [ "$OUT" != "$W" ]; then bad "expected the path $W"
elif [ "$(git -C "$W" symbolic-ref --short HEAD)" != worktree-feat+login ]; then bad "not on branch worktree-feat+login"
else ok; fi

CASE="stdout is exactly the path, though the install and the setup print to stdout"
FIX_SETUP=1 make_repo pnpm-lock.yaml
create quiet
W=$(wt_path quiet)
if   [ "$RC" -ne 0 ]; then bad "expected exit 0, got $RC"
elif ! cmp -s "$ROOT/out" <(printf '%s\n' "$W"); then bad "stdout is not exactly one line holding the path: $(od -c "$ROOT/out" | head -n 3)"
elif ! grep -q 'pnpm: a line on stdout' <<<"$ERR"; then bad "the installer's stdout should have gone to stderr"
elif ! grep -q 'setup: a line on stdout' <<<"$ERR";  then bad "the setup's stdout should have gone to stderr"
else ok; fi

CASE="an invalid name is refused, with nothing created and nothing on stdout"
make_repo
create 'has space'
rc1=$RC reason1=$(last_err) out1=$(<"$ROOT/out")
create '../evil'
if   [ "$rc1" -eq 0 ] || [ "$RC" -eq 0 ];   then bad "expected both names to fail"
elif [ -n "$out1" ] || [ -s "$ROOT/out" ];  then bad "stdout must stay empty on failure"
elif [ -e "$MAIN/.claude/worktrees" ];      then bad ".claude/worktrees should not exist"
elif [[ $reason1 != "worktree-create: name is not"* ]]; then bad "a bad character should be named as such: $reason1"
elif ! last_err | grep -q '^worktree-create: worktree-..+evil is not a valid branch name'; then bad "a .. should fail the branch-name check"
else ok; fi

CASE="a directory outside any git repository is refused with a clear reason"
mkdir -p "$ROOT/notgit"
create plain "$ROOT/notgit"
if   [ "$RC" -eq 0 ];  then bad "expected a failure"
elif [ -s "$ROOT/out" ]; then bad "stdout must stay empty on failure"
elif ! last_err | grep -q 'not a git repository'; then bad "the reason should say it is not a git repository"
else ok; fi

CASE="each run appends one log line: time, create, name, path, outcome, seconds"
make_repo
create logged
W=$(wt_path logged)
if ! grep -qE "^[0-9T:+-]+ create logged $W created [0-9]+s$" "$LOG"; then bad "no matching line in $LOG: $(tail -n 1 "$LOG")"
else ok; fi

# --- create: finding the main checkout ------------------------------------------

echo "create: finding the main checkout"

CASE="a cwd in a subdirectory still resolves the main checkout"
make_repo
create fromsub "$MAIN/sub"
if   [ "$RC" -ne 0 ];                     then bad "expected exit 0, got $RC"
elif [ "$OUT" != "$(wt_path fromsub)" ];  then bad "expected $(wt_path fromsub)"
else ok; fi

CASE="a cwd inside a linked worktree resolves the main checkout, not the worktree"
create one
create two "$(wt_path one)"
if   [ "$RC" -ne 0 ];                 then bad "expected exit 0, got $RC"
elif [ "$OUT" != "$(wt_path two)" ];  then bad "expected $(wt_path two), a sibling, not a nested worktree"
else ok; fi

# --- create: resume and existing branches ------------------------------------

echo "create: resume and existing branches"

CASE="the same name again prints the same path and provisions nothing"
make_repo pnpm-lock.yaml
create again
W=$(wt_path again)
printf 'work in progress\n' >"$W/wip.txt"
calls=$(wc -l <"$STUB_LOG")
create again
if   [ "$RC" -ne 0 ];                        then bad "expected exit 0, got $RC"
elif [ "$OUT" != "$W" ];                     then bad "expected the same path $W"
elif [ "$(wc -l <"$STUB_LOG")" != "$calls" ]; then bad "the resume ran the installer again"
elif [ ! -f "$W/wip.txt" ];                  then bad "the resume touched the worktree's contents"
elif ! grep -q "create again $W resumed" "$LOG"; then bad "the log should say resumed"
else ok; fi

CASE="an existing worktree-<name> branch is checked out as it is, never reset"
make_repo
git -C "$MAIN" checkout -q -b worktree-kept
kept=$(commit_in "$MAIN" kept.txt)
git -C "$MAIN" checkout -q main
create kept
W=$(wt_path kept)
if   [ "$RC" -ne 0 ];                      then bad "expected exit 0, got $RC"
elif [ "$(head_of "$W")" != "$kept" ];     then bad "the worktree is not at the branch's own commit"
elif [ "$(branch_sha worktree-kept)" != "$kept" ]; then bad "the branch was moved"
else ok; fi

CASE="a rollback leaves alone a branch this run did not create"
FIX_SETUP=1 make_repo
git -C "$MAIN" checkout -q -b worktree-kept2
kept=$(commit_in "$MAIN" kept.txt)
git -C "$MAIN" checkout -q main
SETUP_RC=1 create kept2
if   [ "$RC" -eq 0 ];                   then bad "expected the failing setup to fail the hook"
elif [ -e "$(wt_path kept2)" ];         then bad "the worktree should be rolled back"
elif ! branch_exists worktree-kept2;    then bad "the pre-existing branch was deleted"
elif [ "$(branch_sha worktree-kept2)" != "$kept" ]; then bad "the pre-existing branch was moved"
else ok; fi

# --- create: the base commit ------------------------------------------------------

echo "create: the base commit"

CASE="fresh: a FETCH_HEAD older than 24 h (here: none) fetches origin/<default> first"
make_repo
new=$(commit_in "$SEED" upstream.txt)
git -C "$SEED" push -q origin main 2>/dev/null
create fresh
if   [ "$RC" -ne 0 ];                           then bad "expected exit 0, got $RC"
elif [ "$(head_of "$OUT")" != "$new" ];         then bad "expected the freshly fetched origin/main $new"
elif [ -n "$(git -C "$OUT" config --get branch.worktree-fresh.merge)" ]; then bad "the branch should not track origin/main"
else ok; fi

CASE="fresh: a FETCH_HEAD younger than 24 h skips the fetch and uses the local origin/<default>"
make_repo
old=$(git -C "$MAIN" rev-parse origin/main)
commit_in "$SEED" upstream.txt >/dev/null
git -C "$SEED" push -q origin main 2>/dev/null
touch "$MAIN/.git/FETCH_HEAD"
create recent
if   [ "$RC" -ne 0 ];                   then bad "expected exit 0, got $RC"
elif [ "$(head_of "$OUT")" != "$old" ]; then bad "expected the local origin/main $old, without a fetch"
else ok; fi

CASE="baseRef head bases on HEAD of cwd, where fresh would take origin/main"
make_repo
local_head=$(commit_in "$MAIN" local.txt)
printf '{"worktree":{"baseRef":"head"}}\n' >"$MAIN/.claude/settings.json"
create onhead
if   [ "$RC" -ne 0 ];                          then bad "expected exit 0, got $RC"
elif [ "$(head_of "$OUT")" != "$local_head" ]; then bad "expected the local HEAD $local_head"
else ok; fi

CASE="settings.local.json wins over settings.json"
printf '{"worktree":{"baseRef":"fresh"}}\n' >"$MAIN/.claude/settings.local.json"
create localwins
if   [ "$RC" -ne 0 ]; then bad "expected exit 0, got $RC"
elif [ "$(head_of "$OUT")" != "$(git -C "$MAIN" rev-parse origin/main)" ]; then bad "expected origin/main, as settings.local.json says fresh"
else ok; fi

CASE="the user settings count when the repository sets nothing"
make_repo
local_head=$(commit_in "$MAIN" local.txt)
printf '{"worktree":{"baseRef":"head"}}\n' >"$CLAUDE_CONFIG_DIR/settings.json"
create userhead
rm -f "$CLAUDE_CONFIG_DIR/settings.json"
if   [ "$RC" -ne 0 ];                          then bad "expected exit 0, got $RC"
elif [ "$(head_of "$OUT")" != "$local_head" ]; then bad "expected the local HEAD from the user-level head setting"
else ok; fi

CASE="baseRef head from inside a linked worktree bases on that worktree's HEAD"
make_repo
create parent
parent_head=$(commit_in "$(wt_path parent)" parent.txt)
printf '{"worktree":{"baseRef":"head"}}\n' >"$MAIN/.claude/settings.json"
create child "$(wt_path parent)"
if   [ "$RC" -ne 0 ];                           then bad "expected exit 0, got $RC"
elif [ "$(head_of "$OUT")" != "$parent_head" ]; then bad "expected the parent worktree's HEAD $parent_head"
else ok; fi

CASE="no origin remote: bases on local HEAD"
make_repo
local_head=$(commit_in "$MAIN" local.txt)
git -C "$MAIN" remote remove origin
create noorigin
if   [ "$RC" -ne 0 ];                          then bad "expected exit 0, got $RC"
elif [ "$(head_of "$OUT")" != "$local_head" ]; then bad "expected the local HEAD $local_head"
else ok; fi

CASE="an unreachable origin with no origin/<default> falls back to local HEAD"
make_repo
local_head=$(commit_in "$MAIN" local.txt)
git -C "$MAIN" update-ref -d refs/remotes/origin/HEAD
git -C "$MAIN" update-ref -d refs/remotes/origin/main
git -C "$MAIN" remote set-url origin "$CASE_DIR/does-not-exist.git"
create unreachable
if   [ "$RC" -ne 0 ];                          then bad "expected exit 0, got $RC"
elif [ "$(head_of "$OUT")" != "$local_head" ]; then bad "expected the local HEAD $local_head"
elif ! grep -q 'basing on local HEAD' <<<"$ERR"; then bad "stderr should say it fell back"
else ok; fi

# --- create: .worktreeinclude -----------------------------------------------------

echo "create: .worktreeinclude"

CASE="copies the gitignored files it matches, content and mode intact"
make_repo
create inc
W=$(wt_path inc)
if   [ "$RC" -ne 0 ]; then bad "expected exit 0, got $RC"
elif ! cmp -s "$MAIN/.env" "$W/.env"; then bad ".env was not copied"
elif ! cmp -s "$MAIN/config/secret/k.json" "$W/config/secret/k.json"; then bad "config/secret/k.json was not copied"
elif [ "$(stat -c %a "$W/config/secret/k.json")" != 600 ]; then bad "the mode 600 was not kept"
else ok; fi

CASE="skips a symlink, an unlisted ignored file, an unignored file and settings.local.json"
if   [ -e "$W/.envlink" ] || [ -L "$W/.envlink" ];   then bad ".envlink is a symlink and must not be copied"
elif [ -e "$W/app.log" ];                           then bad "app.log is ignored but not in .worktreeinclude"
elif [ -e "$W/notes.txt" ];                         then bad "notes.txt matches *.txt but is not gitignored"
elif [ -e "$W/.claude/settings.local.json" ];       then bad "settings.local.json must never be copied"
elif ! grep -q 'not copying .envlink' <<<"$ERR";    then bad "stderr should name the skipped symlink"
else ok; fi

CASE="never copies through a committed symlink that leads out of the worktree"
make_repo
mkdir -p "$CASE_DIR/outside"
git -C "$MAIN" checkout -q -b worktree-esc
ln -s "$CASE_DIR/outside" "$MAIN/cfg"
git -C "$MAIN" add cfg
git -C "$MAIN" commit -q -m "cfg is a symlink on this branch"
git -C "$MAIN" checkout -q main
mkdir -p "$MAIN/cfg"
printf 'x\n' >"$MAIN/cfg/x.env"
create esc
if   [ "$RC" -ne 0 ];                     then bad "expected exit 0, got $RC"
elif [ -e "$CASE_DIR/outside/x.env" ];    then bad "the copy went through the symlink and out of the worktree"
elif ! grep -q 'not copying cfg/x.env: cfg is a symlink' <<<"$ERR"; then bad "stderr should say why cfg/x.env was skipped"
else ok; fi

# --- create: dependencies ---------------------------------------------------------

echo "create: dependencies"

CASE="pnpm-lock.yaml runs pnpm install --frozen-lockfile in the worktree, corepack prompt off"
make_repo pnpm-lock.yaml
create pn
if   [ "$RC" -ne 0 ]; then bad "expected exit 0, got $RC"
elif [ "$(cat "$STUB_LOG")" != "pnpm cwd=$(wt_path pn) corepack=0 argv=install --frozen-lockfile" ]; then bad "unexpected calls: $(cat "$STUB_LOG")"
else ok; fi

CASE="package-lock.json runs npm ci"
make_repo package-lock.json
create np
if   [ "$RC" -ne 0 ]; then bad "expected exit 0, got $RC"
elif [ "$(cat "$STUB_LOG")" != "npm cwd=$(wt_path np) corepack= argv=ci" ]; then bad "unexpected calls: $(cat "$STUB_LOG")"
else ok; fi

CASE="uv.lock runs uv sync --frozen"
make_repo uv.lock
create uvw
if   [ "$RC" -ne 0 ]; then bad "expected exit 0, got $RC"
elif [ "$(cat "$STUB_LOG")" != "uv cwd=$(wt_path uvw) corepack= argv=sync --frozen" ]; then bad "unexpected calls: $(cat "$STUB_LOG")"
else ok; fi

CASE="no lockfile runs no installer"
make_repo
create bare
if   [ "$RC" -ne 0 ];       then bad "expected exit 0, got $RC"
elif [ -s "$STUB_LOG" ];    then bad "unexpected calls: $(cat "$STUB_LOG")"
else ok; fi

CASE="a lockfile whose tool is missing fails, rolls back, and says which tool"
make_repo pnpm-lock.yaml
HOOK_PATH=$NOPNPM:$SYS create nopnpm
if   [ "$RC" -eq 0 ];                   then bad "expected a failure"
elif [ -s "$ROOT/out" ];                then bad "stdout must stay empty on failure"
elif [ -e "$(wt_path nopnpm)" ];        then bad "the worktree should be rolled back"
elif branch_exists worktree-nopnpm;     then bad "the new branch should be deleted"
elif ! last_err | grep -q 'pnpm is not on PATH'; then bad "the last stderr line should name pnpm"
else ok; fi

# --- create: the repository setup and rollback --------------------------------------

echo "create: the repository setup and rollback"

CASE="the setup runs in the worktree with WORKTREE_MAIN, WORKTREE_PATH, WORKTREE_NAME, after the install"
FIX_SETUP=1 make_repo pnpm-lock.yaml
create feat/setup
W=$(wt_path feat+setup)
expected="pwd=$W
main=$MAIN
path=$W
name=feat/setup"
if   [ "$RC" -ne 0 ];                          then bad "expected exit 0, got $RC"
elif [ ! -f "$SETUP_OUT" ];                    then bad "the setup did not run"
elif [ "$(cat "$SETUP_OUT")" != "$expected" ]; then bad "the setup saw: $(tr '\n' ' ' <"$SETUP_OUT")"
elif [ "$(cut -d' ' -f1 "$STUB_LOG" | tr '\n' ' ')" != "pnpm setup " ]; then bad "expected pnpm, then the setup: $(cat "$STUB_LOG")"
else ok; fi

CASE="a failing setup rolls back the worktree and the branch this run created"
FIX_SETUP=1 make_repo
SETUP_RC=1 create broken
W=$(wt_path broken)
if   [ "$RC" -eq 0 ];                 then bad "expected a failure"
elif [ -s "$ROOT/out" ];              then bad "stdout must stay empty on failure"
elif [ -e "$W" ];                     then bad "the worktree directory is still there"
elif registered "$W";                 then bad "the worktree is still registered"
elif branch_exists worktree-broken;   then bad "the branch is still there"
elif ! last_err | grep -q '^worktree-create: .claude/worktree-setup failed'; then bad "the last stderr line should give the reason"
elif ! grep -q "create broken $W failed [0-9]*s .claude/worktree-setup failed" "$LOG"; then bad "the log should record the failure"
else ok; fi

CASE="a SIGTERM (how a hook timeout ends it) during the setup still rolls back"
FIX_SETUP=1 make_repo
rm -f "$SETUP_OUT.started"
jq -nc --arg c "$MAIN" '{session_id:"s1",cwd:$c,hook_event_name:"WorktreeCreate",name:"slow"}' >"$ROOT/in.json"
(cd "$MAIN" && SETUP_SLEEP=30 PATH=$HOOK_PATH exec "$BASH" "$CREATE" <"$ROOT/in.json" >"$ROOT/out" 2>"$ROOT/err") &
pid=$!
for _ in $(seq 1 100); do [ -e "$SETUP_OUT.started" ] && break; sleep 0.1; done
kill -TERM "$pid"
wait "$pid"
RC=$? OUT=$(<"$ROOT/out") ERR=$(<"$ROOT/err")
if   [ ! -e "$SETUP_OUT.started" ];  then bad "the setup never started"
elif [ "$RC" -eq 0 ];                then bad "expected a failure"
elif [ -s "$ROOT/out" ];             then bad "stdout must stay empty"
elif [ -e "$(wt_path slow)" ];       then bad "the worktree is still there"
elif branch_exists worktree-slow;    then bad "the branch is still there"
elif ! last_err | grep -q 'interrupted by a signal'; then bad "the last stderr line should say it was interrupted"
else ok; fi

CASE="a failing install rolls back too"
make_repo pnpm-lock.yaml
STUB_RC_pnpm=1 create badinstall
if   [ "$RC" -eq 0 ];                    then bad "expected a failure"
elif [ -e "$(wt_path badinstall)" ];     then bad "the worktree directory is still there"
elif branch_exists worktree-badinstall;  then bad "the branch is still there"
elif ! last_err | grep -q 'pnpm install --frozen-lockfile failed'; then bad "the last stderr line should give the reason"
else ok; fi

# --- remove ---------------------------------------------------------------------------

echo "remove"

CASE="removes the worktree and deletes its commit-free worktree-* branch"
make_repo
create merged
W=$OUT
remove "$W"
if   [ "$RC" -ne 0 ];                then bad "expected exit 0, got $RC"
elif [ -e "$W" ];                    then bad "the worktree is still there"
elif registered "$W";                then bad "the worktree is still registered"
elif branch_exists worktree-merged;  then bad "the commit-free branch should be deleted"
else ok; fi

CASE="deletes the branch of a commit-free worktree whose base is ahead of local HEAD"
make_repo
ahead=$(commit_in "$SEED" upstream.txt)
git -C "$SEED" push -q origin main 2>/dev/null
create ahead
W=$OUT
if   [ "$(head_of "$W")" != "$ahead" ]; then bad "precondition: the worktree should sit on the fetched origin/main"
elif git -C "$MAIN" merge-base --is-ancestor "$ahead" HEAD; then bad "precondition: local HEAD should be behind origin/main"
else
    remove "$W"
    if   [ "$RC" -ne 0 ];               then bad "expected exit 0, got $RC"
    elif [ -e "$W" ];                   then bad "the worktree is still there"
    elif branch_exists worktree-ahead;  then bad "the branch holds nothing origin/main lacks, so it should be deleted"
    else ok; fi
fi

CASE="removes a dirty worktree but keeps a branch with a unique commit, and says so"
create unmerged
W=$OUT
commit_in "$W" work.txt >/dev/null
printf 'scratch\n' >"$W/untracked.txt"
remove "$W"
if   [ "$RC" -ne 0 ];                   then bad "expected exit 0, got $RC"
elif [ -e "$W" ];                       then bad "the worktree is still there"
elif ! branch_exists worktree-unmerged; then bad "the branch with a unique commit must be kept"
elif ! grep -q 'kept worktree-unmerged; it has commits no other ref reaches' <<<"$ERR"; then bad "stderr should say the branch was kept"
else ok; fi

CASE="a path that is already gone is pruned and counts as removed"
create gone
W=$OUT
rm -rf "$W"
remove "$W" "$MAIN"
if   [ "$RC" -ne 0 ];  then bad "expected exit 0, got $RC"
elif registered "$W";  then bad "the stale registration should be pruned"
elif ! grep -q "remove gone $W gone" "$LOG"; then bad "the log should say gone"
else ok; fi

CASE="refuses to remove the main checkout"
remove "$MAIN" "$MAIN"
if   [ "$RC" -eq 0 ];           then bad "expected a refusal"
elif [ ! -f "$MAIN/README" ];   then bad "the main checkout was damaged"
else ok; fi

# --- remove: the repository teardown ------------------------------------------------

echo "remove: the repository teardown"

CASE="the teardown runs first, in the intact worktree, with WORKTREE_MAIN, WORKTREE_PATH, WORKTREE_NAME"
FIX_TEARDOWN=1 make_repo
create feat/teardown
W=$OUT
remove "$W"
expected="pwd=$W
main=$MAIN
path=$W
name=feat/teardown
checkout=intact
registered=yes"
if   [ "$RC" -ne 0 ];                          then bad "expected exit 0, got $RC"
elif [ ! -f "$TEARDOWN_OUT" ];                 then bad "the teardown did not run"
elif [ "$(cat "$TEARDOWN_OUT")" != "$expected" ]; then bad "the teardown saw: $(tr '\n' ' ' <"$TEARDOWN_OUT")"
elif [ -e "$W" ] || registered "$W";           then bad "the worktree is still there"
elif branch_exists worktree-feat+teardown;     then bad "the commit-free branch should be deleted"
elif [ -s "$ROOT/out" ];                       then bad "stdout must stay empty"
elif ! grep -q 'teardown: a line on stdout' <<<"$ERR"; then bad "the teardown's stdout should have gone to stderr"
elif ! grep -q "remove feat+teardown $W removed [0-9]*s teardown ran; branch worktree-feat+teardown deleted$" "$LOG"; then bad "the log should say the teardown ran: $(tail -n 1 "$LOG")"
else ok; fi

CASE="a failing teardown warns, and the worktree and its branch go anyway"
FIX_TEARDOWN=1 make_repo
create tdfail
W=$OUT
TEARDOWN_RC=3 remove "$W"
if   [ "$RC" -ne 0 ];                  then bad "expected exit 0, got $RC"
elif [ ! -f "$TEARDOWN_OUT" ];         then bad "the teardown did not run"
elif [ -e "$W" ] || registered "$W";   then bad "the worktree is still there"
elif branch_exists worktree-tdfail;    then bad "the commit-free branch should be deleted"
elif ! grep -q 'worktree-teardown failed with exit 3; removing the worktree anyway' <<<"$ERR"; then bad "stderr should warn"
elif ! grep -q "remove tdfail $W removed [0-9]*s teardown failed with exit 3; what it cleans up outside the worktree may be left behind; branch worktree-tdfail deleted$" "$LOG"; then bad "the log should record the failure: $(tail -n 1 "$LOG")"
else ok; fi

CASE="a missing or non-executable teardown is skipped, and the removal proceeds without a note"
make_repo
create plainrm
W=$OUT
remove "$W"
rc1=$RC line1=$(tail -n 1 "$LOG") w1=$W
FIX_TEARDOWN=1 make_repo
create noexec
W=$OUT
chmod -x "$W/.claude/worktree-teardown"
remove "$W"
if   [ "$rc1" -ne 0 ] || [ "$RC" -ne 0 ]; then bad "expected exit 0 both times, got $rc1 and $RC"
elif [ -e "$w1" ] || [ -e "$W" ];         then bad "a worktree is still there"
elif [ -e "$TEARDOWN_OUT" ];              then bad "the non-executable teardown ran"
elif ! grep -q "remove plainrm $w1 removed [0-9]*s branch worktree-plainrm deleted$" <<<"$line1"; then bad "unexpected log line without a teardown: $line1"
elif ! tail -n 1 "$LOG" | grep -q "remove noexec $W removed [0-9]*s branch worktree-noexec deleted$"; then bad "unexpected log line: $(tail -n 1 "$LOG")"
elif ! grep -q 'worktree-teardown is not an executable file, not running it' <<<"$ERR"; then bad "stderr should say why it did not run"
else ok; fi

CASE="the main checkout is refused before its teardown could run"
FIX_TEARDOWN=1 make_repo
remove "$MAIN" "$MAIN"
if   [ "$RC" -eq 0 ];          then bad "expected a refusal"
elif [ -e "$TEARDOWN_OUT" ];   then bad "the main checkout's teardown ran"
else ok; fi

CASE="a hanging teardown is cut off at CLAUDE_WORKTREE_TEARDOWN_TIMEOUT, its child too"
FIX_TEARDOWN=1 make_repo
create tdhang
W=$OUT
start=$SECONDS
TEARDOWN_HANG=term CLAUDE_WORKTREE_TEARDOWN_TIMEOUT=1 remove "$W"
took=$((SECONDS - start)) child=$(cat "$TEARDOWN_OUT.child" 2>/dev/null)
if   [ "$RC" -ne 0 ];      then bad "expected exit 0, got $RC"
elif [ -z "$child" ];      then bad "the teardown never started its child"
elif [ "$took" -gt 4 ];    then bad "the hook took $took s with a 1 s limit"
elif ! ended "$child";     then bad "the teardown's child $child outlived the timeout"
elif [ -e "$W" ];          then bad "the worktree is still there"
elif ! grep -q "remove tdhang $W removed [0-9]*s teardown timed out after 1 s; what it cleans up outside the worktree may be left behind; branch worktree-tdhang deleted$" "$LOG"; then bad "the log should record the timeout: $(tail -n 1 "$LOG")"
else ok; fi

CASE="a teardown that ignores SIGTERM is killed 5 s after the limit"
FIX_TEARDOWN=1 make_repo
create tdstubborn
W=$OUT
start=$SECONDS
TEARDOWN_HANG=stubborn CLAUDE_WORKTREE_TEARDOWN_TIMEOUT=1 remove "$W"
took=$((SECONDS - start)) child=$(cat "$TEARDOWN_OUT.child" 2>/dev/null)
if   [ "$RC" -ne 0 ];      then bad "expected exit 0, got $RC"
elif [ -z "$child" ];      then bad "the teardown never started its child"
elif [ "$took" -gt 9 ];    then bad "the hook took $took s with a 1 s limit and a 5 s kill delay"
elif ! ended "$child";     then bad "the teardown's child $child outlived the SIGKILL"
elif [ -e "$W" ];          then bad "the worktree is still there"
elif ! grep -q "remove tdstubborn $W removed [0-9]*s teardown timed out after 1 s" "$LOG"; then bad "the log should record the timeout: $(tail -n 1 "$LOG")"
else ok; fi

# --- subagent stop: the sweep ------------------------------------------------------

echo "subagent stop: the sweep"

A1=a1111111111111111 A2=a2222222222222222

# age <worktree> <days>: backdate the admin files the sweep measures idleness by.
age() {
    local admin f
    admin=$(git -C "$1" rev-parse --path-format=absolute --git-dir)
    for f in HEAD index logs/HEAD; do
        [ -e "$admin/$f" ] && touch -d "$2 days ago" "$admin/$f"
    done
}

# sweep_done <log text>: the sweep runs detached under a flock on
# .git/worktrees. Its first log line proves it holds the lock; getting the
# lock afterwards proves it has finished.
sweep_done() {
    wait_for_log "$1" || return 1
    flock -w 10 "$MAIN/.git/worktrees" true
}

reason_for() { # reason_for <path>: the last decision logged about it
    grep -F " $1 " "$LOG" | tail -n 1 | cut -d' ' -f7-
}

CASE="the stopping agent's own worktree stays, even when idle, clean and commit-free"
make_repo
create "agent-$A1"; W1=$OUT
age "$W1" 2
stop "$W1" "$A1"
if   [ "$RC" -ne 0 ];        then bad "expected exit 0, got $RC"
elif [ -s "$ROOT/out" ];     then bad "stdout must stay empty"
elif ! sweep_done "subagent-stop agent-$A1 $W1 kept"; then bad "no decision logged: $(tail -n 1 "$LOG")"
elif [ ! -d "$W1" ];         then bad "the stopping agent's own worktree was removed"
elif ! branch_exists "worktree-agent-$A1"; then bad "its branch was deleted"
elif [ "$(reason_for "$W1")" != "it is the stopping agent's own worktree" ]; then bad "wrong reason: $(reason_for "$W1")"
else ok; fi

CASE="an idle, clean, commit-free worktree of another agent is swept with its branch"
make_repo
create "agent-$A1"; W1=$OUT
create "agent-$A2"; W2=$OUT
age "$W1" 2
stop "$W2" "$A2"
if   [ "$RC" -ne 0 ];        then bad "expected exit 0, got $RC"
elif ! sweep_done "subagent-stop agent-$A2 $W2 kept"; then bad "no decision logged: $(tail -n 2 "$LOG")"
elif [ -e "$W1" ];           then bad "the idle worktree is still there: $(reason_for "$W1")"
elif branch_exists "worktree-agent-$A1"; then bad "its branch is still there"
elif [ ! -d "$W2" ];         then bad "the stopping agent's own worktree was removed"
elif ! grep -q "subagent-stop agent-$A1 $W1 removed [0-9]*s idle 48 h; branch worktree-agent-$A1 deleted" "$LOG"; then bad "the removal should be logged"
else ok; fi

CASE="a stop in the main checkout (a non-isolated subagent) sweeps too"
make_repo
create "agent-$A1"; W1=$OUT
age "$W1" 2
stop "$MAIN" "$A2"
if   [ "$RC" -ne 0 ];  then bad "expected exit 0, got $RC"
elif ! sweep_done "subagent-stop agent-$A1 $W1 removed"; then bad "no removal logged: $(tail -n 1 "$LOG")"
elif [ -e "$W1" ];     then bad "the idle worktree is still there"
else ok; fi

CASE="a young agent worktree is kept within the default 24 h grace"
make_repo
create "agent-$A1"; W1=$OUT
create "agent-$A2"; W2=$OUT
stop "$W2" "$A2"
if   ! sweep_done "subagent-stop agent-$A2 $W2 kept"; then bad "no decision logged"
elif [ ! -d "$W1" ]; then bad "the young worktree was removed"
elif [[ $(reason_for "$W1") != "active "*" min ago, within the 24 h grace" ]]; then bad "wrong reason: $(reason_for "$W1")"
else ok; fi

CASE="CLAUDE_WORKTREE_AGENT_GRACE_HOURS=0 lets the sweep take a fresh one"
CLAUDE_WORKTREE_AGENT_GRACE_HOURS=0 stop "$W2" "$A2"
if   ! sweep_done "subagent-stop agent-$A1 $W1 removed"; then bad "no removal logged: $(reason_for "$W1")"
elif [ -e "$W1" ];   then bad "the worktree is still there"
elif [ ! -d "$W2" ]; then bad "the stopping agent's own worktree was removed"
else ok; fi

# The remaining cases would all be swept on age alone, so each keeps its
# worktree for exactly one other reason.
export CLAUDE_WORKTREE_AGENT_GRACE_HOURS=0

CASE="a dirty agent worktree (an untracked file) is kept"
make_repo
create "agent-$A1"; W1=$OUT
create "agent-$A2"; W2=$OUT
printf 'result\n' >"$W1/report.md"
stop "$W2" "$A2"
if   ! sweep_done "subagent-stop agent-$A1 $W1 kept"; then bad "no decision logged: $(tail -n 2 "$LOG")"
elif [ ! -d "$W1" ]; then bad "the dirty worktree was removed"
elif [ "$(reason_for "$W1")" != "uncommitted changes or untracked files" ]; then bad "wrong reason: $(reason_for "$W1")"
else ok; fi

CASE="an agent worktree with a unique commit is kept, and so is its branch"
make_repo
create "agent-$A1"; W1=$OUT
create "agent-$A2"; W2=$OUT
commit_in "$W1" work.txt >/dev/null
stop "$W2" "$A2"
if   ! sweep_done "subagent-stop agent-$A1 $W1 kept"; then bad "no decision logged: $(tail -n 2 "$LOG")"
elif [ ! -d "$W1" ]; then bad "the worktree was removed"
elif ! branch_exists "worktree-agent-$A1"; then bad "the branch was deleted"
elif [ "$(reason_for "$W1")" != "HEAD has commits no other ref reaches" ]; then bad "wrong reason: $(reason_for "$W1")"
else ok; fi

CASE="a locked agent worktree is kept"
make_repo
create "agent-$A1"; W1=$OUT
create "agent-$A2"; W2=$OUT
git -C "$MAIN" worktree lock --reason "in use" "$W1"
stop "$W2" "$A2"
if   ! sweep_done "subagent-stop agent-$A1 $W1 kept"; then bad "no decision logged: $(tail -n 2 "$LOG")"
elif [ ! -d "$W1" ]; then bad "the locked worktree was removed"
elif [ "$(reason_for "$W1")" != "it is locked" ]; then bad "wrong reason: $(reason_for "$W1")"
else ok; fi

CASE="an agent commit another ref reaches (pushed) is not unique, so the worktree goes"
make_repo
create "agent-$A1"; W1=$OUT
create "agent-$A2"; W2=$OUT
commit_in "$W1" work.txt >/dev/null
git -C "$W1" push -q origin "worktree-agent-$A1" 2>/dev/null
stop "$W2" "$A2"
if   ! sweep_done "subagent-stop agent-$A1 $W1 removed"; then bad "no removal logged: $(reason_for "$W1")"
elif [ -e "$W1" ]; then bad "the worktree is still there"
else ok; fi

CASE="the sweep tears down a worktree it removes, and never the stopping agent's own"
FIX_TEARDOWN=1 make_repo
create "agent-$A1"; W1=$OUT
create "agent-$A2"; W2=$OUT
stop "$W2" "$A2"
if   ! sweep_done "subagent-stop agent-$A1 $W1 removed"; then bad "no removal logged: $(reason_for "$W1")"
elif [ -e "$W1" ];   then bad "the worktree is still there"
elif [ ! -d "$W2" ]; then bad "the stopping agent's own worktree was removed"
elif ! grep -qxF "teardown cwd=$W1" "$STUB_LOG"; then bad "the removed worktree's teardown did not run: $(cat "$STUB_LOG")"
elif grep -qF "teardown cwd=$W2" "$STUB_LOG";   then bad "the stopping agent's own worktree was torn down"
elif [ "$(reason_for "$W1")" != "idle 0 h; teardown ran; branch worktree-agent-$A1 deleted" ]; then bad "wrong reason: $(reason_for "$W1")"
else ok; fi

CASE="the sweep never tears down a worktree it keeps"
FIX_TEARDOWN=1 make_repo
create "agent-$A1"; W1=$OUT
create "agent-$A2"; W2=$OUT
printf 'result\n' >"$W1/report.md"
stop "$W2" "$A2"
if   ! sweep_done "subagent-stop agent-$A1 $W1 kept"; then bad "no decision logged: $(tail -n 2 "$LOG")"
elif [ ! -d "$W1" ];                   then bad "the dirty worktree was removed"
elif grep -q '^teardown' "$STUB_LOG";  then bad "a kept worktree was torn down: $(cat "$STUB_LOG")"
else ok; fi

CASE="a failing teardown in the sweep is logged, and the worktree still goes"
FIX_TEARDOWN=1 make_repo
create "agent-$A1"; W1=$OUT
create "agent-$A2"; W2=$OUT
TEARDOWN_RC=3 stop "$W2" "$A2"
if   ! sweep_done "subagent-stop agent-$A1 $W1 removed"; then bad "no removal logged: $(reason_for "$W1")"
elif [ -e "$W1" ]; then bad "the worktree is still there"
elif branch_exists "worktree-agent-$A1"; then bad "its branch is still there"
elif [ "$(reason_for "$W1")" != "idle 0 h; teardown failed with exit 3; what it cleans up outside the worktree may be left behind; branch worktree-agent-$A1 deleted" ]; then bad "wrong reason: $(reason_for "$W1")"
else ok; fi

CASE="a non-agent worktree is never swept"
make_repo
create feature; WF=$OUT
create "agent-$A2"; W2=$OUT
age "$WF" 2
stop "$W2" "$A2"
if   ! sweep_done "subagent-stop agent-$A2 $W2 kept"; then bad "no decision logged"
elif [ ! -d "$WF" ];                  then bad "the non-agent worktree was removed"
elif grep -qF "subagent-stop feature $WF " "$LOG"; then bad "a non-agent worktree should not even be considered"
else ok; fi

CASE="a repository without agent worktrees spawns nothing and logs nothing"
make_repo
create feature
lines=$(wc -l <"$LOG")
stop "$MAIN" "$A2"
sleep 0.3
if   [ "$RC" -ne 0 ];                    then bad "expected exit 0, got $RC"
elif [ "$(wc -l <"$LOG")" != "$lines" ]; then bad "nothing should be logged: $(tail -n 1 "$LOG")"
else ok; fi

CASE="garbage on stdin still exits 0 with nothing on stdout"
run_hook "$STOP" "$MAIN" 'not json /.claude/worktrees/agent-x'
if   [ "$RC" -ne 0 ];    then bad "expected exit 0, got $RC"
elif [ -s "$ROOT/out" ]; then bad "stdout must stay empty"
else ok; fi

unset CLAUDE_WORKTREE_AGENT_GRACE_HOURS

# --- summary ----------------------------------------------------------------------

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
