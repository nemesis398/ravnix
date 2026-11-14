#!/usr/bin/env python3
# adapters/claude/sessionstart.py
"""SessionStart hook: hand the new session the slice of the board it needs.

It shows the stream this directory was last on and the open parents of the
directory's default project, never the whole board. On a continuation it also
fetches the newest handoff comment on the active parent, mirroring the
full-versus-pointer split this adapter has always made.
"""
from __future__ import annotations

import os

import _common
from _common import hs

# Order matters and is not cosmetic: _common puts the skill's scripts directory
# on sys.path as an import side effect, so `import plane` resolves only after
# `import _common` has run. Reordering these two breaks the hook silently.
import plane  # noqa: E402

# Compaction only. `/clear` used to be here, and it never once delivered: the
# harness mints a NEW session id for a cleared session, so the pointer written
# before the clear is not found and the fetch is skipped anyway. Measured
# 2026-08-25 — cleared session f89622c1, pointer on disk naming 2b8c4f37, same
# cwd. Compaction keeps its session id (17 real compactions in ~/.claude/
# projects, one id each), which is why that half works and stays.
#
# Listing "clear" here was therefore a promise the code could not keep, and
# `/clear` means a clean slate in any case. TOOLS-25.
CONTINUATION_SOURCES = {"compact"}
# The state CLAUDE_AUTOCOMPACT_PCT_OVERRIDE is expected to be in, which is now
# absent. The supported setting is `autoCompactWindow` in settings.json, at
# 500000, and the thresholds in handoff_state.py are tuned for the 487000 tokens
# that leaves once the harness reserves its summary buffer (COMPACT_CEILING
# there). Before 2026-10-17 the window was 800000. The expected value
# used to be "30", back when the window was 1000000 and the override pulled
# compaction down to 300000. The variable was deleted from settings.json when
# the window changed, so a value here now means someone put it back, and
# compaction fires earlier than the nudges assume rather than later.
EXPECTED_PCT = None
# One source for the budget, in the module that owns the transport. A second
# literal here is how this hook and the transport drift apart.
TIMEOUT = plane.TIMEOUT


def _render(project, items, pointer, handoff_html, elsewhere=(), latest=None):
    lines = [f"Board: {project['identifier']} ({project['name']}), "
             f"workspace {project['workspace']}."]
    truncated = bool(getattr(items, "truncated", False))
    total = getattr(items, "total", None)
    if not items and not truncated:
        lines.append("No open work items in this project.")
    elif items:
        lines.append(f"{len(items)} open:")
        for item in items:
            lines.append(f"  [{item.get('state_name', '?')}] {item.get('name', '?')}")
    if truncated:
        # The open-state filter runs after the fetch, so a truncated read can
        # come back with nothing open while the work sits on a later page.
        # Saying "no open work items" there is the lie this line prevents.
        held = f", and the project holds {total} items in total" if total else ""
        lines.append(f"This is NOT the whole board. The read stopped before the "
                     f"last page{held}. Anything further in is missing from the "
                     f"list above, so do not conclude it is not there.")
    if elsewhere:
        # The line names the project this directory maps to, and the project
        # follows the task rather than the directory. Reading "nothing open"
        # as a finished board is how a session starts by inventing work.
        where = ", ".join(f"{p['identifier']} {p['count']} open" for p in elsewhere)
        lines.append(f"Nothing open here, but this workspace is not idle: {where}. "
                     f"Your stream may be one of those, because the project "
                     f"follows the task and not the directory.")
    if pointer.get("identifier"):
        lines.append(f"Active stream: {pointer['identifier']}.")
    elif (latest or {}).get("identifier"):
        # A stream IS claimed for this project, just not by this session — the
        # ordinary case after a `/clear`, which mints a new session id. Saying
        # "No stream claimed" here is simply false, and it is what sends the
        # next session off to open a second stream on the same work. Name it
        # and stop: adopting it silently is the thing the per-session pointer
        # exists to prevent.
        lines.append(f"This session has not claimed a stream. "
                     f"{latest['identifier']} is the one most recently claimed "
                     f"for this project. Claim it before writing a handoff, or "
                     f"claim a different one.")
    elif items:
        # Several streams and none claimed. List them, inject none: guessing
        # which of three handoffs is yours is how a session starts by
        # confidently doing the wrong work.
        lines.append("No stream claimed. Claim one before writing a handoff.")
    if handoff_html:
        lines.append("\nMost recent handoff on the active stream:\n")
        lines.append(handoff_html)
    return "\n".join(lines)


def handle(payload: dict) -> dict | None:
    cwd = payload.get("cwd")
    session = payload.get("session_id", "")
    source = payload.get("source", "startup")

    if hs.project_owned(cwd):
        hs.record_standdown(cwd, "sessionstart", "project_owned")
        return None

    project = hs.resolve_project(cwd)
    pointer = hs.read_pointer(session)
    if not project and not pointer:
        return None
    if not project and pointer:
        project = {"identifier": pointer.get("identifier", "?"),
                   "name": "", "workspace": pointer.get("workspace", ""),
                   "id": pointer.get("project_id", "")}

    try:
        items = plane.open_items(project["workspace"], project["id"], TIMEOUT)
    except plane.PlaneError as exc:
        # Loud and distinct. Never the same shape as an empty board.
        return _common.emit("SessionStart",
                            f"Plane was unreachable, so the board for "
                            f"{project['identifier']} could not be read: {exc}. "
                            f"This is NOT an empty board. Do not conclude there "
                            f"is no open work.")
    except Exception:  # noqa: BLE001 - a hook must never break a session
        return None

    # Only when this directory's own project came back empty and nothing is
    # claimed. There is no workspace-level list to ask instead, that call is a
    # 404, so this costs one read per sibling project and must stay off the
    # path every ordinary session takes.
    elsewhere = []
    if not items and not pointer.get("identifier"):
        elsewhere = plane.open_elsewhere(
            project["workspace"],
            hs.sibling_projects(project["workspace"], project["id"]),
            TIMEOUT)

    handoff_html = None
    if source in CONTINUATION_SOURCES and pointer.get("parent_id"):
        try:
            handoff_html = plane.newest_comment(
                project["workspace"], project["id"], pointer["parent_id"], TIMEOUT)
        except Exception:  # noqa: BLE001
            handoff_html = None

    # Local directory scan, no gateway call, and only when this session holds
    # nothing of its own.
    latest = {} if pointer.get("identifier") else hs.latest_stream(project.get("id", ""))

    text = _render(project, items, pointer, handoff_html, elsewhere, latest)

    # Kept from the pre-board adapter and deliberately not dropped in the
    # rewrite. It is orthogonal to where the handoff lives: it reports that the
    # harness will not compact where this design assumes it does, and a
    # continuation is still what fetches the newest handoff comment above.
    #
    # The polarity is inverted from the original, because the healthy state
    # flipped with EXPECTED_PCT: absent is now correct and silent, and only a
    # value that is set is worth a word. Left as it was, it warned on every
    # single session start once the variable was deleted.
    actual = os.environ.get("CLAUDE_AUTOCOMPACT_PCT_OVERRIDE")
    if actual != EXPECTED_PCT:
        text += (f"\n\nNote: CLAUDE_AUTOCOMPACT_PCT_OVERRIDE is set to {actual}, "
                 "and it is expected to be unset. It moves compaction away from "
                 f"the {hs.COMPACT_CEILING} tokens the handoff thresholds are "
                 "tuned for, so the compaction advice lands at the wrong point "
                 "in the session. Worth telling the user.")
    return _common.emit("SessionStart", text)


if __name__ == "__main__":
    _common.run(handle)
