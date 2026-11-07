#!/usr/bin/env bash
# worktree-create.sh: WorktreeCreate hook (claude/README.md). Creates the git
# worktree Claude Code asked for and provisions it, so whoever lands in it can
# run the project at once.
#
# Why: once a WorktreeCreate hook is registered, every route that makes a
# worktree goes through it (`claude -w`, EnterWorktree, Agent-tool subagents
# with isolation "worktree", /batch, Remote Control's --spawn worktree), and
# Claude does none of its own setup. A bare checkout has no .env, no
# node_modules and no database, so parallel agents in one repository would
# either lack them or share them. Here each worktree gets, in this order:
#   1. the checkout, where the built-in puts it: the directory
#      <main>/.claude/worktrees/<name> and the branch worktree-<name>, both
#      with every / of the name replaced by +. An existing branch is checked
#      out as it is and never reset, because it may hold the commits of a kept
#      worktree whose directory was deleted;
#   2. the gitignored files that <main>/.worktreeinclude matches (gitignore
#      syntax), copied from the main checkout to the same relative path:
#      regular files only, never through a symlink, keeping the mode;
#   3. its own dependencies, by the lockfile at its root: pnpm-lock.yaml
#      (else package-lock.json), and uv.lock. A lockfile whose tool is missing
#      is a failure, not a skip;
#   4. the repository's own setup, <worktree>/.claude/worktree-setup, run in
#      the worktree with WORKTREE_MAIN, WORKTREE_PATH and WORKTREE_NAME set.
#      A web project may use it for per-worktree dev ports and a database.
#
# The base commit is picked as the built-in picks it. worktree.baseRef "head"
# (read from <main>/.claude/settings.local.json, <main>/.claude/settings.json,
# then the user settings; the first file that sets it wins) bases on HEAD of
# the directory Claude runs in. Anything else bases on
# origin/<default branch>, refreshed by a 5 s fetch when FETCH_HEAD is older
# than 24 hours. A failed refresh keeps the local origin/<branch>; with no
# origin/<branch> at all, a failed fetch falls back to local HEAD.
#
# Deliberately not implemented: the settings symlinkDirectories and
# sparsePaths. The per-worktree install is the point, and a symlinked
# node_modules shares state between branches that may need different
# dependencies. .claude/settings.local.json is never copied either, even when
# .worktreeinclude names it: worktree sessions read the main checkout's copy.
#
# Contract with Claude Code 2.1.281: the LAST non-empty line of stdout is the
# path, so stdout carries exactly that line and everything else (git, the
# installers, the repository setup) goes to stderr. Children never see the
# real stdout, so a daemon they leave behind cannot hold it open. Any failure
# after the worktree exists rolls it back, with its branch if this run made
# the branch, and exits 1 with a one-line reason last on stderr, so a
# half-provisioned worktree never looks usable. A name whose worktree already
# exists (a resumed `claude -w name`) is printed as it is, without
# provisioning again.
#
# One line per run goes to ${XDG_STATE_HOME:-~/.local/state}/claude-worktree-hooks.log:
#   <time> create <name> <path> <created|resumed|failed> <seconds>s [reason]

set -uo pipefail

exec 3>&1 1>&2

log_file="${XDG_STATE_HOME:-$HOME/.local/state}/claude-worktree-hooks.log"
name="" path="" main="" branch=""
created_wt=0 created_branch=0 child=""

log() {
    mkdir -p -- "${log_file%/*}" 2>/dev/null
    printf '%s create %s %s %s %ss%s\n' "$(date -Is)" "${name:--}" "${path:--}" \
        "$1" "$SECONDS" "${2:+ $2}" >>"$log_file" 2>/dev/null
}

rollback() {
    if ((created_wt)); then
        git -C "$main" worktree remove --force "$path" || rm -rf -- "$path"
        git -C "$main" worktree prune
    fi
    if ((created_branch)); then
        git -C "$main" branch -D -- "$branch"
    fi
}

# fail <reason>: undo, log, and end with the reason as the last stderr line.
fail() {
    trap - TERM INT HUP
    cd / || true
    rollback
    log failed "$1"
    printf 'worktree-create: %s\n' "$1" >&2
    exit 1
}

# A hook timeout arrives as SIGTERM. Long steps run in the background under
# `wait`, which a trapped signal interrupts, so the rollback still happens.
# shellcheck disable=SC2329  # invoked by the trap
on_signal() {
    [[ -n $child ]] && kill -TERM "$child" 2>/dev/null
    fail "interrupted by a signal (hook timeout?)"
}
trap on_signal TERM INT HUP

