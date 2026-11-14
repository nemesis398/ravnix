"""What each session already got from the hooks, and the log of it.

    state_root()  where all of it lives
    seen()        the notes and domains a session already got
    remember()    adds to them
    forget()      drops a session, once a compaction lost what it was given
    prune()       drops the sessions nobody wrote to for two weeks
    log()         appends one line to `injections.jsonl`

Run state, so it lives in `~/.local/state/ai-memory/`, outside the synced
vault. A session is one file, `sessions/<id>.json`, written whole into a
temp file next to it and swapped in with os.replace, so a hook killed
mid-write leaves the old file and never half of a new one.

Stdlib only, because the hooks import this on every prompt.
"""
from __future__ import annotations

import json
import os
import re
import tempfile
import time
from collections.abc import Iterable
from datetime import datetime
from pathlib import Path

__all__ = ["LOG_FILE", "REASONS", "forget", "log", "prune", "remember", "seen", "state_root"]

# Why a hook logged a line. The Sunday sweep groups by these.
REASONS = ("pinned", "match", "digest", "failure", "miss")
# The injection log in the state root, which `log` writes and the sweep reads.
LOG_FILE = "injections.jsonl"

_KEYS = ("injected", "digested")
_UNSAFE = re.compile(r"[^A-Za-z0-9_-]")
# Far below the 255 bytes a file name may have. Claude Code's ids are UUIDs.
_NAME_MAX = 128


def state_root() -> Path:
    """`AI_MEMORY_STATE_ROOT`, else `~/.local/state/ai-memory`."""
    override = os.environ.get("AI_MEMORY_STATE_ROOT")
    if override:
        return Path(override)
    return Path.home() / ".local" / "state" / "ai-memory"


def _sessions() -> Path:
    return state_root() / "sessions"


def _session_file(session_id: str) -> Path:
    """`sessions/<id>.json`, with the id cut down to a safe file name.

    Every character but an ASCII letter, a digit, `-` and `_` becomes `_`, so
    no id can name a directory, `.` or `..`, or climb out of `sessions/`. A
    UUID passes unchanged.
    """
    name = _UNSAFE.sub("_", session_id)[:_NAME_MAX] or "_"
    return _sessions() / f"{name}.json"


def seen(session_id: str) -> dict:
    """`{"injected": [rel, ...], "digested": [domain, ...]}` for the session.

    Both lists are empty for a session that got nothing yet.
    """
    try:
        data = json.loads(_session_file(session_id).read_text(encoding="utf-8"))
    except FileNotFoundError:
        data = {}
    return {key: list(data.get(key, [])) for key in _KEYS}


def remember(session_id: str, injected: Iterable[str], digested: Iterable[str]) -> None:
    """Add `injected` rels and `digested` domains to what the session got.

    Each list keeps the order its entries first came in and holds none
    twice. The file is rewritten even when nothing is new, which keeps its
    age at the last call, the age `prune` goes by.
    """
    merged = seen(session_id)
    for key, new in zip(_KEYS, (injected, digested)):
        merged[key] = list(dict.fromkeys([*merged[key], *new]))
    path = _session_file(session_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp = tempfile.mkstemp(dir=path.parent, prefix=f".{path.stem}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(merged))
        os.replace(temp, path)
    except BaseException:
        Path(temp).unlink(missing_ok=True)
        raise


def forget(session_id: str) -> None:
    """Drop what the session got, so the next hook gives it everything again."""
    _session_file(session_id).unlink(missing_ok=True)


def prune(days: int = 14) -> None:
    """Remove each file in `sessions/` last written more than `days` ago.

    That covers the temp file of a write that was killed before its swap.
    The logs in the state root are left alone. An entry that cannot be
    removed, such as a directory or a file without permission, is skipped.
    SessionStart prunes before it injects, so one bad entry must not stop
    every session start.
    """
    cutoff = time.time() - days * 86400
    try:
        entries = list(_sessions().iterdir())
    except FileNotFoundError:
        return
    for path in entries:
        try:
            if path.stat().st_mtime < cutoff:
                path.unlink()
        except OSError:
            continue  # gone already, a directory, or not ours to remove


def log(event: str, session_id: str, reason: str, rels: Iterable[str],
        detail: str = "", *, chars: int) -> None:
    """Append one JSON line to `injections.jsonl` in the state root.

    `event` is the hook event, `session_id` the raw id from the payload (the
    sweep counts distinct sessions by it), `reason` one of REASONS, `rels`
    the notes injected, and `detail` what a `miss` was missing. `chars` is
    the number of characters injected for this reason, 0 for a `miss`. It is
    keyword-only and has no default, so a call that forgets it fails instead
    of logging 0. An unknown reason raises ValueError and writes nothing.
    """
    if reason not in REASONS:
        raise ValueError(f"unknown reason {reason!r}, expected one of {', '.join(REASONS)}")
    entry = {
        "ts": datetime.now().astimezone().isoformat(timespec="seconds"),
        "session": session_id,
        "event": event,
        "reason": reason,
        "rels": list(rels),
        "chars": chars,
        "detail": detail,
    }
    root = state_root()
    root.mkdir(parents=True, exist_ok=True)
    # ASCII escapes, so no string from a payload can fail to encode.
    with (root / LOG_FILE).open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(entry) + "\n")
