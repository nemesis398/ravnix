#!/usr/bin/env python3
"""Mechanical verification for the `prose` skill.

Two passes over a document:

  1. Deterministic  dashes, emoji placement, German typography, spacing,
                    high-signal AI phrasing. No network, always runs.
  2. LanguageTool   grammar and spelling, with the markdown masked so code,
                    wikilinks, URLs and table pipes never reach the checker.

Stdlib only, so it runs with no install step.

Usage
    check.py FILE [FILE...]
    check.py --stdin --lang de
    check.py --selftest              which LanguageTool backend is reachable
    check.py --no-lt                 deterministic pass only
    check.py --json                  machine-readable findings
    check.py --strict                warnings count as failures too

Exit status is 1 when anything fatal was found, else 0.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import skill_values as sv  # noqa: E402

# ---------------------------------------------------------------------------
# Editable lists. These are meant to be tuned over time.
# The user's dictionary, ~/.config/prose/dictionary.txt (one word per line),
# is merged into IGNORE_WORDS at runtime.
# ---------------------------------------------------------------------------

IGNORE_WORDS = {
    # A common stack and its surroundings.
    "Proxmox", "Coolify", "netcup", "UniFi", "Ubiquiti", "OPNsense", "pfSense",
    "Nextcloud", "Fedora", "Sway", "waybar", "kanshi", "fuzzel", "dunst",
    "swaylock", "foot", "Ghostty", "Catppuccin", "Wayland", "Hyprland",
    "Umami", "Plausible", "Matomo", "Rybbit", "GoatCounter", "PostHog",
    "GlitchTip", "Bugsink", "AppSignal", "GoAccess", "ClickHouse", "Postgres",
    "PostgreSQL", "Valkey", "Restic", "Borg", "WireGuard", "Tailscale",
    "Netbird", "Pi-hole", "AdGuard", "Grafana", "Prometheus", "Checkmk",
    "Uptime", "Kuma", "Ansible", "Terraform", "Docker", "Kubernetes",
    "Obsidian", "Excalidraw", "Anki", "FSRS",
    "Ausbildungsnachweis", "Lernfeld", "Lernfelder", "Projektarbeit",
    "Berufsschule", "IHK", "AkA", "TDDDG", "DSGVO", "BBiG", "FIAusbV",
    "Wireshark", "tcpdump", "Samba", "LibreOffice", "systemd", "hunspell",
    "LanguageTool", "OpenCode", "Claude", "Anthropic", "Opus", "Sonnet",
    "Stow", "SELinux", "GRUB", "Plymouth", "SDDM", "NVIDIA", "Lenovo",
    "IdeaPad", "Boson", "ExSim", "Geerling", "Messer", "netzwerk",
    # Deliberately lowercase tool names. The casing filter is
    # case-insensitive, so listing them here also stops LanguageTool
    # "correcting" restic to Restic and borg to Borg.
    "restic", "borg", "nginx", "systemd", "vzdump", "rbw", "pass",
    # Product names whose capitalisation is the vendor's, not a mistake.
    "Storage Box", "Proxmox Backup Server", "Hetzner", "Vaultwarden",
    "Bitwarden", "Forgejo", "Stirling", "NetBird", "LanguageTool",
}

# Phrases that mark machine-shaped prose. Kept short and high-precision:
# every entry here should be something a careful writer would rephrase.
AI_PHRASES_EN = [
    ("it's not just", "Antithesis padding. State the thing you mean."),
    ("it is not just", "Antithesis padding. State the thing you mean."),
    ("this isn't about", "Antithesis padding. Say what it is about."),
    ("more than just", "Antithesis padding."),
    ("it's worth noting", "If it is worth noting, note it without the preamble."),
    ("it is worth noting", "If it is worth noting, note it without the preamble."),
    ("it's important to note", "Throat-clearing. Delete and keep the fact."),
    ("it is important to note", "Throat-clearing. Delete and keep the fact."),
    ("in today's", "Throat-clearing opener."),
    ("in the world of", "Throat-clearing opener."),
    ("when it comes to", "Filler. Name the subject directly."),
    ("let's dive", "Signposting the reader does not need."),
    ("let's take a look", "Signposting the reader does not need."),
    ("delve into", "Register mismatch with the rest of your notes."),
    ("at the end of the day", "Cliche."),
    ("the key takeaway", "If the point is the point, just make it."),
    ("in conclusion", "A note does not need a conclusion section."),
    ("to sum up", "A note does not need a summary of itself."),
    ("game-changer", "Marketing register."),
    ("game changer", "Marketing register."),
    ("seamless", "Empty intensifier. Say what actually happens."),
    ("seamlessly", "Empty intensifier. Say what actually happens."),
    ("effortless", "Empty intensifier."),
    ("unlock the", "Marketing register."),
    ("harness the power", "Marketing register."),
    ("navigate the complex", "Marketing register."),
    ("tapestry", "Marketing register."),
    ("a testament to", "Marketing register."),
    ("plays a crucial role", "Says nothing. Name the role."),
    ("plays a vital role", "Says nothing. Name the role."),
    ("robust and scalable", "Paired empty adjectives."),
    ("powerful and flexible", "Paired empty adjectives."),
    ("fast and efficient", "Paired empty adjectives."),
]

AI_PHRASES_DE = [
    ("in der heutigen", "Floskel-Einstieg."),
    ("in der heutigen schnelllebigen", "Floskel-Einstieg."),
    ("es ist wichtig zu beachten", "Vorgeplänkel. Die Tatsache reicht."),
    ("es sei angemerkt", "Vorgeplänkel."),
    ("es gilt zu beachten", "Vorgeplänkel."),
    ("zusammenfassend lässt sich sagen", "Wiederholt nur den Absatz davor."),
    ("abschließend lässt sich", "Wiederholt nur den Absatz davor."),
    ("tauchen wir ein", "Wegweiser, den niemand braucht."),
    ("werfen wir einen blick", "Wegweiser, den niemand braucht."),
    ("nicht nur, sondern auch", "Antithese als Füllung."),
    ("spielt eine entscheidende rolle", "Sagt nichts. Nenn die Rolle."),
    ("spielt eine wichtige rolle", "Sagt nichts. Nenn die Rolle."),
    ("ein wahrer gamechanger", "Werbesprache."),
    ("revolutioniert", "Werbesprache."),
    ("nahtlos", "Leere Verstärkung. Sag, was passiert."),
    ("leistungsstark und flexibel", "Leeres Adjektivpaar."),
    ("schnell und effizient", "Leeres Adjektivpaar."),
]

# German connectives that are fine once and grating four times in a row.
DE_GLUE_WORDS = [
    "darüber hinaus", "des weiteren", "ferner", "zudem", "überdies",
    "nicht zuletzt", "in diesem zusammenhang",
]

# LanguageTool rules that argue with this skill's own policy, or that fire
# constantly on note-shaped markdown.
LT_DISABLED_RULES = [
    "DASH_RULE",              # suggests em dashes
    "TYPOGRAFISCHE_ANFUEHRUNGSZEICHEN",
    "EN_QUOTES",
    "UPPERCASE_SENTENCE_START",   # bullets and cells legitimately start lower
    "PUNCTUATION_PARAGRAPH_END",  # bullets legitimately have no full stop
    "WHITESPACE_RULE",            # markdown alignment is not an error
    "COMMA_PARENTHESIS_WHITESPACE",
    "MORFOLOGIK_RULE_EN_US",      # spelling handled with the ignore list below
    "GERMAN_SPELLER_RULE",
]
# Spelling rules stay available but their hits are filtered through
# IGNORE_WORDS rather than disabled outright.
LT_SPELLING_RULES = {"MORFOLOGIK_RULE_EN_US", "MORFOLOGIK_RULE_EN_GB",
                     "GERMAN_SPELLER_RULE", "HUNSPELL_RULE"}

# Premium injects these as if they were findings. They are adverts for the
# browser plugin and the login, not problems with the text, and showing them
# next to real errors is how a checker loses its credibility.
LT_AD_PREFIXES = ("LT_RECOMMENDATION",)

# The QuillBot-derived premium rules declare issueType=grammar or misspelling,
# but in practice they are rephrasing suggestions: on a real note they wanted
# `restic` capitalised, Hetzner's actual product name "Storage Box"
# lowercased, and a statement turned into a question. Left at error severity
# they would force wrong edits, because this skill says to fix every error.
# They are worth reading, so they stay, demoted to warnings.
LT_SUGGESTION_PREFIXES = ("QB_NEW_", "AI_")

# Casing complaints are filtered through the dictionary too, case-insensitively:
# a term we know about keeps whatever casing it was written with.
LT_CASING_CATEGORIES = {"CASING", "TYPOS"}

DE_ENDASH_WORDS_PER_DASH = 200   # German budget: one spaced en dash per N words

# ---------------------------------------------------------------------------
# Findings
# ---------------------------------------------------------------------------

SEV_ERROR, SEV_WARN, SEV_NOTE = "error", "warning", "note"


@dataclass
class Finding:
    line: int
    col: int
    severity: str
    rule: str
    message: str
    excerpt: str = ""
    suggestion: str = ""

    def as_dict(self) -> dict:
        return {
            "line": self.line, "col": self.col, "severity": self.severity,
            "rule": self.rule, "message": self.message,
            "excerpt": self.excerpt, "suggestion": self.suggestion,
        }


# ---------------------------------------------------------------------------
# Emoji detection
# ---------------------------------------------------------------------------
# Arrows (U+2190..U+21FF) are deliberately excluded: the user uses the arrow as
# prose punctuation, and it is not an emoji.

_EMOJI_RANGES = (
    (0x1F000, 0x1FAFF), (0x1F1E6, 0x1F1FF), (0x2600, 0x26FF),
    (0x2700, 0x27BF), (0x2B00, 0x2BFF), (0x231A, 0x231B),
    (0x23E9, 0x23FA), (0x2049, 0x2049), (0x203C, 0x203C),
    (0x00A9, 0x00A9), (0x00AE, 0x00AE), (0x2122, 0x2122),
)
_EMOJI_JOINERS = {0x200D, 0xFE0F, 0xFE0E, 0x20E3}


def _is_emoji_char(ch: str) -> bool:
    cp = ord(ch)
    return any(lo <= cp <= hi for lo, hi in _EMOJI_RANGES)


def emoji_clusters(text: str) -> list[tuple[int, str]]:
    """Return (offset, cluster) for each emoji as the reader sees it.

    A flag is two regional indicators and a family is several emoji joined by
    zero-width joiners. Counting those as separate emoji would report 🇩🇪 as
    two findings and 👨‍💻 as three.
    """
    out: list[tuple[int, str]] = []
    i, n = 0, len(text)
    while i < n:
        if not _is_emoji_char(text[i]):
            i += 1
            continue
        start = i
        if 0x1F1E6 <= ord(text[i]) <= 0x1F1FF and i + 1 < n and \
                0x1F1E6 <= ord(text[i + 1]) <= 0x1F1FF:
            i += 2
        else:
            i += 1
        while i < n:
            if ord(text[i]) in _EMOJI_JOINERS:
                i += 1
            elif ord(text[i - 1]) == 0x200D and _is_emoji_char(text[i]):
                i += 1
            else:
                break
        out.append((start, text[start:i]))
    return out


# ---------------------------------------------------------------------------
# Markdown masking
# ---------------------------------------------------------------------------

@dataclass
class Segment:
    """One annotation segment, tracking both coordinate systems."""
    kind: str           # "text" | "markup"
    orig_start: int
    orig_text: str
    plain_start: int
    plain_text: str
    suppress: bool = False   # matches landing here are dropped (code, links)


@dataclass
class Masked:
    source: str
    segments: list[Segment] = field(default_factory=list)
    is_markup: list[bool] = field(default_factory=list)
    # True where a LanguageTool complaint should be dropped: code, links,
    # wikilink targets. The user cannot fix a spelling "error" inside a command
    # name without breaking the command.
    suppress_orig: list[bool] = field(default_factory=list)

    def annotations_for(self, lo: int, hi: int) -> list[dict]:
        """Annotations covering source[lo:hi], clipped at the boundaries."""
        out: list[dict] = []
        for s in self.segments:
            s_lo, s_hi = s.orig_start, s.orig_start + len(s.orig_text)
            if s_hi <= lo or s_lo >= hi:
                continue
            clip_lo, clip_hi = max(s_lo, lo), min(s_hi, hi)
            piece = self.source[clip_lo:clip_hi]
            if not piece:
                continue
            if s.kind == "text":
                out.append({"text": piece})
            else:
                item = {"markup": piece}
                # interpretAs only survives an unclipped span, otherwise it
                # would describe text that is no longer fully present.
                if s.plain_text and (clip_lo, clip_hi) == (s_lo, s_hi):
                    item["interpretAs"] = s.plain_text
                out.append(item)
        return out

    def suppressed(self, orig_offset: int, length: int) -> bool:
        hi = min(len(self.source), orig_offset + max(length, 1))
        return any(self.suppress_orig[i] for i in range(max(0, orig_offset), hi))


# LanguageTool runs on the JVM, so the offsets it returns are UTF-16 code
# unit indices, not codepoint indices. Every emoji before a finding shifts it
# by one. The user's notes are full of emoji, so this is not a corner case.

def utf16_prefix(text: str) -> list[int]:
    """prefix[i] is the UTF-16 offset of codepoint i."""
    out = [0]
    total = 0
    for ch in text:
        total += 2 if ord(ch) > 0xFFFF else 1
        out.append(total)
    return out


def utf16_to_codepoint(prefix: list[int], u16_offset: int) -> int:
    import bisect
    return min(bisect.bisect_left(prefix, u16_offset), len(prefix) - 1)


# Ordered: earlier patterns win the character range.
# (regex, kind, interpret) where interpret is either a literal replacement
# string, the sentinel "KEEP" to reuse a capture group, or "" to drop.
_MASK_PATTERNS: list[tuple[re.Pattern, str, str]] = [
    (re.compile(r"\A---\n.*?\n---\n", re.S), "frontmatter", "\n\n"),
    (re.compile(r"^(?: {0,3})(```|~~~).*?^(?: {0,3})\1[^\n]*$", re.M | re.S), "fence", "\n\n"),
    (re.compile(r"<!--.*?-->", re.S), "comment", ""),
    # A <style> or <script> body is code, not prose. Without this the CSS inside
    # the vault's HTML diagrams was checked as German, and DIN 5008's rule about a
    # space between number and unit fired on every `top:17px;`.
    (re.compile(r"<(style|script)\b[^>]*>.*?</\1>", re.S | re.I), "htmlblock", "\n\n"),
    (re.compile(r"\$\$.*?\$\$", re.S), "math", "X"),
    # Inline code may wrap across one line break in real markdown, so the
    # pattern has to allow it. Only one, otherwise a stray backtick swallows
    # whole paragraphs.
    (re.compile(r"`[^`\n]*(?:\n[^`\n]*)?`"), "codespan", "KEEP"),
    (re.compile(r"!?\[\[([^\]|]*)(?:\|([^\]]*))?\]\]"), "wikilink", "KEEP"),
    # These two have to beat the bare-URL rules below, and used to sit after them.
    # `https?://\S+` is greedy over non-whitespace, so on `[Titel](https://x)` it
    # swallowed the closing paren, claimed the range, and left `[Titel](` standing
    # as visible text. Every markdown link in a Quellen list then reported
    # UNPAIRED_BRACKETS at error severity, which is why the vault's own notes could
    # never reach a clean run. Consuming the whole `](target)` first also masks
    # non-http schemes such as `onenote:`, which used to cost three errors a link.
    # `(?:\\.|[^)\s])*` rather than `[^)\s]*`, so an escaped paren inside the URL
    # does not end the match early. A Wikipedia link written
    # `…/Betriebsmittel_\(Produktion\) "Betriebsmittel (Produktion)"` otherwise
    # stopped at the escaped `\)`, leaving the title text exposed and its `(`
    # reported as unpaired.
    (re.compile(r"(?<!\\)\]\((?:\\.|[^)\s])*(?:\s+\"[^\"]*\")?\)"), "linktarget", ""),
    (re.compile(r"!?\[(?=[^\]]*\]\()"), "linkopen", ""),
    # The angle autolink keeps its place ahead of the tag rule, so that it still
    # masks to "X" and leaves a token in the sentence rather than a hole.
    (re.compile(r"<https?://[^>\s]+>"), "url", "X"),
    # Two changes here, both about tags the old pattern could not see.
    # `[^>]*` rather than `[^>\n]*`, because a tag in these notes routinely spans
    # several lines: a long `style="…"` attribute is written one declaration per
    # line. It still cannot run away, since the class stops at the first `>`.
    # And this now sits *ahead* of the bare-URL rule. An `xmlns="http://…/svg"`
    # inside an `<svg …>` was being claimed by the URL rule first, which broke the
    # tag's character range so the tag matched nothing, and the `width="100%"`
    # beside it was then checked as German prose against DIN 5008.
    (re.compile(r"<\/?[a-zA-Z][^>]*>"), "html", ""),
    # A bare URL must not swallow the punctuation that follows it. `\S+` did, and
    # `[source: https://…]` then lost its `]`, so LanguageTool reported an unpaired
    # bracket on every one of them. The body allows a balanced `(…)` or `[…]` so
    # that a Wikipedia-style link keeps its closing paren, and the last character
    # may be either an ordinary one or such a group, never loose punctuation.
    (re.compile(r"https?://(?:[^\s()\[\]]|\([^\s()]*\)|\[[^\s\[\]]*\])*"
                r"(?:[^\s.,;:!?()\[\]{}<>'\"]|\([^\s()]*\)|\[[^\s\[\]]*\])"), "url", "X"),
    (re.compile(r"^\s*\|?[\s:|-]*-{3,}[\s:|-]*\|?\s*$", re.M), "tablerule", "\n"),
    (re.compile(r"^\s*(?:[-*_]\s*){3,}$", re.M), "hrule", "\n"),
    (re.compile(r"^#{1,6}[ \t]+", re.M), "headmark", ""),
    (re.compile(r"^\s*>[ \t]?", re.M), "quotemark", ""),
    (re.compile(r"^\s*(?:[-*+]|\d{1,3}[.)])[ \t]+(?:\[[ xX~/-]\][ \t]+)?", re.M), "listmark", ""),
    (re.compile(r"\[\^[^\]]+\]:?"), "footnote", ""),
    (re.compile(r"(?<!\w)#[A-Za-zÄÖÜäöüß][\w/-]*"), "tag", "X"),
    (re.compile(r"\*\*|__|~~"), "emph", ""),
    (re.compile(r"(?<!\w)[*_](?=\S)|(?<=\S)[*_](?!\w)"), "emph", ""),
    (re.compile(r"\|"), "pipe", "\n"),
    (re.compile(r"`[^`\n]*$", re.M), "strayticks", ""),
]

_SUPPRESS_KINDS = {"codespan", "wikilink", "url", "math", "tag", "html",
                   "fence", "frontmatter", "comment"}


def mask_markdown(source: str) -> Masked:
    n = len(source)
    kinds: list[str | None] = [None] * n
    interps: dict[int, str] = {}   # start offset -> interpretAs for that span

    for pattern, kind, interpret in _MASK_PATTERNS:
        for m in pattern.finditer(source):
            s, e = m.span()
            if s == e or any(kinds[i] is not None for i in range(s, e)):
                continue
            for i in range(s, e):
                kinds[i] = kind
            if interpret == "KEEP":
                inner = next((g for g in m.groups() if g), None)
                if inner is None:
                    inner = m.group(0).strip("`")
                interps[s] = inner
            else:
                interps[s] = interpret

    masked = Masked(source=source, is_markup=[k is not None for k in kinds],
                    suppress_orig=[k in _SUPPRESS_KINDS for k in kinds])
    plain_pos = 0
    i = 0
    while i < n:
        k = kinds[i]
        j = i
        while j < n and kinds[j] == k and (k is None or j == i or j not in interps):
            j += 1
        chunk = source[i:j]
        if k is None:
            seg = Segment("text", i, chunk, plain_pos, chunk)
        else:
            replacement = interps.get(i, "")
            seg = Segment("markup", i, chunk, plain_pos, replacement,
                          suppress=k in _SUPPRESS_KINDS)
        masked.segments.append(seg)
        plain_pos += len(seg.plain_text)
        i = j
    return masked


# ---------------------------------------------------------------------------
# Language detection
# ---------------------------------------------------------------------------

_DE_MARKERS = {
    "der", "die", "das", "den", "dem", "des", "ein", "eine", "einer", "eines",
    "und", "oder", "aber", "nicht", "ist", "sind", "wird", "werden", "wurde",
    "auch", "noch", "nur", "schon", "wenn", "dann", "als", "bei", "für",
    "mit", "von", "zu", "aus", "nach", "über", "unter", "durch", "ohne",
    "dass", "weil", "damit", "jedoch", "allerdings", "zudem", "kein", "keine",
    "sich", "sein", "seine", "ihre", "man", "wie", "was", "wo", "sehr",
    "mehr", "viele", "alle", "jede", "beim", "zum", "zur", "im", "am",
}
_EN_MARKERS = {
    "the", "and", "of", "to", "is", "are", "was", "were", "that", "this",
    "these", "those", "with", "from", "for", "have", "has", "had", "will",
    "would", "not", "but", "you", "your", "our", "their", "them", "they",
    "which", "when", "where", "why", "how", "about", "into", "through",
    "there", "here", "than", "then", "each", "any", "all", "one", "it",
}
_WORD_RE = re.compile(r"[A-Za-zÄÖÜäöüßÀ-ÿ']+")


def detect_language(text: str) -> str:
    words = [w.lower() for w in _WORD_RE.findall(text)]
    if not words:
        return ""
    de = sum(1 for w in words if w in _DE_MARKERS)
    en = sum(1 for w in words if w in _EN_MARKERS)
    de += 3 * sum(text.count(c) for c in "äöüßÄÖÜ")
    if de == en:
        return ""
    return "de" if de > en else "en"


@dataclass
class Block:
    start: int
    end: int
    text: str
    lang: str = ""


def language_blocks(masked: Masked, forced: str = "auto") -> list[Block]:
    """Split the source into blocks and label each with a language."""
    src = masked.source
    visible = "".join(
        " " if masked.is_markup[i] else src[i] for i in range(len(src))
    )
    blocks: list[Block] = []
    pos = 0
    for chunk in re.split(r"(\n\s*\n)", src):
        if not chunk:
            continue
        if not chunk.strip():
            pos += len(chunk)
            continue
        blocks.append(Block(pos, pos + len(chunk), visible[pos:pos + len(chunk)]))
        pos += len(chunk)

    if forced in ("de", "en"):
        for b in blocks:
            b.lang = forced
        return blocks

    doc_lang = detect_language(visible) or "en"
    previous = doc_lang
    for b in blocks:
        guess = detect_language(b.text)
        if not guess or len(_WORD_RE.findall(b.text)) < 6:
            guess = previous
        b.lang = guess
        previous = guess
    return blocks


# ---------------------------------------------------------------------------
# Position helpers
# ---------------------------------------------------------------------------

def line_index(source: str) -> list[int]:
    starts = [0]
    for m in re.finditer(r"\n", source):
        starts.append(m.end())
    return starts


def to_line_col(starts: list[int], offset: int) -> tuple[int, int]:
    lo, hi = 0, len(starts) - 1
    while lo < hi:
        mid = (lo + hi + 1) // 2
        if starts[mid] <= offset:
            lo = mid
        else:
            hi = mid - 1
    return lo + 1, offset - starts[lo] + 1


def excerpt_at(source: str, offset: int, length: int = 1, width: int = 34) -> str:
    """A one-line excerpt. Never crosses a line break, so table rows stay readable."""
    line_lo = source.rfind("\n", 0, offset) + 1
    line_hi = source.find("\n", offset)
    line_hi = len(source) if line_hi == -1 else line_hi
    lo = max(line_lo, offset - width)
    hi = min(line_hi, offset + length + width)
    return (("…" if lo > line_lo else "") + source[lo:hi].strip()
            + ("…" if hi < line_hi else ""))


def table_rows(source: str, is_markup: list[bool]) -> set[int]:
    """1-based line numbers that are markdown table rows.

    Cell padding in an aligned table is layout, not prose spacing, so the
    whitespace rules have to leave those lines alone.
    """
    rows: set[int] = set()
    for n, line in enumerate(source.split("\n"), start=1):
        if line.count("|") >= 2 and line.lstrip().startswith("|"):
            rows.add(n)
        elif line.count("|") >= 3:
            rows.add(n)
    return rows


def _is_lone_cell_value(source: str, offset: int) -> bool:
    """True when the character at offset is the entire content of a table cell."""
    lo = max(source.rfind("|", 0, offset), source.rfind("\n", 0, offset)) + 1
    hi = source.find("|", offset)
    nl = source.find("\n", offset)
    if hi == -1 or (nl != -1 and nl < hi):
        hi = nl if nl != -1 else len(source)
    return len(source[lo:hi].strip()) == 1


# ---------------------------------------------------------------------------
# Pass 1: deterministic checks
# ---------------------------------------------------------------------------

EM_DASHES = {"—": "em dash", "―": "horizontal bar",
             "⸺": "two-em dash", "⸻": "three-em dash"}

_SPACED_ENDASH = re.compile(r"(?<=\s)–(?=\s)")
_HEADING = re.compile(r"^(#{1,6})[ \t]+(.*)$", re.M)


def check_deterministic(source: str, masked: Masked, blocks: list[Block],
                        starts: list[int]) -> list[Finding]:
    out: list[Finding] = []
    tables = table_rows(source, masked.is_markup)

    def lang_at(offset: int) -> str:
        for b in blocks:
            if b.start <= offset < b.end:
                return b.lang
        return blocks[-1].lang if blocks else "en"

    def add(offset: int, sev: str, rule: str, msg: str, suggestion: str = "",
            length: int = 1) -> None:
        line, col = to_line_col(starts, offset)
        out.append(Finding(line, col, sev, rule, msg,
                           excerpt_at(source, offset, length), suggestion))

    # --- dashes ------------------------------------------------------------
    for i, ch in enumerate(source):
        if ch not in EM_DASHES or masked.is_markup[i]:
            continue
        line, _ = to_line_col(starts, i)
        if line in tables and _is_lone_cell_value(source, i):
            add(i, SEV_WARN, "EM-DASH-CELL",
                f"{EM_DASHES[ch]} as an empty-cell placeholder. Not prose, but it "
                "is still the character we are keeping out of these files.",
                "use – or leave the cell empty")
            continue
        lang = lang_at(i)
        fix = ("replace with a spaced en dash: –"
               if lang == "de" else
               "restructure into a comma, colon, parenthesis or two sentences")
        add(i, SEV_ERROR, "EM-DASH",
            f"{EM_DASHES[ch]} in {'German' if lang == 'de' else 'English'} prose. "
            "This character is never correct here.", fix)

    de_dashes: list[int] = []
    for m in _SPACED_ENDASH.finditer(source):
        i = m.start()
        if masked.is_markup[i]:
            continue
        if lang_at(i) == "de":
            de_dashes.append(i)
        else:
            add(i, SEV_ERROR, "EN-DASH-EN",
                "Spaced en dash as a sentence interrupter in English prose.",
                "restructure into a comma, colon, parenthesis or two sentences")

    # The budget is a property of the document, not of any single dash, so
    # flagging individual dashes past an arbitrary cutoff would be noise.
    # Report it once and point at the paragraphs that actually drive the count.
    de_words = sum(len(_WORD_RE.findall(b.text)) for b in blocks if b.lang == "de")
    budget = max(1, de_words // DE_ENDASH_WORDS_PER_DASH)
    if len(de_dashes) > budget:
        dense = []
        for b in blocks:
            if b.lang != "de":
                continue
            hits = [i for i in de_dashes if b.start <= i < b.end]
            if len(hits) >= 2:
                dense.append((len(hits), to_line_col(starts, b.start)[0]))
        dense.sort(reverse=True)
        where = ", ".join(f"line {ln} ({c}×)" for c, ln in dense[:6])
        add(de_dashes[0], SEV_WARN, "EN-DASH-BUDGET",
            f"{len(de_dashes)} spaced en dashes in {de_words} German words. "
            f"Budget is {budget}, one per {DE_ENDASH_WORDS_PER_DASH}. Each one is "
            "correct German, but at this density the Gedankenstrich stops being a "
            "device and becomes the default rhythm."
            + (f" Densest: {where}." if dense else ""),
            f"rewrite about {len(de_dashes) - budget} of them as commas, colons "
            "or sentence breaks")

    # --- emoji -------------------------------------------------------------
    heading_spans: list[tuple[int, int]] = []
    seen_emoji: dict[str, int] = {}

    def _heading_is_code(start: int) -> bool:
        return masked.is_markup[start] and bool(masked.segments) and \
            any(s.kind == "markup" and s.orig_start <= start < s.orig_start + len(s.orig_text)
                and s.orig_text.startswith(("```", "~~~")) for s in masked.segments)

    # The legend exemption below applies to body text, and headings used to be
    # judged without it. But the FiSi guide tags headings the same way it tags
    # rows, with a trailing 🚌 for commute and 🖥️ for desk, and `00 Guide Home`
    # states that legend outright. Every one of those headings was reported as an
    # emoji in the wrong place, and obeying that would have destroyed the marker
    # column the guide is scanned by.
    #
    # The test is the same one the body rule uses, and for the same reason: an
    # emoji that occurs once is decoration, and one that recurs is a marker. It
    # counts occurrences anywhere in the document rather than trailing headings
    # only, because a file may carry a guide-wide marker just once while the
    # legend that defines it lives in another note this run cannot see.
    doc_emoji: dict[str, int] = {}
    for _, cluster in emoji_clusters(source):
        doc_emoji[cluster] = doc_emoji.get(cluster, 0) + 1
    legend_emoji = {e for e, n in doc_emoji.items() if n > 1}

    for m in _HEADING.finditer(source):
        if _heading_is_code(m.start()):
            continue
        text_start = m.start(2)
        heading_spans.append((m.start(), m.end()))
        found = emoji_clusters(m.group(2))
        if not found:
            continue
        if found[0][0] != 0 and found[0][1] in legend_emoji:
            continue
        if found[0][0] != 0:
            add(text_start + found[0][0], SEV_ERROR, "EMOJI-POSITION",
                "Emoji inside a heading but not leading it.",
                "move it to the front: `## ✅ Title`", len(found[0][1]))
        if len(found) > 1:
            add(text_start + found[1][0], SEV_WARN, "EMOJI-COUNT",
                f"{len(found)} emoji in one heading. One label reads as a label, "
                "two read as decoration.", "keep the one that names the section")
        first = found[0][1]
        if first in seen_emoji:
            add(text_start, SEV_WARN, "EMOJI-DUPLICATE",
                f"{first} already labels the heading on line {seen_emoji[first]}. "
                "Repeating it stops it working as a landmark.",
                "pick a different, equally literal icon")
        else:
            seen_emoji[first] = to_line_col(starts, m.start())[0]

    in_heading = [False] * len(source)
    for s, e in heading_spans:
        for i in range(s, e):
            in_heading[i] = True
    # An emoji used once in running text is decoration. The same emoji used
    # repeatedly, or one that also labels a heading, is a deliberate marker:
    # the FiSi guide's 🚌 🖥️ 🇩🇪 legend is the obvious case. Repeating an
    # identical warning twenty times would bury the findings that matter, so
    # systematic markers get one informational line and are left alone.
    body_emoji: dict[str, list[int]] = {}
    for offset, cluster in emoji_clusters(source):
        if in_heading[offset] or masked.is_markup[offset]:
            continue
        body_emoji.setdefault(cluster, []).append(offset)

    for cluster, offsets in body_emoji.items():
        in_headings = cluster in seen_emoji
        # Repetition of one identical marker is systematic. Decoration varies.
        if in_headings or len(offsets) >= 2:
            reason = ("also labels a heading here, so it reads as a pointer to "
                      "that section" if in_headings else
                      f"appears {len(offsets)}× in body text, so it reads as a "
                      "legend rather than decoration")
            add(offsets[0], SEV_NOTE, "EMOJI-LEGEND",
                f"{cluster} {reason}. Left alone.",
                "no action unless you meant it as decoration", len(cluster))
            continue
        for offset in offsets:
            add(offset, SEV_WARN, "EMOJI-BODY",
                f"{cluster} outside a heading. Emoji label sections here, they "
                "are not inline punctuation.",
                "move it to the nearest heading, or drop it", len(cluster))

    # --- German typography -------------------------------------------------
    for m in re.finditer(r"(\d)(%|‰|°C|°F|€|kg|km|MB|GB|TB)", source):
        i = m.start(1)
        if masked.is_markup[i] or lang_at(i) != "de":
            continue
        add(i, SEV_ERROR, "DE-UNIT-SPACE",
            f"German typography puts a space between number and unit: "
            f"{m.group(1)} {m.group(2)}.",
            f"{m.group(1)} {m.group(2)}", len(m.group(0)))

    for m in re.finditer(r"\b\d{1,3},\d{3}\b(?!\d)", source):
        i = m.start()
        if masked.is_markup[i] or lang_at(i) != "de":
            continue
        add(i, SEV_WARN, "DE-THOUSANDS",
            "Looks like an English thousands separator in German text. "
            "German writes 5.000, not 5,000.",
            m.group(0).replace(",", "."), len(m.group(0)))

    # Only fire when a real unit follows, and never inside a version number
    # or an IP address, which is why both sides are fenced off.
    _units = r"%|‰|°C|°F|€|EUR|kg|g|km|m|cm|mm|GB|MB|TB|KB|Mbit|Gbit|h|min|s"
    for m in re.finditer(rf"(?<![\d.\w])\d+\.\d+(?![\d.])\s*(?:{_units})\b", source):
        i = m.start()
        if masked.is_markup[i] or lang_at(i) != "de":
            continue
        number = re.match(r"\d+\.\d+", m.group(0)).group(0)
        add(i, SEV_WARN, "DE-DECIMAL",
            "Decimal point in German text. German uses the comma: 3,5.",
            number.replace(".", ","), len(m.group(0)))

    for m in re.finditer(r"\b(z\.B\.|d\.h\.|u\.a\.|u\.U\.|i\.d\.R\.|z\.T\.)", source):
        i = m.start()
        if masked.is_markup[i] or lang_at(i) != "de":
            continue
        spaced = m.group(0).replace(".", ". ").rstrip()
        add(i, SEV_WARN, "DE-ABBREV-SPACE",
            f"DIN 5008 spaces multi-part abbreviations: {spaced}",
            spaced, len(m.group(0)))

    # --- spacing and quotes ------------------------------------------------
    for m in re.finditer(r"\S  +\S", source):
        i = m.start() + 1
        if masked.is_markup[i] or to_line_col(starts, i)[0] in tables:
            continue
        add(i, SEV_WARN, "DOUBLE-SPACE", "More than one space between words.",
            "single space", len(m.group(0)))

    for m in re.finditer(r"[ \t]+([,;:!?](?:[ \t]|$))", source, re.M):
        i = m.start()
        if masked.is_markup[i] or to_line_col(starts, i)[0] in tables:
            continue
        if lang_at(i) not in ("de", "en"):
            continue
        add(i, SEV_ERROR, "SPACE-BEFORE-PUNCT",
            "Space before punctuation.", m.group(1).strip(), len(m.group(0)))

    typographic = len(re.findall(r"[„“”]", source))
    straight = len(re.findall(r'"', source))
    if typographic and straight > 2:
        add(source.find('"'), SEV_WARN, "QUOTE-MIX",
            f"Both typographic quotes ({typographic}) and straight quotes "
            f"({straight}) in one document. Pick one and hold it.",
            "„…“ for polished German, straight quotes for notes")

    # --- phrasing ----------------------------------------------------------
    lowered = source.lower()
    # Shorter entries match inside longer ones ("seamless" inside
    # "seamlessly"), so collect first and keep only the longest hit that
    # starts at each position.
    phrase_hits: dict[int, tuple[int, str]] = {}
    for lang, phrases in (("en", AI_PHRASES_EN), ("de", AI_PHRASES_DE)):
        for phrase, why in phrases:
            for m in re.finditer(re.escape(phrase), lowered):
                i = m.start()
                if masked.is_markup[i] or lang_at(i) != lang:
                    continue
                if i not in phrase_hits or len(phrase) > phrase_hits[i][0]:
                    phrase_hits[i] = (len(phrase), why)
    for i, (length, why) in sorted(phrase_hits.items()):
        add(i, SEV_WARN, "AI-PHRASE",
            f"“{source[i:i + length]}” reads as machine prose. {why}",
            "", length)

    glue_hits = [m.start() for w in DE_GLUE_WORDS
                 for m in re.finditer(re.escape(w), lowered)
                 if not masked.is_markup[m.start()] and lang_at(m.start()) == "de"]
    if len(glue_hits) >= 3:
        for i in sorted(glue_hits)[2:]:
            add(i, SEV_WARN, "DE-GLUE",
                f"{len(glue_hits)} additive connectives in one document. "
                "Used this often they stop connecting and start padding.",
                "drop it, or replace with a real logical link")

    out.sort(key=lambda f: (f.line, f.col))
    return out


# ---------------------------------------------------------------------------
# Pass 2: LanguageTool
# ---------------------------------------------------------------------------

# The user's own list of accepted words, a word per line, `#` comments. On a
# ravnix host ravnix-dict keeps it (ravnix.dictionary.paths.prose). The list
# beside the skill ships with it and is read only when the user has none; it
# holds no one's words.
BUNDLED_DICT = Path(__file__).resolve().parent.parent / "dictionary.txt"
CLOUD_PREMIUM = "https://api.languagetoolplus.com"
CLOUD_FREE = "https://api.languagetool.org"
MAX_CHUNK = 18000        # under the free-tier ceiling, safe on either plan

# The Premium key is the password of a Bitwarden item, its account the item's
# username, read with rbw. The skill value `prose.languagetool.item` names
# the item, by name or id. No file holds the key: not either repository and
# not the disk. A key in the environment (LANGUAGETOOL_API_KEY, which
# ravnix.shell.secretEnv can put there from the same vault) wins.
ITEM_KEY = "prose.languagetool.item"


def user_dictionary() -> Path:
    config = os.environ.get("XDG_CONFIG_HOME") or str(Path.home() / ".config")
    return Path(config) / "prose" / "dictionary.txt"


def dictionary_files() -> list[Path]:
    """The user's list when it exists, else the one that ships with the skill."""
    mine = user_dictionary()
    return [mine] if mine.is_file() else [BUNDLED_DICT]


