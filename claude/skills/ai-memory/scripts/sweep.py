#!/usr/bin/env python3
"""The report the planner's Sunday session proposes promotions and archivals from.

    sweep.py report --since YYYY-MM-DD [--vault PATH]

Prints five sections and writes nothing:

Candidates
    Each bullet under `## Memory candidates` in the session notes whose
    `updated` is on or after --since, with every session note it occurs in.
    Text that occurs in two notes or more, case and spacing aside and older
    notes included, is a second occurrence. An archive proposal is no
    candidate.
Archive proposals
    Each bullet of the form `archive [[note]]: why it is wrong` under
    `## Memory candidates` in those same session notes: a session found the
    memory wrong and could not ask the user. With the note, the reason and the
    session note it came from. Recommended when the note is active in
    `AI/memory/`, not recommended when no memory note has that name or it is
    already archived.
Recurring failures without a memory
    The log's `miss` lines grouped by `detail`, kept when two sessions or more
    logged one, at least one of them on or after --since. The whole log
    counts, so a failure that comes back once a month still recurs, and one
    that stopped drops out.
Use
    Injections per note on or after --since, by reason. A path with no note
    behind it, such as a note since renamed or archived, is marked.
Review queue
    Active notes whose `updated` is more than 90 days before today, oldest
    first, with their injections in those 90 days.

Each candidate, each archive proposal and each queued note ends in a
default verdict for the planner's proposal. Nothing here decides: the user
confirms every promotion and every archival in the planner's session.

The log is `state.LOG_FILE` in the ai-memory state root. A log line or a note
that cannot be read is skipped, and one line on stderr counts them; the lint
names the notes. A missing log or folder gives sections that say so.

Stdlib only.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import date, datetime, timedelta
from pathlib import Path

from notes import ARCHIVE_DIR, MEMORY_DIR, SESSIONS_DIR, Note, load_notes, vault_root
from state import LOG_FILE, REASONS, state_root

REVIEW_DAYS = 90
CANDIDATES = "Memory candidates"
_DATE = re.compile(r"\d{4}-\d{2}-\d{2}")
# A bullet at any depth: an indented one is a candidate of its own.
_BULLET = re.compile(r"[ \t]*[-*+][ \t]+(?P<text>.*)")
# The scribe's `→ [[target]]` line and the journal's `%%journal:unsure%%`
# marker sit right under an entry, and neither is part of it.
_MARKS = ("→", "%%")
# An archive proposal: `archive [[note]]: why`, the link bare or with an alias
# or a heading, and the colon optional.
_ARCHIVE = re.compile(r"archive \[\[(?P<name>[^\]|#]*[^\]|#\s][^\]|#]*)(?:[|#][^\]]*)?\]\]"
                      r"[ \t]*:?[ \t]*(?P<why>.*)", re.IGNORECASE)


@dataclass(frozen=True)
class Entry:
    """One line of the injection log, its `ts` cut to the day it was written."""

    day: date
    session: str
    reason: str
    rels: tuple[str, ...]
    detail: str


def read_log(path: Path) -> tuple[list[Entry] | None, int, str]:
    """The log's entries, how many lines were skipped, and an error.

    No log gives None and no error. A log that exists but cannot be read,
    such as a directory or a file without permission, gives None and the
    reason, so the report still prints.
    """
    try:
        text = path.read_text(encoding="utf-8", errors="replace")
    except FileNotFoundError:
        return None, 0, ""
    except OSError as exc:
        return None, 0, exc.strerror or str(exc)
    entries, skipped = [], 0
    for raw in text.splitlines():
        if not raw.strip():
            continue
        entry = _entry(raw)
        if entry is None:
            skipped += 1
        else:
            entries.append(entry)
    return entries, skipped, ""


def _entry(raw: str) -> Entry | None:
    """The line as an Entry, or None when it is not what `state.log` writes."""
    try:
        data = json.loads(raw)
    except ValueError:
        return None
    if not isinstance(data, dict):
        return None
    ts, session, reason, rels, detail = (
        data.get(key) for key in ("ts", "session", "reason", "rels", "detail"))
    if not (isinstance(ts, str) and isinstance(session, str) and isinstance(detail, str)
            and reason in REASONS and isinstance(rels, list)
            and all(isinstance(rel, str) for rel in rels)):
        return None
    try:
        day = datetime.fromisoformat(ts).date()
    except ValueError:
        return None
    return Entry(day, session, reason, tuple(rels), detail)


# Fences, read the way the session-note writer reads them: the journal's
# `daily_note._fence_open_len`, `_fence_closes`, `_fences_balanced` and
# `_block_end`, which `session_note.py` splits its sections with. Backtick
# fences only, on the stripped line; a closing run is at least as long as the
# opening one and holds nothing else; and a scan whose fences do not balance
# ignores fences altogether, so an unclosed fence cannot swallow a heading.

def _fence_open_len(stripped: str) -> int:
    n = len(stripped) - len(stripped.lstrip("`"))
    return n if n >= 3 else 0


def _fence_closes(stripped: str, open_len: int) -> bool:
    return len(stripped) >= open_len and set(stripped) == {"`"}


def _fenced(lines: list[str], start: int, end: int) -> list[bool] | None:
    """For each line from `start` to `end`, whether a fence holds it.

    A fence's own opening and closing lines count as fenced. None when the
    fences in that range do not balance, which means: read it unfenced.
    """
    marks, inside, open_len = [], False, 0
    for raw in lines[start:end]:
        stripped = raw.strip()
        if inside:
            inside = not _fence_closes(stripped, open_len)
            marks.append(True)
        elif n := _fence_open_len(stripped):
            inside, open_len = True, n
            marks.append(True)
        else:
            marks.append(False)
    return None if inside else marks


def _section_end(lines: list[str], start: int) -> int:
    """The next `## ` line after `start`, as the writer's `_block_end` finds it."""
    marks = _fenced(lines, start + 1, len(lines))
    for i in range(start + 1, len(lines)):
        if not (marks and marks[i - start - 1]) and lines[i].startswith("## "):
            return i
    return len(lines)


