"""Read the memory and session notes in the vault's `AI/` area.

The lint, the retrieval hooks, the session notes and the migration all read
notes through this module, so a note means the same thing to each of them.

The frontmatter reader covers the YAML subset Obsidian writes: top-level
`key: value`, single and double quotes, `[a, b]` flow lists, `- item` block
lists and nested mappings. Obsidian turns `domain: [a, b]` into a block list
whenever it rewrites a note, so both forms read the same. A line outside that
subset raises FrontmatterError instead of being guessed at. So does anything
Obsidian itself could not read: an unquoted value that opens with a backtick
(YAML reserves it) or holds ": ". The lint reports either as an ERROR, so a
note is never missing from the hooks without a word.

Stdlib only, because the hooks import this on every prompt.
"""
from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass
from datetime import date
from pathlib import Path

import skill_values as sv

VAULT_KEY = "vault.root"
DOMAINS_KEY = "memory.domains"

KINDS = ("gotcha", "feedback", "preference", "reference")
PINNED = "pinned"
MEMORY_DIR = "AI/memory"
SESSIONS_DIR = "AI/sessions"
ARCHIVE_DIR = "AI/archive"



class FrontmatterError(ValueError):
    """The text has no frontmatter, or frontmatter this reader cannot read."""


_KEY = re.compile(r"(?P<key>[^\s:#][^:]*?)[ \t]*:(?:[ \t]+(?P<value>.*?))?[ \t]*")
_DOUBLE = re.compile(r'"((?:[^"\\]|\\.)*)"(?:\s+#.*)?')
_SINGLE = re.compile(r"'((?:[^']|'')*)'(?:\s+#.*)?")
_COMMENT = re.compile(r"(?:^|\s+)#.*$")
_FLOW_ITEM = re.compile(
    r"""\s*(?P<item>"(?:[^"\\]|\\.)*"|'(?:[^']|'')*'|[^,"'\[\]{}]*?)\s*(?P<end>[,\]])"""
)
_DATE = re.compile(r"\d{4}-\d{2}-\d{2}")
# Characters YAML reserves at the start of a plain value. A backtick is the one
# a memory description is likely to open with.
_RESERVED = "`@|>&*!%{}[],"


def parse_frontmatter(text: str) -> tuple[dict, str]:
    """Split a note into its frontmatter and its body.

    Scalars come back as str, lists as list[str] and a nested key as a dict.
    The body is everything after the closing `---` line, unchanged.
    """
    lines = text.split("\n")
    if lines[0].rstrip() != "---":
        raise FrontmatterError("no frontmatter: the first line is not ---")
    for end in range(1, len(lines)):
        if lines[end].rstrip() == "---":
            break
    else:
        raise FrontmatterError("the frontmatter is never closed with ---")
    rows = []
    for number, raw in enumerate(lines[1:end], start=2):
        raw = raw.rstrip("\r")
        content = raw.lstrip(" ")
        if not content.strip() or content.startswith("#"):
            continue
        if content.startswith("\t"):
            raise FrontmatterError(f"line {number}: indented with a tab")
        rows.append((number, len(raw) - len(content), content.rstrip()))
    meta, _ = _mapping(rows, 0, 0)
    return meta, "\n".join(lines[end + 1:])


def _is_item(content: str) -> bool:
    return content == "-" or content.startswith("- ")


def _mapping(rows: list, i: int, indent: int) -> tuple[dict, int]:
    """Read the keys at one indentation level, starting at rows[i]."""
    meta: dict = {}
    while i < len(rows):
        number, level, content = rows[i]
        if level < indent:
            break
        if level > indent:
            raise FrontmatterError(f"line {number}: unexpected indentation")
        match = _KEY.fullmatch(content)
        if not match or _is_item(content):
            raise FrontmatterError(f"line {number}: cannot read {content!r}")
        key, value = match["key"], match["value"]
        if key in meta:
            raise FrontmatterError(f"line {number}: {key} appears twice")
        i += 1
        if value:
            meta[key] = _value(value, number)
        elif i < len(rows) and rows[i][1] >= indent and _is_item(rows[i][2]):
            items, item_level = [], rows[i][1]
            while i < len(rows) and rows[i][1] == item_level and _is_item(rows[i][2]):
                items.append(_scalar(rows[i][2][1:], rows[i][0]))
                i += 1
            meta[key] = items
        elif i < len(rows) and rows[i][1] > indent:
            meta[key], i = _mapping(rows, i, rows[i][1])
        else:
            meta[key] = ""
    return meta, i


def _value(raw: str, number: int) -> str | list[str]:
    return _flow_list(raw, number) if raw.startswith("[") else _scalar(raw, number)


def _flow_list(raw: str, number: int) -> list[str]:
    items, pos = [], 1
    while True:
        match = _FLOW_ITEM.match(raw, pos)
        if not match:
            raise FrontmatterError(f"line {number}: cannot read the list {raw!r}")
        if match["item"]:
            items.append(_scalar(match["item"], number))
        pos = match.end()
        if match["end"] == "]":
            break
    if _COMMENT.sub("", raw[pos:]).strip():
        raise FrontmatterError(f"line {number}: text after the list {raw!r}")
    return items


