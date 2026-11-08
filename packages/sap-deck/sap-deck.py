#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["genanki>=0.13.1"]
# ///
"""sap-deck — build the SAP Anki deck from the vault's own SAP notes.

Companion to `vault-check` and `machine-facts`: the notes are hand-written and
this only generates. Nothing here writes into the vault except the .apkg.

    <shortcuts note>                  ──►  SAP::Kürzel::<H2 der Tabelle>
    <notes dir>/*.md with type: transaktion ─►  SAP::Transaktionen

The shortcuts note, the folder of the transaction notes and the deck file are
the user's own: SAP_DECK_SHORTCUTS and SAP_DECK_DIR (a note and a folder of the
vault) and SAP_DECK_OUT, which ravnix sets from ravnix.scripts.sapDeck. Nothing
is built in; without a shortcuts note there are no shortcut cards.

Two note types, two card templates each, so one fact is asked in both
directions. Import the result and Anki matches on the note GUID, which is
derived from the shortcut or the transaction code alone: fixing a description
updates the existing card and keeps its FSRS history.

FROZEN, and the reason is mechanical. Anki matches a notetype by id and then
compares its *schema*: field count, field names, field order, template count,
template names, template order. Change any of those and Anki forks the
notetype, after which every future import is skipped as "conflicting". So
MODEL_ID and the field list below are permanent. Template bodies and the CSS
are not part of the schema and may be rewritten freely, which is where all the
styling lives. Deck names are matched as strings, so renaming an H2 in the
shortcuts note creates a new subdeck and leaves the old one behind.
"""

import argparse
import html
import json
import os
import re
import shutil
import sys
import tempfile
from pathlib import Path

import genanki


def vault_default():
    """The vault: VAULT_DIR, else the skill value vault.root (claude/README.md,
    RAVNIX_SKILL_VALUES, else ~/.config/ravnix/skill-values.json), else ""."""
    if os.environ.get("VAULT_DIR"):
        return os.environ["VAULT_DIR"]
    path = os.environ.get("RAVNIX_SKILL_VALUES") or os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
        "ravnix", "skill-values.json")
    try:
        with open(path, encoding="utf-8") as fh:
            value = json.load(fh)["vault"]["root"]
    except (OSError, ValueError, KeyError, TypeError):
        return ""
    return value if isinstance(value, str) else ""


# ── identity ────────────────────────────────────────────────────────────────
# Generated once with random.randrange(1 << 30, 1 << 31). Never regenerate.
MODEL_KUERZEL = 1499328489
MODEL_TRANSAKTION = 1909614567
DECK_ROOT = 1715845557
DECK_TRANSAKTIONEN = 2015520346
DECK_KUERZEL_BASE = 1950104753  # + index of the H2, in file order

DECK_TOP = "SAP"
DECK_TX = "SAP::Transaktionen"
DECK_KEY = "SAP::Kürzel"

# Where the notes are, and where the deck goes: paths below the vault. The
# base is the file of the vault that lists the transactions; it is only named
# in a warning, so it may be unset.
SHORTCUT_NOTE = os.environ.get("SAP_DECK_SHORTCUTS", "")
SAP_DIR = os.environ.get("SAP_DECK_DIR", "")
OUT = os.environ.get("SAP_DECK_OUT", "")
BASE = os.environ.get("SAP_DECK_BASE", "") or "the base that lists the transactions"

# Filled by the template and never replaced. Not a description, so not a Detail.
PLACEHOLDER = "*(wofür die Transaktion da ist, in einem Satz)*"

