# shellcheck shell=bash
# shellcheck disable=SC2015 # "A && B || bad" is the test idiom here: bad only logs
# The tests of obsidian-open-daily (tests/desktop/obsidian-open-daily.nix runs
# this in the build sandbox). The environment names the script built for the
# vault "/tmp/ood/My Notes" (script) and the one built without a vault
# (scriptNoVault). Obsidian's CLI and gtk-launch are stand-ins that keep their
# calls in a state directory, so each test can read what the script did and
# decide how Obsidian answers.
set +e
set -u
script=${script:?}
scriptNoVault=${scriptNoVault:?}
fail=0
bad() { echo "FAIL: $*" >&2; fail=1; }
ok() { echo "ok: $*"; }

work=$PWD/work
mkdir -p "$work"
# The build sandbox throws everything away; a run outside it must not leave
# the vault behind.
trap 'rm -rf /tmp/ood' EXIT
vault="/tmp/ood/My Notes"
daily="Daily"
state=""

# The stand-in CLI. `vault info=name` answers the next line of $STATE/vault
# (the last line again and again; nothing when the file is empty), `open
# path=...` answers $STATE/open-reply or "Opened: PATH". Every call is logged.
{ echo "#!$BASH"; cat <<'CLI'
echo "$*" >>"$STATE/cli.log"
case "$1" in
vault)
  [ -s "$STATE/vault" ] || exit 0
  head -n 1 "$STATE/vault"
  [ "$(wc -l <"$STATE/vault")" -le 1 ] || sed -i 1d "$STATE/vault"
  ;;
open)
  if [ -f "$STATE/open-reply" ]; then cat "$STATE/open-reply"; else echo "Opened: ${2#path=}"; fi
  ;;
esac
exit 0
CLI
} >"$work/cli"
# The stand-in gtk-launch: logs its arguments; if $STATE/after-launch exists,
# Obsidian "comes up" and answers from then on.
{ echo "#!$BASH"; cat <<'GTK'
echo "$*" >>"$STATE/launch.log"
[ ! -f "$STATE/after-launch" ] || cp "$STATE/after-launch" "$STATE/vault"
exit 0
GTK
} >"$work/gtk-launch"
chmod +x "$work/cli" "$work/gtk-launch"

# The vault: three kinds of daily note, and things that are none.
mkvault() {
  rm -rf /tmp/ood
  mkdir -p "$vault/.obsidian" "$vault/$daily"
  printf '{"folder": "%s"}\n' "$daily" >"$vault/.obsidian/daily-notes.json"
  local f
  for f in "Friday, 31. Dec 2025 (W53)" "Thursday, 01. Jan 2026 (W1)" "Sunday, 09. Aug 2026 (W32)" \
    "Monday, 10. Foo 2027" "readme" "Saturday, 8. August 2026"; do
    : >"$vault/$daily/$f.md"
  done
}
newest="Daily/Sunday, 09. Aug 2026 (W32).md"

# run NAME ARGS...: a state directory $work/NAME (names are unique), the
# script (or $SCRIPT) run with the stand-ins and a short wait; stdout in
# $state/out, stderr in $state/err, status in $rc. What Obsidian answers is
# set by vault_lines (the lines of `vault info=name`, one per call), what it
# does after gtk-launch by after_lines, and the answer to `open` by open_reply.
run() {
  state=$work/$1
  shift
  mkdir -p "$state"
  [ -z "$vault_lines" ] || printf '%s\n' "$vault_lines" >"$state/vault"
  [ -z "$after_lines" ] || printf '%s\n' "$after_lines" >"$state/after-launch"
  [ -z "$open_reply" ] || printf '%s\n' "$open_reply" >"$state/open-reply"
  STATE=$state OBSIDIAN_CLI=${CLI_BIN:-$work/cli} GTK_LAUNCH=${GTK_BIN:-$work/gtk-launch} \
    OBSIDIAN_OPEN_DAILY_WAIT=${WAIT:-2} OBSIDIAN_OPEN_DAILY_POLL=0.05 \
    "${SCRIPT:-$script}" "$@" >"$state/out" 2>"$state/err"
  rc=$?
}
reset() { vault_lines="" after_lines="" open_reply="" CLI_BIN="" GTK_BIN="" SCRIPT="" WAIT=""; }
opened() { local n=0; [ -f "$state/cli.log" ] && n=$(grep -c '^open ' "$state/cli.log"); echo "$n"; }
launched() { local n=0; [ -f "$state/launch.log" ] && n=$(grep -c . "$state/launch.log"); echo "$n"; }
has() { grep -qF -- "$2" "$state/$1" 2>/dev/null; } # has FILE TEXT