def _run(cmd: list[str], timeout: int = 20) -> tuple[int, str, str]:
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout.strip(), p.stderr.strip()
    except FileNotFoundError:
        return 127, "", "not installed"
    except Exception as e:                        # noqa: BLE001
        return 126, "", f"{type(e).__name__}: {e}"


def from_bitwarden(allow_unlock: bool = False) -> tuple[dict, str]:
    """Read the key from the Bitwarden item the skill values name, via rbw.

    Probing with `rbw unlocked` first keeps an unattended run from blocking
    on a pinentry prompt forever.
    """
    item = sv.get(ITEM_KEY)
    if not item:
        return {}, f"{sv.Missing(ITEM_KEY)} to use LanguageTool Premium"
    if not shutil.which("rbw"):
        return {}, "rbw not installed"
    if _run(["rbw", "unlocked"])[0] != 0 and not allow_unlock:
        return {}, "vault locked, run `rbw unlock` or pass --unlock"
    rc, out, err = _run(["rbw", "get", "--full", item], timeout=90)
    if rc != 0:
        detail = err or "item not found"
        return {}, f"rbw: {detail[:80]}"
    lines = out.splitlines()
    creds = {"LANGUAGETOOL_API_KEY": lines[0].strip()} if lines else {}
    for line in lines[1:]:
        if line.lower().startswith("username:"):
            creds["LANGUAGETOOL_USERNAME"] = line.split(":", 1)[1].strip()
    return creds, f"from the Bitwarden item named by {ITEM_KEY}"


