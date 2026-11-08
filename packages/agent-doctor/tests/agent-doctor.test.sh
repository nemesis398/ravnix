#!/usr/bin/env bash
# Tests for agent-doctor (packages/agent-doctor), run by the check
# bin-agent-doctor. The script has no tests in Fedora; these are new. They build
# a small corpus (a vault with its roles, a skills directory, a norms document)
# and look at what the four checks report: DUPLICATE, DEADPATH, LINECOUNT, and
# the exit code and summary around them. The AGREEMENT check watches nothing
# since 2026-10-03 and has no case.
#
# AGENT_DOCTOR_UNDER_TEST=<file> tests another copy; by default it is the
# agent-doctor on the PATH.

# The checks are eval'd, so their $ expand at check time.
# shellcheck disable=SC2016

set -uo pipefail

SUT=$(readlink -f "${AGENT_DOCTOR_UNDER_TEST:-$(type -P agent-doctor)}")
SB=$(mktemp -d "${TMPDIR:-/tmp}/agent-doctor-test.XXXXXX")
trap 'rm -r -- "$SB"' EXIT

pass=0 fail=0
ok()  { printf '  \e[32m✓\e[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \e[31m✗\e[0m %s\n%s\n' "$1" "$2"; fail=$((fail + 1)); }

HOME_DIR="$SB/home"
mkdir -p "$HOME_DIR/.claude/skills"