# ── --print reports the plan and starts nothing ──────────────────────────────
reset; mkvault; vault_lines="My Notes"
run print --print
[ $rc = 0 ] || bad "--print exited $rc"
has out "vault        : My Notes ($vault)" || bad "--print does not name the vault: $(cat "$state/out")"
has out "newest daily : $newest" || bad "--print does not name the newest daily note: $(cat "$state/out")"
has out "active vault : My Notes" || bad "--print does not name the active vault: $(cat "$state/out")"
[ "$(launched)" = 0 ] && [ "$(opened)" = 0 ] || bad "--print started or opened something"
ok "--print"

# ── Obsidian up on the vault: the newest note is opened, nothing is started ──
reset; mkvault; vault_lines="My Notes"
run up
[ $rc = 0 ] || bad "the running case exited $rc: $(cat "$state/err")"
[ "$(opened)" = 1 ] && has cli.log "open path=$newest" || bad "the newest daily note was not opened: $(cat "$state/cli.log")"
[ "$(launched)" = 0 ] || bad "a running Obsidian was launched again"
ok "a running Obsidian on the vault opens the newest note"

# The newest by date, not by name or mtime: Dec 2025 < Jan 2026 < Aug 2026, a
# month that is no month and a note without a date are skipped, a long month
# name counts.
touch -d '2001-01-01' "$vault/$daily/Sunday, 09. Aug 2026 (W32).md"
touch -d '2030-01-01' "$vault/$daily/Friday, 31. Dec 2025 (W53).md"
reset; vault_lines="My Notes"
run bydate
has cli.log "open path=$newest" || bad "the note is chosen by modification time or by name, not by its date: $(cat "$state/cli.log")"
: >"$vault/$daily/Monday, 10. August 2026.md"
reset; vault_lines="My Notes"
run longmonth
has cli.log "open path=Daily/Monday, 10. August 2026.md" || bad "a long month name is not read: $(cat "$state/cli.log")"
ok "the newest note is the latest date"

# ── Obsidian not up: started once through its desktop id, then waited for ────
reset; mkvault
vault_lines=$'Error: Command "vault" not found. Did you mean: daily?\nError: Command "vault" not found. Did you mean: daily?\nMy Notes'
run cold
[ $rc = 0 ] || bad "the cold start exited $rc: $(cat "$state/err")"
[ "$(launched)" = 1 ] && has launch.log "md.obsidian.Obsidian" && ! has launch.log "obsidian://" || bad "Obsidian was not started once, plainly, by its desktop id: $(cat "$state/launch.log")"
[ "$(opened)" = 1 ] && has cli.log "open path=$newest" || bad "the note was not opened after the start: $(cat "$state/cli.log")"
ok "a cold start launches plainly and opens the note once Obsidian answers"

# An error is not a vault name, however many times it comes.
reset; mkvault
vault_lines=$'Error: Command "vault" not found.\nError: x'
WAIT=0.5 run errors
[ "$(opened)" = 0 ] && ! has launch.log "obsidian://" || bad "an error line was taken for the name of a vault"
has err "did not answer" || bad "no word that Obsidian never answered: $(cat "$state/err")"
ok "an error line is not a vault name"

# ── another vault on top: the URI is the one thing that can switch ───────────
reset; mkvault; vault_lines="Other Vault"
run other
[ $rc = 0 ] || bad "the other-vault case exited $rc"
[ "$(opened)" = 0 ] || bad "the note was opened in the wrong vault"
want="md.obsidian.Obsidian obsidian://open?vault=My%20Notes&file=Daily/Sunday%2C%2009.%20Aug%202026%20%28W32%29"
has launch.log "$want" || bad "the fallback URI is not the quoted one: $(cat "$state/launch.log")"
has err 'active vault is "Other Vault", not "My Notes"' || bad "the wrong vault is not said: $(cat "$state/err")"
ok "a different active vault takes the URI fallback"

# ── Obsidian never answers, or the CLI is not installed ──────────────────────
reset; mkvault
WAIT=0.4 run silent
[ $rc = 0 ] || bad "a silent Obsidian made the script fail ($rc)"
[ "$(launched)" = 1 ] && [ "$(opened)" = 0 ] && has err "did not answer" || bad "silent Obsidian: launches $(launched), opens $(opened), $(cat "$state/err")"
ok "an Obsidian that never answers is left alone"
reset; mkvault; CLI_BIN=/nonexistent/obsidian WAIT=0.4 run nocli
[ $rc = 0 ] && [ "$(launched)" = 1 ] && has err "did not answer" || bad "a missing CLI is not survived: rc $rc, $(cat "$state/err")"
ok "a missing CLI is survived"

# gtk-launch missing is said, not a traceback.
reset; mkvault
GTK_BIN=/nonexistent/gtk-launch WAIT=0.3 run nogtk2
[ $rc = 0 ] && ! has err Traceback || bad "a missing gtk-launch crashes the script: rc $rc, $(cat "$state/err")"
ok "a missing gtk-launch is survived"

