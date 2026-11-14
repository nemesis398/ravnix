#!/usr/bin/env python3
"""Write a session note into the vault's `AI/sessions/`. Composes nothing.

    session_note.py write --title T --domain D [--domain D2] --description S
        --body-file F [--session ID] [--date YYYY-MM-DD] [--dry-run]

The body is the model's own prose, already prose-checked, under `## `
headings taken from SECTIONS. This module names the file, writes the
frontmatter and the Day link, and on a later call from the same session
appends each section's text under its heading. `sessions.json` in the
journal's state root maps each session id to its note, so a session resumed
on another day extends the note it started instead of opening a second one.

Exit 0 on a write, 2 on input it refuses, 3 outside an attended session. Only
an interactive main session writes a session note, and a headless `claude -p`
run has CLAUDE_CODE_SESSION_ATTENDED=0.

Stdlib only.
"""
from __future__ import annotations

import fcntl
import json
import os
import re
import sys
from datetime import date
from pathlib import Path

import daily_note as dn
import journal_state as js

# The lint and the hooks read every note in the AI area through notes.py, so
# the frontmatter an append extends is read the way they read it. ravnix
# installs the ai-memory skill beside this one, from the same tree.
sys.path.append(str(Path(__file__).resolve().parents[2] / "ai-memory" / "scripts"))
from notes import SESSIONS_DIR, parse_frontmatter  # noqa: E402

SECTIONS = ("Done", "Decisions", "Findings", "Memory candidates", "Next")

# Obsidian refuses * " \ / < > : | ? in a filename, and # ^ [ ] | mean
# something inside a wikilink, so a filename keeps none of them.
_UNSAFE = re.compile(r'[/\\:#^\[\]|?*"<>]')
# A session id goes into the frontmatter unquoted and keys the map.
_SESSION = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]*")
# A one-word domain goes into the flow list bare, the way Obsidian writes it.
_BARE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*")


def safe_title(title: str) -> str:
    """`title` fit for a filename: each reserved character becomes a space and
    whitespace collapses. Umlauts and the en dash stay."""
    return " ".join(_UNSAFE.sub(" ", title).split())


def note_path(d: date, title: str) -> Path:
    return dn.vault_root() / SESSIONS_DIR / f"{d:%Y-%m-%d} {safe_title(title)}.md"


def map_path() -> Path:
    """Next to the journal's lock, outside the vault: a session id is run
    state, and run state never syncs."""
    return js.state_root() / "sessions.json"


def _section_starts(lines: list[str], after: int = -1) -> list[int]:
    """The indexes of the `## ` lines past `after`, fenced code skipped.

    Through daily_note's one fence-aware scan, so a Markdown sample pasted
    into a section cannot split it.
    """
    starts = []
    at = dn._block_end(lines, after, ("## ",))
    while at < len(lines):
        starts.append(at)
        at = dn._block_end(lines, at, ("## ",))
    return starts


def _trimmed(lines: list[str]) -> list[str]:
    start, end = 0, len(lines)
    while start < end and not lines[start].strip():
        start += 1
    while end > start and not lines[end - 1].strip():
        end -= 1
    return lines[start:end]


def parse_body(body: str) -> dict[str, list[str]]:
    """The body's lines per section, in SECTIONS order, empty sections left out.

    Raises ValueError on text before the first heading, on a `## ` heading
    that is not in SECTIONS and on a body with nothing under any heading.
    """
    lines = body.splitlines()
    starts = _section_starts(lines)
    if _trimmed(lines[:starts[0] if starts else len(lines)]):
        raise ValueError("text before the first section heading: the body starts "
                         f"with one of ## {', ## '.join(SECTIONS)}")
    found: dict[str, list[str]] = {}
    for at, end in zip(starts, [*starts[1:], len(lines)]):
        name = lines[at][3:].strip()
        if name not in SECTIONS:
            raise ValueError(f"unknown section {name!r}: the sections are {', '.join(SECTIONS)}")
        text = _trimmed(lines[at + 1:end])
        if text:
            found[name] = [*found[name], "", *text] if name in found else text
    if not found:
        raise ValueError("the body is empty: there is no text under any section")
    return {name: found[name] for name in SECTIONS if name in found}


def _quoted(text: str) -> str:
    """One line in YAML double quotes. JSON strings are valid YAML."""
    return json.dumps(" ".join(text.split()), ensure_ascii=False)


