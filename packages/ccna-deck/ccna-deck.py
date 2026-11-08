#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["genanki>=0.13.1"]
# ///
"""ccna-deck: build the CCNA basics Anki deck from the vault's own card notes.

Sibling of `sap-deck`, same look, same rules. The notes are hand-written (or
researched and reviewed) and this only generates.

    <notes dir>/CCNA NN – <Subject>.md  ──►  <deck name>::NN <Subject>

The notes folder, the folder the diagrams are in and the deck's name are the
user's own: CCNA_DECK_NOTES_DIR and CCNA_DECK_MEDIA_DIR (folders of the vault)
and CCNA_DECK_NAME, which ravnix sets from ravnix.scripts.ccnaDeck. Nothing is
built in.

Each note holds its cards as callouts under `## Cards`:

    > [!card] <key>     Fact, one way:  **Q:** / *DE: …* / **A:** / *DE: …*
    > [!term] <key>     Term, both ways: **EN:** / **DE:** / **Def:** / *DE: …*
    > [!cloze] <key>    Cloze, one card per {{cN::…}} cluster

Optional lines in any block: `**Note:**` (shown on the back), `![[x.svg]]`
(a diagram on the back), `**Shows:** ![[x.svg]]` (a diagram on the question
side, fact cards only). `**Src:**` is required, because a card nobody can
check is a card nobody can fix.

The key after the callout type is the note GUID. Rewording a card updates it
and keeps its FSRS history; changing the key mints a new card and orphans the
old one. Keys are therefore permanent.

FROZEN, for the same mechanical reason as sap-deck: Anki matches a notetype by
id and then compares field count, names and order and template count, names
and order. Change any of them and every later import is skipped as
"conflicting". Template bodies and CSS are free. Each model carries one unused
`Extra` field as the only slack. Decks are matched by name, so renaming a
subject note creates a second subdeck instead of renaming the first.
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
MODEL_FACT = 1492212467
MODEL_TERM = 1245484431
MODEL_CLOZE = 1414464252
DECK_ROOT = 1375823793
DECK_SUBJECT_BASE = 1649887507  # + the subject number from the filename

# The deck's name (Anki matches decks by name), and two folders of the vault.
DECK_TOP = os.environ.get("CCNA_DECK_NAME", "")
CARD_DIR = os.environ.get("CCNA_DECK_NOTES_DIR", "")
MEDIA_DIR = os.environ.get("CCNA_DECK_MEDIA_DIR", "")
NOTE_NAME = re.compile(r"^CCNA (\d{2}) – (.+)$")

FONTS = ("_ccna-jbmono-regular.woff2", "_ccna-jbmono-bold.woff2",
         "_ccna-jbmono-italic.woff2")

# ── the look ────────────────────────────────────────────────────────────────
# Catppuccin Mocha with the mauve accent, the same flat, square language as
# sap-deck and the waybar. Every rule that must survive Anki's night mode is
# written twice, the second time as `.card.nightMode`, because reviewer.css
# sets `body.nightMode` at (0,1,1) and a bare `.card` is only (0,1,0). No flex
# `gap`; sibling margins do that job everywhere.
#
# German subtext is subtext-coloured and italic, on both sides, so the eye
# learns that the second line is always the exam's word for the first.
CSS = r"""
@font-face { font-family: "CCNAMono"; src: url("_ccna-jbmono-regular.woff2") format("woff2");
             font-weight: 400; font-style: normal; font-display: swap; }
@font-face { font-family: "CCNAMono"; src: url("_ccna-jbmono-bold.woff2") format("woff2");
             font-weight: 700; font-style: normal; font-display: swap; }
@font-face { font-family: "CCNAMono"; src: url("_ccna-jbmono-italic.woff2") format("woff2");
             font-weight: 400; font-style: italic; font-display: swap; }

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
  --green:    #a6e3a1;

  font-family: "CCNAMono", "JetBrains Mono", ui-monospace, SFMono-Regular,
               Menlo, Consolas, monospace;
  font-size: 17px;
  line-height: 1.5;
  text-align: center;
  color: var(--text);
  background-color: var(--base);
  margin: 0;
}