# ── the look ────────────────────────────────────────────────────────────────
# Catppuccin Mocha, mauve accent, the same flat and square language as waybar.
# Deliberately dark in both of Anki's themes: Mocha is a dark palette, and a
# light variant of it would be a different palette wearing the name.
#
# `.card` sits on <body>, and Anki's own reviewer.css carries
# `body.nightMode { background-color: var(--canvas) }` at specificity (0,1,1).
# A bare `.card` is (0,1,0) and loses to it, which is why every rule that must
# survive night mode is written out twice, the second time as `.card.nightMode`.
#
# No flex `gap`: it needs Chromium 84 and AnkiDroid's floor is WebView 77.
# Sibling margins do the same job everywhere.
#
# The embedded face is named JBMonoDeck, a family that exists nowhere else, so
# a `loaded` status can only have come from these files. Only that status
# proves the font loaded: `document.fonts.forEach(f => console.log(f.family,
# f.weight, f.status))`, after the weight has rendered once, since faces load
# lazily. The glyphs prove nothing, because the stack falls back to another
# monospace (SF Mono on iOS), and neither does a pixel diff on this laptop,
# whose own JetBrains Mono renders identically.
CSS = r"""
@font-face {
  font-family: "JBMonoDeck";
  src: url("_jbmono-regular.woff2") format("woff2");
  font-weight: 400;
  font-display: swap;
}
@font-face {
  font-family: "JBMonoDeck";
  src: url("_jbmono-bold.woff2") format("woff2");
  font-weight: 700;
  font-display: swap;
}

.card, .card.nightMode {
  --base:     #1e1e2e;
  --mantle:   #181825;
  --crust:    #11111b;
  --surface0: #313244;
  --surface1: #45475a;
  --text:     #cdd6f4;
  --subtext0: #a6adc8;
  --overlay0: #6c7086;
  --mauve:    #cba6f7;
  --peach:    #fab387;

  font-family: "JBMonoDeck", "JetBrains Mono", ui-monospace, SFMono-Regular,
               Menlo, Consolas, monospace;
  font-size: 17px;
  line-height: 1.5;
  text-align: center;
  color: var(--text);
  background-color: var(--base);
  margin: 0;
}

/* The strip is the card's waybar: section on the left, direction on the right,
   a mauve tick at the edge. It answers "which way am I being asked" before the
   question is read, which is the one thing a two-way deck has to get right. */
.sap-bar, .card.nightMode .sap-bar {
  display: flex;
  justify-content: space-between;
  align-items: center;
  background: var(--mantle);
  border-bottom: 1px solid var(--surface0);
  border-left: 2px solid var(--mauve);
  padding: 7px 12px 7px 10px;
  font-size: 11px;
  letter-spacing: 0.10em;
  text-transform: uppercase;
  color: var(--overlay0);
  text-align: left;
}

/* The direction never wraps: it is the one thing on the strip that has to be
   readable at a glance. A long Bereich gives way to it instead. */
.sap-bar > span:first-child {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  min-width: 0;
}
.sap-bar > span:last-child { white-space: nowrap; padding-left: 10px; }

.sap-body { padding: 34px 22px 30px; }

/* Whatever gets typed into SAP lives in a command field, on whichever side of
   the card it happens to be. On a reverse question the field stands empty. */
.sap-keys { display: flex; flex-direction: column; align-items: center; }
.sap-keys > * + * { margin-top: 9px; }

.sap-keys kbd, .card.nightMode .sap-keys kbd {
  display: inline-block;
  white-space: nowrap;
  background: var(--crust);
  border: 1px solid var(--surface1);
  color: var(--mauve);
  font-family: inherit;
  font-weight: 700;
  font-size: clamp(15px, 4.6vw, 27px);
  line-height: 1.15;
  padding: 8px 18px;
  letter-spacing: 0.02em;
  max-width: 100%;
  box-sizing: border-box;
}

.sap-keys kbd.sap-leer, .card.nightMode .sap-keys kbd.sap-leer {
  color: var(--overlay0);
  font-weight: 400;
  border-style: dashed;
  min-width: 5ch;
}

.sap-oder { font-size: 12px; letter-spacing: 0.12em; text-transform: uppercase;
            color: var(--overlay0); }

.sap-aktion, .card.nightMode .sap-aktion {
  font-size: clamp(18px, 5.2vw, 24px);
  font-weight: 700;
  color: var(--text);
}
.sap-aktion-klein, .card.nightMode .sap-aktion-klein {
  font-size: 16px;
  color: var(--subtext0);
}
.sap-detail, .card.nightMode .sap-detail {
  font-size: 14px;
  color: var(--subtext0);
  margin-top: 14px;
}

hr#answer { border: none; height: 1px; background: var(--surface0); margin: 26px 0; }

/* Peach appears here and nowhere else, the same rule the waybar follows:
   the warm end of the palette means a warning, never decoration. */
.sap-warnung, .card.nightMode .sap-warnung {
  margin: 20px auto 0;
  max-width: 44ch;
  background: var(--mantle);
  border-left: 2px solid var(--peach);
  color: var(--peach);
  font-size: 13px;
  line-height: 1.55;
  padding: 9px 12px;
  text-align: left;
}
"""