def load_credentials(allow_unlock: bool = False) -> tuple[dict, list[str]]:
    """Resolve credentials: the environment over the Bitwarden item."""
    creds: dict[str, str] = {}
    trail: list[str] = []

    found, note = from_bitwarden(allow_unlock)
    trail.append(f"bitwarden: {note}")
    creds.update({k: v for k, v in found.items() if v})

    env_hits = []
    for key in ("LANGUAGETOOL_USERNAME", "LANGUAGETOOL_API_KEY",
                "LANGUAGETOOL_SERVER"):
        if os.environ.get(key):
            creds[key] = os.environ[key]
            env_hits.append(key)
    if env_hits:
        trail.insert(0, f"environment: overrides {', '.join(env_hits)}")

    return {k: v for k, v in creds.items() if v}, trail


def load_dictionary() -> set[str]:
    words = set(IGNORE_WORDS)
    for path in dictionary_files():
        try:
            text = path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for raw in text.splitlines():
            w = raw.strip()
            if w and not w.startswith("#"):
                words.add(w)
    return words


@dataclass
class Backend:
    url: str
    label: str
    username: str = ""
    api_key: str = ""

    @property
    def premium(self) -> bool:
        return bool(self.username and self.api_key)


def lt_post(backend: Backend, payload: dict, timeout: int = 30,
            retries: int = 2) -> dict:
    """POST to /v2/check, retrying the transient failures.

    Rate limiting is the common one: premium allows 80 requests a minute and a
    long document chunked across several requests can brush that. A retried
    429 is invisible; an unretried one silently removes findings from the
    report, which is worse than being slow.
    """
    import time
    body = dict(payload)
    if backend.premium:
        body["username"] = backend.username
        body["apiKey"] = backend.api_key
    data = urllib.parse.urlencode(body).encode("utf-8")
    req = urllib.request.Request(
        backend.url.rstrip("/") + "/v2/check", data=data,
        headers={"Content-Type": "application/x-www-form-urlencoded",
                 "Accept": "application/json",
                 "User-Agent": "prose-skill/1.0"},
    )
    last: Exception | None = None
    for attempt in range(retries + 1):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as e:
            last = e
            if e.code not in (429, 500, 502, 503, 504) or attempt == retries:
                raise
        except (TimeoutError, urllib.error.URLError) as e:
            last = e
            if attempt == retries:
                raise
        time.sleep(2 * (attempt + 1))
    raise last if last else RuntimeError("unreachable")