.cc-bar, .card.nightMode .cc-bar {
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
.cc-bar > span:first-child { overflow: hidden; text-overflow: ellipsis;
                             white-space: nowrap; min-width: 0; }
.cc-bar > span:last-child { white-space: nowrap; padding-left: 10px; }

.cc-body { padding: 30px 20px 26px; max-width: 46ch; margin: 0 auto; }

.cc-q, .card.nightMode .cc-q {
  font-size: clamp(17px, 4.8vw, 22px);
  font-weight: 700;
  color: var(--text);
}
.cc-q-klein, .card.nightMode .cc-q-klein { font-size: 15px; color: var(--subtext0); }

/* The term itself sits in the same command-field box sap-deck uses for a
   transaction code: the thing you are asked to produce, framed. */
.cc-term, .card.nightMode .cc-term {
  display: inline-block;
  background: var(--crust);
  border: 1px solid var(--surface1);
  color: var(--mauve);
  font-weight: 700;
  font-size: clamp(17px, 5vw, 25px);
  line-height: 1.2;
  padding: 8px 16px;
  max-width: 100%;
  box-sizing: border-box;
}
.cc-term.cc-leer, .card.nightMode .cc-term.cc-leer {
  color: var(--overlay0); font-weight: 400; border-style: dashed; min-width: 5ch;
}

.cc-de, .card.nightMode .cc-de {
  font-style: italic;
  font-size: 14px;
  color: var(--subtext0);
  margin-top: 8px;
}

.cc-a, .card.nightMode .cc-a {
  font-size: clamp(16px, 4.6vw, 20px);
  font-weight: 700;
  color: var(--text);
}

.cc-def, .card.nightMode .cc-def { font-size: 15px; color: var(--text); margin-top: 14px; }

/* Diagrams are drawn about 440 px wide; letting them into the side padding
   buys back the few pixels of text size a phone card would otherwise cost. */
.cc-img { margin: 18px -14px 0; }
.cc-img img { max-width: 100%; height: auto; }

.cc-note, .card.nightMode .cc-note {
  margin: 18px auto 0;
  background: var(--mantle);
  border-left: 2px solid var(--peach);
  color: var(--peach);
  font-size: 13px;
  line-height: 1.55;
  padding: 9px 12px;
  text-align: left;
}

.cc-src, .card.nightMode .cc-src {
  margin-top: 18px;
  font-size: 11px;
  color: var(--overlay0);
  overflow-wrap: anywhere;
}

.cc-cloze, .card.nightMode .cc-cloze { text-align: left; font-size: 16px; }
.cloze, .card.nightMode .cloze { color: var(--mauve); font-weight: 700; }
.cloze .cc-i, .cloze i { color: var(--mauve); }

code, .card.nightMode code {
  font-family: inherit;
  background: var(--crust);
  border: 1px solid var(--surface0);
  padding: 0 4px;
  color: var(--green);
}

hr#answer { border: none; height: 1px; background: var(--surface0); margin: 22px 0; }
"""


def bar(richtung):
    """Subject on the left, direction on the right. Subject is conditional so an
    empty one costs the label and never the card (genanki's required-field
    logic makes every plain field in a qfmt required)."""
    return ('<div class="cc-bar"><span>{{#Subject}}{{Subject}}{{/Subject}}</span>'
            f"<span>{richtung}</span></div>")


IMG_Q = '{{#QImage}}<div class="cc-img">{{QImage}}</div>{{/QImage}}'
BACK_EXTRAS = (
    '{{#Image}}<div class="cc-img">{{Image}}</div>{{/Image}}'
    '{{#Note}}<div class="cc-note">{{Note}}</div>{{/Note}}'
    '{{#Source}}<div class="cc-src">{{Source}}</div>{{/Source}}'
)

TPL_FACT = [{
    "name": "Question → Answer",
    "qfmt": bar("Q → A") + '<div class="cc-body"><div class="cc-q">{{Question}}</div>'
    + '{{#Frage}}<div class="cc-de">{{Frage}}</div>{{/Frage}}' + IMG_Q + "</div>",
    "afmt": bar("Q → A") + '<div class="cc-body"><div class="cc-q-klein">{{Question}}</div>'
    + '{{#Frage}}<div class="cc-de">{{Frage}}</div>{{/Frage}}' + IMG_Q
    + '<hr id="answer"><div class="cc-a">{{Answer}}</div>'
    + '{{#Antwort}}<div class="cc-de">{{Antwort}}</div>{{/Antwort}}'
    + BACK_EXTRAS + "</div>",
}]

TERM_BACK = (
    '{{#Definition}}<div class="cc-def">{{Definition}}</div>{{/Definition}}'
    '{{#DefinitionDE}}<div class="cc-de">{{DefinitionDE}}</div>{{/DefinitionDE}}'
)
TPL_TERM = [
    {
        "name": "EN → DE",
        "qfmt": bar("EN → DE") + '<div class="cc-body"><div class="cc-term">{{Term}}</div>'
        + '<div style="margin-top:22px"><span class="cc-term cc-leer">DE</span></div></div>',
        "afmt": bar("EN → DE") + '<div class="cc-body"><div class="cc-q-klein">{{Term}}</div>'
        + '<hr id="answer"><div class="cc-term">{{Begriff}}</div>'
        + TERM_BACK + BACK_EXTRAS + "</div>",
    },
    {
        # Whole question side conditional: no German term, no reverse card.
        "name": "DE → EN",
        "qfmt": "{{#Begriff}}" + bar("DE → EN")
        + '<div class="cc-body"><div class="cc-term">{{Begriff}}</div>'
        + '<div style="margin-top:22px"><span class="cc-term cc-leer">EN</span></div></div>'
        + "{{/Begriff}}",
        "afmt": bar("DE → EN") + '<div class="cc-body"><div class="cc-q-klein">{{Begriff}}</div>'
        + '<hr id="answer"><div class="cc-term">{{Term}}</div>'
        + TERM_BACK + BACK_EXTRAS + "</div>",
    },
]

TPL_CLOZE = [{
    "name": "Cloze",
    "qfmt": bar("Cloze") + '<div class="cc-body"><div class="cc-cloze">{{cloze:Text}}</div></div>',
    "afmt": bar("Cloze") + '<div class="cc-body"><div class="cc-cloze">{{cloze:Text}}</div>'
    + BACK_EXTRAS + "</div>",
}]

# Key is first, invisible and never edited: it is what the GUID hangs on.
MODEL_FACT_DEF = genanki.Model(
    MODEL_FACT, "CCNA Fact",
    fields=[{"name": n} for n in ("Key", "Question", "Frage", "Answer", "Antwort",
                                  "QImage", "Image", "Note", "Subject", "Source", "Extra")],
    templates=TPL_FACT, css=CSS, sort_field_index=1,
)
MODEL_TERM_DEF = genanki.Model(
    MODEL_TERM, "CCNA Term",
    fields=[{"name": n} for n in ("Key", "Term", "Begriff", "Definition", "DefinitionDE",
                                  "Image", "Note", "Subject", "Source", "Extra")],
    templates=TPL_TERM, css=CSS, sort_field_index=1,
)
MODEL_CLOZE_DEF = genanki.Model(
    MODEL_CLOZE, "CCNA Cloze",
    fields=[{"name": n} for n in ("Key", "Text", "Image", "Note", "Subject", "Source", "Extra")],
    templates=TPL_CLOZE, css=CSS, sort_field_index=1,
    model_type=genanki.Model.CLOZE,
)


class StabileNote(genanki.Note):
    """GUID from the Key field alone, so rewording keeps the review history."""

    @property
    def guid(self):
        return genanki.guid_for("ccna", self.fields[0])


# ── reading the vault ───────────────────────────────────────────────────────
HEAD = re.compile(r"^>\s*\[!(card|term|cloze)\][+-]?\s+([a-z0-9][a-z0-9-]*)\s*$")
FIELD = re.compile(r"^\*\*(Q|A|EN|DE|Def|Note|Src|Shows):\*\*\s*(.*)$")
SUBTEXT = re.compile(r"^\*DE:\s*(.*?)\*$")
EMBED = re.compile(r"!\[\[([^\[\]|#]+)(?:\|[^\[\]]*)?\]\]")
WIKILINK = re.compile(r"\[\[([^\[\]|#]+)(?:#[^\[\]|]*)?(?:\|([^\[\]]+))?\]\]")
MDLINK = re.compile(r"\[([^\]]+)\]\((https?://[^)\s]+)\)")
KEY_OK = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")


def inline(text):
    """Vault markup to card HTML. Escape first, then re-introduce the few
    constructs a card needs. Underscores are left alone, the lesson sap-deck
    learned from S_TABU_DIS: identifiers must survive verbatim."""
    text = WIKILINK.sub(lambda m: m.group(2) or m.group(1), text)
    links = []

    def keep_link(m):
        links.append((m.group(1), m.group(2)))
        return f"\x00{len(links) - 1}\x00"

    text = MDLINK.sub(keep_link, text)
    text = html.escape(" ".join(text.split()), quote=False)
    codes = []

    def keep_code(m):
        codes.append(m.group(1))
        return f"\x01{len(codes) - 1}\x01"

    text = re.sub(r"`([^`]+)`", keep_code, text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", text)
    text = re.sub(r"(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])", r"<i>\1</i>", text)
    text = re.sub(r"\x01(\d+)\x01", lambda m: f"<code>{codes[int(m.group(1))]}</code>", text)
    # A link on a phone card goes nowhere useful; the source text is enough.
    text = re.sub(r"\x00(\d+)\x00", lambda m: html.escape(links[int(m.group(1))][0]), text)
    return text


CLOZE_GAP = re.compile(r"\{\{c(\d+)::(.*?)\}\}")


def protect_cloze(text):
    """Inside a gap, Anki reads `::` as the start of a hint, so the IPv6 gap
    {{c1::2000::/3}} would ask for "2000" with "/3" as the hint. A colon written
    as &#58; renders the same and is invisible to the cloze parser, which works
    on the raw field. Hints are never used in this deck."""
    return CLOZE_GAP.sub(lambda m: "{{c%s::%s}}" % (m.group(1), m.group(2).replace(":", "&#58;")),
                         text)


def img_tag(name):
    return f'<img src="{html.escape(name, quote=True)}">'


def read_blocks(path, warn):
    """Yield (kind, key, lines) for every card callout in the note's Cards
    section. Only that section: a block moved under Dropped, or quoted in the
    verification log, must never reach the deck."""
    lines, inside = [], False
    for line in path.read_text(encoding="utf-8").splitlines():
        if re.match(r"^#{1,2} ", line):
            inside = bool(re.match(r"^#{1,2} Cards\s*$", line))
            lines.append("")
            continue
        lines.append(line if inside else "")
    if not any(lines):
        warn(f"{path.name}: no '# Cards' section, no cards")
    i = 0
    while i < len(lines):
        m = HEAD.match(lines[i])
        if not m:
            if re.match(r"^>\s*\[!(card|term|cloze)\]", lines[i]):
                warn(f"{path.name}:{i + 1}: card callout with a malformed key, skipped")
            i += 1
            continue
        kind, key = m.groups()
        body = []
        i += 1
        while i < len(lines) and lines[i].startswith(">"):
            body.append(lines[i][1:].strip())
            i += 1
        yield kind, key, [b for b in body if b]


def parse_block(kind, key, body, where, warn):
    """Turn a block's lines into a dict of raw (unconverted) parts."""
    rec = {"kind": kind, "key": key, "text": [], "images": [], "qimages": []}
    last = None
    for line in body:
        f = FIELD.match(line)
        s = SUBTEXT.match(line)
        if f:
            name, val = f.groups()
            if name == "Shows":
                rec["qimages"] += EMBED.findall(val)
                continue
            rec[name] = val
            last = name
        elif s and last in ("Q", "A", "Def"):
            rec[last + "_de"] = s.group(1)
            last = None
        elif EMBED.fullmatch(line):
            rec["images"] += EMBED.findall(line)
        elif kind == "cloze":
            rec["text"].append(line)
        else:
            warn(f"{where} [{key}]: unrecognized line ignored: {line[:60]}")
    return rec


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
    ap = argparse.ArgumentParser(description="Build the CCNA Anki deck from the vault.")
    ap.add_argument("--vault", default=vault_default(),
                    help="the vault (default: $VAULT_DIR, else the skill value vault.root)")
    ap.add_argument("--out", default=None,
                    help="default: <vault>/$CCNA_DECK_MEDIA_DIR/$CCNA_DECK_NAME.apkg")
    ap.add_argument("--check", action="store_true", help="parse and validate only")
    args = ap.parse_args()

    if not args.vault:
        sys.exit("ccna-deck: no vault: set VAULT_DIR, pass --vault, or set vault.root in ravnix.claude.skillValues")
    vault = Path(args.vault)
    if not (vault / "Vault.md").exists():
        sys.exit(f"ccna-deck: no vault at {vault}")
    unset = [n for n, v in (("CCNA_DECK_NOTES_DIR", CARD_DIR), ("CCNA_DECK_MEDIA_DIR", MEDIA_DIR),
                            ("CCNA_DECK_NAME", DECK_TOP)) if not v]
    if unset:
        sys.exit(f"ccna-deck: not set: {', '.join(unset)} "
                 "(ravnix.scripts.ccnaDeck.notesDir, mediaDir and deckName)")
    out = Path(args.out) if args.out else vault / MEDIA_DIR / f"{DECK_TOP}.apkg"
    media_dir = vault / MEDIA_DIR

    warnings, errors = [], []

    def warn(msg):
        warnings.append(msg)
        print(f"WARN   {msg}", file=sys.stderr)

    def error(msg):
        errors.append(msg)
        print(f"ERROR  {msg}", file=sys.stderr)

    here = Path(__file__).resolve().parent
    fonts = [here.parent / "share/ccna-deck" / f for f in FONTS]
    for f in fonts:
        if not f.exists():
            sys.exit(f"ccna-deck: missing embedded font {f}")

    notes_by_subject, seen, media = {}, {}, set()
    for path in sorted((vault / CARD_DIR).glob("CCNA [0-9][0-9] – *.md")):
        m = NOTE_NAME.match(path.stem)
        if not m:
            warn(f"{path.name}: name is not 'CCNA NN – Subject', skipped")
            continue
        num, subject = int(m.group(1)), f"{m.group(1)} {m.group(2)}"
        raw = path.read_text(encoding="utf-8")
        if "—" in raw:
            warn(f"{path.name}: contains an em dash")

        rows = []
        for kind, key, body in read_blocks(path, warn):
            where = path.name
            if key in seen:
                error(f"{where}: key '{key}' already used in {seen[key]}")
                continue
            seen[key] = where
            rec = parse_block(kind, key, body, where, warn)
            if not rec.get("Src"):
                error(f"{where} [{key}]: no **Src:** line")
            for img in rec["images"] + rec["qimages"]:
                if not (media_dir / img).exists():
                    error(f"{where} [{key}]: image {img} not in {MEDIA_DIR}/")
                media.add(img)
            if kind == "card" and not (rec.get("Q") and rec.get("A")):
                error(f"{where} [{key}]: a card needs **Q:** and **A:**")
            if kind == "term" and not (rec.get("EN") and rec.get("DE")):
                error(f"{where} [{key}]: a term needs **EN:** and **DE:**")
            if kind == "cloze" and not re.search(r"\{\{c\d+::", " ".join(rec["text"])):
                error(f"{where} [{key}]: a cloze needs at least one {{{{cN::…}}}}")
            if kind != "card" and rec["qimages"]:
                warn(f"{where} [{key}]: **Shows:** only works on fact cards, ignored")
            rows.append(rec)
        notes_by_subject[(num, subject)] = rows

    if not notes_by_subject:
        sys.exit("ccna-deck: no subject notes found")
    if errors:
        sys.exit(f"ccna-deck: {len(errors)} error(s), nothing written")

    subject_decks, cards, expected, total_notes = [], 0, 0, 0
    for (num, subject), rows in sorted(notes_by_subject.items()):
        deck = genanki.Deck(DECK_SUBJECT_BASE + num, f"{DECK_TOP}::{subject}")
        subject_decks.append(deck)
        for r in rows:
            imgs = "".join(img_tag(i) for i in r["images"])
            src = inline(r.get("Src", ""))
            note_txt = inline(r.get("Note", ""))
            if r["kind"] == "card":
                fields = [r["key"], inline(r["Q"]), inline(r.get("Q_de", "")),
                          inline(r["A"]), inline(r.get("A_de", "")),
                          "".join(img_tag(i) for i in r["qimages"]), imgs,
                          note_txt, subject, src, ""]
                note = StabileNote(model=MODEL_FACT_DEF, fields=fields,
                                   tags=["CCNA", "fact"])
                want = 1
            elif r["kind"] == "term":
                fields = [r["key"], inline(r["EN"]), inline(r["DE"]),
                          inline(r.get("Def", "")), inline(r.get("Def_de", "")),
                          imgs, note_txt, subject, src, ""]
                note = StabileNote(model=MODEL_TERM_DEF, fields=fields,
                                   tags=["CCNA", "term"])
                want = 2
            else:
                text = protect_cloze("<br>".join(inline(t) for t in r["text"]))
                fields = [r["key"], text, imgs, note_txt, subject, src, ""]
                note = StabileNote(model=MODEL_CLOZE_DEF, fields=fields,
                                   tags=["CCNA", "cloze"])
                want = len(set(re.findall(r"\{\{c(\d+)::", text)))
            deck.add_note(note)
            got = len(note.cards)
            if got != want:
                error(f"{subject} [{r['key']}]: {got} card(s), expected {want}")
            cards += got
            expected += want
            total_notes += 1

    # genanki reimplements Anki's required-field logic and a suppressed card
    # fails silently, so the count is checked rather than trusted.
    if errors or cards != expected:
        sys.exit(f"ccna-deck: {cards} cards, expected {expected}, nothing written")

    for (num, subject), rows in sorted(notes_by_subject.items()):
        n = sum({"card": 1, "term": 2}.get(r["kind"], 0) for r in rows)
        n += sum(len(set(re.findall(r"\{\{c(\d+)::", " ".join(r["text"]))))
                 for r in rows if r["kind"] == "cloze")
        print(f"       {DECK_TOP}::{subject}  {len(rows)} notes, {n} cards")

    if args.check:
        print(f"OK     check only: {total_notes} notes, {cards} cards, "
              f"{len(media)} diagram(s)" + (f", {len(warnings)} warning(s)" if warnings else ""))
        return

    root = genanki.Deck(DECK_ROOT, DECK_TOP)  # holds the tree together, stays empty
    pkg = genanki.Package([root, *subject_decks])
    out.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory() as tmp:
        pkg.media_files = stage_media(
            [*fonts, *(media_dir / m for m in sorted(media))], tmp)
        # No timestamp=: a frozen note mtime turns every re-import into a silent
        # no-op under Anki's default "update if newer".
        pkg.write_to_file(str(out))
    print(f"OK     {out} ({out.stat().st_size // 1024} KB): {total_notes} notes, "
          f"{cards} cards, {len(media)} diagram(s)"
          + (f", {len(warnings)} warning(s)" if warnings else ""))


if __name__ == "__main__":
    main()