# run <dir> <command...>: run a long step in <dir> with stdin closed.
run() {
    local dir=$1 rc
    shift
    (cd -- "$dir" && exec "$@") </dev/null &
    child=$!
    wait "$child"
    rc=$?
    child=""
    return "$rc"
}

need() {
    command -v "$1" >/dev/null || fail "$2 is present but $1 is not on PATH"
}

is_registered() {
    local line
    while IFS= read -r -d '' line; do
        [[ $line == "worktree $path" ]] && return 0
    done < <(git -C "$main" worktree list --porcelain -z)
    return 1
}

default_branch() {
    local b
    if b=$(git -C "$main" symbolic-ref -q --short refs/remotes/origin/HEAD); then
        b=${b#origin/}
        git -C "$main" show-ref --verify -q "refs/remotes/origin/$b" && { printf '%s' "$b"; return; }
    fi
    for b in main master; do
        git -C "$main" show-ref --verify -q "refs/remotes/origin/$b" && { printf '%s' "$b"; return; }
    done
    printf 'main'
}

base_ref_setting() {
    local f v
    for f in "$main/.claude/settings.local.json" "$main/.claude/settings.json" \
        "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json"; do
        [[ -f $f ]] || continue
        if ! v=$(jq -r '.worktree.baseRef // empty' "$f" 2>/dev/null); then
            printf 'worktree-create: cannot read worktree.baseRef from %s, ignoring the file\n' "$f" >&2
            continue
        fi
        [[ -n $v ]] && { printf '%s' "$v"; return; }
    done
}

# Prints the commit to base a new branch on. It runs in a command
# substitution, so anything else it lets through to stdout would become part
# of the base.
pick_base() {
    local d mtime ref
    if [[ $(base_ref_setting) == head ]]; then
        git -C "$cwd" rev-parse --verify -q 'HEAD^{commit}' || fail "worktree.baseRef is head, but $cwd has no HEAD commit"
        return
    fi
    ref=HEAD
    if git -C "$main" remote get-url origin >/dev/null 2>&1; then
        d=$(default_branch)
        if git -C "$main" show-ref --verify -q "refs/remotes/origin/$d"; then
            ref=origin/$d
            mtime=$(stat -c %Y -- "$common/FETCH_HEAD" 2>/dev/null) || mtime=0
            if (($(date +%s) - mtime > 86400)); then
                GIT_TERMINAL_PROMPT=0 timeout 5 git -C "$main" fetch origin "$d" </dev/null >&2 ||
                    printf 'worktree-create: refreshing origin/%s failed, using the local copy\n' "$d" >&2
            fi
        else
            # The built-in waits for this first fetch without a limit; a hung
            # remote should not hold the hook to its timeout, so 60 s.
            if GIT_TERMINAL_PROMPT=0 timeout 60 git -C "$main" fetch origin "$d" </dev/null >&2 &&
                git -C "$main" show-ref --verify -q "refs/remotes/origin/$d"; then
                ref=origin/$d
            else
                printf 'worktree-create: fetching origin/%s failed, basing on local HEAD\n' "$d" >&2
            fi
        fi
    fi
    git -C "$main" rev-parse --verify -q "$ref^{commit}" || fail "cannot resolve the base $ref in $main"
}

copy_included() {
    local wti="$main/.worktreeinclude" rel rest sub n=0 files=()
    [[ -f $wti ]] || return 0
    # Untracked files the patterns match, narrowed to those git ignores.
    # check-ignore exits 1 when nothing matched, which is not an error here.
    mapfile -d '' -t files < <(
        git -C "$main" ls-files -z --others --ignored --exclude-from="$wti" |
            git -C "$main" check-ignore -z --stdin
        st=("${PIPESTATUS[@]}")
        ((st[0] == 0 && st[1] <= 1))
    )
    wait $! || fail "cannot list the files .worktreeinclude matches"
    for rel in "${files[@]}"; do
        if [[ $rel == .claude/settings.local.json ]]; then
            continue
        fi
        if [[ -L $main/$rel || ! -f $main/$rel ]]; then
            printf 'worktree-create: not copying %s: not a regular file\n' "$rel" >&2
            continue
        fi
        # A committed symlink in the worktree could lead the copy outside it.
        rest=$rel sub=""
        while [[ $rest == */* ]]; do
            sub=$sub${sub:+/}${rest%%/*}
            rest=${rest#*/}
            if [[ -L $path/$sub || -L $main/$sub ]]; then
                printf 'worktree-create: not copying %s: %s is a symlink\n' "$rel" "$sub" >&2
                continue 2
            fi
        done
        if [[ -e $path/$rel || -L $path/$rel ]]; then
            printf 'worktree-create: not copying %s: the worktree already has it\n' "$rel" >&2
            continue
        fi
        if ! mkdir -p -- "$path/$sub" || ! cp --preserve=mode -- "$main/$rel" "$path/$rel"; then
            fail "copying $rel from .worktreeinclude failed"
        fi
        n=$((n + 1))
    done
    printf 'worktree-create: copied %d file(s) from .worktreeinclude\n' "$n" >&2
}

install_deps() {
    if [[ -f $path/pnpm-lock.yaml ]]; then
        need pnpm pnpm-lock.yaml
        run "$path" env COREPACK_ENABLE_DOWNLOAD_PROMPT=0 pnpm install --frozen-lockfile ||
            fail "pnpm install --frozen-lockfile failed"
    elif [[ -f $path/package-lock.json ]]; then
        need npm package-lock.json
        run "$path" npm ci || fail "npm ci failed"
    fi
    if [[ -f $path/uv.lock ]]; then
        need uv uv.lock
        run "$path" uv sync --frozen || fail "uv sync --frozen failed"
    fi
}

run_setup() {
    local setup="$path/.claude/worktree-setup"
    [[ -e $setup ]] || return 0
    if [[ ! -f $setup || ! -x $setup ]]; then
        printf 'worktree-create: %s is not an executable file, not running it\n' "$setup" >&2
        return 0
    fi
    run "$path" env WORKTREE_MAIN="$main" WORKTREE_PATH="$path" WORKTREE_NAME="$name" "$setup" ||
        fail ".claude/worktree-setup failed"
}

provision() {
    local input base flat p rc
    input=$(cat)
    name=$(jq -r '.name // empty' <<<"$input" 2>/dev/null) || fail "stdin is not the WorktreeCreate JSON"
    cwd=$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null) || fail "stdin is not the WorktreeCreate JSON"

    [[ -n $name ]] || fail "the hook input has no name"
    ((${#name} <= 64)) || fail "name longer than 64 characters: $name"
    [[ $name =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] ||
        fail "name is not /-separated segments of [A-Za-z0-9._-]: $name"
    flat=${name//\//+}
    [[ $flat != . && $flat != .. ]] || fail "name cannot be . or ..: $name"
    branch=worktree-$flat
    git check-ref-format "refs/heads/$branch" || fail "$branch is not a valid branch name"

    [[ -n $cwd && -d $cwd ]] || fail "cwd is not a directory: ${cwd:-(none)}"
    common=$(git -C "$cwd" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) ||
        fail "not a git repository: $cwd"
    main=$(realpath -e -- "${common%/*}") || fail "cannot resolve the main checkout of $cwd"
    [[ $(git -C "$main" rev-parse --show-toplevel 2>/dev/null) == "$main" ]] ||
        fail "cannot find the main checkout of $cwd (git dir $common); bare repositories, submodules and separate git dirs are not supported"
    path=$main/.claude/worktrees/$flat

    for p in "$main/.claude" "$main/.claude/worktrees" "$path"; do
        [[ -L $p ]] && fail "$p is a symlink; it could redirect the worktree outside the repository"
    done

    if is_registered; then
        if [[ -d $path ]]; then
            log resumed
            return 0
        fi
        git -C "$main" worktree prune
    fi

    base=$(pick_base) || exit 1
    mkdir -p -- "$main/.claude/worktrees" || fail "cannot create $main/.claude/worktrees"

    # Whatever git leaves at a path that did not exist is ours to roll back.
    [[ -e $path ]] || created_wt=1
    if git -C "$main" show-ref --verify -q "refs/heads/$branch"; then
        run "$main" git worktree add -- "$path" "$branch" ||
            fail "git worktree add failed for the existing branch $branch"
    else
        run "$main" git worktree add --no-track -b "$branch" -- "$path" "$base"
        rc=$?
        git -C "$main" show-ref --verify -q "refs/heads/$branch" && created_branch=1
        ((rc == 0)) || fail "git worktree add failed for the new branch $branch"
    fi
    created_wt=1

    copy_included
    install_deps
    run_setup
    log created
}

# fd 3 is the real stdout. Closing it for provision keeps every child, and any
# daemon a child leaves behind, from holding Claude's pipe open.
provision 3>&-
printf '%s\n' "$path" >&3
exit 0
