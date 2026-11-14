#!/usr/bin/env python3
"""File mechanics for the daily note. Composes nothing.

Every sentence this places was written and prose-checked by the model that
called it. This module resolves paths, creates the note from the vault's own
template, and splices a block into the right place. Keeping composition out
of here is what stops the daily note filling with generated filler.

Stdlib only, no work at import time: the Stop adapter imports this on every
turn end and it must never fail to load.
"""
from __future__ import annotations

import os
import re
from datetime import date
from pathlib import Path

import skill_values as sv

VAULT_KEY = "vault.root"
PROTECTED_KEY = "journal.protectedSection"

# Built by hand rather than with strftime("%A")/strftime("%b"). Those follow
# LC_TIME, so a session under a German locale would name the file
# "Sonntag, 09. Aug. 2026" and silently start a second note for the same day.
WEEKDAYS = ("Monday", "Tuesday", "Wednesday", "Thursday",
            "Friday", "Saturday", "Sunday")
MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun",
          "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")


def vault_root() -> Path:
    """The skill value `vault.root`, or JOURNAL_VAULT, which wins so tests
    never touch the real vault. Raises skill_values.Missing without both."""
    named = os.environ.get("JOURNAL_VAULT")
    return Path(named) if named else Path(sv.require(VAULT_KEY)).expanduser()


def iso_week_label(d: date) -> str:
    """`2026-W32`, matching the Calendar plugin and the weekly notes' filenames.

    The ISO year is taken from isocalendar(), not from d.year: 2027-01-01
    belongs to ISO week 53 of 2026, and using the calendar year there would
    point the note at a weekly note that does not exist.
    """
    iso = d.isocalendar()
    return f"{iso.year}-W{iso.week:02d}"


def note_name(d: date) -> str:
    """The vault's own `.obsidian/daily-notes.json` format, by hand.

    `"dddd, DD. MMM Y ([W]W)"`: `DD` is moment's padded day, `[W]W` is a
    literal "W" followed by moment's *unpadded* ISO week -- unlike
    `iso_week_label`'s `WW`, which is padded and belongs to a different
    convention (the weekly note's wikilink). `daily-notes/Friday, 13. Feb
    2026 (W7).md` is the proof this vault already writes unpadded weeks;
    padding here silently started a second file for the same day the
    first time a single-digit week came up on this machine instead.
    """
    return (f"{WEEKDAYS[d.weekday()]}, {d.day:02d}. {MONTHS[d.month - 1]} "
            f"{d.year} (W{d.isocalendar().week}).md")


def note_path(d: date) -> Path:
    return vault_root() / "daily-notes" / note_name(d)


# moment's German `monthsShort`, as emitted by the iPhone's locale. Not
# uniformly three letters or uniformly dotted: "März", "Mai", "Juni" and
# "Juli" carry no trailing period, the rest do. The trailing period is
# stripped before comparison in `_month_index` rather than encoded here, so
# this table holds the bare word either way.
_MONTHS_DE_SHORT = ("Jan", "Feb", "März", "Apr", "Mai", "Juni",
                    "Juli", "Aug", "Sep", "Okt", "Nov", "Dez")
# The full German names, accepted too: a different moment version could
# emit these instead of the short forms above.
_MONTHS_DE_LONG = ("Januar", "Februar", "März", "April", "Mai", "Juni",
                   "Juli", "August", "September", "Oktober", "November",
                   "Dezember")

# ", DD. <month token> YYYY" -- anchored on the comma that always separates
# the weekday from the date, so it does not care what language or spelling
# the weekday itself is in, and does not accidentally match the week
# number in the trailing "(W7)".
_NAME_DATE_RE = re.compile(r",\s*(\d{1,2})\.\s+(\S+)\s+(\d{4})\b")


def _month_index(token: str) -> int | None:
    """1-based month number for `token`, or None if it names no month.

    Matches case-insensitively with any trailing period stripped, so the
    same code accepts this module's own English abbreviations and
    moment's German ones (`Aug.`) and full names (`August`) alike.
    """
    bare = token.rstrip(".").casefold()
    for months in (MONTHS, _MONTHS_DE_SHORT, _MONTHS_DE_LONG):
        for i, name in enumerate(months, start=1):
            if bare == name.casefold():
                return i
    return None