# run [ENV=VAL ...] -- ARGS: sets $out (stdout), $err, $rc. The environment is
# empty but the home directory and the PATH; the case adds what it needs.
run() {
    local envs=()
    while [[ $1 != -- ]]; do envs+=("$1"); shift; done
    shift
    out=$(env -i HOME="$HOME_DIR" PATH="$PATH" "${envs[@]}" "$SUT" "$@" 2>"$SB/err")
    rc=$?
    err=$(<"$SB/err")
}
check() { if eval "$2"; then ok "$1"; else bad "$1" "    rc: $rc
    out: ${out:0:900}
    err: $err"; fi; }

# vault NAME: the files every vault of the cases has; the case adds its own.
vault() {
    local v="$SB/$1"
    mkdir -p "$v/.agents"
    printf 'Vault rules\nline 2\nline 3\nline 4\nline 5\n' >"$v/Vault.md"
    printf '%s' "$v"
}

echo "agent-doctor"

# ── a clean corpus ─────────────────────────────────────────────────────────
C=$(vault clean)
printf 'Always loaded.\nNever mv a note, see Vault.md.\n' >"$C/AGENTS.md"
printf 'A role.\nNever mv a note.\nRead `Vault.md` and `./Vault.md` and `.agents/ROLE.md`.\n' >"$C/.agents/SCRIBE.md"
run VAULT_DIR="$C" --
check "a corpus without drift exits 0 and says how many files it looked at" \
    '[[ $rc == 0 && $out == "SUMMARY 0 finding(s) across 3 instruction file(s)" ]]'
run VAULT_DIR="$C" -- --quiet
check "--quiet has no summary when there is nothing to say" '[[ $rc == 0 && -z $out ]]'

# ── DUPLICATE ──────────────────────────────────────────────────────────────
D=$(vault dup)
printf 'Wikilinks are bare.\n' >"$D/CLAUDE.md"
run VAULT_DIR="$D" --
check "a rule restated away from its home without a pointer is a DUPLICATE, at its line" \
    '[[ $rc == 1 && $out == "DUPLICATE $D/CLAUDE.md:1"* && $out == *"restates '\''bare-wikilinks-only'\'' without pointing at $D/Vault.md"* && $out == *"SUMMARY 1 finding(s) across 2 instruction file(s)"* ]]'
run VAULT_DIR="$D" -- --quiet
check "--quiet prints the findings and no summary, and the exit code stays 1" \
    '[[ $rc == 1 && $out == DUPLICATE* && $out != *SUMMARY* ]]'
printf 'Wikilinks are bare, see [[Vault]] for the rule.\n' >"$D/CLAUDE.md"
run VAULT_DIR="$D" --
check "the same sentence with a pointer to the home is no finding" '[[ $rc == 0 ]]'
printf 'Intro.\n\n```\nWikilinks are bare.\n```\n' >"$D/CLAUDE.md"
run VAULT_DIR="$D" --
check "a statement inside a code fence is usage, not a restatement" '[[ $rc == 0 ]]'
printf 'Wikilinks are bare.\n' >"$D/.agents/SCRIBE.md"
printf 'x\n' >"$D/CLAUDE.md"
run VAULT_DIR="$D" --
check "a rule marked for replication may stand in a role file; this one is not, so it is a finding there" \
    '[[ $rc == 1 && $out == "DUPLICATE $D/.agents/SCRIBE.md:1"* ]]'
printf 'Never mv a note.\n' >"$D/CLAUDE.md"
run VAULT_DIR="$D" --
check "a rule replicated in roles on purpose is not a finding in a role, but is outside one" \
    '[[ $rc == 1 && $out == "DUPLICATE $D/CLAUDE.md:1"* && $out == *"never-mv-a-note"* ]]'

# ── DEADPATH ───────────────────────────────────────────────────────────────
P=$(vault dead)
printf 'Read `.agents/GONE.md`, `.agents/ROLE.md`, `.excalidraw.md` and `Vault.md`.\nAnd `./Vault.md` and `/nonexistent/abs.md`.\n' >"$P/.agents/SCRIBE.md"
run VAULT_DIR="$P" --
check "a cited path that is not there is a DEADPATH at its line" \
    '[[ $rc == 1 && $out == *"DEADPATH  $P/.agents/SCRIBE.md:1"*"cites \`.agents/GONE.md\`, which is not there"* ]]'
check "the role placeholder, a file-kind suffix and paths that exist are not cited as dead" \
    '[[ $out != *"ROLE.md\`, which"* && $out != *"excalidraw"* && $out != *"cites \`Vault.md\`"* && $out != *"cites \`./Vault.md\`"* ]]'
check "an absolute path that is not there is dead too" '[[ $out == *"cites \`/nonexistent/abs.md\`"* ]]'
printf 'See `~/gone-in-home.md`.\n' >"$P/.agents/SCRIBE.md"
run VAULT_DIR="$P" --
check "a path under the home directory is shown with a ~ in the report" \
    '[[ $out == *"DEADPATH  ~"* || $out == *"cites \`~/gone-in-home.md\`"* ]]'
mkdir -p "$P/sub"
printf 'x\n' >"$P/sub/exists.md"
printf 'See `./sub/exists.md` and `.agents/SCRIBE.md`.\n' >"$P/.agents/SCRIBE.md"
run VAULT_DIR="$P" --
check "a path relative to the vault root, spelled with or without ./, counts as there" '[[ $rc == 0 ]]'

# ── LINECOUNT ──────────────────────────────────────────────────────────────
L=$(vault lines)
printf 'See `Vault.md`, 12 lines.\n' >"$L/.agents/SCRIBE.md"
run VAULT_DIR="$L" --
check "a claimed line count that no longer matches is a LINECOUNT with both numbers" \
    '[[ $rc == 1 && $out == *"LINECOUNT $L/.agents/SCRIBE.md:1"*"claims Vault.md is 12 lines; it is 5"* ]]'
printf 'See `Vault.md` (5 lines).\n' >"$L/.agents/SCRIBE.md"
run VAULT_DIR="$L" --
check "a claim that is right is no finding" '[[ $rc == 0 ]]'
printf 'See `nothing-by-that-name.md`, 40 lines.\n' >"$L/.agents/SCRIBE.md"
run VAULT_DIR="$L" --
check "a claim about a file that does not exist is not a LINECOUNT" '[[ $out != *LINECOUNT* ]]'

# ── the corpus ─────────────────────────────────────────────────────────────
S=$(vault skills)
mkdir -p "$SB/skills/prose" "$SB/skills/other"
printf 'Wikilinks are bare.\n' >"$SB/skills/other/SKILL.md"
printf 'The house style.\n' >"$SB/skills/prose/SKILL.md"
run VAULT_DIR="$S" -- 
check "without AGENT_DOCTOR_SKILLS the skills are ~/.claude/skills, which is empty here" \
    '[[ $rc == 0 && $out == "SUMMARY 0 finding(s) across 1 instruction file(s)" ]]'
run VAULT_DIR="$S" AGENT_DOCTOR_SKILLS="$SB/skills" -- 
check "AGENT_DOCTOR_SKILLS names the skills directory, whose SKILL.md files are in the corpus" \
    '[[ $rc == 1 && $out == "DUPLICATE $SB/skills/other/SKILL.md:1"* && $out == *"across 3 instruction file(s)"* ]]'

N=$(vault norms)
printf 'Norms.\nSELinux stays Enforcing.\n' >"$SB/norms.md"
printf 'We say that SELinux stays Enforcing here.\n' >"$N/.agents/SCRIBE.md"
run VAULT_DIR="$N" -- 
check "without a norms document the rules whose home it is are not checked" '[[ $rc == 0 ]]'
run VAULT_DIR="$N" AGENT_DOCTOR_NORMS="$SB/norms.md" -- 
check "with AGENT_DOCTOR_NORMS they are: the norms document is the home and is in the corpus" \
    '[[ $rc == 1 && $out == *"restates '\''selinux-stays-enforcing'\'' without pointing at $SB/norms.md"* && $out == *"across 3 instruction file(s)"* ]]'
run VAULT_DIR="$N" AGENT_DOCTOR_NORMS="$SB/missing-norms.md" -- 
check "a norms path that is no file is left out of the corpus without a crash; its rules still name it" \
    '[[ $rc == 1 && -z $err && $out == *"across 2 instruction file(s)"* && $out == *"pointing at $SB/missing-norms.md"* ]]'

B=$(vault binary)
printf '\xff\xfe not utf-8 \x80\n' >"$B/.agents/BAD.md"
run VAULT_DIR="$B" -- 
check "a file that is not UTF-8 is skipped by every check, not a crash" \
    '[[ $rc == 0 && $out == *"across 2 instruction file(s)"* && -z $err ]]'

M=$(vault many)
for i in $(seq 1 300); do
    printf 'Role %d.\n\nSome ordinary prose that says nothing about rules.\n- a bullet\n- another one\n' "$i" >"$M/.agents/R$i.md"
done
run VAULT_DIR="$M" -- 
check "three hundred role files are read" '[[ $rc == 0 && $out == *"across 301 instruction file(s)"* ]]'

# ── where the vault comes from ─────────────────────────────────────────────
run -- 
check "with no vault at all it says what to set, and exits 2" \
    '[[ $rc == 2 && $err == "agent-doctor: no vault: set VAULT_DIR, or vault.root in ravnix.claude.skillValues" && -z $out ]]'
run -- --rules
check "--rules needs no vault" '[[ $rc == 0 && $out == *"never-mv-a-note"* ]]'
check "--rules lists the rules with their homes, the vault one for the vault rules" \
    '[[ $out == *"home: /nonexistent-vault/Vault.md"* ]]'
check "--rules leaves the norms rules out without a norms document" '[[ $out != *selinux-stays-enforcing* ]]'
run AGENT_DOCTOR_NORMS="$SB/norms.md" -- --rules
check "--rules lists the norms rules when there is a norms document" \
    '[[ $out == *"selinux-stays-enforcing"*"home: $SB/norms.md"* && $out == *daily-note-duty* ]]'
check "a home under the home directory is shown with a ~" '[[ $out == *"no-em-dashes"*"home: ~/.claude/skills/prose/SKILL.md"* ]]'

printf '{"vault":{"root":"%s"}}' "$C" >"$SB/values.json"
run RAVNIX_SKILL_VALUES="$SB/values.json" -- 
check "with no VAULT_DIR the vault is the skill value vault.root, read at run time" \
    '[[ $rc == 0 && $out == *"across 3 instruction file(s)"* ]]'
run RAVNIX_SKILL_VALUES="$SB/values.json" VAULT_DIR="$S" -- 
check "VAULT_DIR beats the skill value" '[[ $rc == 0 && $out == *"across 1 instruction file(s)"* ]]'
mkdir -p "$HOME_DIR/.config/ravnix"
cp "$SB/values.json" "$HOME_DIR/.config/ravnix/skill-values.json"
run -- 
check "the file in ~/.config/ravnix is found when no variable names one" '[[ $rc == 0 && $out == *"across 3 instruction file(s)"* ]]'
run XDG_CONFIG_HOME="$SB/nowhere" -- 
check "XDG_CONFIG_HOME moves where it looks" '[[ $rc == 2 ]]'
printf '{"vault":{"root":' >"$HOME_DIR/.config/ravnix/skill-values.json"
run -- 
check "a skill-values file that is not JSON is the same as none" '[[ $rc == 2 && $err == *"no vault"* ]]'
printf '{"vault":{"root":["x"]}}' >"$HOME_DIR/.config/ravnix/skill-values.json"
run -- 
check "a vault.root of the wrong type is the same as none" '[[ $rc == 2 && $err == *"no vault"* ]]'
rm -- "$HOME_DIR/.config/ravnix/skill-values.json"

run VAULT_DIR="$SB/does-not-exist" -- 
check "a vault that is not there has an empty corpus and no finding" \
    '[[ $rc == 0 && $out == "SUMMARY 0 finding(s) across 0 instruction file(s)" ]]'

run VAULT_DIR="$C" -- --bogus
check "an unknown option exits 2 with the usage" '[[ $rc == 2 && $err == *"usage: agent-doctor"* ]]'
run -- --help
check "--help says what it is" '[[ $rc == 0 && $out == "usage: agent-doctor"* && $out == *"--quiet"* && $out == *"--rules"* ]]'

echo
echo "$pass passed, $fail failed"
[[ $fail == 0 ]]