def _flow(items: list[str]) -> str:
    return "[" + ", ".join(i if _BARE.fullmatch(i) else json.dumps(i, ensure_ascii=False)
                           for i in items) + "]"


def _new_note(session: str, title: str, domains: list[str], description: str,
              sections: dict[str, list[str]], d: date, day: str) -> str:
    lines = ["---", "type: session", f"domain: {_flow(domains)}",
             f"updated: {d.isoformat()}", f"description: {_quoted(description)}",
             f"generated: claude/{session}", "---", "",
             f"# {' '.join(title.split())}", "", f"Day: [[{day}]]"]
    for name, text in sections.items():
        lines += ["", f"## {name}", "", *text]
    return "\n".join(lines) + "\n"


def _set_key(rows: list[str], key: str, value: str, nl: str) -> list[str]:
    """Frontmatter `rows` with the top-level `key` set to `value`.

    The old value can run over several lines, as `domain` does once Obsidian
    has rewritten the list in block form, and all of them go. Every other row
    stays as it was. A missing key is added at the end.
    """
    new = f"{key}: {value}{nl}"
    for i, row in enumerate(rows):
        if re.match(rf"{re.escape(key)}[ \t]*:(?=\s|$)", row):
            end = i + 1
            while end < len(rows) and (rows[end].startswith((" ", "\t", "- "))
                                       or rows[end].strip() == "-"):
                end += 1
            return [*rows[:i], new, *rows[end:]]
    return [*rows, new]


def _append(text: str, domains: list[str], description: str,
            sections: dict[str, list[str]], d: date, day: str) -> str:
    """`text` with `updated`, `domain` and `description` set, the day linked,
    and each section's lines at the end of its own section.

    A section the note lacks goes in before the first heading that comes
    later in SECTIONS, else at the end. Lines outside those edits stay
    byte-identical, line endings included.
    """
    meta, _ = parse_frontmatter(text)
    lines = text.splitlines(keepends=True)
    nl = dn._newline_of(lines)
    close = next(i for i in range(1, len(lines)) if lines[i].rstrip() == "---")
    have = meta.get("domain")
    have = have if isinstance(have, list) else [have] if isinstance(have, str) and have else []
    rows = lines[1:close]
    rows = _set_key(rows, "updated", d.isoformat(), nl)
    rows = _set_key(rows, "domain", _flow(list(dict.fromkeys([*have, *domains]))), nl)
    rows = _set_key(rows, "description", _quoted(description), nl)
    lines = [lines[0], *rows, *lines[close:]]
    close = len(rows) + 1

    link = f"[[{day}]]"
    starts = _section_starts(lines, close)
    head = range(close + 1, starts[0] if starts else len(lines))
    day_at = next((i for i in head if lines[i].startswith("Day:")), None)
    if day_at is None:
        title_at = next((i for i in head if lines[i].startswith("# ")), close)
        lines = dn._insert(lines, title_at + 1, ["", f"Day: {link}", ""])
    elif link not in lines[day_at]:
        row = lines[day_at]
        content = row.rstrip("\r\n")
        lines[day_at] = f"{content.rstrip()}, {link}{row[len(content):]}"

    for name, text_lines in sections.items():
        starts = _section_starts(lines, close)
        names: dict[str, int] = {}
        for i in starts:
            names.setdefault(lines[i][3:].strip(), i)
        if name in names:
            at = dn._block_end(lines, names[name], ("## ",))
            block = ["", *text_lines, ""]
        else:
            later = SECTIONS[SECTIONS.index(name) + 1:]
            at = next((i for i in starts if lines[i][3:].strip() in later), len(lines))
            block = ["", f"## {name}", "", *text_lines, ""]
        if at == len(lines):
            block = block[:-1]  # the note ends on its last line, not a blank one
        lines = dn._insert(lines, at, block)
    return "".join(lines)


def _read_map() -> dict:
    """The session map, {} before the first note. A map that does not read
    as a JSON object is refused, since overwriting it would drop every other
    session's entry."""
    path = map_path()
    try:
        loaded = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except ValueError as exc:
        raise ValueError(f"{path} is not valid JSON: {exc}") from None
    if not isinstance(loaded, dict):
        raise ValueError(f"{path} is not a JSON object")
    return loaded


def _target(sessions: dict, session: str, d: date, title: str) -> Path:
    """The note the map names for this session while it is still a file in
    the sessions folder, else the note for this day and title."""
    rel = sessions.get(session)
    if isinstance(rel, str) and rel:
        mapped = dn.vault_root() / rel
        folder = (dn.vault_root() / SESSIONS_DIR).resolve()
        if mapped.is_file() and mapped.resolve().is_relative_to(folder):
            return mapped
    return note_path(d, title)