def resolve_note(d: date) -> Path:
    """The path to `d`'s note if one already exists, else where to create it.

    The same day gets two different filenames depending on which device
    wrote first: the vault's moment.js date format renders in the writing
    device's own locale, German on the iPhone and English on the desktop
    (`daily-notes/Montag, 10. Aug. 2026 (W33).md` is today's proof). Without
    this, the skill would silently open a second note for a day that
    already has one. Only when nothing matches does this hand back the
    canonical English name, for `ensure_note` to create.

    Matches on day, month and year alone. The weekday and the week number
    in a filename are not trustworthy: `daily-notes/Wednesday, 30. Jul
    2026 (W31).md` names a Wednesday for a date that is a Thursday, and the
    week number is sometimes padded (`W07`) and sometimes not (`W7`) across
    the notes already in this vault.

    Two notes for one day is already a broken state; resolving must not
    make it worse by picking a different one on each run. When more than
    one file matches, the canonical English name wins if it is among them;
    otherwise the lexicographically first match does.
    """
    folder = vault_root() / "daily-notes"
    canonical = note_name(d)
    try:
        names = sorted(p.name for p in folder.iterdir() if p.suffix == ".md")
    except OSError:
        names = []
    matches = []
    for name in names:
        found = _NAME_DATE_RE.search(name)
        if not found:
            continue
        day_s, month_s, year_s = found.groups()
        month_i = _month_index(month_s)
        if month_i is None:
            continue
        try:
            candidate = date(int(year_s), month_i, int(day_s))
        except ValueError:
            continue
        if candidate == d:
            matches.append(name)
    if not matches:
        return folder / canonical
    if canonical in matches:
        return folder / canonical
    return folder / sorted(matches)[0]


def ensure_note(d: date) -> tuple[Path, bool]:
    """Return the note path, creating it from the template when absent.

    Resolves an existing note under either the English or the German
    filename before ever computing a name to create -- see `resolve_note`.
    Never overwrites. The second return value says whether it created one,
    so a caller can report "created" rather than guessing.
    """
    target = resolve_note(d)
    if target.exists():
        return target, False
    template = vault_root() / "templates" / "Daily Note.md"
    try:
        body = template.read_text(encoding="utf-8")
    except OSError:
        body = "## ✅ Today\n\n- [ ] \n\n## \U0001f4dd Capture\n\n"
    body = body.replace("{{date:GGGG-[W]WW}}", iso_week_label(d))
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(body, encoding="utf-8")
    return target, True


CAPTURE = "## \U0001f4dd Capture"


def protected_section() -> str | None:
    """The heading of the daily note's section that is the user's alone, the
    skill value `journal.protectedSection`, or None. Capture goes in above
    it, and nothing below it is ever touched."""
    return sv.get(PROTECTED_KEY)


def normalize_title(s: str) -> str:
    """Identity of an entry: the words, not the decoration.

    The model picks a fresh emoji every time it writes, so comparing whole
    headings would open a second block for the same topic on the same day.
    Anything that is not a letter, digit or space is dropped, which takes the
    emoji, the variation selectors and any stray punctuation with it.
    """
    kept = [c for c in s if c.isalnum() or c.isspace()]
    return " ".join("".join(kept).split()).casefold()


def _fence_open_len(stripped: str) -> int:
    """Backtick count if `stripped` opens a fence, else 0.

    A run of three or more backticks at the start of the line opens a
    fence and may carry an info string after it -- ```python is exactly
    how you document fenced-code syntax, and that has to keep opening a
    fence rather than being read as plain text.
    """
    n = len(stripped) - len(stripped.lstrip("`"))
    return n if n >= 3 else 0


def _fence_closes(stripped: str, open_len: int) -> bool:
    """True if `stripped` closes a fence that was opened `open_len` long.

    CommonMark's rule, applied on purpose: the closing run must be at
    least as long as the opening one and carry nothing else. Without the
    length check, a 3-backtick line documenting fenced-code syntax inside
    a 4-backtick outer fence reads as closing the outer fence early, and
    the addition gets spliced into the middle of it -- content corruption,
    not misplacement. Without the "nothing else" check, an opening fence's
    own info string (```python) would close itself on the same line.
    """
    return len(stripped) >= open_len and set(stripped) == {"`"}