def bar(richtung):
    """The strip. Bereich is conditional so it can never suppress a card.

    genanki recomputes Anki's required-field set from the question side, and
    two plain fields in one qfmt make BOTH of them required. Wrapping this one
    turns that into "any", so an empty Bereich costs the label and not the card.
    """
    return (
        '<div class="sap-bar">'
        "<span>{{#Bereich}}{{Bereich}}{{/Bereich}}</span>"
        f'<span>{richtung}</span>'
        "</div>"
    )


KEYS_KUERZEL = (
    '<div class="sap-keys"><kbd>{{Kürzel}}</kbd>'
    '{{#Kürzel2}}<span class="sap-oder">oder</span><kbd>{{Kürzel2}}</kbd>{{/Kürzel2}}'
    "</div>"
)
KEYS_LEER = '<div class="sap-keys"><kbd class="sap-leer">&#9615;</kbd></div>'
EXTRAS = (
    "{{#Detail}}<div class=\"sap-detail\">{{Detail}}</div>{{/Detail}}"
    "{{#Warnung}}<div class=\"sap-warnung\">{{Warnung}}</div>{{/Warnung}}"
)

TPL_KUERZEL = [
    {
        "name": "Kürzel → Aktion",
        "qfmt": bar("Kürzel → Aktion") + f'<div class="sap-body">{KEYS_KUERZEL}</div>',
        "afmt": bar("Kürzel → Aktion") + '<div class="sap-body">' + KEYS_KUERZEL
        + '<hr id="answer"><div class="sap-aktion">{{Aktion}}</div>'
        + "{{#Detail}}<div class=\"sap-detail\">{{Detail}}</div>{{/Detail}}</div>",
    },
    {
        # The whole question side is conditional: Anki does not create a card
        # whose front renders empty, so a row without an Aktion yields one card.
        "name": "Aktion → Kürzel",
        "qfmt": "{{#Aktion}}" + bar("Aktion → Kürzel")
        + '<div class="sap-body"><div class="sap-aktion">{{Aktion}}</div>'
        + f'<div style="margin-top:26px">{KEYS_LEER}</div></div>{{{{/Aktion}}}}',
        "afmt": bar("Aktion → Kürzel")
        + '<div class="sap-body"><div class="sap-aktion-klein">{{Aktion}}</div>'
        + f'<hr id="answer">{KEYS_KUERZEL}'
        + "{{#Detail}}<div class=\"sap-detail\">{{Detail}}</div>{{/Detail}}</div>",
    },
]

KEYS_TX = '<div class="sap-keys"><kbd>{{Transaktion}}</kbd></div>'

TPL_TRANSAKTION = [
    {
        "name": "Code → Aktion",
        "qfmt": bar("Code → Aktion") + f'<div class="sap-body">{KEYS_TX}</div>',
        "afmt": bar("Code → Aktion") + '<div class="sap-body">' + KEYS_TX
        + '<hr id="answer"><div class="sap-aktion">{{Aktion}}</div>' + EXTRAS + "</div>",
    },
    {
        "name": "Aktion → Code",
        "qfmt": "{{#Aktion}}" + bar("Aktion → Code")
        + '<div class="sap-body"><div class="sap-aktion">{{Aktion}}</div>'
        + f'<div style="margin-top:26px">{KEYS_LEER}</div></div>{{{{/Aktion}}}}',
        "afmt": bar("Aktion → Code")
        + '<div class="sap-body"><div class="sap-aktion-klein">{{Aktion}}</div>'
        + f'<hr id="answer">{KEYS_TX}' + EXTRAS + "</div>",
    },
]

# Schlüssel is first, invisible and never edited: it is what the GUID hangs on.
# Extra is unused today and exists because adding a field later would fork the
# notetype. It is the one piece of slack the schema rule makes worth carrying.
MODEL_KUERZEL_DEF = genanki.Model(
    MODEL_KUERZEL,
    "SAP Kürzel",
    fields=[{"name": n} for n in
            ("Schlüssel", "Kürzel", "Kürzel2", "Aktion", "Detail", "Bereich", "Extra")],
    templates=TPL_KUERZEL,
    css=CSS,
    sort_field_index=1,
)