def probe(backend: Backend, timeout: int = 12) -> tuple[bool, str]:
    try:
        res = lt_post(backend, {"text": "This are a test.", "language": "en-US"},
                      timeout=timeout)
    except urllib.error.HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:200].strip()
        return False, f"HTTP {e.code} {e.reason}. {detail}"
    except Exception as e:                       # noqa: BLE001
        return False, f"{type(e).__name__}: {e}"
    n = len(res.get("matches", []))
    status = res.get("software", {})
    # software.premium only says the build *can* do premium rules. premiumHint
    # is present exactly when the answer did not use them, so that is the
    # field to trust. Reporting the other one would overstate what you get.
    got_premium = not status.get("premiumHint")
    tier = "premium rules active" if got_premium else "free rules only"
    return True, (f"ok, {n} match(es) on the probe sentence, "
                  f"LanguageTool {status.get('version', '?')}, {tier}")


def resolve_backends(creds: dict) -> list[Backend]:
    chain: list[Backend] = []
    if creds.get("LANGUAGETOOL_SERVER"):
        chain.append(Backend(creds["LANGUAGETOOL_SERVER"], "self-hosted"))
    if creds.get("LANGUAGETOOL_API_KEY") and creds.get("LANGUAGETOOL_USERNAME"):
        chain.append(Backend(CLOUD_PREMIUM, "premium cloud",
                             creds["LANGUAGETOOL_USERNAME"],
                             creds["LANGUAGETOOL_API_KEY"]))
    chain.append(Backend(CLOUD_FREE, "free cloud"))
    return chain


