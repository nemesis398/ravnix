#!/usr/bin/env python3
# adapters/claude/stop.py
"""Stop hook: measure the context and advise the user when to compact or start fresh."""
from __future__ import annotations

import os
import subprocess

import _common
import advisor
from _common import hs

# The nudge used to speak to the model, which is what made the handoff fire by
# itself. It now speaks to the user: systemMessage renders to them and does not
# re-invoke the model, so the turn ends where it would have ended anyway. The
# whole resume apparatus above the stop_hook_active guard goes quiet with it,
# because nothing arms resume_ready() when no nudge instructs anyone.
#
# That systemMessage renders on Stop is measured, not assumed. Probed
# 2026-08-23 with a throwaway third Stop hook: the user saw the literal marker
# string in their terminal, and a marker file proved the hook had run, so a
# rendered string is a real yes rather than a hook that happened to fire.
# The harness prefixes the text with "Stop says: ", which is why the advice
# does not open by naming the hook: it would read as a stutter.
#
# hs.CONTINUE_CLAUSE and hs.resume_ready are deliberately left in the brain
# untouched. a project's own Plane Stop hook imports both by absolute path.
#
# One line was not enough. TOOLS-18's acceptance run failed on 2026-08-25 and
# not on the half that was worried about: the reminder fired at 200k and again
# at 300k, the model correctly ignored both, and the user could not find either
# line afterwards. Rendering and being seen are different questions, and only
# the first had been probed. The reminder now takes several lines with a rule
# around it, and it also leaves the terminal entirely, below.
#
# The reminder became the compaction advisor on 2026-10-17, when the window
# moved to 500k. It no longer only says "write a handoff". It says which of
# /compact or /clear fits, and whether a handoff should come first, and only at
# a natural break in the work until the hard band, where it says it regardless.
# advisor.py holds the reading and the wording; this file keeps the gates, the
# stamp and the two deliveries. One stamp and one message per Stop is also what
# stops the advisor and the old reminder from both firing: there is only one.


def notify_argv(level: str, tokens: int, stream: str, short: str) -> list[str]:
    """The desktop notification, as a command. Pure, so it can be asserted on.

    Separate from the sending so a test can check what would be sent without a
    notification popping on the user's desktop every time the suite runs.
    """
    return ["notify-send", "--app-name", "Claude Code",
            "--urgency", "critical" if level == "hard" else "normal",
            ("Compact or hand off now" if level == "hard"
             else "Good moment to compact or hand off"),
            f"{tokens:,} tokens{stream}. Suggest: {short}."]


def notify(level: str, tokens: int, stream: str, short: str) -> None:
    """Put the reminder where scrollback cannot bury it.

    It does not re-invoke the model and cannot: it is a process, not a hook
    field.

    Silent with no session bus, which covers cron, ssh and headless runs, and
    silent on failure, because a missing notify-send or a dead daemon is not a
    reason to lose the reminder that is already on its way to the terminal.
    """
    if not os.environ.get("DBUS_SESSION_BUS_ADDRESS"):
        return None
    try:
        subprocess.run(notify_argv(level, tokens, stream, short),
                       timeout=2, check=False, capture_output=True)
    except (OSError, subprocess.SubprocessError):
        pass
    return None


def handle(payload: dict) -> dict | None:
    if hs.project_owned(payload.get("cwd")):
        hs.record_standdown(payload.get("cwd"), "stop", "project_owned")
        return None
    cwd = payload.get("cwd")
    session = payload.get("session_id", "")
    stamp = hs.read_stamp(cwd, session)

    # The harness's documented contract for Stop/SubagentStop hooks: when a
    # previous Stop hook is why the session is still running (an autonomous
    # /goal loop, an agent, a skill), stay out of it entirely. Silent, and the
    # stamp is untouched so the threshold can still fire once the loop
    # actually ends instead of being consumed by a turn that was suppressed.
    if payload.get("stop_hook_active"):
        hs.record_standdown(cwd, "stop", "stop_hook_active")
        return None
    transcript = payload.get("transcript_path")
    if not transcript:
        hs.record_standdown(cwd, "stop", "no_transcript")
        return None
    if _common.goal_is_active(transcript):
        # A /goal run is exactly the kind of stop-hook loop a reminder would
        # clutter: its state lives only in the transcript, so a hook that
        # ignores it derails the run. Same contract as stop_hook_active above,
        # stamp untouched for the same reason.
        hs.record_standdown(cwd, "stop", "goal_active")
        return None
    tokens = _common.last_usage_tokens(transcript)
    if tokens is None:
        hs.record_standdown(cwd, "stop", "no_usage")
        return None

    # Re-arm after a compaction, read from the context itself. A context
    # smaller than the band that already fired has been compacted, or rewound,
    # since. precompact.py resets the mark too, but only if it ran, and with
    # the same cwd: this does not depend on either. Written at once, because
    # in memory alone the reset is lost the moment the context grows back
    # past the old mark without firing, and that band would stay silent.
    last_fired = int(stamp.get("last_fired", 0) or 0)
    if tokens < last_fired:
        last_fired = stamp["last_fired"] = 0
        hs.write_stamp(cwd, session, stamp)
    level, mark = hs.verdict(tokens, last_fired)
    if level == "none":
        return None

    pointer = hs.read_pointer(session)
    records = _common.tail_records(transcript)
    found = advisor.boundary(advisor.last_turn(records), pointer.get("parent_id") or "")
    if level == "soft" and found is None:
        # Mid-work in the soft band: wait for a natural break. Nothing is
        # stamped, so the band stays armed for the next turn end, and the
        # hard band speaks regardless if no break ever comes.
        hs.record_standdown(cwd, "stop", "awaiting_boundary")
        return None
    # last_fired is all that is written. nudged_at and resumed armed the
    # resume shot that was deleted, and writing state nothing reads would
    # leave a false comment behind in a Nextcloud-synced tree.
    stamp["last_fired"] = mark
    hs.write_stamp(cwd, session, stamp)

    # Naming the stream is what makes the advice actionable: "write a
    # handoff" is a chore, "write a handoff for TOOLS-12" is a decision the user
    # can already answer. With no stream claimed, saying so is the point, since
    # the handoff has nowhere to go until one is.
    identifier = pointer.get("identifier") or ""
    if identifier:
        stream = f", on {identifier}"
    else:
        project = hs.resolve_project(cwd)
        stream = (f", no stream claimed in {project['identifier']}" if project
                  else ", no stream claimed")

    # The share decides only between the two ways of carrying on, so it is
    # counted only when the work goes on: mid-work in the hard band, or at a
    # step rather than at the end of the work.
    goes_on = found is None or found["kind"] == "step"
    share = advisor.tool_share(records) if goes_on else None
    action = advisor.recommend(found, share)
    notify(level, tokens, stream, advisor.SHORT[action])
    # Returned bare, with no hookSpecificOutput: that field is what re-invokes
    # the model, and a full-context turn at 200k and up is the expensive thing
    # this whole hook exists to save. The notification above is deliberately
    # not that either: it reaches the user without the model ever learning a
    # threshold was crossed.
    return {"systemMessage": advisor.render(level, tokens, stream, identifier,
                                            found, action, hs.COMPACT_CEILING)}


if __name__ == "__main__":
    _common.run(handle)