def _fences_balanced(lines: list[str], start: int, end: int) -> bool:
    """True if every fence opened between `start` and `end` also closes there.

    Checked once, ahead of the real scan: a body that opens a fence and
    never closes it must not have every line to `end` -- including a
    genuine sibling heading -- read as fenced content. Falling back to
    plain stops for the whole scan when its fences do not balance degrades
    to the documented unfenced limitation in `_block_end`, which is
    accepted; swallowing a sibling entry is not.
    """
    fenced = False
    open_len = 0
    for i in range(start + 1, end):
        stripped = lines[i].strip()
        if fenced:
            if _fence_closes(stripped, open_len):
                fenced = False
        else:
            n = _fence_open_len(stripped)
            if n:
                fenced, open_len = True, n
    return not fenced


def _block_end(lines: list[str], start: int, stops: tuple[str, ...],
               limit: int | None = None) -> int:
    """Index one past the last line of the block opening at `start`.

    The only block-end scan in this module, deliberately. Capture's end, an
    area's end and an entry's end are one question asked at three depths,
    and for three rounds fence-awareness lived at the entry level while the
    two outer boundaries were blind to it. A fenced changelog excerpt
    ("## [1.0.0]"), a quoted README or a note about Markdown itself then
    truncated those boundaries mid-fence: the target entry fell outside the
    searched range, was reported not found, and a duplicate "#### " heading
    plus its body was spliced into the middle of the code block, splitting
    it, while the real entry sat untouched further down. One scan is what
    stops a fourth call site repeating that.

    `limit` bounds the scan and each level passes the level above it, so an
    area can never end past its Capture section and an entry never past its
    area, whatever their bodies contain. That cap matters on its own: a
    second, later "#### " entry in the same area is the ordinary shape of a
    real daily note here, so an entry scan has to stop at the first genuine
    sibling or extending entry A would swallow entries B and C.

    A heading-looking line inside a *well-formed* fenced code block is not
    a stop: pasted markdown in this vault lives in fences, so that is the
    paste-versus-heading case plain text actually lets you resolve. Fence
    state is tracked fresh from `start`, never inherited from earlier in
    the file, and `_fences_balanced` is checked first, so a fence that
    never closes disables fence-awareness for this whole scan instead of
    letting every following line -- a genuine sibling heading included --
    read as fenced content.

    Held to that and no further, on purpose: no tilde fences, no indented
    fences, no CommonMark leading-space allowance. Those are recorded
    limitations, not oversights.

    A heading-looking line that is genuinely NOT fenced -- including every
    line of a scan whose fences do not balance -- is still treated as a
    real heading even though it might be an unfenced paste. That is a
    deliberate, accepted limitation, not a bug to "fix" later. It is
    genuinely undecidable from plain text whether such a line is someone's
    next heading of the day or a raw paste that happens to start with
    hashes, and splitting an entry's prose on a rare unfenced paste is far
    less harmful than the alternative of silently swallowing a sibling
    entry's content into the wrong addition on every multi-entry area.
    """
    end = len(lines) if limit is None else limit
    use_fences = _fences_balanced(lines, start, end)
    fenced = False
    open_len = 0
    for i in range(start + 1, end):
        stripped = lines[i].strip()
        if use_fences:
            if fenced:
                if _fence_closes(stripped, open_len):
                    fenced = False
                continue
            n = _fence_open_len(stripped)
            if n:
                fenced, open_len = True, n
                continue
        if lines[i].startswith(stops):
            return i
    return end


def _is_blank(line: str) -> bool:
    """A line is blank once its own terminator is stripped away."""
    return not line.strip()


def _newline_of(lines: list[str]) -> str:
    """The line terminator this note already uses.

    Taken from the first line that carries one, so an inserted block joins
    the note in the note's own convention instead of a hardcoded "\\n". A
    CRLF note spliced with LF comes back mixed, and mixed endings show up
    as a whole-file rewrite in git and as stray characters in some editors.
    Only the terminators `splitlines` itself recognizes as ending a line are
    possible here, so checking CRLF before the single characters is enough.
    """
    for line in lines:
        if line.endswith("\r\n"):
            return "\r\n"
        if line.endswith(("\n", "\r")):
            return line[-1]
    return "\n"