def _compose(sessions: dict, session: str, title: str, domains: list[str],
             description: str, sections: dict[str, list[str]], d: date,
             day: str) -> tuple[Path, str, str]:
    """The target, "created" or "appended", and the note's new text."""
    target = _target(sessions, session, d, title)
    if target.exists():
        old = target.read_text(encoding="utf-8", newline="")
        return target, "appended", _append(old, domains, description, sections, d, day)
    return target, "created", _new_note(session, title, domains, description, sections, d, day)


def _write(session: str, title: str, domains: list[str], description: str,
           body: str, d: date, dry_run: bool = False) -> tuple[Path, str, str]:
    if not session:
        raise ValueError("no session id: pass --session, or run where CLAUDE_CODE_SESSION_ID is set")
    if not _SESSION.fullmatch(session):
        raise ValueError(f"{session!r} is not a session id")
    if not safe_title(title):
        raise ValueError("the title is empty once the characters a filename cannot hold are gone")
    if not description.strip():
        raise ValueError("the description is empty")
    sections = parse_body(body)
    domains = list(dict.fromkeys(domains))
    if dry_run:
        # resolve_note names the daily note that ensure_note would create,
        # and creates nothing.
        return _compose(_read_map(), session, title, domains, description,
                        sections, d, dn.resolve_note(d).stem)
    with dn.lock_path().open("w") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            sessions = _read_map()
            day = dn.ensure_note(d)[0].stem
            target, what, text = _compose(sessions, session, title, domains,
                                          description, sections, d, day)
            target.parent.mkdir(parents=True, exist_ok=True)
            dn.atomic_write(target, text)
            sessions[session] = target.relative_to(dn.vault_root()).as_posix()
            dn.atomic_write(map_path(), json.dumps(
                sessions, indent=2, ensure_ascii=False, sort_keys=True) + "\n")
            return target, what, text
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def write(session: str, title: str, domains: list[str], description: str,
          body: str, d: date) -> Path:
    """Create the session's note, or append to it, and return its path.

    Holds the journal's lock, the one write_entry holds, across both
    read-modify-writes, the note's and the map's, so two sessions writing at
    once cannot drop each other's entry. The Day link names the daily note
    that ensure_note resolves, which creates it from the template when the
    day has none yet: vault-check fails on a link that resolves to nothing.
    Raises ValueError on input it will not write.
    """
    return _write(session, title, domains, description, body, d)[0]


def main(argv: list[str] | None = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(
        prog="session_note", description="Write this session's note into the vault's AI/sessions/.")
    subs = parser.add_subparsers(dest="command", required=True)
    cmd = subs.add_parser("write", help="create the session's note, or append to it")
    cmd.add_argument("--title", required=True)
    cmd.add_argument("--domain", action="append", required=True, help="once per domain")
    cmd.add_argument("--description", required=True, help="one line on what the session did")
    cmd.add_argument("--body-file", required=True,
                     help=f"the text under ## headings, each one of: {', '.join(SECTIONS)}")
    cmd.add_argument("--session", default=os.environ.get("CLAUDE_CODE_SESSION_ID", ""),
                     help="default: $CLAUDE_CODE_SESSION_ID")
    cmd.add_argument("--date", help="YYYY-MM-DD, default today")
    cmd.add_argument("--dry-run", action="store_true", help="print the note instead of writing it")
    args = parser.parse_args(argv)

    # Ahead of the body and of --dry-run, so an unattended run gets nothing.
    # Only argparse goes first, so that --help works anywhere.
    if os.environ.get("CLAUDE_CODE_SESSION_ATTENDED") != "1":
        print("session_note: not an attended session (CLAUDE_CODE_SESSION_ATTENDED is not 1); "
              "only an interactive main session writes a session note", file=sys.stderr)
        return 3
    try:
        when = date.fromisoformat(args.date) if args.date else date.today()
        body = Path(args.body_file).read_text(encoding="utf-8")
        target, what, text = _write(args.session, args.title, args.domain,
                                    args.description, body, when, args.dry_run)
    except (OSError, ValueError, LookupError) as exc:
        print(f"session_note: {exc}", file=sys.stderr)
        return 2
    if args.dry_run:
        print(f"would have {what} {target}\n\n{text}", end="")
    else:
        print(f"{what} {target}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
