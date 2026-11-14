"""Pick the memory notes a hook injects.

    pinned()         the pinned notes, at session start
    match_prompt()   the notes whose words a prompt uses, scored by rarity
    digest()         one domain's notes, the first time a prompt touches it
    match_failure()  the notes whose symptom appears in a tool's error

Pure functions over the notes `notes.load_notes` read, so the hooks do all
the reading, remembering and logging. Only active notes count anywhere, and
`exclude` holds the `rel` paths a session already got. Every budget measures
a block as `sum(len(l) + 1 for l in lines)`, each line plus its newline, and
a note goes in only while that total stays within it. The header is the
hook's and is not counted.

Stdlib only, because the hooks import this on every prompt.
"""
from __future__ import annotations

import math
import re
import unicodedata
from collections import Counter
from datetime import date
from pathlib import Path

from notes import MEMORY_DIR, PINNED, Note, line

__all__ = [
    "DIGEST_BUDGET", "MATCH_BUDGET", "MAX_FAILURE_HITS", "MAX_MATCHES", "MIN_SCORE",
    "PINNED_BUDGET", "STOPWORDS", "SYMPTOM_MIN", "digest", "header", "line",
    "match_failure", "match_prompt", "pinned", "symptoms", "tokens", "touched_domains",
]

PINNED_BUDGET = 4000
MATCH_BUDGET = 1000
DIGEST_BUDGET = 4000
MAX_MATCHES = 4
MAX_FAILURE_HITS = 2
# A word scores ln(N / df): N active notes, df of them holding the word. With
# N about 300, a word in up to about 5 notes fires alone (ln 60 = 4.1), two
# words in 20 notes each fire together (2 ln 15 = 5.4), and a word in 20
# notes never fires alone (ln 15 = 2.7). Under N = 55 (e^4) even a word in
# one note does not. The injection log calibrates this later.
MIN_SCORE = 4.0
SYMPTOM_MIN = 6