def _scalar(raw: str, number: int) -> str:
    raw = raw.strip()
    if raw.startswith('"'):
        match = _DOUBLE.fullmatch(raw)
        if not match:
            raise FrontmatterError(f"line {number}: cannot read the double-quoted value {raw!r}")
        try:
            return json.loads(f'"{match[1]}"', strict=False)
        except ValueError:  # a YAML escape JSON lacks, such as \x41
            return re.sub(r"\\(.)", r"\1", match[1])
    if raw.startswith("'"):
        match = _SINGLE.fullmatch(raw)
        if not match:
            raise FrontmatterError(f"line {number}: cannot read the single-quoted value {raw!r}")
        return match[1].replace("''", "'")
    raw = _COMMENT.sub("", raw)
    if raw and raw[0] in _RESERVED:
        raise FrontmatterError(f"line {number}: a value that starts with {raw[0]} must be quoted")
    if ": " in raw or raw.endswith(":"):
        raise FrontmatterError(f"line {number}: a value that holds ': ' must be quoted")
    return raw


def _text(value: object) -> str:
    return value if isinstance(value, str) else ""


def _items(value: object) -> list[str]:
    if isinstance(value, list):
        return [item for item in value if isinstance(item, str) and item]
    return [value] if isinstance(value, str) and value else []


@dataclass(frozen=True)
class Note:
    """One note in the area. `rel` is relative to the vault, `title` is the
    filename stem and `size` is the file's length in bytes."""

    path: Path
    rel: str
    title: str
    meta: dict
    body: str
    size: int

    @property
    def status(self) -> str:
        return _text(self.meta.get("status"))

    @property
    def description(self) -> str:
        return _text(self.meta.get("description"))

    @property
    def domains(self) -> list[str]:
        return _items(self.meta.get("domain"))

    @property
    def tags(self) -> list[str]:
        return _items(self.meta.get("tags"))

    @property
    def updated(self) -> date | None:
        value = self.meta.get("updated")
        if not isinstance(value, str) or not _DATE.fullmatch(value):
            return None
        try:
            return date.fromisoformat(value)
        except ValueError:
            return None


def line(note: Note) -> str:
    """A note as one injected line. Every budget measures a block of these as
    `sum(len(l) + 1 for l in lines)`, each line plus its newline."""
    return f"- {note.title}: {note.description}"


def load_notes(folder: Path, vault: Path) -> tuple[list[Note], list[tuple[str, str]]]:
    """Read every `*.md` under `folder`, subfolders included.

    Returns the notes and the problems as (rel, message) pairs. A file that
    cannot be read or parsed is a problem, never a crash. A Nextcloud conflict
    copy is skipped and reported, because it holds a second version of a note
    that someone has to merge. A missing folder, as mid-sync, yields nothing.
    """
    notes: list[Note] = []
    problems: list[tuple[str, str]] = []
    if not folder.is_dir():
        return notes, problems
    for path in sorted(folder.rglob("*.md")):
        rel = path.relative_to(vault).as_posix()
        if "conflicted copy" in path.name.casefold():
            problems.append((rel, "a Nextcloud conflict copy, skipped: merge it into its note"))
            continue
        try:
            data = path.read_bytes()
            meta, body = parse_frontmatter(data.decode("utf-8"))
        except FrontmatterError as exc:
            problems.append((rel, f"the frontmatter does not parse: {exc}"))
            continue
        except (OSError, UnicodeDecodeError) as exc:
            problems.append((rel, f"cannot be read: {exc}"))
            continue
        notes.append(Note(path, rel, path.stem, meta, body, len(data)))
    return notes, problems


def vault_root() -> Path:
    """The vault: `AI_MEMORY_VAULT`, else the skill value `vault.root`.
    Raises skill_values.Missing without both."""
    named = os.environ.get("AI_MEMORY_VAULT")
    return Path(named or sv.require(VAULT_KEY)).expanduser()


def load_domains() -> dict[str, list[str]]:
    """The domain keywords: the file `AI_MEMORY_DOMAINS` names, else the
    skill value `memory.domains`. A missing file or value is {}; one that is
    not an object of keyword lists raises ValueError."""
    named = os.environ.get("AI_MEMORY_DOMAINS")
    if named:
        path = Path(named).expanduser()
        where = str(path)
        try:
            text = path.read_text(encoding="utf-8")
        except FileNotFoundError:
            return {}
        try:
            domains = json.loads(text)
        except ValueError as exc:
            raise ValueError(f"{path} is not valid JSON: {exc}") from None
    else:
        where = f"the skill value {DOMAINS_KEY}"
        domains = sv.get(DOMAINS_KEY, object)
        if domains is None:
            return {}
    if not isinstance(domains, dict) or not all(
        isinstance(words, list) and all(isinstance(w, str) for w in words)
        for words in domains.values()
    ):
        raise ValueError(f"{where} must map each domain to a list of keywords")
    return domains