def _insert(lines: list[str], at: int, block: list[str]) -> list[str]:
    """Splice `block` (plain text, no line endings) in before `lines[at]`.

    This is the only place allowed to add or drop a blank line, and it only
    ever touches the two lines that actually sit at the seam: a blank line
    this is about to insert is dropped if the original already had one
    right there, which is what keeps a splice at a block boundary from
    leaving a double blank line. Every other original line -- and that
    includes the whole protected section when the insertion happens above it --
    passes through untouched: same terminator, same trailing whitespace,
    same everything.

    An earlier version rebuilt the whole document through a `_tidy` pass
    that rstripped and blank-collapsed every line in the file, not just the
    inserted ones. That reached into sections the splice never touched,
    which is how a Markdown hard break (two trailing spaces) or a
    deliberate double blank line inside the protected section got silently
    rewritten, and how a CRLF note came back as LF. Building the result by
    insertion instead of by rewrite makes that impossible rather than
    merely unlikely.

    The one line this is allowed to repair is the note's last, and only
    when the block is going after it. `splitlines(keepends=True)` gives the
    final line no terminator when the file does not end with one, and 4 of
    the 14 daily notes in this vault do not -- so without the repair the
    block is concatenated onto that line and the heading stops being a
    heading. It is worse than cosmetic: `startswith("#### ")` cannot see a
    glued heading on the next run, so the tool writes a second entry with
    the same title and orphans the body of the first. Measured on
    `daily-notes/Tuesday, 28. Jul 2026 (W31).md`, which has the full
    structure, no protected section and no trailing newline. Repairing only at
    `at == len(lines)` is what keeps byte-identity everywhere else: a note
    with no trailing newline that gets an insertion in the middle still
    comes back with no trailing newline.
    """
    nl = _newline_of(lines)
    block = list(block)
    if at == len(lines) and lines and not lines[-1].endswith(("\n", "\r")):
        lines = lines[:-1] + [lines[-1] + nl]
    if block and not block[0] and at > 0 and _is_blank(lines[at - 1]):
        block = block[1:]
    if block and not block[-1] and at < len(lines) and _is_blank(lines[at]):
        block = block[:-1]
    return lines[:at] + [line + nl for line in block] + lines[at:]


def _ensure_capture(lines: list[str]) -> tuple[list[str], int]:
    """Return the lines with a Capture heading guaranteed, and its index.

    A daily note is not guaranteed to have the template skeleton: the note for
    13 February 2026 is a raw paste with no headings at all. Inserting before
    the protected section rather than appending keeps the section order the
    template establishes.

    Both fallbacks go through `_insert` so that the one function allowed to
    add a line is the only one that does. The "no Capture, no protected section"
    branch used to hand-roll its own append with a hardcoded "\\n", which
    made it the last place that assumed LF and could still glue a heading
    onto an unterminated final line: 3 of the 4 daily notes here that lack a
    trailing newline also lack a Capture heading, so that branch is exactly
    the one they take.
    """
    for i, line in enumerate(lines):
        if line.strip() == CAPTURE:
            return lines, i
    protected = protected_section()
    for i, line in enumerate(lines):
        if protected and line.strip() == protected.strip():
            return _insert(lines, i, [CAPTURE, ""]), i
    trimmed = list(lines)
    while trimmed and _is_blank(trimmed[-1]):
        trimmed.pop()
    at = len(trimmed)
    return _insert(trimmed, at, ["", CAPTURE, ""]), at + 1


