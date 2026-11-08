#!/usr/bin/env bash
# Tests for ccna-deck (packages/ccna-deck), run by the check bin-ccna-deck. The
# script has no tests in Fedora; these are new. They build decks from a small
# fixture vault and look at what the script says and at the .apkg it writes (a
# zip with the collection and the media), and they feed it the vaults it must
# refuse: none, a directory that is no vault, a vault without card notes, a
# duplicate key, a card with no source, a missing diagram, a malformed key.
#
# CCNA_DECK_UNDER_TEST=<file> tests another copy; by default it is the
# ccna-deck on the PATH.

# The checks are eval'd, so their $ expand at check time (SC2016), and the
# variables they read are set outside them (SC2034).
# shellcheck disable=SC2016,SC2034

set -uo pipefail

SUT=$(readlink -f "${CCNA_DECK_UNDER_TEST:-$(type -P ccna-deck)}")
SB=$(mktemp -d "${TMPDIR:-/tmp}/ccna-deck-test.XXXXXX")
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
    out=$(env -i HOME="$SB/home" PATH="$PATH" CCNA_DECK_NOTES_DIR="Notes/Cards" CCNA_DECK_MEDIA_DIR="Media/cards" \
        CCNA_DECK_NAME="Test Deck" "${envs[@]}" "$SUT" "$@" 2>"$SB/err")
    rc=$?
    err=$(<"$SB/err")
}
check() { if eval "$2"; then ok "$1"; else bad "$1" "    rc: $rc
    out: ${out:0:600}
    err: ${err:0:900}"; fi; }

# vault NAME: a vault with the card directory, and the note text on stdin.
vault() {
    local v="$SB/$1"
    mkdir -p "$v/Notes/Cards" "$v/Media/cards"
    : >"$v/Vault.md"
    printf '%s' "$v"
}

echo "ccna-deck"

# ── a good vault ───────────────────────────────────────────────────────────
V=$(vault good)
cat >"$V/Notes/Cards/CCNA 01 – Fundamentals.md" <<'NOTE'
---
type: note
---

# Cards

> [!card] osi-layers
> **Q:** How many layers has the OSI model?
> *DE: Wie viele Schichten hat das OSI-Modell?*
> **A:** Seven, from `physical` to **application**.
> **Src:** Odom, ch. 1

> [!term] mtu
> **EN:** MTU
> **DE:** maximale Übertragungseinheit
> **Def:** The largest *payload* a link carries in one frame.
> **Src:** Odom, ch. 3

> [!cloze] ipv6-global
> The global unicast block is {{c1::2000::/3}} and the link-local one is {{c2::fe80::/10}}.
> **Src:** RFC 4291

# Dropped

> [!card] never-shown
> **Q:** This is below Dropped.
> **A:** And never reaches the deck.
NOTE
cat >"$V/Notes/Cards/CCNA 02 – Switching.md" <<'NOTE'
# Cards

> [!card] vlan-id
> **Q:** What is the range of normal VLAN IDs?
> **A:** 1 to 1005.
> **Shows:** ![[vlan.svg]]
> **Src:** Odom, ch. 8
NOTE
printf '<svg xmlns="http://www.w3.org/2000/svg"/>\n' >"$V/Media/cards/vlan.svg"

run VAULT_DIR="$V" -- --check
check "--check on a good vault counts the notes and cards and writes nothing" \
    '[[ $rc == 0 && $out == *"OK     check only: 4 notes, 6 cards, 1 diagram(s)"* && ! -e "$V/Media/cards/Test Deck.apkg" ]]'
check "--check names each subject deck with its counts, in order" \
    '[[ $out == *"Test Deck::01 Fundamentals  3 notes, 5 cards"* && $out == *"Test Deck::02 Switching  1 notes, 1 cards"* ]]'
check "the Dropped section does not reach the deck" \
    '[[ $out != *never-shown* && $err != *never-shown* ]]'

run VAULT_DIR="$V" -- 
check "a build writes the deck to the default place in the vault and says how big" \
    '[[ $rc == 0 && $out == *"OK     $V/Media/cards/Test Deck.apkg ("*"): 4 notes, 6 cards, 1 diagram(s)"* && -s "$V/Media/cards/Test Deck.apkg" ]]'
members=$(python3 -I -m zipfile -l "$V/Media/cards/Test Deck.apkg" 2>&1)
check "the .apkg is a zip with the collection and the media: the fonts and the diagram" \
    '[[ $members == *collection.anki2* && $members == *media* ]]'
media=$(python3 -I -c '
import json, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
print(" ".join(sorted(json.loads(z.read("media")).values())))
' "$V/Media/cards/Test Deck.apkg" 2>&1)
check "the media list holds the three fonts the script ships and the diagram the card shows" \
    '[[ $media == "_ccna-jbmono-bold.woff2 _ccna-jbmono-italic.woff2 _ccna-jbmono-regular.woff2 vlan.svg" ]]'

run VAULT_DIR="$V" -- --out "$SB/elsewhere/deck.apkg"
check "--out puts the deck elsewhere and makes the directory" \
    '[[ $rc == 0 && -s "$SB/elsewhere/deck.apkg" ]]'

cp "$SB/elsewhere/deck.apkg" "$SB/first.apkg"
run VAULT_DIR="$V" -- --out "$SB/elsewhere/deck2.apkg"
ids() { python3 -I -c '
import sys, sqlite3, tempfile, zipfile
z = zipfile.ZipFile(sys.argv[1])
d = tempfile.mkdtemp(dir=sys.argv[2])
z.extract("collection.anki2", d)
c = sqlite3.connect(d + "/collection.anki2")
print(",".join(sorted(r[0] for r in c.execute("select guid from notes"))))
' "$1" "$SB"; }
check "the note GUIDs come from the keys alone, so a second build is a re-import and not a new deck" \
    '[[ -n "$(ids "$SB/first.apkg")" && "$(ids "$SB/first.apkg")" == "$(ids "$SB/elsewhere/deck2.apkg")" ]]'

# ── the cloze colon ────────────────────────────────────────────────────────
fields=$(python3 -I -c '
import sys, sqlite3, tempfile, zipfile
z = zipfile.ZipFile(sys.argv[1])
d = tempfile.mkdtemp(dir=sys.argv[2])
z.extract("collection.anki2", d)
c = sqlite3.connect(d + "/collection.anki2")
for (f,) in c.execute("select flds from notes"):
    print(f.replace("\x1f", " | "))
' "$SB/first.apkg" "$SB")
check "inside a cloze gap a colon is written as an entity, so 2000::/3 is not read as a hint" \
    '[[ $fields == *"{{c1::2000&#58;&#58;/3}}"* && $fields == *"{{c2::fe80&#58;&#58;/10}}"* ]]'
check "underscores and code survive: bold, italic and code become tags, the key stays a field" \
    '[[ $fields == *"<code>physical</code>"* && $fields == *"<b>application</b>"* && $fields == *"<i>payload</i>"* && $fields == *"osi-layers"* ]]'

# ── the skill value is the vault ───────────────────────────────────────────
printf '{"vault":{"root":"%s"}}' "$V" >"$SB/values.json"
run RAVNIX_SKILL_VALUES="$SB/values.json" -- --check
check "with no VAULT_DIR the vault is the skill value vault.root, read at run time" \
    '[[ $rc == 0 && $out == *"OK     check only: 4 notes"* ]]'
run RAVNIX_SKILL_VALUES="$SB/values.json" VAULT_DIR="$SB/nope" -- --check
check "VAULT_DIR beats the skill value" '[[ $rc == 1 && $err == *"no vault at $SB/nope"* ]]'
run XDG_CONFIG_HOME="$SB/xdg" -- --check
mkdir -p "$SB/xdg/ravnix"
cp "$SB/values.json" "$SB/xdg/ravnix/skill-values.json"
check "without either, and without the file, it says what to set" \
    '[[ $rc == 1 && $err == *"no vault: set VAULT_DIR, pass --vault, or set vault.root in ravnix.claude.skillValues"* ]]'
run XDG_CONFIG_HOME="$SB/xdg" -- --check
check "the file in the user's config is found when no variable names one" \
    '[[ $rc == 0 && $out == *"OK     check only"* ]]'
printf '{"vault":' >"$SB/xdg/ravnix/skill-values.json"
run XDG_CONFIG_HOME="$SB/xdg" -- --check
check "a skill-values file that is not JSON is the same as none" \
    '[[ $rc == 1 && $err == *"no vault: set VAULT_DIR"* ]]'
printf '{"vault":{"root":42}}' >"$SB/xdg/ravnix/skill-values.json"
run XDG_CONFIG_HOME="$SB/xdg" -- --check
check "a vault.root that is no string is the same as none" \
    '[[ $rc == 1 && $err == *"no vault: set VAULT_DIR"* ]]'

# ── where things are is the user's ────────────────────────────────────────
run VAULT_DIR="$V" CCNA_DECK_NOTES_DIR= -- --check
check "without the notes folder it says what to set" \
    '[[ $rc == 1 && $err == *"ccna-deck: not set: CCNA_DECK_NOTES_DIR"* && $err == *"ravnix.scripts.ccnaDeck"* ]]'
run VAULT_DIR="$V" CCNA_DECK_MEDIA_DIR= CCNA_DECK_NAME= -- --check
check "all that is missing is named, in one message" \
    '[[ $rc == 1 && $err == *"not set: CCNA_DECK_MEDIA_DIR, CCNA_DECK_NAME"* ]]'
run VAULT_DIR="$V" CCNA_DECK_NAME="Other Name" -- --check
check "the deck's name is the one given, in the deck tree" '[[ $rc == 0 && $out == *"Other Name::01 Fundamentals"* && $out != *"Test Deck"* ]]'
run VAULT_DIR="$V" CCNA_DECK_NAME="Other Name" CCNA_DECK_MEDIA_DIR="Elsewhere" -- --check
check "the media folder is the one given: a diagram that is not in it is an error" \
    '[[ $rc == 1 && $err == *"image vlan.svg not in Elsewhere/"* ]]'
run VAULT_DIR="$V" CCNA_DECK_NAME="Other Name" -- 
check "the deck file is named after the deck, in the media folder" '[[ $rc == 0 && -s "$V/Media/cards/Other Name.apkg" ]]'

# ── what it refuses ────────────────────────────────────────────────────────
mkdir -p "$SB/not-a-vault"
run VAULT_DIR="$SB/not-a-vault" -- --check
check "a directory without Vault.md is no vault" '[[ $rc == 1 && $err == *"no vault at $SB/not-a-vault"* ]]'
run VAULT_DIR="$SB/missing" -- --check
check "a path that does not exist is no vault" '[[ $rc == 1 && $err == *"no vault at $SB/missing"* ]]'
run VAULT_DIR="" -- --check
check "an empty VAULT_DIR is no vault" '[[ $rc == 1 && $err == *"no vault: set VAULT_DIR"* ]]'

E=$(vault empty)
run VAULT_DIR="$E" -- --check
check "a vault with no CCNA notes has nothing to build" '[[ $rc == 1 && $err == *"ccna-deck: no subject notes found"* ]]'

# A note of a wrong name is skipped with a warning, the others still count.
N=$(vault names)
printf '# Cards\n\n> [!card] a-card\n> **Q:** q\n> **A:** a\n> **Src:** s\n' >"$N/Notes/Cards/CCNA 03 – Routing.md"
printf '# Cards\n\n> [!card] other\n> **Q:** q\n> **A:** a\n> **Src:** s\n' >"$N/Notes/Cards/CCNA 3 – Short number.md"
run VAULT_DIR="$N" -- --check
check "a note whose number is not two digits is not even looked at" \
    '[[ $rc == 0 && $out == *"1 notes, 1 cards"* && $out != *"other"* ]]'

D=$(vault dup)
printf '# Cards\n\n> [!card] same-key\n> **Q:** q\n> **A:** a\n> **Src:** s\n\n> [!card] same-key\n> **Q:** q2\n> **A:** a2\n> **Src:** s\n' >"$D/Notes/Cards/CCNA 01 – One.md"
run VAULT_DIR="$D" -- --check
check "a key used twice is an error that names both places, and nothing is written" \
    '[[ $rc == 1 && $err == *"ERROR  CCNA 01 – One.md: key '\''same-key'\'' already used in CCNA 01 – One.md"* && $err == *"1 error(s), nothing written"* ]]'

S=$(vault nosrc)
printf '# Cards\n\n> [!card] no-source\n> **Q:** q\n> **A:** a\n' >"$S/Notes/Cards/CCNA 01 – One.md"
run VAULT_DIR="$S" -- 
check "a card with no **Src:** line is refused and the deck is not written" \
    '[[ $rc == 1 && $err == *"[no-source]: no **Src:** line"* && ! -e "$S/Media/cards/Test Deck.apkg" ]]'

Q=$(vault noanswer)
printf '# Cards\n\n> [!card] half\n> **Q:** only a question\n> **Src:** s\n\n> [!term] half-term\n> **EN:** only english\n> **Src:** s\n\n> [!cloze] no-gap\n> a sentence without any gap\n> **Src:** s\n' >"$Q/Notes/Cards/CCNA 01 – One.md"
run VAULT_DIR="$Q" -- --check
check "a card needs Q and A, a term EN and DE, a cloze a gap" \
    '[[ $rc == 1 && $err == *"[half]: a card needs **Q:** and **A:**"* && $err == *"[half-term]: a term needs **EN:** and **DE:**"* && $err == *"[no-gap]: a cloze needs at least one"* && $err == *"3 error(s)"* ]]'

I=$(vault noimage)
printf '# Cards\n\n> [!card] pic\n> **Q:** q\n> **A:** a\n> ![[gone.svg]]\n> **Src:** s\n' >"$I/Notes/Cards/CCNA 01 – One.md"
run VAULT_DIR="$I" -- --check
check "a diagram that is not in the media directory is an error" \
    '[[ $rc == 1 && $err == *"[pic]: image gone.svg not in Media/cards/"* ]]'

M=$(vault malformed)
printf '# Cards\n\n> [!card] Bad_Key\n> **Q:** q\n> **A:** a\n> **Src:** s\n\n> [!card] fine\n> **Q:** q\n> **A:** a\n> **Src:** s\n' >"$M/Notes/Cards/CCNA 01 – One.md"
run VAULT_DIR="$M" -- --check
check "a card callout with a malformed key is skipped with a warning, the rest builds" \
    '[[ $rc == 0 && $err == *"WARN   CCNA 01 – One.md:3: card callout with a malformed key, skipped"* && $out == *"1 notes, 1 cards"* && $out == *"1 warning(s)"* ]]'

W=$(vault warns)
printf '# Cards\n\n> [!card] with-dash\n> **Q:** a — b\n> **A:** a\n> **Src:** s\n> stray line\n' >"$W/Notes/Cards/CCNA 01 – One.md"
run VAULT_DIR="$W" -- --check
check "an em dash and a line it does not understand are warnings, not errors" \
    '[[ $rc == 0 && $err == *"contains an em dash"* && $err == *"unrecognized line ignored: stray line"* && $out == *"2 warning(s)"* ]]'

H=$(vault nosection)
printf 'no cards section here\n' >"$H/Notes/Cards/CCNA 01 – One.md"
run VAULT_DIR="$H" -- --check
check "a note with no Cards section warns and has no cards" \
    '[[ $err == *"no '\''# Cards'\'' section, no cards"* && $out == *"0 notes, 0 cards"* ]]'

U=$(vault unicode)
printf '# Cards\n\n> [!card] umlaut\n> **Q:** Wofür steht <b>&</b> "ä"?\n> **A:** `a_b_c` und [[Link|Text]]\n> **Src:** [Quelle](https://example.org/x)\n' >"$U/Notes/Cards/CCNA 01 – One.md"
run VAULT_DIR="$U" -- --out "$SB/unicode.apkg"
uf=$(python3 -I -c '
import sys, sqlite3, tempfile, zipfile
z = zipfile.ZipFile(sys.argv[1])
d = tempfile.mkdtemp(dir=sys.argv[2])
z.extract("collection.anki2", d)
c = sqlite3.connect(d + "/collection.anki2")
for (f,) in c.execute("select flds from notes"):
    print(f.replace("\x1f", " | "))
' "$SB/unicode.apkg" "$SB")
check "HTML in the text is escaped, underscores stay, a wikilink is its text, a link is its source text" \
    '[[ $rc == 0 && $uf == *"&lt;b&gt;&amp;&lt;/b&gt;"* && $uf == *"<code>a_b_c</code>"* && $uf == *"und Text"* && $uf == *"Quelle"* && $uf != *"example.org"* ]]'

H2=$(vault huge)
{
    printf '# Cards\n'
    for i in $(seq 1 400); do
        printf '\n> [!card] k-%d\n> **Q:** question %d\n> **A:** answer %d\n> **Src:** s\n' "$i" "$i" "$i"
    done
} >"$H2/Notes/Cards/CCNA 01 – Many.md"
run VAULT_DIR="$H2" -- --check
check "four hundred cards in one note build" '[[ $rc == 0 && $out == *"400 notes, 400 cards"* ]]'

run VAULT_DIR="$V" -- --bogus
check "an unknown option exits 2 with the usage" '[[ $rc == 2 && $err == *"usage: ccna-deck"* ]]'
run -- --help
check "--help describes the options and mentions the skill value" \
    '[[ $rc == 0 && $out == *"usage: ccna-deck"* && $out == *"--vault"* && $out == *"vault.root"* && $out == *"VAULT_DIR"* ]]'

echo
echo "$pass passed, $fail failed"
[[ $fail == 0 ]]
