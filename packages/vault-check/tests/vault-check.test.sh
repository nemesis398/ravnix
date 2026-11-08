#!/usr/bin/env bash
# Tests for vault-check's unresolved-link handling, its run of the AI memory
# lint, and the link checks' exemption of AI/specs and AI/plans.
#
# Why a stub harness rather than a run against the real vault: the check that
# matters here rides on the Obsidian CLI, which answers about whatever vault the
# desktop app has open and cannot be pointed elsewhere (vault-check says so
# itself and skips the check when the two disagree). So the CLI is stubbed, and
# with it the one thing that makes the weekly-note rule untestable by hand —
# the current date. Both stubs go on PATH; everything else is the real tool.
#
# The AI memory lint is a stand-in, fixtures/lint.py: the ai-memory skill that
# owns the real one is not part of ravnix. The stand-in has the three behaviors
# the cases need: an ERROR for a memory note over 6 KB, an ERROR for a domains
# file that is no JSON, and exit 1 when it found an ERROR. Its markdownlint is
# a silent stub, as the real lint's would otherwise add line-length findings to
# every fixture. Its domains file is one inside the sandbox.
#
# The script finds its baseline through VAULT_CHECK_BASELINE, which each
# sandbox sets to its own file, so a test can say what is accepted.
#
# The script is the package's, with its tools first on the PATH as
# writeShellApplication makes it. The stubs (obsidian, date) must come before
# those tools, so the check (tests/bin/vault-check.nix) makes a copy of the
# script whose PATH line starts with $STUB_PATH, and that copy is
# VAULT_CHECK_UNDER_TEST; nothing else of it differs.
#
# Run:  bash vault-check.test.sh          (exit 0 = all green)

# The setup functions are called by name, as the third argument of run.
# shellcheck disable=SC2329

set -uo pipefail

