#!/usr/bin/env python3
"""Lint the vault's `AI/` area: memory notes, archived notes and session notes.

    lint.py [--vault PATH] [--summary]

Prints one `LEVEL rel: message` line per finding and exits 1 on any ERROR,
else 0, so a caller such as vault-check can count the lines by their prefix.

AI/memory and AI/archive answer for every memory rule. AI/sessions answers
only for what a session note has: flat frontmatter, `type: session`, a
description, an `updated` date and known domains. Session notes carry no
status, no tags and no size cap. The secrets heuristic and markdownlint-cli2
cover all three folders. The heuristic flags private addresses anywhere, URLs
included, and token-like runs only outside URLs.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

from notes import (
    ARCHIVE_DIR,
    KINDS,
    MEMORY_DIR,
    PINNED,
    SESSIONS_DIR,
    Note,
    line,
    load_domains,
    load_notes,
    vault_root,
)
from retrieve import PINNED_BUDGET, SYMPTOM_MIN, symptoms

SOFT_CAP = 2048
HARD_CAP = 6144
DESCRIPTION_CAP = 250
STATUSES = ("active", "superseded")

MDLINT_DEFAULT = "~/.local/share/nvim/mason/bin/markdownlint-cli2"
MDLINT_TIMEOUT = 120
FOLDERS = (MEMORY_DIR, SESSIONS_DIR, ARCHIVE_DIR)
# Globs, never file names: markdownlint-cli2 reads every argument as a glob,
# and a parenthesis in a session title would break a file name.
MDLINT_GLOBS = tuple(f"{folder}/**/*.md" for folder in FOLDERS)
# What markdownlint-cli2 v0.23.3 prints to stderr for each finding, with the
# path relative to its working directory:
#   AI/memory/x.md:5:81 error MD013/line-length Line length [...]
# The column and the severity are optional. The banner goes to stdout.
_MDLINT_LINE = re.compile(
    r"(?P<rel>.+?\.md):(?P<line>\d+)(?::(?P<column>\d+))?"
    r"(?: (?:error|warning))? (?P<rule>\S+) (?P<text>.*)"
)

_URL = re.compile(r"[A-Za-z][A-Za-z0-9+.-]*://\S+")
_IPV4 = re.compile(r"(?<![\d.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?!\.?\d)")
_RUN = re.compile(r"[A-Za-z0-9_-]{32,}")
_SEGMENT_MIN = 20


@dataclass(frozen=True)
class Finding:
    level: str  # "ERROR" or "WARN"
    rel: str
    message: str


def lint_vault(vault: Path, domains: dict[str, list[str]]) -> list[Finding]:
    """Every finding for the area, grouped by note, ERRORs first."""
    findings: list[Finding] = []
    pinned: list[Note] = []
    for folder in FOLDERS:
        notes, problems = load_notes(vault / folder, vault)
        findings += [Finding("ERROR", rel, message) for rel, message in problems]
        for note in notes:
            if folder == SESSIONS_DIR:
                findings += _session_findings(note, domains)
            else:
                findings += _memory_findings(note, folder, domains)
                if _is_pinned(note):
                    pinned.append(note)
            findings += _secret_findings(note)
    pinned_chars = _block_chars(pinned)
    if pinned_chars > PINNED_BUDGET:
        findings.append(Finding("WARN", MEMORY_DIR,
                                f"the pinned lines take {pinned_chars} characters, "
                                f"over the {PINNED_BUDGET} budget"))
    findings += markdown_findings(vault)
    return sorted(findings, key=lambda f: (f.rel, f.level != "ERROR"))


def _is_pinned(note: Note) -> bool:
    return note.status == "active" and PINNED in note.tags


def _block_chars(notes: list[Note]) -> int:
    return sum(len(line(note)) + 1 for note in notes)


def _shown(note: Note, key: str) -> str:
    raw = note.meta.get(key)
    return "missing" if raw in (None, "") else repr(raw)


def _shared_findings(note: Note, domains: dict[str, list[str]]) -> list[Finding]:
    """The rules a session note and a memory note have in common."""
    out = [Finding("ERROR", note.rel, f"nested key {key}: the frontmatter must be flat")
           for key, value in note.meta.items() if isinstance(value, dict)]
    if not note.description.strip():
        out.append(Finding("ERROR", note.rel, "the description is missing"))
    if note.updated is None:
        out.append(Finding("ERROR", note.rel,
                           f"updated is {_shown(note, 'updated')}, must be a date (YYYY-MM-DD)"))
    if domains:
        out += [Finding("WARN", note.rel, f"unknown domain {domain!r}, not in memory.domains")
                for domain in note.domains if domain not in domains]
    return out


def _type_finding(note: Note, wanted: str) -> list[Finding]:
    if note.meta.get("type") == wanted:
        return []
    return [Finding("ERROR", note.rel, f"type is {_shown(note, 'type')}, must be {wanted}")]


def _session_findings(note: Note, domains: dict[str, list[str]]) -> list[Finding]:
    return _type_finding(note, "session") + _shared_findings(note, domains)


def _memory_findings(note: Note, folder: str, domains: dict[str, list[str]]) -> list[Finding]:
    out = _type_finding(note, "memory") + _shared_findings(note, domains)
    if note.status not in STATUSES:
        out.append(Finding("ERROR", note.rel,
                           f"status is {_shown(note, 'status')}, must be active or superseded"))
    elif note.status == "superseded" and folder != ARCHIVE_DIR:
        out.append(Finding("WARN", note.rel,
                           f"superseded but still here: move it to {ARCHIVE_DIR}"))
    kinds = [tag for tag in note.tags if tag in KINDS]
    if len(kinds) != 1:
        has = ", ".join(kinds) or "none"
        out.append(Finding("ERROR", note.rel,
                           f"needs exactly one kind tag of {', '.join(KINDS)}, has {has}"))
    if len(note.description) > DESCRIPTION_CAP:
        out.append(Finding("WARN", note.rel,
                           f"the description is {len(note.description)} characters, "
                           f"over {DESCRIPTION_CAP}"))
    if "gotcha" in kinds and not symptoms(note.description):
        out.append(Finding("WARN", note.rel,
                           f"a gotcha needs its symptom in backticks in the description, "
                           f"{SYMPTOM_MIN} characters or more"))
    if note.size > HARD_CAP:
        out.append(Finding("ERROR", note.rel, f"{note.size} bytes, over 6 KB ({HARD_CAP})"))
    elif note.size > SOFT_CAP:
        out.append(Finding("WARN", note.rel, f"{note.size} bytes, over 2 KB ({SOFT_CAP})"))
    return out


def _private(octets: tuple[str, ...]) -> bool:
    a, b, *rest = (int(o) for o in octets)
    if max(a, b, *rest) > 255:
        return False
    return a == 10 or (a == 172 and 16 <= b <= 31) or (a == 192 and b == 168)


def _secret_findings(note: Note) -> list[Finding]:
    """WARN on RFC 1918 addresses anywhere, URLs included, and on token-like
    runs outside URLs.

    A run of 32 or more [A-Za-z0-9_-] counts only if one of its `-`/`_`
    segments is 20 characters or more. That spares the UUIDs in every
    provenance line and the kebab-case slugs of memory filenames, and still
    catches API keys, full commit hashes and JWT parts. The message never
    repeats a token, so the lint output does not leak what it found.
    """
    try:
        text = note.path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):  # gone since load_notes read it
        return []
    out = []
    for number, raw in enumerate(text.split("\n"), start=1):
        for match in _IPV4.finditer(raw):
            if _private(match.groups()):
                out.append(Finding("WARN", note.rel,
                                   f"line {number}: private address {match[0]}, "
                                   f"which must not sync to the phone"))
        for match in _RUN.finditer(_URL.sub(" ", raw)):
            if any(len(segment) >= _SEGMENT_MIN for segment in re.split(r"[-_]", match[0])):
                out.append(Finding("WARN", note.rel,
                                   f"line {number}: a {len(match[0])}-character run that may be "
                                   f"a token or secret, starting {match[0][:4]}"))
    return out


def markdown_findings(vault: Path) -> list[Finding]:
    """Run markdownlint-cli2 on the area, from the vault so its config applies.

    Each finding is an ERROR. A binary that is missing or hangs is one WARN,
    since the notes then went unchecked rather than failed. A run that ends
    in an error of its own, such as a broken config, is one ERROR.
    """
    if not any((vault / folder).is_dir() for folder in FOLDERS):
        return []
    binary = str(Path(os.environ.get("AI_MEMORY_MDLINT") or MDLINT_DEFAULT).expanduser())
    tool = "markdownlint-cli2"
    try:
        done = subprocess.run([binary, *MDLINT_GLOBS], cwd=vault, capture_output=True,
                              text=True, encoding="utf-8", errors="replace",
                              timeout=MDLINT_TIMEOUT)
    except subprocess.TimeoutExpired:
        return [Finding("WARN", tool, f"timed out after {MDLINT_TIMEOUT} s, "
                                      f"so the Markdown went unchecked")]
    except OSError as exc:
        return [Finding("WARN", tool, f"not found or not runnable at {binary} ({exc.strerror}), "
                                      f"so the Markdown went unchecked")]
    out = []
    for raw in done.stderr.splitlines():
        match = _MDLINT_LINE.fullmatch(raw)
        if match:
            where = match["line"] + (f":{match['column']}" if match["column"] else "")
            out.append(Finding("ERROR", match["rel"],
                               f"{match['rule']} on line {where}: {match['text']}"))
    if done.returncode != 0 and not (done.returncode == 1 and out):
        first = next((text for text in done.stderr.splitlines() if text.strip()), "no output")
        out.append(Finding("ERROR", tool, f"exited {done.returncode}: {first}"))
    return out


def _plural(count: int, word: str) -> str:
    return f"{count} {word}" if count == 1 else f"{count} {word}s"


def _summary(vault: Path) -> list[str]:
    """Counts for the telemetry report: notes and bytes per folder, kinds in
    AI/memory and the pinned characters against their budget."""
    out = []
    pinned: list[Note] = []
    kinds = dict.fromkeys(KINDS, 0)
    for folder in FOLDERS:
        notes, _ = load_notes(vault / folder, vault)
        out.append(f"{folder}: {_plural(len(notes), 'note')}, "
                   f"{sum(n.size for n in notes)} bytes")
        for note in notes:
            if folder == MEMORY_DIR:
                for tag in note.tags:
                    if tag in kinds:
                        kinds[tag] += 1
            if folder != SESSIONS_DIR and _is_pinned(note):
                pinned.append(note)
    out.append("kinds in AI/memory: " + ", ".join(f"{k} {n}" for k, n in kinds.items()))
    out.append(f"pinned: {_plural(len(pinned), 'note')}, "
               f"{_block_chars(pinned)} of {PINNED_BUDGET} characters")
    return out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Lint the vault's AI area.")
    parser.add_argument("--vault", type=Path,
                        help="the vault (default: AI_MEMORY_VAULT, else the skill value vault.root)")
    parser.add_argument("--summary", action="store_true",
                        help="also print counts: notes per kind, pinned characters, bytes")
    args = parser.parse_args(argv)
    try:
        vault = (args.vault or vault_root()).expanduser()
    except LookupError as exc:
        print(f"{Path(sys.argv[0]).name}: {exc}", file=sys.stderr)
        return 2
    if not vault.is_dir():
        parser.error(f"no vault at {vault}")
    findings = []
    try:
        domains = load_domains()
    except ValueError as exc:
        domains = {}
        findings.append(Finding("ERROR", "memory.domains", str(exc)))
    findings += lint_vault(vault, domains)
    for finding in findings:
        print(f"{finding.level} {finding.rel}: {finding.message}")
    if args.summary:
        print("\n".join(_summary(vault)))
    return 1 if any(f.level == "ERROR" for f in findings) else 0


if __name__ == "__main__":
    sys.exit(main())