MODEL_TRANSAKTION_DEF = genanki.Model(
    MODEL_TRANSAKTION,
    "SAP Transaktion",
    fields=[{"name": n} for n in
            ("Schlüssel", "Transaktion", "Aktion", "Detail", "Warnung", "Bereich", "Extra")],
    templates=TPL_TRANSAKTION,
    css=CSS,
    sort_field_index=1,
)


class StabileNote(genanki.Note):
    """GUID from the Schlüssel field alone.

    genanki's default is guid_for(*self.fields), a hash of every field, so
    correcting a description would mint a new note and orphan the old one with
    its whole review history. Keying on Schlüssel means the text is free to
    change and the card stays the same card.
    """

    @property
    def guid(self):
        return genanki.guid_for(self.fields[0])


# ── reading the vault ───────────────────────────────────────────────────────
WIKILINK = re.compile(r"\[\[([^\[\]|]+)(?:\|([^\[\]]+))?\]\]")
ROW = re.compile(r"^\|(.*)\|\s*$")
SEP = re.compile(r"^\|[\s:|-]+\|\s*$")


def plain(text):
    """Vault markup out, HTML-safe text in. A wikilink means nothing in Anki.

    The underscore is deliberately left alone. Stripping it as emphasis turned
    S_TABU_DIS into STABUDIS and &SAP_EDIT into &SAPEDIT, and a flashcard that
    teaches a mangled identifier is worse than no flashcard.
    """
    text = WIKILINK.sub(lambda m: m.group(2) or m.group(1), text)
    text = re.sub(r"<br\s*/?>", " ", text, flags=re.I)
    text = re.sub(r"[*`]", "", text)
    return html.escape(" ".join(text.split()))


def split_alternatives(cell):
    """`Strg + s<br>oder<br>F11` is two answers to one question, not one string."""
    parts = re.split(r"<br\s*/?>\s*oder\s*<br\s*/?>|\s+oder\s+", cell, flags=re.I)
    parts = [" ".join(p.split()) for p in parts]
    parts = [re.sub(r"\s*\+\s*", " + ", p) for p in parts if p.strip()]
    return parts[:2] if parts else [""]


def read_frontmatter(text):
    if not text.startswith("---\n"):
        return {}, text
    end = text.find("\n---\n", 3)
    if end == -1:
        return {}, text
    head, body = text[4:end], text[end + 5:]
    fm = {}
    key = None
    for line in head.splitlines():
        stripped = line.strip()
        # Both YAML list forms are correct in this vault, and Obsidian rewrites
        # frontmatter into the block form whenever it renames a note. Before
        # 2026-08-30 a block list was silently dropped here, which cost RZ12 its
        # alias and therefore its card, with only a warning to show for it.
        if stripped.startswith("- ") and key:
            item = stripped[2:].strip()
            fm[key] = f"{fm[key]}, {item}" if fm.get(key) else item
            continue
        if ":" in line and not line.startswith((" ", "-")):
            k, _, v = line.partition(":")
            key = k.strip()
            fm[key] = v.strip()
    return fm, body


def yaml_list(value):
    value = value.strip()
    if value.startswith("[") and value.endswith("]"):
        value = value[1:-1]
    return [v.strip().strip("\"'") for v in value.split(",") if v.strip()]


