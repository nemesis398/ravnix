#!/usr/bin/env python3
# adapters/claude/sessionstart.py
"""SessionStart hook: give the session the lines of the pinned notes.

The pinned notes are the operating knowledge nearly every session needs,
injected as one line each under the pinned header, newest first, within
PINNED_BUDGET. Each line goes out once per session:

- `startup`, `clear` and `fork` get every pinned line the session was not
  given yet, which for a new session id is all of them.
- `resume` gets only what is new, because its transcript already holds the
  lines it was given before.
- `compact` forgets the session first, because the summary lost the lines,
  so the pinned lines go out again and the prompt hooks may repeat theirs.

A subagent gets nothing. The script modules are imported inside the
handler, so a missing one fails open under `run()` (see `_common`).
"""
from __future__ import annotations

import _common

EVENT = "SessionStart"


def handle(payload: dict) -> dict | None:
    if _common.is_subagent(payload):
        return None
    import notes
    import retrieve
    import state

    session = str(payload.get("session_id") or "")
    if payload.get("source") == "compact":
        state.forget(session)
    try:
        vault = notes.vault_root()
    except LookupError:  # vault.root is not set: the skill is off, quietly
        return None
    found, problems = notes.load_notes(vault / notes.MEMORY_DIR, vault)
    _common.log_problems(problems)
    given = set(state.seen(session)["injected"])
    fresh = [note for note in retrieve.pinned(found) if note.rel not in given]
    text = "\n".join([retrieve.header("pinned", vault), *map(retrieve.line, fresh)])
    # After the text, and on its own: an odd entry in sessions/ must never
    # cost a session its pinned lines.
    try:
        state.prune()
    except Exception:  # noqa: BLE001
        pass
    if not fresh:
        return None
    rels = [note.rel for note in fresh]
    state.remember(session, rels, [])
    state.log(EVENT, session, "pinned", rels, chars=len(text))
    return _common.emit(EVENT, text)


if __name__ == "__main__":
    _common.run(handle)
