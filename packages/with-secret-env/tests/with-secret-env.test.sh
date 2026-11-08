#!/usr/bin/env bash
# Tests for with-secret-env (packages/with-secret-env), run by the check
# bin-with-secret-env. rbw is a stand-in that logs what it is asked, answers
# from a fixed table of items, and records which secrets an rbw child could see
# in its environment (the helper must export only after the last read). The
# command it runs is a stand-in that records its argument vector and the
# secrets it got. The cases that matter most are the negative ones: that a
# value reaches no command line, no log and no trace, that nothing is exported
# when a read fails, and that a locked vault is never prompted for.
#
# WITH_SECRET_ENV_UNDER_TEST=<file> tests another copy; by default it is the
# with-secret-env on the PATH.

# The checks are eval'd, so their $ expand at check time (SC2016), and the
# variables they read are set outside them (SC2034).
# shellcheck disable=SC2016,SC2034

set -uo pipefail

SUT=$(readlink -f "${WITH_SECRET_ENV_UNDER_TEST:-$(type -P with-secret-env)}")
BASH_BIN=$(type -P bash)
SB=$(mktemp -d "${TMPDIR:-/tmp}/with-secret-env-test.XXXXXX")
trap 'rm -r -- "$SB"' EXIT

pass=0 fail=0
ok()  { printf '  \e[32m✓\e[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \e[31m✗\e[0m %s\n%s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$SB/bin" "$SB/nobin" "$SB/home" "$SB/tools"
# The tools the stand-ins need, found once; the PATH of a run is the stand-ins
# and these.
TOOLS="$SB/tools"
for t in env grep cat tr sort; do ln -s "$(type -P "$t")" "$TOOLS/$t"; done

stub() { # stub DIR NAME: the script on stdin, made executable, naming this bash
    cat >"$1/$2"
    sed -i "1s|.*|#!$BASH_BIN|" "$1/$2"
    chmod +x "$1/$2"
}
stub "$SB/bin" rbw <<'STUB'
#!/usr/bin/env bash
printf 'rbw %s\n' "$*" >>"$LOG"
case $1 in
    unlocked) [[ ${RBW_LOCKED:-0} == 0 ]] ;;
    get)
        # What this child of the helper could see of the secrets.
        env | grep -E '^[A-Z0-9_]*_TOKEN=' >>"$SEEN" || true
        case $3 in
            "First item") printf 'plain-1\n' ;;
            "Second item") printf 'two words  with spaces\n' ;;
            "Third item") printf '%s\n' 'a=b$HOME`id`"q'"'"'\z' ;;
            "Fourth item") printf 'line1\nline2\n' ;;
            "Empty item") ;;
            "Item=with=equals") printf 'eq-value\n' ;;
            "Spill item") printf 'rbw-stderr-spill-secret\n' >&2; exit 1 ;;
            *) exit 1 ;;
        esac ;;
    *) exit 0 ;;
esac
STUB
# The command: records its argv (NUL-separated, and its own command line from
# /proc) and the secrets it got. Its exit code comes from CHILD_RC.
stub "$SB/bin" child <<'STUB'
#!/usr/bin/env bash
printf '%s\0' "$@" >"$OUT.argv"
tr '\0' ' ' </proc/$$/cmdline >"$OUT.cmdline"
env | grep -E '^[A-Z0-9_]*_TOKEN=|^WITH_SECRET_ENV_' | sort >"$OUT.env" || true
printf '%s' "${FIRST_TOKEN-<unset>}" >"$OUT.first"
printf '%s' "${SECOND_TOKEN-<unset>}" >"$OUT.second"
printf '%s' "${THIRD_TOKEN-<unset>}" >"$OUT.third"
printf '%s' "${FOURTH_TOKEN-<unset>}" >"$OUT.fourth"
exit "${CHILD_RC:-0}"
STUB

cat >"$SB/table" <<'TABLE'
FIRST_TOKEN=First item
SECOND_TOKEN=Second item
THIRD_TOKEN=Third item
FOURTH_TOKEN=Fourth item
TABLE