def read_shortcuts(vault, warn):
    """Every table row under an H2 becomes a note; the H2 becomes the subdeck."""
    if not SHORTCUT_NOTE:
        return []
    path = vault / SHORTCUT_NOTE
    if not path.exists():
        warn(f"missing {SHORTCUT_NOTE}, no shortcut cards")
        return []
    _, body = read_frontmatter(path.read_text(encoding="utf-8"))

    out, bereich, seen_header = [], None, False
    for line in body.splitlines():
        if line.startswith("## "):
            bereich = line[3:].strip().replace("::", " ")
            seen_header = False
            continue
        m = ROW.match(line)
        if not m or bereich is None:
            continue
        if SEP.match(line):
            seen_header = True
            continue
        cells = [c.strip() for c in m.group(1).split("|")]
        if not seen_header:
            continue  # the header row itself
        if len(cells) < 2 or not cells[0] or not cells[1]:
            continue
        keys = split_alternatives(cells[0])
        # The key sits in a nowrap box sized off the viewport. Past roughly this
        # width it stops fitting a phone, and CSS cannot rescue it, so say so
        # here rather than let it overflow on the one screen that matters.
        for k in keys:
            if len(k) > 24:
                warn(f"{bereich}: '{k}' is {len(k)} chars, it will overflow a phone")
        aktion = plain(cells[1])
        detail = plain(cells[2]) if len(cells) > 2 else ""
        out.append({
            "schluessel": f"kuerzel:{keys[0].lower()}",
            "kuerzel": html.escape(keys[0]),
            "kuerzel2": html.escape(keys[1]) if len(keys) > 1 else "",
            "aktion": aktion,
            "detail": detail,
            "bereich": bereich,
        })
    return out


def read_transaktionen(vault, warn):
    """Every note with type: transaktion. The code is the filename up to the first
    spaced en dash, alias the answer, the lead paragraph the detail, the first
    Stolperstein the warning."""
    out = []
    for path in sorted((vault / SAP_DIR).glob("*.md")):
        fm, body = read_frontmatter(path.read_text(encoding="utf-8"))
        if fm.get("type") != "transaktion":
            continue
        # Notes are named "RZ10 – Profilpflege" since 2026-08-30. Splitting on the
        # dash keeps the GUID at transaktion:rz10, so the rename costs no card its
        # review history. A note still named with the bare code works unchanged.
        code = path.stem.split(" – ")[0].strip()
        aliases = yaml_list(fm.get("aliases", ""))
        if not aliases:
            warn(f"{path.name}: no alias, skipped (the alias is the answer)")
            continue

        lead, stolper, section = [], [], None
        for line in body.splitlines():
            if line.startswith("## "):
                section = line[3:].strip()
                continue
            stripped = line.strip()
            if not stripped or stripped == PLACEHOLDER:
                continue
            if section is None:
                if not stripped.startswith("**"):
                    lead.append(stripped)
            elif section.startswith("Stolpersteine") and stripped.startswith("- "):
                stolper.append(stripped[2:])

        # `description` exists so that a base can show the sentence; a base
        # reads frontmatter and cannot see a note body. That means the sentence
        # is stored twice on purpose, so the copies get compared here rather
        # than left to drift. The body stays the source a human edits. The key
        # was `beschreibung` until 2026-10-08.
        description = fm.get("description", "").strip().strip("\"'")
        if not description:
            warn(f"{path.name}: no description, so it shows blank in {BASE}")
        elif lead and description != lead[0]:
            warn(f"{path.name}: description and the lead sentence have drifted apart")

        tags = yaml_list(fm.get("tags", ""))
        extra = [t for t in tags if t != "sap"]
        out.append({
            "schluessel": f"transaktion:{code.lower()}",
            "code": html.escape(code),
            "aktion": plain(aliases[0]),
            "detail": plain(" ".join(lead)),
            "warnung": plain(stolper[0]) if stolper else "",
            "bereich": extra[0].capitalize() if extra else "Transaktion",
        })
    return out


def stage_media(files, tmp):
    """Copy the media into tmp, each under its own name, so that every file has
    a current mtime. A file in the Nix store carries the mtime 1 (1970), which a
    zip cannot hold, and genanki writes with strict timestamps: the build would
    stop with "ZIP does not support timestamps before 1980". The leading
    underscore of the fonts and the basenames survive the copy."""
    staged = []
    for i, f in enumerate(files):
        d = Path(tmp) / str(i)
        d.mkdir()
        shutil.copyfile(f, d / Path(f).name)
        staged.append(str(d / Path(f).name))
    return staged