SELF=$(readlink -f "$0")
TESTDIR=${SELF%/*}
SCRIPT=$(readlink -f "${VAULT_CHECK_UNDER_TEST:-$(type -P vault-check)}")
[ -f "$SCRIPT" ] || { echo "no vault-check at $SCRIPT" >&2; exit 2; }
LINT=$(readlink -f "$TESTDIR/fixtures/lint.py")
[ -f "$LINT" ] || { echo "no lint.py at $LINT" >&2; exit 2; }
BASH_BIN=$(type -P bash)
REAL_DATE=$(type -P date)

pass=0
fail=0
CASE=""

ok()   { pass=$((pass+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  \033[31m✗\033[0m %s\n     %s\n' "$CASE" "$1"
         printf '%s\n' "$OUT" | sed 's/^/       | /' ; }

# --- the sandbox -----------------------------------------------------------
# One vault, two notes, no dot-directories: every check other than the one
# under test has to stay quiet, or the assertions below measure noise.
make_sandbox() {
  SB=$(mktemp -d)
  mkdir -p "$SB/vault" "$SB/bin"
  printf '# One\n\nlinks to [[Two]]\n' > "$SB/vault/One.md"
  printf '# Two\n\nlinks back to [[One]]\n' > "$SB/vault/Two.md"

  # 2026-W29 is in this baseline as permanently dead, and it is a past week,
  # so it is exactly the case where the baseline and the pattern rule disagree.
  cat > "$SB/vault-check.baseline" <<'EOF'
unresolved Some Server
unresolved 2026-W29
notes 1
EOF

  # STUB_UNRESOLVED holds one link per line, in the CLI's verbose shape:
  # link<TAB>count<TAB>sources, the sources joined by ", ". A bare link gets
  # the one source One.md, an ordinary note. Without `verbose` the stub prints
  # the link alone, as the real CLI does. A line that starts with `raw:` loses
  # the marker and is printed as it stands in either form, the way the CLI
  # prints an "Error:" line with exit 0.
  cat > "$SB/bin/obsidian" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  vault)      printf '%s\n' "$STUB_VAULT" ;;
  orphans|deadends|aliases) echo 0 ;;
  unresolved) if [ -n "${STUB_UNRESOLVED:-}" ]; then
                while IFS= read -r l; do
                  [[ "$l" == raw:* ]] && { printf '%s\n' "${l#raw:}"; continue; }
                  [[ "$l" == *$'\t'* ]] || l="$l"$'\t1\tOne.md'
                  case " $* " in
                    *" verbose "*) printf '%s\n' "$l" ;;
                    *)             printf '%s\n' "${l%%$'\t'*}" ;;
                  esac
                done <<< "$STUB_UNRESOLVED"
              fi
              exit "${STUB_UNRESOLVED_RC:-0}" ;;
  base:query) : ;;
esac
exit 0
EOF

  # Only the ISO-week format is answered; anything else is the real date, so a
  # future use of date(1) in vault-check cannot be silently faked by this stub.
  cat > "$SB/bin/date" <<'EOF'
#!/usr/bin/env bash
[ "${1:-}" = "+%G-W%V" ] && { printf '%s\n' "$STUB_WEEK"; exit 0; }
exec "${REAL_DATE:?}" "$@"
EOF

  printf '#!/bin/sh\nexit 0\n' > "$SB/bin/markdownlint-cli2"

  # The build sandbox has no /usr/bin/env, so the stubs name the bash that
  # runs the tests.
  sed -i "1s|.*|#!$BASH_BIN|" "$SB/bin/obsidian" "$SB/bin/date"
  chmod +x "$SB/bin/obsidian" "$SB/bin/date" \
           "$SB/bin/markdownlint-cli2"

  # A setup function may point these elsewhere. The domains file does not
  # exist, which the lint reads as "no domains". SB_APP_VAULT is the vault
  # the stubbed app claims to have open.
  SB_LINT="$LINT"
  SB_DOMAINS="$SB/domains.json"
  SB_APP_VAULT="$SB/vault"
}

# run <week> <unresolved-links> [setup]: captures OUT and RC. The setup
# function runs once the sandbox exists, to add notes or set SB_LINT,
# SB_DOMAINS and SB_APP_VAULT.
run() {
  make_sandbox
  [ -n "${3:-}" ] && "$3"
  OUT=$(STUB_PATH="$SB/bin" \
        REAL_DATE="$REAL_DATE" \
        VAULT_CHECK_BASELINE="$SB/vault-check.baseline" \
        VAULT_DIR="$SB/vault" \
        STUB_VAULT="$SB_APP_VAULT" \
        STUB_WEEK="$1" \
        STUB_UNRESOLVED="$2" \
        AI_MEMORY_LINT="$SB_LINT" \
        AI_MEMORY_MDLINT="$SB/bin/markdownlint-cli2" \
        AI_MEMORY_DOMAINS="$SB_DOMAINS" \
        "$BASH_BIN" "$SCRIPT" 2>&1)
  RC=$?
  rm -rf "$SB"
}

# --- setups for the AI memory lint -----------------------------------------

# A memory note that breaks nothing but the hard cap: valid frontmatter, one
# kind tag, an H1, and a body of about 8 KB.
oversized_note() {
  mkdir -p "$SB/vault/AI/memory"
  {
    printf -- '---\ntype: memory\nstatus: active\ndomain: [vault]\n'
    printf 'updated: 2026-10-17\ndescription: A note grown past the hard cap\n'
    printf 'tags: [reference]\n---\n\n# Oversized\n\n'
    for _ in $(seq 100); do
      printf 'Filler for the size test, repeated until the note is past six kilobytes.\n'
    done
  } > "$SB/vault/AI/memory/Oversized.md"
}

# A domains file the lint rejects whenever it runs, notes or not, so its
# ERROR shows whether the lint ran at all.
broken_domains() {
  printf 'not json\n' > "$SB_DOMAINS"
}

empty_ai_folder() { broken_domains; mkdir -p "$SB/vault/AI"; }

# The app has another vault open, so vault-check skips every graph check.
oversized_note_app_elsewhere() { oversized_note; SB_APP_VAULT="$SB/other"; }

crashing_lint() {
  mkdir -p "$SB/vault/AI"
  SB_LINT="$SB/crash.py"
  printf 'raise RuntimeError("stub lint crashed")\n' > "$SB_LINT"
}

missing_lint() {
  mkdir -p "$SB/vault/AI"
  SB_LINT="$SB/nowhere/lint.py"
}

# --- setups for the AI/specs and AI/plans exemption ------------------------

# A note that quotes both forbidden forms once, the way a plan does: a
# path-qualified wikilink and a Markdown link to a note.
forbidden_forms() {
  mkdir -p "$SB/vault/${1%/*}"
  printf '# Example\n\nwrite [[notes/Two]] bare, never [Two](Two.md)\n' > "$SB/vault/$1"
}

forms_in_specs_and_plans() {
  forbidden_forms AI/specs/x.md
  forbidden_forms AI/plans/y.md
}
forms_in_notes()        { forbidden_forms notes/x.md; }
forms_in_nested_specs() { forbidden_forms notes/AI/specs/x.md; }
forms_in_specsheet()    { forbidden_forms AI/specsheet.md; }

# A plan named like an ordinary note: the exemption must not reach the
# duplicate-basename check.
plan_shares_a_basename() {
  mkdir -p "$SB/vault/AI/plans"
  printf '# One\n\nA plan that happens to share a name.\n' > "$SB/vault/AI/plans/One.md"
}

# An empty note that one link points at, from a plan or from an ordinary note.
stub_linked_from() {
  : > "$SB/vault/Stub.md"
  mkdir -p "$SB/vault/${1%/*}"
  printf '# Example\n\nsee [[Stub]]\n' > "$SB/vault/$1"
}
stub_linked_from_plan() { stub_linked_from AI/plans/y.md; }
stub_linked_from_note() { stub_linked_from notes/x.md; }

has()    { printf '%s\n' "$OUT" | grep -q -- "$1"; }
has_not() { ! has "$1"; }

# --- cases -----------------------------------------------------------------

CASE="the current week is accepted in silence"
run 2026-W33 "2026-W33"
if   [ "$RC" -ne 0 ];        then bad "expected exit 0, got $RC"
elif has ERROR;              then bad "the running week must not gate the vault"
elif has WARN;               then bad "the running week is expected, so it must not even warn"
elif has_not "current week"; then bad "the INFO line should say the link was accepted by pattern"
else ok "$CASE"; fi

CASE="a past week warns instead of gating"
run 2026-W34 "2026-W33"
if   [ "$RC" -ne 0 ];   then bad "expected exit 0, got $RC"
elif has ERROR;         then bad "an unharvested week must not red-gate the vault"
elif has_not WARN;      then bad "expected a WARN naming the missing week"
elif has_not "2026-W33"; then bad "the WARN has to name the week"
else ok "$CASE"; fi

CASE="a long-gone week stays visible"
run 2026-W33 "2026-W20"
if   [ "$RC" -ne 0 ]; then bad "expected exit 0, got $RC"
elif has_not WARN;    then bad "a week note that vanished must still be reported"
else ok "$CASE"; fi

CASE="an unrelated dangling link still gates"
run 2026-W33 "Some Note"
if   [ "$RC" -ne 1 ]; then bad "expected exit 1, got $RC"
elif has_not ERROR;   then bad "the pattern rule must not swallow ordinary dangling links"
else ok "$CASE"; fi

CASE="the baseline still wins over the pattern"
run 2026-W33 "2026-W29"
if   [ "$RC" -ne 0 ]; then bad "expected exit 0, got $RC"
elif has ERROR;       then bad "2026-W29 is accepted in the baseline"
elif has WARN;        then bad "a baseline entry is a decision already made, so it must be silent"
else ok "$CASE"; fi

CASE="a week and a real dangler in the same run"
run 2026-W33 "$(printf '2026-W33\nSome Note')"
if   [ "$RC" -ne 1 ];          then bad "expected exit 1, got $RC"
elif has_not "not in baseline: Some Note"; then bad "the dangling link has to be named"
elif has "not in baseline: 2026-W33";      then bad "the running week must not be reported as an error"
else ok "$CASE"; fi

CASE="a week written ahead warns rather than gates"
run 2026-W33 "2026-W34"
if   [ "$RC" -ne 0 ]; then bad "a daily note created ahead of the week must not gate, got $RC"
elif has_not WARN;    then bad "expected a WARN, since the note is genuinely not there yet"
else ok "$CASE"; fi

CASE="a lookalike is not a week"
run 2026-W33 "2026-Week33"
if   [ "$RC" -ne 1 ]; then bad "expected exit 1, got $RC"
elif has_not ERROR;   then bad "only YYYY-Www is the weekly-note pattern"
else ok "$CASE"; fi

CASE="a memory note over the hard cap gates the vault"
run 2026-W33 "" oversized_note
if   [ "$RC" -ne 1 ];        then bad "expected exit 1, got $RC"
elif has_not "over 6 KB";    then bad "the lint's size ERROR has to be printed"
elif has_not "^ERROR  *AI/memory/Oversized.md: "; then bad "the finding needs vault-check's ERROR prefix and the note's path"
elif has_not "^SUMMARY 1 error(s)"; then bad "the one lint ERROR has to count once, and nothing else may fire"
else ok "$CASE"; fi

CASE="the lint gates even when the app has another vault open"
run 2026-W33 "" oversized_note_app_elsewhere
if   [ "$RC" -ne 1 ];        then bad "the lint reads files only, so it must not ride on the CLI, got $RC"
elif has_not "graph checks"; then bad "the CLI branch has to be skipped, or this case proves nothing"
elif has_not "over 6 KB";    then bad "the lint's size ERROR has to be printed"
else ok "$CASE"; fi

CASE="without an AI folder the lint stays silent"
run 2026-W33 "" broken_domains
if   [ "$RC" -ne 0 ];        then bad "expected exit 0, got $RC"
elif has "domains.json";     then bad "the lint ran, although the vault has no AI folder"
elif has ERROR;              then bad "nothing in this vault is broken"
elif has WARN;               then bad "nothing in this vault is worth a look"
else ok "$CASE"; fi

# The control for the case above: the same broken domains file, and the lint
# speaks as soon as AI/ exists. Without it, silence would prove nothing.
CASE="an AI folder runs the lint even before it holds notes"
run 2026-W33 "" empty_ai_folder
if   [ "$RC" -ne 1 ];        then bad "expected exit 1, got $RC"
elif has_not "^ERROR  *domains.json: "; then bad "the lint's domains ERROR has to be printed"
else ok "$CASE"; fi

CASE="a lint that crashes gates the vault"
run 2026-W33 "" crashing_lint
if   [ "$RC" -ne 1 ];        then bad "expected exit 1, got $RC"
elif has_not "^ERROR  *AI memory lint failed (exit 1)"; then bad "a crash must not read as a clean AI folder"
elif has_not "stub lint crashed"; then bad "the end of the traceback has to be shown"
else ok "$CASE"; fi

CASE="a missing lint warns when there is an AI folder"
run 2026-W33 "" missing_lint
if   [ "$RC" -ne 0 ];        then bad "an absent skill is an environment problem, not a vault defect, got $RC"
elif has_not "^WARN  *AI memory lint not found"; then bad "the skipped lint has to be named"
else ok "$CASE"; fi

# --- the AI/specs and AI/plans exemption -----------------------------------

CASE="a spec or a plan may quote the forbidden forms"
run 2026-W33 "" forms_in_specs_and_plans
if   [ "$RC" -ne 0 ]; then bad "expected exit 0, got $RC"
elif has ERROR;       then bad "a dated record quoting an example must not gate the vault"
elif has WARN;        then bad "nothing else in this vault is worth a look"
else ok "$CASE"; fi

# The control for the case above: the same note outside the two folders. It
# proves that both checks scan the fixture, so the silence above is earned.
CASE="the same forms in an ordinary note still gate"
run 2026-W33 "" forms_in_notes
if   [ "$RC" -ne 1 ]; then bad "expected exit 1, got $RC"
elif has_not "^ERROR  *path-qualified wikilinks: 1 "; then bad "the path-qualified link has to be reported"
elif has_not "^ERROR  *legacy markdown links to .md: 1 "; then bad "the Markdown link has to be reported"
else ok "$CASE"; fi

CASE="AI/specs deeper in the tree is not exempt"
run 2026-W33 "" forms_in_nested_specs
if   [ "$RC" -ne 1 ]; then bad "notes/AI/specs/ is not the vault's AI/specs/, got $RC"
elif has_not "^ERROR  *path-qualified wikilinks: 1 "; then bad "the path-qualified link has to be reported"
elif has_not "^ERROR  *legacy markdown links to .md: 1 "; then bad "the Markdown link has to be reported"
else ok "$CASE"; fi

CASE="a name that only starts like AI/specs is not exempt"
run 2026-W33 "" forms_in_specsheet
if   [ "$RC" -ne 1 ]; then bad "AI/specsheet.md is not inside AI/specs/, got $RC"
elif has_not "^ERROR  *path-qualified wikilinks: 1 "; then bad "the path-qualified link has to be reported"
elif has_not "^ERROR  *legacy markdown links to .md: 1 "; then bad "the Markdown link has to be reported"
else ok "$CASE"; fi

CASE="a plan still counts for duplicate basenames"
run 2026-W33 "" plan_shares_a_basename
if   [ "$RC" -ne 1 ]; then bad "expected exit 1, got $RC"
elif has_not "^ERROR  *duplicate basename: One.md"; then bad "a bare link to One is ambiguous whatever folder the second note is in"
else ok "$CASE"; fi

CASE="an unresolved link from a spec or a plan does not gate"
run 2026-W33 "$(printf 'Placeholder\t2\tAI/plans/y.md, AI/specs/2026-10-17-design.md')"
if   [ "$RC" -ne 0 ]; then bad "expected exit 0, got $RC"
elif has ERROR;       then bad "a placeholder link in a dated record must not gate the vault"
elif has WARN;        then bad "a skipped link is not worth a look"
elif has_not "1 only from AI/specs or AI/plans"; then bad "the INFO line has to count the skipped link"
else ok "$CASE"; fi

CASE="an unresolved link from an ordinary note still gates, whatever its name"
run 2026-W33 "$(printf 'AI/plans/Missing Plan\t1\tnotes/x.md')"
if   [ "$RC" -ne 1 ]; then bad "expected exit 1, got $RC"
elif has_not "not in baseline: AI/plans/Missing Plan"; then bad "the exemption goes by the source, never by the target"
else ok "$CASE"; fi

CASE="one ordinary source is enough to gate"
run 2026-W33 "$(printf 'Shared\t2\tAI/plans/y.md, notes/x.md')"
if   [ "$RC" -ne 1 ]; then bad "expected exit 1, got $RC"
elif has_not "not in baseline: Shared"; then bad "a link from notes/x.md counts, even when a plan links it too"
else ok "$CASE"; fi

CASE="a source that only looks like AI/specs still gates"
run 2026-W33 "$(printf 'Nested\t1\tnotes/AI/specs/x.md\nSheet\t1\tAI/specsheet.md')"
if   [ "$RC" -ne 1 ]; then bad "expected exit 1, got $RC"
elif has_not "not in baseline: Nested"; then bad "notes/AI/specs/ is not the vault's AI/specs/"
elif has_not "not in baseline: Sheet";  then bad "AI/specsheet.md is not inside AI/specs/"
else ok "$CASE"; fi

# The split falls after ".md", so a source with another extension stays glued
# to the next one and the piece starts with the exempt folder.
CASE="a non-.md source in a plan cannot hide an ordinary one"
run 2026-W33 "$(printf 'Glued\t2\tAI/plans/board.canvas, notes/real.md')"
if   [ "$RC" -ne 1 ]; then bad "expected exit 1, got $RC"
elif has_not "not in baseline: Glued"; then bad "the link from notes/real.md has to be checked"
else ok "$CASE"; fi

# The real CLI exits 0 on an error, so the exit-code WARN never fires and this
# line is the only trace of a list that was never read.
CASE="a CLI error line in place of the list still gates"
run 2026-W33 "raw:Error: Vault not found."
if   [ "$RC" -ne 1 ]; then bad "an unread list must not pass for a clean one, got $RC"
elif has_not "^ERROR  *unresolved link not in baseline: Error: Vault not found"; then bad "the CLI's error has to be shown as an ERROR"
else ok "$CASE"; fi

# A plan quotes a link to show its shape, not because the stub is wanted.
CASE="a link from a plan does not make a stub wanted"
run 2026-W33 "" stub_linked_from_plan
if   [ "$RC" -ne 0 ]; then bad "expected exit 0, got $RC"
elif has "stub note with inbound links"; then bad "only a link from a plan points at Stub.md"
else ok "$CASE"; fi

# The control: the same link from an ordinary note still warns.
CASE="a link from an ordinary note still flags a stub"
run 2026-W33 "" stub_linked_from_note
if   has_not "^WARN  *stub note with inbound links: ./Stub.md"; then bad "the stub has to be reported"
else ok "$CASE"; fi

# --- where the vault and the baseline come from -----------------------------
# Nothing is built in: VAULT_DIR, else the skill value vault.root; and
# VAULT_CHECK_BASELINE, else ravnix/vault-check.baseline under
# XDG_CONFIG_HOME (or ~/.config). bare runs the script with only the variables
# it is given; @SB@ in an argument stands for the sandbox.
bare() {
  make_sandbox
  mkdir -p "$SB/xdg/ravnix" "$SB/home"
  printf '{"vault":{"root":"%s"}}\n' "$SB/vault" > "$SB/skill-values.json"
  printf '{"vault":{"root":"%s"}}\n' "$SB/nowhere" > "$SB/dead-values.json"
  cp "$SB/skill-values.json" "$SB/xdg/ravnix/skill-values.json"
  cp "$SB/vault-check.baseline" "$SB/xdg/ravnix/vault-check.baseline"
  OUT=$(env -i PATH="$SB/bin" STUB_PATH="$SB/bin" REAL_DATE="$REAL_DATE" HOME="$SB/home" \
        STUB_VAULT="$SB/vault" STUB_WEEK=2026-W33 STUB_UNRESOLVED="" \
        VAULT_CHECK_BASELINE="$SB/vault-check.baseline" \
        "${@//@SB@/$SB}" "$BASH_BIN" "$SCRIPT" 2>&1)
  RC=$?
  rm -rf "$SB"
}

CASE="VAULT_DIR names the vault"
bare VAULT_DIR=@SB@/vault
if   [ "$RC" -ne 0 ];          then bad "expected exit 0, got $RC"
elif has_not "^SUMMARY 0 error"; then bad "the run has to reach the end"
else ok "$CASE"; fi

CASE="without VAULT_DIR the skill value vault.root names it"
bare RAVNIX_SKILL_VALUES=@SB@/skill-values.json
if   [ "$RC" -ne 0 ];          then bad "expected exit 0, got $RC"
elif has_not "^SUMMARY 0 error"; then bad "the run has to reach the end"
else ok "$CASE"; fi

CASE="VAULT_DIR wins over the skill value"
bare VAULT_DIR=@SB@/vault RAVNIX_SKILL_VALUES=@SB@/dead-values.json
if   [ "$RC" -ne 0 ];          then bad "expected exit 0, got $RC"
elif has "no vault at";        then bad "the skill value was used although VAULT_DIR was set"
else ok "$CASE"; fi

CASE="without RAVNIX_SKILL_VALUES the file under XDG_CONFIG_HOME is read"
bare XDG_CONFIG_HOME=@SB@/xdg
if   [ "$RC" -ne 0 ];          then bad "expected exit 0, got $RC"
elif has_not "^SUMMARY 0 error"; then bad "the run has to reach the end"
else ok "$CASE"; fi

CASE="no vault is set anywhere: exit 2, and both settings are named"
bare
if   [ "$RC" -ne 2 ];          then bad "expected exit 2, got $RC"
elif has_not "VAULT_DIR";      then bad "the message has to name VAULT_DIR"
elif has_not "vault.root";     then bad "the message has to name the skill value"
else ok "$CASE"; fi

CASE="a skill value that is no vault path is no vault"
bare RAVNIX_SKILL_VALUES=@SB@/dead-values.json
if   [ "$RC" -ne 2 ];          then bad "expected exit 2, got $RC"
elif has_not "no vault at";    then bad "the missing directory has to be named"
else ok "$CASE"; fi

CASE="a VAULT_DIR that does not exist: exit 2"
bare VAULT_DIR=@SB@/nowhere
if   [ "$RC" -ne 2 ];          then bad "expected exit 2, got $RC"
elif has_not "no vault at";    then bad "the missing directory has to be named"
else ok "$CASE"; fi

CASE="without VAULT_CHECK_BASELINE the baseline under XDG_CONFIG_HOME is read"
bare VAULT_DIR=@SB@/vault VAULT_CHECK_BASELINE= XDG_CONFIG_HOME=@SB@/xdg
if   has "baseline missing"; then bad "the baseline in XDG_CONFIG_HOME was not found"
elif [ "$RC" -ne 0 ];        then bad "expected exit 0, got $RC"
else ok "$CASE"; fi

CASE="with no baseline anywhere the WARN names the path that was looked at"
bare VAULT_DIR=@SB@/vault VAULT_CHECK_BASELINE= XDG_CONFIG_HOME=@SB@/nowhere
if   has_not "^WARN  *baseline missing: .*/nowhere/ravnix/vault-check.baseline"; then bad "the missing baseline has to be named with its path"
else ok "$CASE"; fi

# --- summary ---------------------------------------------------------------
echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
