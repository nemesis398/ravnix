#!/usr/bin/env bash
# Tests for sap-deck (packages/sap-deck), run by the check bin-sap-deck. The
# script has no tests in Fedora; these are new. They build the deck from a small
# fixture vault and look at the notes in the .apkg it writes, and they feed it
# the vaults it must refuse or warn about: none, no Vault.md, nothing to build,
# a long shortcut, a transaction note without an alias.
#
# SAP_DECK_UNDER_TEST=<file> tests another copy; by default it is the sap-deck
# on the PATH.

# The checks are eval'd, so their $ expand at check time (SC2016), and the
# variables they read are set outside them (SC2034).
# shellcheck disable=SC2016,SC2034

set -uo pipefail

SUT=$(readlink -f "${SAP_DECK_UNDER_TEST:-$(type -P sap-deck)}")
SB=$(mktemp -d "${TMPDIR:-/tmp}/sap-deck-test.XXXXXX")
trap 'rm -r -- "$SB"' EXIT

pass=0 fail=0
ok()  { printf '  \e[32m✓\e[0m %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \e[31m✗\e[0m %s\n%s\n' "$1" "$2"; fail=$((fail + 1)); }

mkdir -p "$SB/home"

# run [ENV=VAL ...] -- ARGS: sets $out (stdout), $err, $rc.
run() {
    local envs=()
    while [[ $1 != -- ]]; do envs+=("$1"); shift; done
    shift
    out=$(env -i HOME="$SB/home" PATH="$PATH" SAP_DECK_DIR="Notes/Tx" SAP_DECK_SHORTCUTS="Notes/Tx/Shortcut table.md" \
        SAP_DECK_OUT="Out/deck.apkg" "${envs[@]}" "$SUT" "$@" 2>"$SB/err")
    rc=$?
    err=$(<"$SB/err")
}
check() { if eval "$2"; then ok "$1"; else bad "$1" "    rc: $rc
    out: ${out:0:600}
    err: ${err:0:900}"; fi; }

# vault NAME: an empty vault with its SAP directory.
vault() {
    local v="$SB/$1"
    mkdir -p "$v/Notes/Tx"
    : >"$v/Vault.md"
    printf '%s' "$v"
}

# notes FILE: the "flds" and tags of every note in a deck, one per line.
notes() {
    python3 -I -c '
import sys, sqlite3, tempfile, zipfile
z = zipfile.ZipFile(sys.argv[1])
d = tempfile.mkdtemp(dir=sys.argv[2])
z.extract("collection.anki2", d)
c = sqlite3.connect(d + "/collection.anki2")
for (f, t) in c.execute("select flds, tags from notes"):
    print(f.replace("\x1f", " | ") + " ## " + t.strip())
' "$1" "$SB"
}

echo "sap-deck"

# ── a good vault ───────────────────────────────────────────────────────────
V=$(vault good)
cat >"$V/Notes/Tx/Shortcut table.md" <<'NOTE'
---
type: note
---

# Shortcuts

## Navigation

| Kürzel | Aktion | Detail |
| --- | --- | --- |
| Strg + s<br>oder<br>F11 | Speichern | Sichert den [[Beleg]] <b>jetzt</b> |
| F3 | Zurück | |

## Fenster::Neu

| Kürzel | Aktion |
| --- | --- |
| Strg+Umschalt+F12 | Beenden |
NOTE
cat >"$V/Notes/Tx/RZ10 – Profilpflege.md" <<'NOTE'
---
type: transaktion
aliases: [Profilparameter pflegen]
description: Pflegt die Profilparameter.
tags: [sap, basis]
---

Pflegt die Profilparameter.

## Stolpersteine

- Ein Neustart ist nötig.
- Ein zweiter Stein.
NOTE
cat >"$V/Notes/Tx/SU01.md" <<'NOTE'
---
type: transaktion
aliases:
  - Benutzer pflegen
description: Benutzerstammsätze
tags:
  - sap
---

**Fett am Anfang zählt nicht zum Lead.**

Etwas ganz anderes als die Beschreibung.
NOTE
cat >"$V/Notes/Tx/Overview.md" <<'NOTE'
---
type: note
---
Not a transaction.
NOTE

run VAULT_DIR="$V" -- 
check "a build writes the deck to the default place and counts Kürzel and Transaktionen" \
    '[[ $rc == 0 && $out == *"3 Kürzel"*"2 Transaktionen"*"10 cards"* && -s "$V/Out/deck.apkg" && $out == *"OK     $V/Out/deck.apkg ("* ]]'
check "each Bereich is a subdeck in the order of the note, transactions have their own" \
    '[[ $out == *"SAP::Kürzel::Navigation  2"* && $out == *"SAP::Kürzel::Fenster Neu  1"* && $out == *"SAP::Transaktionen  2"* ]]'
check "the lead sentence and the description of SU01 have drifted, which is a warning" \
    '[[ $err == *"SU01.md: description and the lead sentence have drifted apart"* && $out == *"1 warning(s)"* ]]'
check "the note that is no transaction is left out" '[[ $err != *Overview* && $(notes "$V/Out/deck.apkg") != *"Not a transaction"* ]]'
n=$(notes "$V/Out/deck.apkg")
check "an alternative key (Strg + s oder F11) becomes the two fields of one note, the plus is spaced" \
    '[[ $n == *"kuerzel:strg + s | Strg + s | F11 | Speichern"* ]]'
check "wikilinks are their text, and the HTML of the cell is escaped" '[[ $n == *"Sichert den Beleg &lt;b&gt;jetzt&lt;/b&gt;"* && $n != *"[["* ]]'
check "the transaction code is the file name up to the first spaced en dash" \
    '[[ $n == *"transaktion:rz10 | RZ10 | Profilparameter pflegen"* && $n == *"transaktion:su01 | SU01 | Benutzer pflegen"* ]]'
check "the first Stolperstein is the warning, the second is not on the card" \
    '[[ $n == *"Ein Neustart ist nötig."* && $n != *"Ein zweiter Stein"* ]]'
check "the block list form of the frontmatter is read as well as the inline one" \
    '[[ $n == *"Benutzer pflegen"* ]]'
check "the Bereich of a transaction is its first tag besides sap, capitalised, else Transaktion" \
    '[[ $n == *"| Basis |"* && $n == *"| Transaktion |"* ]]'
check "notes are tagged for the deck" '[[ $n == *"## SAP Kürzel"* && $n == *"## SAP Transaktion"* ]]'
members=$(python3 -I -m zipfile -l "$V/Out/deck.apkg" 2>&1)
media=$(python3 -I -c '
import json, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
print(" ".join(sorted(json.loads(z.read("media")).values())))
' "$V/Out/deck.apkg" 2>&1)
check "the .apkg is a zip with the collection and the two fonts, the underscore kept" \
    '[[ $members == *collection.anki2* && $media == "_jbmono-bold.woff2 _jbmono-regular.woff2" ]]'

cp "$V/Out/deck.apkg" "$SB/first.apkg"
run VAULT_DIR="$V" -- --out "$SB/elsewhere/deck.apkg"
check "--out puts the deck elsewhere and makes the directory" '[[ $rc == 0 && -s "$SB/elsewhere/deck.apkg" ]]'
guids() {
    python3 -I -c '
import sys, sqlite3, tempfile, zipfile
z = zipfile.ZipFile(sys.argv[1])
d = tempfile.mkdtemp(dir=sys.argv[2])
z.extract("collection.anki2", d)
c = sqlite3.connect(d + "/collection.anki2")
print(",".join(sorted(r[0] for r in c.execute("select guid from notes"))))
' "$1" "$SB"
}
check "the note GUIDs come from the keys alone, so a second build is a re-import" \
    '[[ -n "$(guids "$SB/first.apkg")" && "$(guids "$SB/first.apkg")" == "$(guids "$SB/elsewhere/deck.apkg")" ]]'

# An edited description keeps the GUID.
sed -i 's/Speichern/Sichern/' "$V/Notes/Tx/Shortcut table.md"
run VAULT_DIR="$V" -- --out "$SB/edited.apkg"
check "fixing a description keeps the GUID, which is what keeps the review history" \
    '[[ "$(guids "$SB/edited.apkg")" == "$(guids "$SB/first.apkg")" && "$(notes "$SB/edited.apkg")" == *Sichern* ]]'

# ── the skill value is the vault ───────────────────────────────────────────
printf '{"vault":{"root":"%s"}}' "$V" >"$SB/values.json"
run RAVNIX_SKILL_VALUES="$SB/values.json" -- --out "$SB/viaskill.apkg"
check "with no VAULT_DIR the vault is the skill value vault.root, read at run time" \
    '[[ $rc == 0 && -s "$SB/viaskill.apkg" ]]'
run RAVNIX_SKILL_VALUES="$SB/values.json" VAULT_DIR="$SB/nope" -- 
check "VAULT_DIR beats the skill value" '[[ $rc == 1 && $err == *"no vault at $SB/nope"* ]]'
run XDG_CONFIG_HOME="$SB/xdg" -- 
check "without either, and without the file, it says what to set" \
    '[[ $rc == 1 && $err == *"sap-deck: no vault: set VAULT_DIR, pass --vault, or set vault.root in ravnix.claude.skillValues"* ]]'
mkdir -p "$SB/xdg/ravnix"
printf '{"vault":{"root":"%s"}}' "$V" >"$SB/xdg/ravnix/skill-values.json"
run XDG_CONFIG_HOME="$SB/xdg" -- --out "$SB/viaxdg.apkg"
check "the file in the user's config is found when no variable names one" '[[ $rc == 0 && -s "$SB/viaxdg.apkg" ]]'
printf 'not json' >"$SB/xdg/ravnix/skill-values.json"
run XDG_CONFIG_HOME="$SB/xdg" -- 
check "a skill-values file that is not JSON is the same as none" '[[ $rc == 1 && $err == *"no vault: set VAULT_DIR"* ]]'
printf '{"vault":["x"]}' >"$SB/xdg/ravnix/skill-values.json"
run XDG_CONFIG_HOME="$SB/xdg" -- 
check "a vault entry of the wrong shape is the same as none" '[[ $rc == 1 && $err == *"no vault: set VAULT_DIR"* ]]'

# ── where things are is the user's ────────────────────────────────────────
run VAULT_DIR="$V" SAP_DECK_DIR= -- 
check "without the notes folder it says what to set and writes nothing" \
    '[[ $rc == 1 && $err == *"sap-deck: not set: SAP_DECK_DIR"* && $err == *"ravnix.scripts.sapDeck"* ]]'
run VAULT_DIR="$V" SAP_DECK_OUT= -- 
check "without the deck file it says what to set" '[[ $rc == 1 && $err == *"sap-deck: not set: SAP_DECK_OUT"* ]]'
run VAULT_DIR="$V" SAP_DECK_OUT= -- --out "$SB/given.apkg"
check "--out stands in for the deck file" '[[ $rc == 0 && -s "$SB/given.apkg" ]]'
run VAULT_DIR="$V" SAP_DECK_DIR= SAP_DECK_OUT= -- 
check "both missing are both named" '[[ $err == *"not set: SAP_DECK_DIR, SAP_DECK_OUT"* ]]'
run VAULT_DIR="$V" SAP_DECK_SHORTCUTS= -- --out "$SB/noshort.apkg"
check "without a shortcuts note there are no shortcut cards, and nothing is said about it" \
    '[[ $rc == 0 && $out == *"0 Kürzel"*"2 Transaktionen"* && $err != *"no shortcut cards"* ]]'
run VAULT_DIR="$V" SAP_DECK_DIR="Elsewhere" -- --out "$SB/elsewhere.apkg"
check "the notes folder is the one named: another folder has no transactions, the shortcuts note still counts" \
    '[[ $rc == 0 && $out == *"3 Kürzel"*"0 Transaktionen"* ]]'

# ── what it refuses ────────────────────────────────────────────────────────
mkdir -p "$SB/not-a-vault"
run VAULT_DIR="$SB/not-a-vault" -- 
check "a directory without Vault.md is no vault" '[[ $rc == 1 && $err == *"no vault at $SB/not-a-vault"* ]]'
run VAULT_DIR="$SB/missing" -- 
check "a path that does not exist is no vault" '[[ $rc == 1 && $err == *"no vault at $SB/missing"* ]]'
run VAULT_DIR="" -- 
check "an empty VAULT_DIR is no vault" '[[ $rc == 1 && $err == *"no vault: set VAULT_DIR"* ]]'

E=$(vault empty)
run VAULT_DIR="$E" -- 
check "a vault with no shortcut note and no transaction has nothing to build" \
    '[[ $rc == 1 && $err == *"missing Notes/Tx/Shortcut table.md, no shortcut cards"* && $err == *"sap-deck: nothing to build"* && ! -e "$E/Out/deck.apkg" ]]'

# A vault with no SAP directory at all.
mkdir -p "$SB/nosap"
: >"$SB/nosap/Vault.md"
run VAULT_DIR="$SB/nosap" -- 
check "a vault with no SAP directory fails with an error and not a traceback" \
    '[[ $rc != 0 ]]'

T=$(vault noalias)
printf -- '---\ntype: transaktion\ndescription: x\n---\nx\n' >"$T/Notes/Tx/RZ11.md"
printf -- '---\ntype: transaktion\naliases: [Ok]\ntags: [sap]\n---\nLead.\n' >"$T/Notes/Tx/SM50.md"
run VAULT_DIR="$T" -- --out "$SB/noalias.apkg"
check "a transaction with no alias is skipped with a warning, one with no description warns" \
    '[[ $rc == 0 && $err == *"RZ11.md: no alias, skipped (the alias is the answer)"* && $err == *"SM50.md: no description, so it shows blank in the base that lists the transactions"* && $out == *"1 Transaktionen"* ]]'
check "without a base set, the warning names no file of the vault" '[[ $err != *".base"* ]]'
run VAULT_DIR="$T" SAP_DECK_BASE="Notes/Tx/Listing.base" -- --out "$SB/noalias2.apkg"
check "with SAP_DECK_BASE set, the warning names that base" \
    '[[ $rc == 0 && $err == *"SM50.md: no description, so it shows blank in Notes/Tx/Listing.base"* ]]'

L=$(vault long)
printf '## Bereich\n\n| K | A |\n| --- | --- |\n| Strg + Umschalt + Alt + F12 + X | Zu lang |\n| | leer |\n| nur | |\n' >"$L/Notes/Tx/Shortcut table.md"
run VAULT_DIR="$L" -- --out "$SB/long.apkg"
check "a key past 24 characters warns that it will overflow a phone, a row with an empty cell is dropped" \
    '[[ $rc == 0 && $err == *"chars, it will overflow a phone"* && $out == *"1 Kürzel"* ]]'

I=$(vault ident)
printf '## Bereich\n\n| K | A | D |\n| --- | --- | --- |\n| `S_TABU_DIS` | &SAP_EDIT <b>x</b> | a_b_c |\n' >"$I/Notes/Tx/Shortcut table.md"
run VAULT_DIR="$I" -- --out "$SB/ident.apkg"
ni=$(notes "$SB/ident.apkg")
check "identifiers keep their underscores, and HTML is escaped" \
    '[[ $ni == *"S_TABU_DIS"* && $ni == *"&amp;SAP_EDIT &lt;b&gt;x&lt;/b&gt;"* && $ni == *"a_b_c"* ]]'

H=$(vault many)
{
    printf '## Bereich\n\n| K | A |\n| --- | --- |\n'
    for i in $(seq 1 500); do printf '| K%d | Aktion %d |\n' "$i" "$i"; done
} >"$H/Notes/Tx/Shortcut table.md"
run VAULT_DIR="$H" -- --out "$SB/many.apkg"
check "five hundred shortcuts build into one thousand cards" '[[ $rc == 0 && $out == *"500 Kürzel"*"1000 cards"* ]]'

run -- --bogus
check "an unknown option exits 2 with the usage" '[[ $rc == 2 && $err == *"usage: sap-deck"* ]]'
run -- --help
check "--help describes the options and names the vault variable" \
    '[[ $rc == 0 && $out == *"usage: sap-deck"* && $out == *"--vault"* && $out == *"VAULT_DIR"* ]]'

echo
echo "$pass passed, $fail failed"
[[ $fail == 0 ]]