# ── the CLI says "not found" with exit status 0 ──────────────────────────────
reset; mkvault; vault_lines="My Notes"; open_reply="Error: File not found"
run notfound
[ $rc = 0 ] && has err 'could not open "Daily/Sunday, 09. Aug 2026 (W32).md"' || bad "a failed open is not said: rc $rc, $(cat "$state/err")"
ok "an open that fails by its output is reported"

# ── no vault: Obsidian starts plainly and nothing else happens ───────────────
reset; mkvault; vault_lines="My Notes"; SCRIPT=$scriptNoVault
run novault
[ $rc = 0 ] && [ "$(launched)" = 1 ] && [ ! -e "$state/cli.log" ] || bad "no vault: rc $rc, launches $(launched), CLI calls: $(cat "$state/cli.log" 2>/dev/null)"
has launch.log "md.obsidian.Obsidian" || bad "no vault: Obsidian was not started plainly"
reset; mkvault; vault_lines="My Notes"; SCRIPT=$scriptNoVault
run novault-print --print
[ $rc = 0 ] && ! has out "vault        : ." || bad "no vault: --print takes the current directory for the vault: $(cat "$state/out")"
ok "no vault starts Obsidian plainly"

# ── the vault is gone, or its settings are ───────────────────────────────────
reset; rm -rf /tmp/ood; vault_lines="My Notes"
run gone
[ $rc = 0 ] && [ "$(launched)" = 1 ] && [ "$(opened)" = 0 ] && has err "vault is gone" || bad "a missing vault: rc $rc, launches $(launched), $(cat "$state/err")"
ok "a missing vault starts Obsidian plainly"

reset; mkvault; vault_lines="My Notes"
rm -f '/tmp/ood/My Notes/.obsidian/daily-notes.json'
run nosettings
[ $rc = 0 ] && [ "$(opened)" = 0 ] && has err "daily-notes.json" || bad "no daily-notes.json: rc $rc, opens $(opened), $(cat "$state/err")"
printf '{"folder": ' >"$vault/.obsidian/daily-notes.json"
run brokensettings
[ $rc = 0 ] && [ "$(opened)" = 0 ] && has err "daily-notes.json" || bad "a broken daily-notes.json: rc $rc, opens $(opened), $(cat "$state/err")"
printf '{"folder": "Elsewhere"}' >"$vault/.obsidian/daily-notes.json"
run nofolder
[ $rc = 0 ] && [ "$(opened)" = 0 ] && has err "no such folder" || bad "a missing daily folder: rc $rc, $(cat "$state/err")"
printf '[]' >"$vault/.obsidian/daily-notes.json"
run notanobject
[ $rc = 0 ] && [ "$(opened)" = 0 ] || bad "a settings file that is no object crashes the script: rc $rc, $(cat "$state/err")"
ok "missing and broken settings are said, never fatal"

reset; mkvault; vault_lines="My Notes"
find '/tmp/ood/My Notes/Daily' -name '*.md' -delete
: >"$vault/$daily/notes.md"
run nodates
[ $rc = 0 ] && [ "$(opened)" = 0 ] && has err "parsed as a date" && has err "no daily note to open" || bad "no dated note: rc $rc, $(cat "$state/err")"
ok "a folder without dated notes opens nothing"

# A daily folder that is the vault's root.
reset; mkvault; vault_lines="My Notes"
printf '{"folder": ""}' >"$vault/.obsidian/daily-notes.json"
: >"$vault/Sunday, 09. Aug 2026.md"
run root
has cli.log "open path=Sunday, 09. Aug 2026.md" || bad "an empty daily folder is not the vault root: $(cat "$state/cli.log" 2>/dev/null) $(cat "$state/err")"
ok "an empty daily folder means the vault root"

# ── a big folder, a bad wait, concurrent runs ────────────────────────────────
reset; mkvault; vault_lines="My Notes"
for i in $(seq 1 3000); do : >"$vault/$daily/Monday, 01. Jan 2024 ($i).md"; done
run big
has cli.log "open path=$newest" || bad "a folder of 3000 notes: $(cat "$state/cli.log") $(cat "$state/err")"
reset; vault_lines="My Notes"; WAIT=abc
run badwait
[ $rc = 0 ] && has cli.log "open path=$newest" || bad "a wait that is no number crashes the script: rc $rc, $(cat "$state/err")"
for n in 1 2 3; do
  (
    mkdir -p "$work/par$n"
    printf 'My Notes\n' >"$work/par$n/vault"
    STATE=$work/par$n OBSIDIAN_CLI=$work/cli GTK_LAUNCH=$work/gtk-launch OBSIDIAN_OPEN_DAILY_WAIT=2 OBSIDIAN_OPEN_DAILY_POLL=0.05 "$script" 2>/dev/null
  ) &
done
wait
for n in 1 2 3; do
  grep -q "open path=$newest" "$work/par$n/cli.log" || bad "concurrent run $n did not open the note"
done
ok "a big folder, a bad wait and concurrent runs"

[ $fail = 0 ] || exit 1
echo "obsidian-open-daily: all tests passed"
