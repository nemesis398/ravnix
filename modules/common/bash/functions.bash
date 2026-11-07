# shellcheck shell=bash
# The shell functions of the Fedora .bashrc, ported. bash.nix puts this file
# into every interactive bash; tests/common/helpers/functions.test.bash
# sources it on its own, so it holds definitions and nothing that runs.
#
# Left out on purpose: the httpie alias (httpie is dropped), the Android and
# Flutter block (so are the SDKs), `edit-bash` (the bashrc is a read-only link
# into the store here), and the herdr hook and its alias `t`, which are the
# terminal glue's (ravnix.shell.autoAttach).

# `cat` on images draws them with chafa, which speaks the kitty graphics
# protocol that herdr passes through to ghostty. Only when stdout is a
# terminal and every argument is an image; anything else goes to bat, so
# `cat x | ...` and a mix of text and images are as before. Images are 50% of
# the window wide; chafa's own `-s WxH` (or `-s W`) as the first argument sets
# the size instead. kitty and full color are forced under herdr and ghostty,
# so chafa's guess can never drop to 256-color character art.
cat() {
    local f size fmt=() all=("$@")
    if [[ -t 1 ]] && command -v chafa &>/dev/null; then
        case $1 in
            -s | --size) size=$2; shift 2 ;;
            --size=*) size=${1#*=}; shift ;;
        esac
        (($#)) || { bat "${all[@]}"; return; }
        for f in "$@"; do
            [[ $f != -* && -f $f && $(file -b --mime-type -- "$f") == image/* ]] || { bat "${all[@]}"; return; }
        done
        [[ $TERM_PROGRAM == herdr || $TERM_PROGRAM == ghostty ]] && fmt=(-f kitty)
        if [[ $size ]]; then
            chafa "${fmt[@]}" -c full --animate=off --scale max -s "$size" -- "$@"
        else
            chafa "${fmt[@]}" -c full --animate=off --scale max --view-size "$((${COLUMNS:-$(tput cols)} / 2))x" -- "$@"
        fi
        return
    fi
    bat "$@"
}

# `sudo nvim FILE...` runs as `sudoedit FILE...`: Neovim starts as you, with
# your config and plugins, on a temporary copy that sudo writes back as root.
# Running nvim itself as root would make root execute plugin code you can
# write without root, and leave root-owned files in ~/.local/share/nvim.
# Anything else, including a bare `sudo nvim`, goes to the real sudo.
sudo() {
    if [[ $1 == nvim ]] && (($# > 1)); then
        shift
        command sudoedit "$@"
    else
        command sudo "$@"
    fi
}

# sff DESTINATION: pick the most recently changed file under the current
# directory with fzf (previewed in bat) and scp it to DESTINATION.
sff() {
    if [ $# -eq 0 ]; then
        echo "Usage: sff <destination> (e.g. sff host:/tmp/)"
        return 1
    fi
    local file
    file=$(find . -type f -printf '%T@\t%p\n' | sort -rn | cut -f2- |
        fzf --preview 'bat --style=numbers --color=always {}') && [ -n "$file" ] && scp "$file" "$1"
}

# zoxide-driven cd; `cd` is an alias for it. `zd` jumps with zoxide; the
# prompt already shows the cwd. A directory that exists is entered as it is.
zd() {
    if (($# == 0)); then
        builtin cd ~ || return
    elif [[ -d $1 ]]; then
        builtin cd "$1" || return
    else
        if ! z "$@"; then
            echo "Error: Directory not found"
            return 1
        fi
    fi
}

# Open in the default XDG app (a browser, an editor, ...).
open() (
    xdg-open "$@" >/dev/null 2>&1 &
)

# over [N] [file]: print the lines wider than N columns (default 80) with their
# line numbers, tabs expanded first so they count as the columns they occupy.
# Reads stdin when no file is given. The check behind the 80-column Markdown rule.
over() {
    local c=${1:-80}
    expand -- "${@:2}" | awk -v "c=$c" 'length($0) > c { printf("%4d %s\n", NR, $0) }'
}

# gr [subpath]: cd to the root of the current git work tree, or to subpath
# below it. `builtin cd` because `cd` is aliased to zd, which would hand a
# missing directory to zoxide's fuzzy search instead of failing. Outside a
# repository git prints its own error and gr stays where it is.
gr() {
    local root
    root=$(git rev-parse --show-toplevel) || return
    builtin cd "$root/${1-}" || return
}

# The name of the main branch, from origin/HEAD. That ref exists after a
# `git clone` but not after `git init` plus `git remote add`; then
# `git remote set-head origin --auto` creates it. Functions, not aliases,
# because the name differs per repository (main, master, ...). Adapted from
# github.com/bahamas10/dotfiles.
gmb() {
    local main
    main=$(git symbolic-ref --short -q refs/remotes/origin/HEAD) || {
        echo "gmb: origin/HEAD is not set (try: git remote set-head origin --auto)" >&2
        return 1
    }
    echo "${main#origin/}"
}

# gbd: what this branch changed since it left the main branch. Three dots, so
# commits that main gained meanwhile do not show up as reversed changes.
gbd() {
    local mb
    mb=$(gmb) || return
    git diff "$mb"...HEAD
}

# gsm: switch to the main branch and update it. (gcm is taken by commit -m.)
gsm() {
    local mb
    mb=$(gmb) || return
    git switch "$mb" && git pull
}

# gmm: merge the main branch into the current branch.
gmm() {
    local mb
    mb=$(gmb) || return
    git merge "$mb"
}

# gho [file-or-dir] [remote]: print the web URL of the current directory, or of
# the given file or directory, at the current branch (or commit when HEAD is
# detached) and open it. The remote defaults to origin. github.com gets
# GitHub's /tree and /blob layout; every other host is assumed to be Forgejo or
# Gitea (/src/branch/...). A branch that is not pushed yet gives a 404.
gho() {
    local target=${1-} remote=${2:-origin}
    local url re host repo ref kind prefix path view
    url=$(git config --get "remote.$remote.url") || {
        echo "gho: no remote named '$remote'" >&2
        return 1
    }
    prefix=$(git rev-parse --show-prefix) || return
    # Both remote spellings: scheme://[user@]host[:port]/owner/repo[.git] and the
    # scp form [user@]host:owner/repo[.git]. The port is for ssh and is dropped.
    re='^([a-z+]+://)?([^@/]+@)?([^:/]+)(:[0-9]+)?[:/](.+)$'
    if [[ ! $url =~ $re ]]; then
        echo "gho: cannot read the remote URL '$url'" >&2
        return 1
    fi
    host=${BASH_REMATCH[3]}
    repo=${BASH_REMATCH[5]%/}
    repo=${repo%.git}
    if ref=$(git symbolic-ref --short -q HEAD); then
        kind=branch
    else
        ref=$(git rev-parse HEAD) kind=commit
    fi
    # A dot is the directory itself (the Fedora version printed it as /.).
    [[ $target == . ]] && target=
    path=${prefix}${target}
    path=${path%/}
    path=${path// /%20}
    if [[ $host == github.com ]]; then
        [[ -f $target ]] && view=blob || view=tree
        url="https://$host/$repo/$view/$ref"
    else
        url="https://$host/$repo/src/$kind/$ref"
    fi
    url+=${path:+/$path}
    echo "$url"
    open "$url"
}

# Odin. ob [dir] [-o out]: build the package in dir (default: the current
# directory); the binary lands in dir, named after it. -o renames it, before
# or after dir: a bare name still lands in dir, a name with a / is a path from
# where ob was called, not from dir. ot [-b] [dir]: run dir's tests, and
# with -b build dir first (ob), testing only when the build passes. With a
# tests/ folder they are a package of their own that runs the binary as
# ./<name>, so without -b they test whatever binary the last build left.
# Without one they are *_test.odin files in the package itself, which may
# have no main to build, so -b there fails for a package without one.
# Subshells keep the cd local; `builtin cd` because cd is aliased to zd.
# shellcheck disable=SC2120 # the arguments are the caller's, from the prompt
ob() (
    local out='' dir=
    while (($#)); do
        case $1 in
            -o)
                out=${2:?ob: -o needs a file name}
                shift 2
                ;;
            *)
                [[ -z $dir ]] || { echo "ob: one directory only" >&2; exit 2; }
                dir=$1
                shift
                ;;
        esac
    done
    # A path is taken from here, before the cd below moves us into dir.
    [[ $out == */* && $out != /* ]] && out=$PWD/$out
    builtin cd -- "${dir:-.}" && odin build . -vet ${out:+"-out:$out"}
)
ot() (
    build=
    if [[ ${1-} == -b ]]; then
        build=1
        shift
    fi
    builtin cd -- "${1:-.}" || exit
    if [[ -n $build ]]; then
        # shellcheck disable=SC2119 # no arguments: the package in this directory
        ob || exit
    fi
    if [[ -d tests ]]; then
        odin test tests
    else
        odin test .
    fi
)