LT_CODES = {"de": "de-DE", "en": "en-US"}


def language_runs(blocks: list[Block], length: int) -> list[tuple[int, int, str]]:
    """Merge blocks into contiguous single-language spans covering the source.

    Sending a mixed document under one language code is the failure that
    matters here: English paragraphs checked as German get German grammar
    rules and no English spellcheck at all.
    """
    if not blocks:
        return [(0, length, "en")]
    runs: list[list] = []
    for b in blocks:
        if runs and runs[-1][2] == b.lang:
            runs[-1][1] = b.end
        else:
            runs.append([b.start, b.end, b.lang])
    runs[0][0] = 0
    for i in range(len(runs) - 1):
        runs[i][1] = runs[i + 1][0]
    runs[-1][1] = length
    return [(a, b, c or "en") for a, b, c in runs]


def chunk_annotations(annotations: list[dict], base: int, limit: int = MAX_CHUNK):
    """Yield (annotation slice, source offset where that slice starts)."""
    batch: list[dict] = []
    size = 0
    offset = base
    for ann in annotations:
        piece = ann.get("text") or ann.get("markup") or ""
        if size + len(piece) > limit and batch:
            yield batch, offset
            offset += size
            batch, size = [], 0
        batch.append(ann)
        size += len(piece)
    if batch:
        yield batch, offset


