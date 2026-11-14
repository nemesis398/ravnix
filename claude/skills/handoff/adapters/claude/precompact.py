#!/usr/bin/env python3
# adapters/claude/precompact.py
"""PreCompact hook: reset the token high-water mark before a compaction.

This hook does not, and cannot, steer what the compaction summary contains.
Claude Code has no hookSpecificOutput variant for PreCompact: measured
2026-08-08 against a real compaction on this machine, emitting
{"hookSpecificOutput": {"hookEventName": "PreCompact", ...}} failed every
time with "Hook JSON output validation failed - (root): Invalid input", and
the harness's own printed schema lists variants only for PreToolUse,
UserPromptSubmit, PostToolUse, PostToolBatch, and Stop/SubagentStop. There is
no supported channel on this event for the summary, so nothing here tries to
be one. The compaction summary is always the harness's own stock template.

What this hook still does: reset the token high-water mark (last_fired) to 0.
Context drops to near zero after a compaction, so leaving the mark at its
pre-compaction value would push the next threshold out to 500k absolute, past
the 487k compaction point, and the advisor would speak once per session and
then go silent forever. stop.py also re-arms by itself when it finds the
context smaller than the mark, so a PreCompact that never ran costs nothing;
this reset is the earlier of the two, not the only one.

HANDOFF_PRECOMPACT_RAW=1 writes the same instructions to plain stdout instead
of staying silent. That channel is unverified rather than measured to fail
the way the JSON envelope did, and costs nothing to leave available, but it
is not the default: nothing confirms Claude Code reads PreCompact stdout for
anything either, and a hook that is silent unless asked otherwise is the
honest default until it is.
"""
from __future__ import annotations

import os
import sys

import _common
from _common import hs

WITH_STREAM = ("Your handoff for this work lives on Plane work item {identifier}. "
               "After this compaction, read it back before acting.\n")
WITHOUT_STREAM = ("No stream is claimed in this session, so there is no handoff "
                  "to come back to. Claim one if this work should survive.\n")


def handle(payload: dict) -> dict | None:
    if hs.project_owned(payload.get("cwd")):
        hs.record_standdown(payload.get("cwd"), "precompact", "project_owned")
        return None
    cwd = payload.get("cwd")
    session = payload.get("session_id", "")
    transcript = payload.get("transcript_path")

    # No longer literally first: the project-ownership check above can now
    # skip this whole function before it runs. Still unconditional with
    # respect to the goal check just below, which is the property that
    # actually matters here: a compaction drops context to near zero whether
    # or not anything below fires, because this hook is advisory and cannot
    # stop the harness's own compaction from proceeding regardless of what it
    # returns. Resetting only after the goal check, or not at all on that
    # branch, left the mark stale against a context that had already dropped,
    # the fire-once-then-silent-forever shape the reset exists to prevent.
    # Leaving it at 400k means the next threshold is 500k absolute, which a
    # freshly compacted session will never reach before it compacts again.
    stamp = hs.read_stamp(cwd, session)
    stamp["last_fired"] = 0
    hs.write_stamp(cwd, session, stamp)

    if transcript and _common.goal_is_active(transcript):
        # A compaction landing mid-goal-run must not overwrite the summary:
        # this skill has to be invisible to that loop, not merely quiet
        # about it. Same contract stop.py applies at Stop. The stamp reset
        # above still applies regardless, because it is unconditional.
        hs.record_standdown(cwd, "precompact", "goal_active")
        return None

    # The stream, not a file path. There is no slot any more, so naming
    # paths(cwd)["current"] here would point at the failure sink rather than
    # at where this session's work actually lives.
    pointer = hs.read_pointer(session)
    identifier = pointer.get("identifier")
    text = WITH_STREAM.format(identifier=identifier) if identifier else WITHOUT_STREAM

    if os.environ.get("HANDOFF_PRECOMPACT_RAW") == "1":
        sys.stdout.write(text)
    return None


if __name__ == "__main__":
    _common.run(handle)