def candidates(body: str) -> list[str]:
    """The bullets under `## Memory candidates`, each on one line.

    Sections split where the session-note writer splits them. Inside the
    section a fenced line is skipped and ends the bullet before it. A bullet
    at any depth is a candidate, its marker stripped. A non-blank line right
    after a bullet continues it, indented or lazy, unless it is a scribe's
    `→` line or a `%%` marker. A blank line ends it.
    """
    lines = body.splitlines()
    out: list[str] = []
    at = _section_end(lines, -1)
    while at < len(lines):
        end = _section_end(lines, at)
        if lines[at][3:].strip() == CANDIDATES:
            marks = _fenced(lines, at + 1, end) or [False] * (end - at - 1)
            joining = False
            for raw, fenced in zip(lines[at + 1:end], marks):
                bullet = None if fenced else _BULLET.fullmatch(raw)
                text = " ".join((bullet["text"] if bullet else raw).split())
                if bullet and text:
                    out.append(text)
                    joining = True
                elif fenced or not text or text.startswith(_MARKS):
                    joining = False
                elif joining:
                    out[-1] = f"{out[-1]} {text}"
        at = end
    return out


def unclosed_fence(body: str) -> bool:
    """True when the body opens a fence it never closes."""
    lines = body.splitlines()
    return _fenced(lines, 0, len(lines)) is None


def _candidate_lines(sessions: list[Note], since: date) -> list[str]:
    occurs: dict[str, list[str]] = {}  # casefolded text -> the notes it occurs in
    shown: dict[str, str] = {}  # casefolded text -> its text in the first recent note
    for note in sessions:
        texts: dict[str, str] = {}
        for text in candidates(note.body):
            if not _ARCHIVE.fullmatch(text):
                texts.setdefault(text.casefold(), text)
        for key, text in texts.items():
            occurs.setdefault(key, []).append(note.title)
            if note.updated >= since:
                shown.setdefault(key, text)
    lines = []
    for key, text in shown.items():
        where = "; ".join(occurs[key])
        verdict = ("second occurrence | promotion recommended" if len(occurs[key]) >= 2
                   else "first occurrence | promotion not recommended")
        lines.append(f"- {text} | {where} | {verdict}")
    return lines or [f"None: no session note updated since {since} lists a memory candidate."]