def run_languagetool(masked: Masked, blocks: list[Block], starts: list[int],
                     backends: list[Backend], dictionary: set[str],
                     picky: bool, tables: set[int] | None = None
                     ) -> tuple[list[Finding], str, str]:
    """Return (findings, backend label, note). Empty label means nothing ran."""
    source = masked.source
    tables = tables if tables is not None else table_rows(source, masked.is_markup)

    chosen: Backend | None = None
    note = ""
    for backend in backends:
        ok, detail = probe(backend)
        if ok:
            chosen = backend
            note = f"{backend.label}: {detail}"
            break
        note = f"{backend.label} unavailable ({detail})"
    if chosen is None:
        return [], "", note

    findings: list[Finding] = []
    dictionary_cf = {w.casefold() for w in dictionary}
    for run_lo, run_hi, lang in language_runs(blocks, len(source)):
        annotations = masked.annotations_for(run_lo, run_hi)
        if not annotations:
            continue
        for batch, chunk_start in chunk_annotations(annotations, run_lo):
            chunk_text = "".join(a.get("text") or a.get("markup") or ""
                                 for a in batch)
            prefix = utf16_prefix(chunk_text)
            payload = {
                "data": json.dumps({"annotation": batch}, ensure_ascii=False),
                "language": LT_CODES.get(lang, "en-US"),
                "disabledRules": ",".join(LT_DISABLED_RULES),
                "level": "picky" if picky else "default",
            }
            try:
                res = lt_post(chosen, payload)
            except Exception as e:                # noqa: BLE001
                # A dropped chunk means part of the document went unchecked.
                # Reporting that as a note and exiting 0 would let an
                # incomplete run read as a clean one, so it becomes a real
                # error that fails the run and names the lines it skipped.
                first = to_line_col(starts, chunk_start)[0]
                last_line = to_line_col(
                    starts, min(len(source) - 1,
                                chunk_start + len(chunk_text)))[0]
                note += f" | chunk failed: {type(e).__name__}: {e}"
                findings.append(Finding(
                    first, 1, SEV_ERROR, "LT-CHUNK-FAILED",
                    f"Lines {first} to {last_line} were never checked: "
                    f"{type(e).__name__}: {str(e)[:80]}. This run is "
                    "incomplete, so a clean result here would be misleading.",
                    "", "re-run, and if it repeats use --no-lt knowingly "
                        "rather than trusting a partial pass"))
                continue

            for match in res.get("matches", []):
                orig = chunk_start + utf16_to_codepoint(prefix, match.get("offset", 0))
                length = match.get("length", 1)
                rule = match.get("rule", {})
                rule_id = rule.get("id", "LT")
                category = rule.get("category", {}).get("id", "")
                issue = rule.get("issueType", "")
                ctx = match.get("context", {})
                flagged = ctx.get("text", "")[
                    ctx.get("offset", 0):ctx.get("offset", 0) + ctx.get("length", 0)]
                is_suggestion = rule_id.startswith(LT_SUGGESTION_PREFIXES)

                if rule_id.startswith(LT_AD_PREFIXES):
                    continue
                if masked.suppressed(orig, length):
                    continue

                # Key the dictionary filter on issueType, not on the rule name
                # or category. PERSONALIZED_SPELLER_RULE is filed under MISC
                # while plainly being a spelling rule, so any list of names or
                # categories will keep springing leaks as LanguageTool adds
                # rules. issueType is the property that actually means this.
                word = flagged.strip().strip(".,;:()[]„“”\"'")
                if (issue in ("misspelling", "typographical")
                        or rule_id in LT_SPELLING_RULES
                        or category in LT_CASING_CATEGORIES):
                    if word.casefold() in dictionary_cf:
                        continue

                # Table cells are fragments, not sentences. The premium
                # spacing and comma rules read a row as running prose and
                # suggest turning `| 3 copies | Live data |` into
                # `3 copies: live`, which would corrupt the table.
                if is_suggestion and to_line_col(starts, orig)[0] in tables:
                    continue

                # Cheap correctness check on the offset arithmetic. If the
                # flagged string is not where we computed, say so rather than
                # printing a confident wrong line number.
                if flagged and source[orig:orig + len(flagged)] != flagged:
                    near = source.find(flagged, max(0, orig - 200), orig + 200)
                    if near == -1:
                        continue
                    orig = near

                line, col = to_line_col(starts, orig)
                sev = SEV_WARN if is_suggestion else (
                    SEV_ERROR if issue in ("grammar", "misspelling",
                                           "typographical") else SEV_WARN)
                repl = ", ".join(r["value"] for r in match.get("replacements", [])[:3])
                findings.append(Finding(
                    line, col, sev, f"LT:{rule_id}",
                    match.get("message", "").rstrip("."),
                    excerpt_at(source, orig, max(length, 1)), repl))

    findings.sort(key=lambda f: (f.line, f.col))
    return findings, chosen.label, note