def splice(text: str, area: str, title: str, body: str) -> tuple[str, str]:
    """Place `body` under `#### title` under `### area` under Capture.

    Pure, so the three structural cases can be tested without a filesystem.
    Returns the new text and what happened: "created" when the Capture
    heading had to be added, "extended" when an entry with this title was
    already there, "appended" otherwise.

    Splits with `splitlines(keepends=True)` rather than `splitlines()`:
    every line keeps its own terminator and trailing whitespace attached, so
    a line the splice does not insert is never rebuilt from parts -- it is
    copied whole. That is what guarantees the protected section, and everything
    else outside the inserted block, comes back byte-identical regardless
    of what it contains.
    """
    lines = text.splitlines(keepends=True)
    had_capture = any(line.strip() == CAPTURE for line in lines)
    lines, capture_at = _ensure_capture(lines)
    # All three boundaries below -- Capture's, the area's, the entry's --
    # come from the same fence-aware `_block_end`, each bounded by the one
    # above it. Anything else here would be a boundary blind to fences
    # again; see that function for why that corrupted content.
    capture_end = _block_end(lines, capture_at, ("## ",))

    area_at = None
    for i in range(capture_at + 1, capture_end):
        if lines[i].startswith("### ") and lines[i][4:].strip() == area.strip():
            area_at = i
            break

    entry = [f"#### {title}".rstrip(), "", *body.rstrip().splitlines(), ""]

    if area_at is None:
        block = ["", f"### {area}", ""] + entry
        out = _insert(lines, capture_end, block)
        return "".join(out), "created" if not had_capture else "appended"

    area_end = _block_end(lines, area_at, ("### ", "## "), capture_end)
    wanted = normalize_title(title)
    for i in range(area_at + 1, area_end):
        if lines[i].startswith("#### ") and normalize_title(lines[i][5:]) == wanted:
            entry_end = _block_end(lines, i, ("#### ", "### ", "## "), area_end)
            addition = ["", *body.rstrip().splitlines(), ""]
            out = _insert(lines, entry_end, addition)
            return "".join(out), "extended"

    # The leading blank line is what separates the new heading from the
    # paragraph above it when the area ends at the end of the file. In the
    # ordinary case the line before `area_end` is already blank and
    # `_insert`'s seam logic drops it again, so nothing else changes.
    out = _insert(lines, area_end, [""] + entry)
    return "".join(out), "created" if not had_capture else "appended"


import fcntl
import shutil
import sys
import tempfile
from datetime import timedelta

UNSURE = "%%journal:unsure%%"


def lock_path() -> Path:
    """Outside the vault, deliberately.

    A lock file inside daily-notes/ would sync to Nextcloud and to the phone,
    and would show up in Obsidian's file list.
    """
    root = os.environ.get("JOURNAL_STATE_ROOT")
    base = Path(root) if root else Path.home() / ".local" / "state" / "agent-journal"
    base.mkdir(parents=True, exist_ok=True)
    return base / "notes.lock"


def atomic_write(target: Path, text: str) -> None:
    """Replace `target` with `text` in one rename, so no reader ever sees half
    a file and a crash leaves the old one whole.

    write_entry and session_note both call it, for the notes and for the
    session map. `text` goes to disk as given (newline=""), so a CRLF note
    stays CRLF.
    """
    # mkstemp, not target.with_name(target.name + ".tmp"): a bare "*.tmp" is
    # not on Nextcloud's own sync-exclude list (only "~*.tmp" is), so a
    # SIGKILL between the write and os.replace would leave a stray file that
    # syncs to the vault and to the phone -- the exact outcome lock_path's
    # own docstring keeps the lock file itself from causing. ".part" is on
    # that list. dir=target.parent keeps it on the note's own filesystem, so
    # os.replace stays an atomic rename rather than a copy.
    fd, tmp_name = tempfile.mkstemp(
        dir=target.parent, prefix=target.name + ".", suffix=".part")
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as fh:
            fh.write(text)
        # mkstemp creates at 0600; every other file in the vault is 0644.
        # An existing file keeps its own mode, or a note's mode would
        # silently drop on its first write through this tool. A file this
        # creates gets 0644 for the same reason: a session note would
        # otherwise be born 0600.
        if target.exists():
            shutil.copymode(target, tmp)
        else:
            os.chmod(tmp, 0o644)
        os.replace(tmp, target)
    finally:
        # A no-op once os.replace has renamed it away; a real cleanup on
        # every other path out, including an exception from the write itself.
        tmp.unlink(missing_ok=True)


