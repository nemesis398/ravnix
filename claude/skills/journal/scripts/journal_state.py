#!/usr/bin/env python3
"""Run state for the journal nudge. Never the synced tree.

Deliberately separate from handoff_state.py rather than importing it.
record_standdown there overwrites one file per repo, so sharing it would make
each skill erase the other's most recent record, which is exactly the signal
those files exist to carry.

Stdlib only and no work at import time: this loads on every turn end.
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import tempfile
from datetime import datetime
from pathlib import Path


def state_root() -> Path:
    override = os.environ.get("JOURNAL_STATE_ROOT")
    if override:
        return Path(override)
    return Path.home() / ".local" / "state" / "agent-journal"


def git_root(cwd: str | None = None) -> str | None:
    """Two second cap: this runs per turn."""
    target = cwd or os.getcwd()
    try:
        done = subprocess.run(
            ["git", "-C", target, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=2,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if done.returncode != 0:
        return None
    return done.stdout.strip() or None


def repo_key(cwd: str | None = None) -> str:
    """Basename for readability, hash for uniqueness.

    Keyed on the git root so one project's state does not fragment across
    every subdirectory it gets opened from.
    """
    root = git_root(cwd) or os.path.abspath(cwd or os.getcwd())
    digest = hashlib.sha256(root.encode("utf-8")).hexdigest()[:8]
    return f"{os.path.basename(root.rstrip('/')) or 'root'}-{digest}"


def _write_json(target: Path, data: dict) -> None:
    """Through a uniquely-named temp file, so a crash cannot leave a
    half-written record and two writers can never collide on the same name.

    A deterministic name like `target.name + ".tmp"` is shared by every
    writer to this target. Two Claude Code sessions open on the same
    repository both reaching Stop at about the same moment is ordinary, not
    contrived, and under that name it races: one process's `os.replace`
    renames the shared temp file away while another process's own
    `os.replace` is still in flight, which raises FileNotFoundError.
    Measured directly: 8 processes making 3200 concurrent
    record_standdown calls against the old deterministic name produced 587
    unhandled FileNotFoundError. `tempfile.mkstemp` hands back a name unique
    to this call, so no other writer can ever touch it, and
    dir=target.parent keeps the eventual os.replace on the same filesystem
    so the rename stays an atomic rename rather than falling back to a copy.

    A truncated stamp reads back as {} and the nudge fires a second time,
    which the atomic replace is what prevents here.
    """
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_name = tempfile.mkstemp(
        dir=target.parent, prefix=target.name + ".", suffix=".tmp")
    tmp = Path(tmp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(json.dumps(data))
        os.replace(tmp, target)
    finally:
        # A no-op once os.replace has renamed it away; a real cleanup on
        # every other path out, including a write that raises.
        tmp.unlink(missing_ok=True)


def _read_json(target: Path) -> dict:
    try:
        loaded = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return loaded if isinstance(loaded, dict) else {}


def _safe_component(session: str) -> str:
    """Reduce `session` to one path component that cannot escape its directory.

    `_read_json` already treats file *content* defensively; a raw session id
    landing straight in a path was the one place in this module that didn't.
    A session id is expected to be an opaque id handed down by the harness,
    but "expected" is not "guaranteed", and the failure mode is worth
    guarding against anyway: `os.path.basename` collapses something like
    "../../escaped" down to "escaped", discarding every path separator to
    its left -- including a leading "/", which would otherwise make the
    whole joined path absolute. Pathlib's `/` operator discards its left
    operand entirely when the right one is absolute, so an unsanitized
    session of "/etc/passwd" would resolve `stamp_file` to the literal path
    "/etc/passwd.json", bypassing state_root() and repo_key() completely.
    """
    if not session:
        return "unknown"
    return os.path.basename(session) or "unknown"


def stamp_file(cwd: str | None, session: str) -> Path:
    """Per-session stamp path. See `_safe_component` for why `session` is
    reduced to a single path component rather than used as given.
    """
    return state_root() / repo_key(cwd) / f"{_safe_component(session)}.json"


def read_stamp(cwd: str | None, session: str) -> dict:
    return _read_json(stamp_file(cwd, session))


def write_stamp(cwd: str | None, session: str, data: dict) -> None:
    try:
        _write_json(stamp_file(cwd, session), data)
    except Exception:
        # This runs on every turn end of every session; a hook that raises
        # breaks the turn, while a stamp that fails to write only costs a
        # nudge that may repeat. The first is not acceptable and the second
        # is a nuisance, so every exception here is deliberately swallowed.
        pass


def standdown_file(cwd: str | None = None) -> Path:
    return state_root() / repo_key(cwd) / "standdown.json"


def record_standdown(cwd: str | None, adapter: str, reason: str) -> None:
    """One overwritten record, not a log.

    An adapter reaches here on every turn end of every session, forever, so
    an append-only file would grow without bound.
    """
    try:
        _write_json(standdown_file(cwd), {
            "adapter": adapter, "reason": reason,
            "at": datetime.now().isoformat(timespec="seconds"),
        })
    except Exception:
        # Same reasoning as write_stamp: this must never break a turn over a
        # record that exists only to answer "is this working" after the fact.
        pass


def read_standdown(cwd: str | None = None) -> dict:
    return _read_json(standdown_file(cwd))