# ---------------------------------------------------------------------------
# hunspell fallback (English spelling only, when LanguageTool is unreachable)
# ---------------------------------------------------------------------------

def hunspell_available() -> bool:
    return subprocess.run(["which", "hunspell"], capture_output=True).returncode == 0


def run_hunspell(masked: Masked, blocks: list[Block], starts: list[int],
                 dictionary: set[str]) -> list[Finding]:
    if not hunspell_available():
        return []
    text = "".join(
        " " if masked.is_markup[i] else masked.source[i]
        for i in range(len(masked.source))
    )
    try:
        proc = subprocess.run(["hunspell", "-d", "en_US", "-a"], input=text,
                              capture_output=True, text=True, timeout=30)
    except Exception:                             # noqa: BLE001
        return []
    findings: list[Finding] = []
    line_no = 0
    seen: set[tuple[int, str]] = set()
    for out_line in proc.stdout.splitlines():
        if not out_line.strip():
            line_no += 1
            continue
        if out_line[0] in "&#":
            parts = out_line.split()
            word = parts[1]
            if word in dictionary or not word.isalpha():
                continue
            if (line_no, word) in seen:
                continue
            seen.add((line_no, word))
            findings.append(Finding(
                line_no + 1, 1, SEV_WARN, "HUNSPELL",
                f"Unknown word “{word}” (hunspell fallback, "
                "LanguageTool was unreachable)", "", ""))
    return findings


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

