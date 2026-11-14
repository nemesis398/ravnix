#!/usr/bin/env python3
# adapters/claude/stop.py
"""Stop hook: remind the session to journal, once, when work has wound down."""
from __future__ import annotations

import _common
from _common import js

# The tuning knob of this design. At 2 the nudge can arrive a turn later than
# ideal; at 1 it can interrupt a turn where the model only answered a
# question. Once-per-session bounds the damage either way. Revisit after a
# week of real sessions.
QUIET_TURNS = 2

NUDGE = ("This session changed files and has not written a session note. "
         "If any of it clears the bar in the journal skill, a decision whose "
         "reasoning will matter later, a non-obvious finding, or a finished "
         "artifact, write the session note now with that skill. If none of it "
         "does, say so in one line and carry on.")


def handle(payload: dict) -> dict | None:
    cwd = payload.get("cwd")

    transcript = payload.get("transcript_path")
    if not transcript:
        js.record_standdown(cwd, "stop", "no_transcript")
        return None

    # Ahead of every check below, because nothing they decide matters to a
    # headless run: only an interactive main session writes a session note,
    # and a nudge costs a `claude -p` run a turn with nobody there to read it.
    if not _common.is_interactive(_common._tail_records(transcript)):
        js.record_standdown(cwd, "stop", "not_interactive")
        return None

    # A previous Stop hook is why the session is still running: an autonomous
    # /goal loop, an agent, a skill. Injecting into that is how a run gets
    # steered off its own condition. The stamp stays untouched so the nudge
    # can still fire once the loop actually ends.
    if payload.get("stop_hook_active"):
        js.record_standdown(cwd, "stop", "stop_hook_active")
        return None

    if _common.goal_is_active(transcript):
        js.record_standdown(cwd, "stop", "goal_active")
        return None

    session = payload.get("session_id", "")
    stamp = js.read_stamp(cwd, session)
    if stamp.get("fired"):
        return None

    seen = _common.turns(transcript)
    if any(turn["journalled"] for turn in seen):
        js.record_standdown(cwd, "stop", "already_journalled")
        return None
    if not any(turn["modified"] for turn in seen):
        return None
    if len(seen) < QUIET_TURNS:
        return None
    if any(turn["modified"] for turn in seen[-QUIET_TURNS:]):
        js.record_standdown(cwd, "stop", "still_working")
        return None

    stamp["fired"] = True
    js.write_stamp(cwd, session, stamp)
    return _common.emit("Stop", NUDGE)


if __name__ == "__main__":
    _common.run(handle)