# run [ENV=VAL ...] -- ARGS: runs the helper with the stand-ins; sets $rc, $out
# (stdout), $err (stderr) and $log (what rbw was asked).
run() {
    local envs=()
    while [[ $1 != -- ]]; do envs+=("$1"); shift; done
    shift
    : >"$SB/log"; : >"$SB/seen"; rm -f "$SB"/out.*
    env -i HOME="$SB/home" PATH="$SB/bin:$TOOLS" LOG="$SB/log" SEEN="$SB/seen" OUT="$SB/out" \
        "${envs[@]}" "$BASH_BIN" "$SUT" "$@" >"$SB/stdout" 2>"$SB/stderr" </dev/null
    rc=$?
    out=$(<"$SB/stdout") err=$(<"$SB/stderr") log=$(<"$SB/log")
}
check() { if eval "$2"; then ok "$1"; else bad "$1" "    rc: $rc
    out: ${out:0:400}
    err: ${err:0:600}
    log: ${log:0:400}"; fi; }
asked() { grep -qxF -- "$1" "$SB/log"; }
child_env() { cat "$SB/out.env" 2>/dev/null; }
child_argv() { tr '\0' '|' <"$SB/out.argv" 2>/dev/null; }
# True when none of the values of the table appears in the files.
no_value_in() { ! grep -qF -e plain-1 -e "two words" -e 'q'"'" -e line1 -e eq-value -- "$@"; }

echo "with-secret-env"

# ── what reaches the command ───────────────────────────────────────────────
run -- --table "$SB/table" -- child
check "every secret of the table reaches the command, byte for byte, whatever it holds" \
    '[[ $rc == 0 && $(<"$SB/out.first") == "plain-1" && $(<"$SB/out.second") == "two words  with spaces" && $(<"$SB/out.third") == "a=b\$HOME\`id\`\"q'"'"'\\z" && $(<"$SB/out.fourth") == $'"'"'line1\nline2'"'"' ]]'
check "each item is read with rbw get, by its name, after one check that the vault is unlocked" \
    'asked "rbw unlocked" && asked "rbw get -- First item" && asked "rbw get -- Fourth item" && ! asked "rbw unlock"'
check "no rbw child could see a secret: nothing is exported before the last read" '[[ ! -s $SB/seen ]]'
check "no value is on the command line of the command, in anything the helper printed, or in the log" \
    'no_value_in "$SB/out.cmdline" "$SB/stdout" "$SB/stderr" "$SB/log"'
check "the command is not given the helper's own markers unless it asks for them" '! child_env | grep -q WITH_SECRET_ENV'

run -- --table "$SB/table" -- child "a b" "" --flag -n '*' --
check "the arguments of the command pass unchanged: spaces, empty, dashes, a glob, a bare --" \
    '[[ $(child_argv) == "a b||--flag|-n|*|--|" ]]'
run CHILD_RC=7 -- --table "$SB/table" -- child
check "the exit status is the command's" '[[ $rc == 7 ]]'
run -- --table "$SB/table" child --table x
check "without -- the first word that is no option is the command, and its options are its own" \
    '[[ $rc == 0 && $(child_argv) == "--table|x|" ]]'

# A trace of the helper itself must not carry a value.
env -i HOME="$SB/home" PATH="$SB/bin:$TOOLS" LOG="$SB/log" SEEN="$SB/seen" OUT="$SB/out" \
    "$BASH_BIN" -x "$SUT" --table "$SB/table" -- child >"$SB/stdout" 2>"$SB/stderr" </dev/null
check "run under bash -x, the trace holds no value" \
    'no_value_in "$SB/stderr" && [[ $(<"$SB/out.first") == plain-1 ]]'
env -i HOME="$SB/home" PATH="$SB/bin:$TOOLS" LOG="$SB/log" SEEN="$SB/seen" OUT="$SB/out" \
    SHELLOPTS=xtrace PS4='+X ' \
    "$BASH_BIN" "$SUT" --table "$SB/table" -- child >"$SB/stdout" 2>"$SB/stderr" </dev/null
check "with SHELLOPTS=xtrace in the environment, the trace holds no value either" \
    'no_value_in "$SB/stderr" && [[ $(<"$SB/out.first") == plain-1 ]]'

# ── a read that fails ──────────────────────────────────────────────────────
printf '%s\n' 'FIRST_TOKEN=First item' 'SECOND_TOKEN=No such item' 'THIRD_TOKEN=Third item' >"$SB/oneBad"
run -- --table "$SB/oneBad" -- child
check "when one read fails, none of the secrets is set, and the command still runs" \
    '[[ $rc == 0 && $(<"$SB/out.first") == "<unset>" && $(<"$SB/out.third") == "<unset>" && ! -s $SB/seen ]]'
check "the item that failed is named, and so is the consequence" \
    '[[ $err == *"SECOND_TOKEN: rbw cannot read the item \"No such item\""* && $err == *"none of the secrets is set"* ]]'
printf '%s\n' 'FIRST_TOKEN=First item' 'SECOND_TOKEN=Spill item' >"$SB/spill"
run -- --table "$SB/spill" -- child
check "what rbw writes to stderr when it fails is not passed on" '[[ $err != *spill-secret* && $out != *spill-secret* ]]'

printf '%s\n' 'FIRST_TOKEN=First item' 'SECOND_TOKEN=Empty item' >"$SB/oneEmpty"
run -- --table "$SB/oneEmpty" -- child
check "an item with an empty value is named and left unset, the others are set" \
    '[[ $rc == 0 && $(<"$SB/out.first") == "plain-1" && $(<"$SB/out.second") == "<unset>" && $err == *"SECOND_TOKEN: the item is empty"* ]]'

# ── a vault that cannot be read ────────────────────────────────────────────
run RBW_LOCKED=1 -- --table "$SB/table" -- child
check "a locked vault: the command runs without secrets and the note says to unlock" \
    '[[ $rc == 0 && $(<"$SB/out.first") == "<unset>" && $err == *"locked"* && $err == *"ai-unlock"* ]]'
check "a locked vault is neither read nor asked for a password" '! asked "rbw unlock" && [[ $log != *"rbw get"* ]]'
mkdir -p "$SB/onlychild"
cp "$SB/bin/child" "$SB/onlychild/child"
run PATH="$SB/onlychild:$TOOLS" -- --table "$SB/table" -- child
check "without rbw the command runs without secrets and the note says rbw is not installed" \
    '[[ $rc == 0 && $(<"$SB/out.first") == "<unset>" && $err == *"rbw is not installed"* ]]'

run -- --table "$SB/missing" -- child
check "a table that is not there is named, and the command runs" \
    '[[ $rc == 0 && $err == *"there is no $SB/missing"* && $(<"$SB/out.first") == "<unset>" && $log != *"rbw get"* ]]'
: >"$SB/emptytable"
run -- --table "$SB/emptytable" -- child
check "an empty table is not a problem: the command runs, nothing is said, nothing is read" \
    '[[ $rc == 0 && -z $err && $log != *"rbw get"* ]]'
printf '%s\n' '# only comments' '' '   ' >"$SB/comments"
run -- --table "$SB/comments" -- child
check "a table of comments is the same as an empty one" '[[ $rc == 0 && -z $err && $log != *"rbw get"* ]]'

# ── the table ──────────────────────────────────────────────────────────────
printf '%s\n' '# a comment' '' 'lower=First item' 'NOEQUALS' '1BAD=First item' 'FIRST_TOKEN=' ' SPACED=First item' 'SECOND_TOKEN=Second item' >"$SB/messy"
run -- --table "$SB/messy" -- child
check "comments, blank lines and lines that are not NAME=item are not part of the table" \
    '[[ $rc == 0 && -z $err && $log != *"First item"* && $(<"$SB/out.second") == "two words  with spaces" && $(<"$SB/out.first") == "<unset>" ]]'
printf '%s\n' 'FIRST_TOKEN=Item=with=equals' >"$SB/equals"
run -- --table "$SB/equals" -- child
check "an item name may hold an equals sign: the name ends at the first one" \
    'asked "rbw get -- Item=with=equals" && [[ $(<"$SB/out.first") == "eq-value" ]]'
printf 'FIRST_TOKEN=First item' >"$SB/nonl"
run -- --table "$SB/nonl" -- child
check "a last line with no newline is read" '[[ $(<"$SB/out.first") == "plain-1" ]]'
printf '%s\n' 'FIRST_TOKEN=Second item' 'FIRST_TOKEN=First item' >"$SB/dup"
run -- --table "$SB/dup" -- child
check "a name that appears twice gets the later item" '[[ $(<"$SB/out.first") == "plain-1" ]]'
for i in $(seq 1 300); do printf 'MANY_%d_TOKEN=First item\n' "$i"; done >"$SB/many"
run -- --table "$SB/many" -- child
check "three hundred secrets are all read and none is lost" \
    '[[ $rc == 0 && $(grep -c "^rbw get" "$SB/log") == 300 && $(grep -c "^MANY_" "$SB/out.env") == 300 ]]'

# ── where the table is ─────────────────────────────────────────────────────
mkdir -p "$SB/home/.config/ravnix" "$SB/xdg/ravnix"
cp "$SB/table" "$SB/home/.config/ravnix/secret-env"
printf 'FIRST_TOKEN=Item=with=equals\n' >"$SB/xdg/ravnix/secret-env"
run -- child
check "with no option the table is ~/.config/ravnix/secret-env" '[[ $(<"$SB/out.first") == "plain-1" ]]'
run XDG_CONFIG_HOME="$SB/xdg" -- child
check "XDG_CONFIG_HOME moves it" '[[ $(<"$SB/out.first") == "eq-value" ]]'
run RAVNIX_SECRET_ENV="$SB/table" XDG_CONFIG_HOME="$SB/xdg" -- child
check "RAVNIX_SECRET_ENV beats it" '[[ $(<"$SB/out.first") == "plain-1" ]]'
run RAVNIX_SECRET_ENV="$SB/xdg/ravnix/secret-env" -- --table "$SB/table" -- child
check "--table beats both" '[[ $(<"$SB/out.first") == "plain-1" ]]'

# ── the markers ────────────────────────────────────────────────────────────
run -- --table "$SB/table" --report -- child
check "--report names what was set in WITH_SECRET_ENV_LOADED, names only" \
    '[[ $(child_env) == *"WITH_SECRET_ENV_LOADED=FIRST_TOKEN SECOND_TOKEN THIRD_TOKEN FOURTH_TOKEN"* && $(child_env) != *WITH_SECRET_ENV_WHY* ]]'
run -- --table "$SB/oneBad" --report -- child
check "--report names why nothing was set in WITH_SECRET_ENV_WHY" \
    '[[ $(child_env) == *"WITH_SECRET_ENV_WHY=rbw could not read SECOND_TOKEN, so none of the secrets is set"* && $(child_env) != *WITH_SECRET_ENV_LOADED* ]]'
run RBW_LOCKED=1 -- --table "$SB/table" --report -- child
check "--report on a locked vault says so" '[[ $(child_env) == *"WITH_SECRET_ENV_WHY="*locked* ]]'
run -- --table "$SB/emptytable" --report -- child
check "--report on an empty table says that" '[[ $(child_env) == *"WITH_SECRET_ENV_WHY=the secret table names no secrets"* ]]'

# ── usage ──────────────────────────────────────────────────────────────────
run --
check "no command: usage on stderr, exit 2" '[[ $rc == 2 && $err == "usage: with-secret-env"* && -z $out ]]'
run -- --table "$SB/table"
check "a table and no command is the same" '[[ $rc == 2 && $err == "usage: with-secret-env"* ]]'
run -- --bogus child
check "an unknown option: usage, exit 2" '[[ $rc == 2 && $err == "usage: with-secret-env"* ]]'
run -- --table
check "--table with no file: usage, exit 2" '[[ $rc == 2 ]]'
run -- --help
check "--help prints the usage on stdout, exit 0" '[[ $rc == 0 && $out == "usage: with-secret-env"* ]]'
run -- --table "$SB/table" -- no-such-command-here
check "a command that does not exist exits 127" '[[ $rc == 127 ]]'

printf '\n%d passed, %d failed\n' "$pass" "$fail"
((fail == 0))