def _archive_lines(sessions: list[Note], since: date, memories: list[Note],
                   archived: list[Note]) -> list[str]:
    # Obsidian resolves a link by filename, case aside.
    by_name: dict[str, tuple[str, Note]] = {}
    for where, group in ((ARCHIVE_DIR, archived), (MEMORY_DIR, memories)):
        for note in group:
            by_name[note.title.casefold()] = (where, note)
    lines = []
    for note in sessions:
        if note.updated < since:
            continue
        named: set[str] = set()
        for text in candidates(note.body):
            proposal = _ARCHIVE.fullmatch(text)
            if not proposal:
                continue
            name = proposal["name"].strip()
            if name.casefold() in named:
                continue
            named.add(name.casefold())
            where, target = by_name.get(name.casefold(), ("", None))
            if target is None:
                verdict = "no memory note by that name | archive not recommended"
            elif where == ARCHIVE_DIR:
                verdict = f"already archived in {ARCHIVE_DIR} | archive not recommended"
            elif target.status != "active":
                verdict = (f"its status is {target.status or 'missing'}, not active"
                           " | archive not recommended")
            else:
                verdict = f"the note is active in {MEMORY_DIR} | archive recommended"
            why = proposal["why"] or "no reason given"
            lines.append(f"- {name} | {why} | {note.title} | {verdict}")
    return lines or [f"None: no session note updated since {since} proposes an archival."]


def _failure_lines(entries: list[Entry], since: date) -> list[str]:
    groups: dict[str, list[Entry]] = defaultdict(list)
    for entry in entries:
        if entry.reason == "miss":
            groups[entry.detail].append(entry)
    rows = []
    for detail, misses in groups.items():
        sessions = len({entry.session for entry in misses})
        last = max(entry.day for entry in misses)
        if sessions >= 2 and last >= since:
            rows.append((sessions, last, detail, len(misses)))
    # Most sessions first, then the most recent, then by text.
    rows.sort(key=lambda row: (-row[0], -row[1].toordinal(), row[2]))
    lines = [f"- {detail} | {sessions} sessions, {count} misses, last {last}"
             for sessions, last, detail, count in rows]
    return lines or [f"None: no failure without a memory came up in two sessions, "
                     f"one of them since {since}."]


def _use_lines(entries: list[Entry], since: date, vault: Path) -> list[str]:
    use: dict[str, Counter] = defaultdict(Counter)
    for entry in entries:
        if entry.day >= since:
            for rel in dict.fromkeys(entry.rels):
                use[rel][entry.reason] += 1
    lines = []
    for rel, counts in sorted(use.items(), key=lambda item: (-item[1].total(), item[0])):
        gone = "" if (vault / rel).is_file() else " (no such note)"
        reasons = ", ".join(f"{reason} {counts[reason]}" for reason in REASONS if counts[reason])
        lines.append(f"- {rel}{gone}: {counts.total()} ({reasons})")
    return lines or [f"None: no note was injected since {since}."]


def _queue_lines(active: list[Note], entries: list[Entry], no_log: str,
                 vault: Path, today: date) -> list[str]:
    cutoff = today - timedelta(days=REVIEW_DAYS)
    queue = sorted((note for note in active if note.updated < cutoff),
                   key=lambda note: (note.updated, note.rel))
    if not queue:
        return [f"None: no active note was last updated before {cutoff}."]
    used = Counter(rel for entry in entries if entry.day >= cutoff
                   for rel in dict.fromkeys(entry.rels))
    # What the log cannot show: injections before it starts, and injections
    # under a path that has since gone, as a renamed or moved note leaves.
    lines = []
    first = min((entry.day for entry in entries), default=None)
    if no_log:
        lines.append(f"{no_log[0].upper()}{no_log[1:]}, so no note has a recorded injection.")
    elif first is None:
        lines.append("The injection log holds no entry, so no note has a recorded injection.")
    elif first > cutoff:
        lines.append(f"The log only goes back to {first}, "
                     f"so the injection counts below miss anything before that day.")
    gone = sum(1 for rel in used if not (vault / rel).is_file())
    if gone:
        lines.append(f"Injections in the last {REVIEW_DAYS} days name "
                     f"{_plural(gone, 'path')} with no note, so a renamed or moved note "
                     f"may show no injection here.")
    for note in queue:
        count = used[note.rel]
        if count:
            use = f"{_plural(count, 'injection')} in {REVIEW_DAYS} days"
            verdict = "archive not recommended"
        else:
            use, verdict = f"no injection in {REVIEW_DAYS} days", "archive recommended"
        age = (today - note.updated).days
        lines.append(f"- {note.rel} | updated {note.updated}, {age} days ago | {use} | {verdict}")
    return lines