def write_entry(d: date, area: str, title: str, body: str,
                unsure: bool = False) -> str:
    """Splice one entry into the day's note, atomically and under a lock.

    Two sessions can journal in the same second. Without the lock the second
    read-modify-write silently discards the first entry.
    """
    if unsure:
        body = body.rstrip() + "\n\n" + UNSURE
    with lock_path().open("w") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            target, created = ensure_note(d)
            # newline="" on read: the default text mode normalizes every
            # \r\n to \n and never restores it, so a CRLF note would come
            # back as a whole-file LF rewrite -- splice's byte-identity
            # guarantee held in memory only, not on disk. (On write,
            # newline="" only guards against a non-Linux os.linesep; on
            # this machine the default write would already be a no-op
            # here, since os.linesep is "\n".)
            text = target.read_text(encoding="utf-8", newline="")
            new_text, what = splice(text, area, title, body)
            atomic_write(target, new_text)
            return "created" if created else what
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def recent_areas(d: date, days: int = 14) -> list[str]:
    """The `### ` headings used in the last `days` notes, most recent first.

    The skill picks an area out of this rather than inventing one, because a
    new area heading is a structural decision and those are the user's.

    Fence-aware for the same reason every `splice` boundary is (see
    `_block_end`): a changelog excerpt or a quoted README pasted into an
    entry's body can contain a line that looks like a heading. Left
    unguarded that errs both ways -- a fenced "### " invents an area the user
    never made, and a fenced "## " reads as leaving Capture and cuts real
    areas below it off early. Reuses `_fences_balanced` and the two
    length-aware helpers rather than a second fence tracker; the same
    fall-to-plain-matching rule applies when a note's fences do not
    balance.

    Resolves through `resolve_note`, not `note_path`, for the same reason
    `ensure_note` does: a German-named note is a real note, and reading
    only the canonical English name would silently skip it.
    """
    seen: list[str] = []
    for back in range(days):
        target = resolve_note(d - timedelta(days=back))
        try:
            text = target.read_text(encoding="utf-8")
        except OSError:
            continue
        lines = text.splitlines()
        use_fences = _fences_balanced(lines, -1, len(lines))
        fenced = False
        open_len = 0
        inside = False
        for line in lines:
            stripped = line.strip()
            if use_fences:
                if fenced:
                    if _fence_closes(stripped, open_len):
                        fenced = False
                    continue
                n = _fence_open_len(stripped)
                if n:
                    fenced, open_len = True, n
                    continue
            if line.startswith("## "):
                inside = stripped == CAPTURE
                continue
            if inside and line.startswith("### "):
                name = line[4:].strip()
                if name and name not in seen:
                    seen.append(name)
    return seen


def _parse_date(value: str | None) -> date:
    return date.fromisoformat(value) if value else date.today()


def main(argv: list[str] | None = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(prog="daily_note")
    subs = parser.add_subparsers(dest="command", required=True)

    write = subs.add_parser("write")
    write.add_argument("--area", required=True)
    write.add_argument("--title", required=True)
    write.add_argument("--body-file", required=True)
    write.add_argument("--date")
    write.add_argument("--unsure", action="store_true")
    write.add_argument("--dry-run", action="store_true")

    areas = subs.add_parser("areas")
    areas.add_argument("--days", type=int, default=14)
    areas.add_argument("--date")

    where = subs.add_parser("path")
    where.add_argument("--date")

    args = parser.parse_args(argv)

    try:
        when = _parse_date(args.date)
        if args.command == "path":
            print(resolve_note(when))
            return 0
        if args.command == "areas":
            print("\n".join(recent_areas(when, args.days)))
            return 0

        body = Path(args.body_file).read_text(encoding="utf-8")
        if not body.strip():
            print("daily_note: the body file is empty", file=sys.stderr)
            return 2
        if args.dry_run:
            existing = ""
            resolved = resolve_note(when)
            if resolved.exists():
                existing = resolved.read_text(encoding="utf-8")
            elif (vault_root() / "templates" / "Daily Note.md").exists():
                existing = (vault_root() / "templates" / "Daily Note.md").read_text(
                    encoding="utf-8").replace("{{date:GGGG-[W]WW}}", iso_week_label(when))
            marked = body.rstrip() + ("\n\n" + UNSURE if args.unsure else "")
            print(splice(existing, args.area, args.title, marked)[0])
            return 0
        what = write_entry(when, args.area, args.title, body, args.unsure)
        print(f"{what} {resolve_note(when)}")
        return 0
    except (OSError, ValueError, sv.Missing) as exc:
        print(f"daily_note: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