COLOR = sys.stdout.isatty() and os.environ.get("NO_COLOR") is None
_C = {"error": "\033[31m", "warning": "\033[33m", "note": "\033[36m",
      "dim": "\033[2m", "bold": "\033[1m", "off": "\033[0m"}


def paint(text: str, key: str) -> str:
    return f"{_C[key]}{text}{_C['off']}" if COLOR else text


def report(path: str, findings: list[Finding], backend_note: str) -> tuple[int, int]:
    errors = sum(1 for f in findings if f.severity == SEV_ERROR)
    warns = sum(1 for f in findings if f.severity == SEV_WARN)
    print(paint(path, "bold"))
    if backend_note:
        print("  " + paint(backend_note, "dim"))
    if not findings:
        print("  " + paint("clean", "note"))
    for f in findings:
        loc = f"{f.line}:{f.col}"
        print(f"  {loc:>9}  {paint(f.severity.ljust(7), f.severity)}  "
              f"{f.rule:<22} {f.message}")
        if f.excerpt:
            print(f"  {'':>9}  {paint(f.excerpt, 'dim')}")
        if f.suggestion:
            print(f"  {'':>9}  {paint('→ ' + f.suggestion, 'dim')}")
    print(f"  {errors} error(s), {warns} warning(s), "
          f"{len(findings) - errors - warns} note(s)\n")
    return errors, warns


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def check_text(source: str, lang: str, use_lt: bool, picky: bool,
               allow_unlock: bool = False) -> tuple[list[Finding], str]:
    masked = mask_markdown(source)
    blocks = language_blocks(masked, lang)
    starts = line_index(source)
    findings = check_deterministic(source, masked, blocks, starts)
    note = ""
    if use_lt:
        creds, _trail = load_credentials(allow_unlock)
        dictionary = load_dictionary()
        lt_findings, label, note = run_languagetool(
            masked, blocks, starts, resolve_backends(creds), dictionary, picky)
        if label:
            findings.extend(lt_findings)
        else:
            findings.extend(run_hunspell(masked, blocks, starts, dictionary))
    langs = sorted({b.lang for b in blocks if b.lang})
    note = (f"language: {', '.join(langs) or 'unknown'}"
            + (f" | {note}" if note else ""))
    findings.sort(key=lambda f: (f.line, f.col, f.rule))
    return findings, note


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("files", nargs="*", help="files to check")
    ap.add_argument("--stdin", action="store_true", help="read from stdin")
    ap.add_argument("--lang", default="auto", choices=["auto", "de", "en"])
    ap.add_argument("--no-lt", action="store_true", help="skip LanguageTool")
    ap.add_argument("--picky", action="store_true",
                    help="LanguageTool picky mode, for text that must be formal")
    ap.add_argument("--json", action="store_true", dest="as_json")
    ap.add_argument("--strict", action="store_true",
                    help="warnings fail the run too")
    ap.add_argument("--selftest", action="store_true",
                    help="report where credentials come from and which backend answers")
    ap.add_argument("--unlock", action="store_true",
                    help="allow an interactive Bitwarden unlock prompt")
    args = ap.parse_args()

    if args.selftest:
        creds, trail = load_credentials(args.unlock)
        print(paint("Credential sources, strongest first", "bold"))
        for line in trail:
            print(f"  {line}")
        print()
        print(paint("Resolved", "bold"))
        print(f"  username      : {creds.get('LANGUAGETOOL_USERNAME', '(unset)')}")
        key = creds.get("LANGUAGETOOL_API_KEY", "")
        print(f"  api key       : "
              f"{'set, ' + str(len(key)) + ' chars' if key else '(unset)'}")
        print(f"  self-hosted   : {creds.get('LANGUAGETOOL_SERVER', '(unset)')}")
        mine = user_dictionary()
        print(f"  personal dict : {mine} "
              f"({'found' if mine.is_file() else 'not present, the shipped list instead'})")
        print()
        for backend in resolve_backends(creds):
            ok, detail = probe(backend)
            mark = paint("PASS", "note") if ok else paint("FAIL", "error")
            print(f"  {mark}  {backend.label:<14} {backend.url}")
            print(f"        {paint(detail, 'dim')}")
        return 0

    sources: list[tuple[str, str]] = []
    if args.stdin:
        sources.append(("<stdin>", sys.stdin.read()))
    for f in args.files:
        p = Path(f)
        if not p.is_file():
            print(f"not a file: {f}", file=sys.stderr)
            return 2
        sources.append((f, p.read_text(encoding="utf-8")))
    if not sources:
        ap.print_help()
        return 2

    payload = []
    total_err = total_warn = 0
    for name, text in sources:
        findings, note = check_text(text, args.lang, not args.no_lt, args.picky,
                                    args.unlock)
        if args.as_json:
            payload.append({"file": name, "note": note,
                            "findings": [f.as_dict() for f in findings]})
        else:
            e, w = report(name, findings, note)
            total_err += e
            total_warn += w

    if args.as_json:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        total_err = sum(1 for d in payload for f in d["findings"]
                        if f["severity"] == SEV_ERROR)
        total_warn = sum(1 for d in payload for f in d["findings"]
                         if f["severity"] == SEV_WARN)

    if total_err or (args.strict and total_warn):
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