def _readable(notes: list[Note]) -> tuple[list[Note], int]:
    """The notes with an `updated` date, and how many lack one."""
    dated = [note for note in notes if note.updated is not None]
    return dated, len(notes) - len(dated)


def report(vault: Path, since: date, log: Path) -> tuple[str, list[str]]:
    """The report's text, and the problems for the one stderr line."""
    sessions, problems = load_notes(vault / SESSIONS_DIR, vault)
    sessions, undated = _readable(sessions)
    skipped_notes = len(problems) + undated
    memories, problems = load_notes(vault / MEMORY_DIR, vault)
    active, undated = _readable([note for note in memories if note.status == "active"])
    skipped_notes += len(problems) + undated
    archived, problems = load_notes(vault / ARCHIVE_DIR, vault)
    skipped_notes += len(problems)
    entries, skipped_lines, error = read_log(log)

    stderr = [f"cannot read {log}: {error}"] if error else []
    skipped = [_plural(skipped_lines, "malformed log line")] if skipped_lines else []
    if skipped_notes:
        skipped.append(f"{_plural(skipped_notes, 'note')} it could not read")
    if skipped:
        stderr.append(f"skipped {' and '.join(skipped)}")
    fences = sum(1 for note in sessions if note.updated >= since and unclosed_fence(note.body))
    if fences:
        stderr.append(f"an unclosed code fence in {_plural(fences, 'session note')}, "
                      f"so check the candidates by hand")

    no_log = (f"the injection log at {log} cannot be read ({error})" if error
              else f"there is no injection log at {log}" if entries is None else "")
    sections = {
        "Candidates": _candidate_lines(sessions, since),
        "Archive proposals": _archive_lines(sessions, since, memories, archived),
        "Recurring failures without a memory":
            [f"None: {no_log}."] if no_log else _failure_lines(entries, since),
        "Use": [f"None: {no_log}."] if no_log else _use_lines(entries, since, vault),
        "Review queue": _queue_lines(active, entries or [], no_log, vault, date.today()),
    }
    text = "\n\n".join(f"## {name}\n\n" + "\n".join(lines) for name, lines in sections.items())
    return text, stderr


def _plural(count: int, word: str) -> str:
    return f"{count} {word}" if count == 1 else f"{count} {word}s"


def _day(value: str) -> date:
    try:
        if _DATE.fullmatch(value):
            return date.fromisoformat(value)
    except ValueError:
        pass
    raise argparse.ArgumentTypeError(f"not a date (YYYY-MM-DD): {value!r}")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="The Sunday sweep's report for the planner.")
    commands = parser.add_subparsers(dest="command", required=True)
    command = commands.add_parser("report", help="print the five sections, write nothing")
    command.add_argument("--since", required=True, type=_day,
                         help="the first day counted, YYYY-MM-DD (last Sunday)")
    command.add_argument("--vault", type=Path,
                         help="the vault (default: AI_MEMORY_VAULT, else the skill value vault.root)")
    args = parser.parse_args(argv)
    try:
        vault = (args.vault or vault_root()).expanduser()
    except LookupError as exc:
        print(f"{Path(sys.argv[0]).name}: {exc}", file=sys.stderr)
        return 2
    if not vault.is_dir():
        command.error(f"no vault at {vault}")
    text, problems = report(vault, args.since, state_root() / LOG_FILE)
    print(text)
    if problems:
        print(f"sweep.py: {'; '.join(problems)}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