# Words a prompt is full of that say nothing about which note applies. Left
# in, one that happens to be rare in the notes fires on its own, and two of
# them fire together. The list covers English function words by class, holds
# every word of 3 characters or more in NLTK's English stopword list but
# `down`, and adds the common prompt verbs, the number words and fillers. A
# verb here comes in all its forms: base, -s, -ed, -ing, and the irregular
# past and participle. `\w+` splits "doesn't" into "doesn" and "t", hence the
# stems, and the spellings without the apostrophe are here too. Measured on
# 2026-10-17 in the titles and descriptions of the old memory store's 374
# notes, where every word that fired alone was sorted into a class or left
# out: 192 of the 277 stopwords that occur there are in 1 to 6 notes, enough
# to fire alone at N = 374 (at N = 300 it takes 1 to 5), and most of the rest
# in up to 55 (`its` 55, `every` 50, `never` 47, `one` 41), enough to fire
# next to a rarer one. Some are commands, flags or states there too (`make`,
# `wait`, `show`, `get`, `help`, `keep`, `last`, `continue`, `yes`, `ahead`,
# `off`, `none`, `bit`, `today`), but no stopword is the only way to find its
# note: every note keeps at least three words that fire alone. Left out on
# purpose: `down`, Uptime Kuma's state in a note's title, `sort`, the command,
# and words that name what a note is about, such as `commit`, `test`, `file`
# and `plan`.
STOPWORDS = frozenset(" ".join((
    # pronouns, possessive and reflexive ones included, and interrogatives
    "you your yours yourself yourselves she her hers herself him his himself"
    " its itself our ours ourselves they them their theirs themselves mine"
    " myself oneself who whom whose whoever what whatever which whichever how"
    " when where why someone somebody anyone anybody everyone everybody nobody"
    " something anything everything nothing none ones",
    # determiners and quantifiers
    "the this that these those all any both each either neither every few"
    " fewer many much more most less least little several some such enough"
    " other others another own same different various plenty whole entire"
    " half twice",
    # prepositions
    "about above across after against along alongside amid among amongst"
    " around before behind below beneath beside besides between beyond despite"
    " during except for from including incl inside into near off onto out"
    " outside over past per regarding regardless since than through throughout"
    " till toward towards under underneath unlike until upon versus via with"
    " within without",
    # conjunctions
    "and but nor yet plus because although though while whilst whereas whether"
    " unless once however therefore thus hence otherwise moreover furthermore"
    " meanwhile instead whenever wherever whereby",
    # auxiliaries and modals, the n't stems, and the forms typed without the
    # apostrophe
    "are was were been being have has had having does did doing done can"
    " cannot could may might must shall should will would ought need needs"
    " needed needing ain aren couldn didn doesn don hadn hasn haven isn mightn"
    " mustn needn shan shouldn wasn weren won wouldn arent cant couldnt didnt"
    " doesnt dont hadnt hasnt havent isnt mightnt mustnt shouldnt wasnt werent"
    " wont wouldnt ive youre youve youll theyre weve thats whats theres heres",
    # verbs a prompt asks with, each in all its forms
    "ask asks asked asking become becomes became becoming change changes"
    " changed changing come comes came coming continue continues continued"
    " continuing get gets got gotten getting give gives gave given giving goes"
    " going went gone happen happens happened happening help helps helped"
    " helping keep keeps kept keeping know knows knew known knowing let lets"
    " letting like likes liked liking look looks looked looking make makes made"
    " making mean means meant meaning put puts putting say says said saying see"
    " sees saw seen seeing seem seems seemed seeming show shows showed shown"
    " showing take takes took taken taking tell tells told telling thank thanks"
    " thanked thanking think thinks thought thinking try tries tried trying use"
    " uses used using wait waits waited waiting want wants wanted wanting work"
    " works worked working",
    # number words from one to twelve
    "one two three four five six seven eight nine ten eleven twelve first"
    " second third fourth fifth sixth seventh eighth ninth tenth eleventh"
    " twelfth",
    # discourse adverbs and fillers
    "absolutely actual actually afterward afterwards again ahead almost alone"
    " already alright also always anymore anyway anyways anywhere apparently"
    " away back basically best better bit btw certainly clearly cool correct"
    " definitely early earlier else elsewhere entirely etc even ever everywhere"
    " exactly far fine further fyi good great hello here hey hmm idea ideas"
    " indeed just kind last later literally lot lots maybe nearly never next"
    " nice nope not now nowhere obvious obviously often okay only opposite"
    " perfect perhaps please possibly pretty probably problem quite rather"
    " really right sense simply somehow sometimes somewhere soon sorry step"
    " steps still stuff supposedly sure then there thing things today tomorrow"
    " tonight too totally truly usual usually very way well worth wrong yeah"
    " yep yes yesterday",
    # German
    "aber alle als auch auf aus bei bis bitte das dass dem den der des die"
    " diese dieser doch durch ein eine einem einen einer für hat ich ist kann"
    " mit nach nicht noch nur oder sich sie sind über und uns von war warum"
    " weil wenn wie wir wird zum zur",
)).split())

_WORD = re.compile(r"\w+")
_BACKTICKED = re.compile(r"`([^`]+)`")

_HEADERS = {
    "pinned": "Pinned memory (notes in {dir}; open one only when its line is not enough):",
    "match": "Memory that may apply to this prompt (notes in {dir}):",
    "digest": "Memory digest for {domain}, most recently verified first (notes in {dir}):",
    "failure": "Memory that may explain this failure (notes in {dir}):",
}


def tokens(text: str) -> set[str]:
    """The words of `text` that can match: runs of word characters in the
    casefolded text, 3 characters or more, minus STOPWORDS.

    NFC comes after the casefold, so a decomposed umlaut, as a filename from
    macOS or iOS may spell it, stays inside its word.
    """
    folded = unicodedata.normalize("NFC", text.casefold())
    return {word for word in _WORD.findall(folded) if len(word) >= 3 and word not in STOPWORDS}


def symptoms(description: str) -> list[str]:
    """The backticked spans of `description` that are SYMPTOM_MIN characters
    or more. Backticks pair up in order, so the text between two short spans
    is never a span. The lint's gotcha rule reads the same spans."""
    return [span for span in _BACKTICKED.findall(description) if len(span) >= SYMPTOM_MIN]


def header(kind: str, vault: Path, domain: str = "") -> str:
    """The line a hook puts above its block: `kind` is pinned, match, digest
    or failure. The memory folder is absolute, with the home directory as ~."""
    folder = Path(vault).expanduser().absolute() / MEMORY_DIR
    home = Path.home()
    shown = ("~/" + folder.relative_to(home).as_posix() if folder.is_relative_to(home)
             else folder.as_posix())
    return _HEADERS[kind].format(dir=shown, domain=domain)