def main():
    ap = argparse.ArgumentParser(description="Build the SAP Anki deck from the vault.")
    ap.add_argument("--vault", default=vault_default(),
                    help="the vault (default: $VAULT_DIR, else the skill value vault.root)")
    ap.add_argument("--out", default=None, help="default: <vault>/$SAP_DECK_OUT")
    args = ap.parse_args()

    if not args.vault:
        sys.exit("sap-deck: no vault: set VAULT_DIR, pass --vault, or set vault.root in ravnix.claude.skillValues")
    vault = Path(args.vault)
    if not (vault / "Vault.md").exists():
        sys.exit(f"sap-deck: no vault at {vault}")
    unset = ([] if SAP_DIR else ["SAP_DECK_DIR"]) + ([] if args.out or OUT else ["SAP_DECK_OUT"])
    if unset:
        sys.exit(f"sap-deck: not set: {', '.join(unset)} "
                 "(ravnix.scripts.sapDeck.notesDir and out, or --out)")
    out = Path(args.out) if args.out else vault / OUT

    warnings = []
    def warn(msg):
        warnings.append(msg)
        print(f"WARN   {msg}", file=sys.stderr)

    here = Path(__file__).resolve().parent
    fonts = [here.parent / "share/sap-deck/_jbmono-regular.woff2",
             here.parent / "share/sap-deck/_jbmono-bold.woff2"]
    for f in fonts:
        if not f.exists():
            sys.exit(f"sap-deck: missing embedded font {f}")

    kuerzel = read_shortcuts(vault, warn)
    transaktionen = read_transaktionen(vault, warn)
    if not kuerzel and not transaktionen:
        sys.exit("sap-deck: nothing to build")

    # One deck per H2, in the order the note lists them, so the deck tree reads
    # top to bottom the way the note does.
    bereiche = []
    for row in kuerzel:
        if row["bereich"] not in bereiche:
            bereiche.append(row["bereich"])

    decks = {}
    for i, b in enumerate(bereiche):
        decks[b] = genanki.Deck(DECK_KUERZEL_BASE + i, f"{DECK_KEY}::{b}")
    tx_deck = genanki.Deck(DECK_TRANSAKTIONEN, DECK_TX)

    cards = 0
    for row in kuerzel:
        note = StabileNote(
            model=MODEL_KUERZEL_DEF,
            fields=[row["schluessel"], row["kuerzel"], row["kuerzel2"],
                    row["aktion"], row["detail"], row["bereich"], ""],
            tags=["SAP", "Kürzel"],
        )
        decks[row["bereich"]].add_note(note)
        cards += len(note.cards)

    for row in transaktionen:
        note = StabileNote(
            model=MODEL_TRANSAKTION_DEF,
            fields=[row["schluessel"], row["code"], row["aktion"], row["detail"],
                    row["warnung"], row["bereich"], ""],
            tags=["SAP", "Transaktion"],
        )
        tx_deck.add_note(note)
        cards += len(note.cards)

    # genanki reimplements Anki's required-field logic and gets edge cases
    # wrong, and a suppressed card fails silently. Two notes, two cards, always.
    expected = 2 * (len(kuerzel) + len(transaktionen))
    if cards != expected:
        sys.exit(f"sap-deck: {cards} cards from {len(kuerzel) + len(transaktionen)} "
                 f"notes, expected {expected}. A card was suppressed, check the "
                 f"question sides for an empty field.")

    root = genanki.Deck(DECK_ROOT, DECK_TOP)  # holds the tree together, stays empty
    pkg = genanki.Package([root, *decks.values(), tx_deck])
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        # Basenames only: genanki packs media by basename, and the leading
        # underscore is what stops Anki's media check from purging the fonts.
        pkg.media_files = stage_media(fonts, tmp)
        # No timestamp= here on purpose. genanki writes the note mtime from it,
        # and Anki's default import option only updates a note "if newer". A
        # frozen timestamp would make every re-import a silent no-op.
        pkg.write_to_file(str(out))

    print(f"       {len(kuerzel)} Kürzel · {len(transaktionen)} Transaktionen "
          f"· {cards} cards")
    for b in bereiche:
        n = sum(1 for r in kuerzel if r["bereich"] == b)
        print(f"       {DECK_KEY}::{b}  {n}")
    print(f"       {DECK_TX}  {len(transaktionen)}")
    print(f"OK     {out} ({out.stat().st_size // 1024} KB)"
          + (f", {len(warnings)} warning(s)" if warnings else ""))


if __name__ == "__main__":
    main()