def _active(notes: list[Note]) -> list[Note]:
    return [note for note in notes if note.status == "active"]


def _newest_first(note: Note) -> tuple[int, str]:
    """Sort key: `updated` newest first, a note without a date last, then by path."""
    return (-(note.updated or date.min).toordinal(), note.rel)


def _fit(ranked: list[Note], budget: int, limit: int | None = None) -> list[Note]:
    """The leading notes of `ranked` whose lines stay within `budget`."""
    taken: list[Note] = []
    used = 0
    for note in ranked:
        used += len(line(note)) + 1
        if used > budget or len(taken) == limit:
            break
        taken.append(note)
    return taken


def pinned(notes: list[Note]) -> list[Note]:
    """The active pinned notes, newest first, as many as fit PINNED_BUDGET."""
    chosen = sorted((n for n in _active(notes) if PINNED in n.tags), key=_newest_first)
    return _fit(chosen, PINNED_BUDGET)


def _names(words: set[str], keyword: str) -> bool:
    parts = tokens(keyword)
    return bool(parts) and parts <= words


def touched_domains(words: set[str], domains: dict[str, list[str]]) -> set[str]:
    """The domains one of whose keywords is among `words`, a prompt's tokens.

    A keyword goes through tokens() too, so it matches the way a prompt word
    does, and a keyword of several words, such as `claude-code`, needs every
    one of them. The domain's own name does not count, only its keywords.
    """
    return {name for name, keywords in domains.items()
            if any(_names(words, keyword) for keyword in keywords)}


def _terms(note: Note) -> set[str]:
    """The words a prompt can match in a note. `\\w+` already splits the
    kebab-case title at each `-`."""
    return (tokens(note.title) | tokens(note.description)
            | {tag.casefold() for tag in note.tags}
            | {domain.casefold() for domain in note.domains})


def match_prompt(prompt: str, notes: list[Note], domains: dict[str, list[str]],
                 exclude: set[str], min_score: float = MIN_SCORE) -> list[Note]:
    """The notes the prompt's rare words point at, best first.

    A note scores ln(N / df) for each prompt word among its terms, its
    title, description, tags and domains, and is a hit at `min_score`. Ties
    go to a note in a domain the prompt touched, then to the newer one.
    At most MAX_MATCHES whose lines fit MATCH_BUDGET.
    """
    words = tokens(prompt)
    active = _active(notes)
    shared = [(note, _terms(note) & words) for note in active]
    df = Counter(word for _, common in shared for word in common)
    touched = touched_domains(words, domains)
    hits = []
    for note, common in shared:
        if note.rel in exclude:
            continue
        # sorted(): a fixed order of addition, so a score is the same in every run.
        score = sum(math.log(len(active) / df[word]) for word in sorted(common))
        if common and score >= min_score:
            hits.append((score, note))
    hits.sort(key=lambda hit: (-hit[0], not touched.intersection(hit[1].domains),
                               _newest_first(hit[1])))
    return _fit([note for _, note in hits], MATCH_BUDGET, MAX_MATCHES)


def digest(domain: str, notes: list[Note], exclude: set[str]) -> list[Note]:
    """The domain's active notes not yet injected, most recently verified
    first, as many as fit DIGEST_BUDGET."""
    chosen = sorted((n for n in _active(notes) if domain in n.domains and n.rel not in exclude),
                    key=_newest_first)
    return _fit(chosen, DIGEST_BUDGET)


def match_failure(error: str, notes: list[Note], exclude: set[str]) -> list[Note]:
    """The notes with a symptom that appears in `error`, ignoring case.

    The longest matched symptom is the most specific, so it leads, then the
    newer note. At most MAX_FAILURE_HITS.
    """
    folded = error.casefold()
    hits = []
    for note in _active(notes):
        if note.rel in exclude:
            continue
        found = [span for span in symptoms(note.description) if span.casefold() in folded]
        if found:
            hits.append((max(map(len, found)), note))
    hits.sort(key=lambda hit: (-hit[0], _newest_first(hit[1])))
    return [note for _, note in hits[:MAX_FAILURE_HITS]]
