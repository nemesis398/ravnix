# adapters/claude/_common.py
"""Shared plumbing for the Claude Code hook adapters.

The one rule these enforce: whatever goes wrong, exit 0 and stay quiet. A hook
that raises blocks a turn, and a handoff is not worth a broken session. Errors
go to the log so they are still findable.
"""
from __future__ import annotations

import json
import os
import sys
import traceback
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import handoff_state as hs  # noqa: E402

# How much of the transcript any reader here examines. One constant, so the
# usage reader, the goal check and the advisor's turn reader can never drift on
# it. 256 KiB holds the last turn of an ordinary session several times over,
# and parses in about 5 ms; the whole file can run to hundreds of megabytes.
TAIL_BYTES = 262_144


def disabled() -> bool:
    """The kill switch. HANDOFF_DISABLED=1 and nothing else means off.

    Checked once, in `run()`, so all three adapters share it and cannot
    drift. Gives the user a way to silence the whole skill for a session, e.g. a
    /goal run this hasn't been proven safe around yet, without editing
    settings.json or unstowing anything.
    """
    return os.environ.get("HANDOFF_DISABLED") == "1"


def log(message: str) -> None:
    try:
        target = hs.state_root() / "handoff.log"
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("a", encoding="utf-8") as fh:
            fh.write(message.rstrip() + "\n")
    except Exception:
        pass


def _tail_lines(path: str, tail_bytes: int) -> list[str]:
    """Raw lines from the last `tail_bytes` of `path`, oldest of the window first.

    Shared by `last_usage_tokens`, `goal_is_active` and `tail_records` so the
    transcript readers can never drift on how much of a multi-megabyte file
    gets examined. An unreadable path yields an empty list rather than
    raising; every caller already treats "nothing found" as its safe default.
    """
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - tail_bytes))
            chunk = fh.read().decode("utf-8", "ignore")
    except OSError:
        return []
    return chunk.splitlines()


def _tail_records(path: str, tail_bytes: int):
    """Parsed JSON objects from the tail of `path`, most recent first.

    Shares the strip, skip-non-object, parse-or-skip sequence between
    `last_usage_tokens`, `goal_is_active` and `tail_records`, leaving each
    with only its own per-record logic. A line that starts with `{` but still
    fails to parse is skipped, same as before; a non-object top-level JSON
    value cannot pass the `{` check, so callers can rely on receiving a dict.
    """
    for line in reversed(_tail_lines(path, tail_bytes)):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            yield json.loads(line)
        except ValueError:
            continue


def tail_records(path: str, tail_bytes: int = TAIL_BYTES) -> list[dict]:
    """The tail's parsed records in file order, oldest first.

    For readers that need turn structure, which only reads forwards. The same
    window and the same skip rules as `_tail_records`, which yields newest
    first for readers that stop at the first match.
    """
    return list(_tail_records(path, tail_bytes))[::-1]


def last_usage_tokens(transcript_path: str, tail_bytes: int = TAIL_BYTES) -> int | None:
    """Current context size, read from the last assistant entry's usage block.

    Only the tail is read because transcripts reach megabytes and this runs on
    every turn end. The three input fields together are the context size; the
    output field is not part of it.
    """
    for record in _tail_records(transcript_path, tail_bytes):
        if record.get("type") != "assistant":
            continue
        usage = (record.get("message") or {}).get("usage") or record.get("usage")
        if not isinstance(usage, dict):
            continue
        return (
            int(usage.get("input_tokens", 0) or 0)
            + int(usage.get("cache_creation_input_tokens", 0) or 0)
            + int(usage.get("cache_read_input_tokens", 0) or 0)
        )
    return None


# Measured 2026-08-09 against a real /goal run on Claude Code 2.1.226, in
# this vault's own transcript (906c8782-6d30-40a3-ad4a-b47daa18a65e.jsonl).
# Two records, both read directly from the raw file rather than assumed:
#
# Record 1483, written when /goal was set and the condition not yet met:
#   {"type": "attachment",
#    "attachment": {"type": "goal_status", "met": false, "sentinel": true,
#                   "condition": "the file ... exists"},
#    ...}
#
# Record 1512, written the next time the Stop hook evaluated and found the
# condition true, at which point Claude Code auto-clears the goal:
#   {"type": "attachment",
#    "attachment": {"type": "goal_status", "met": true,
#                   "condition": "the file ... exists", "reason": "...",
#                   "durationMs": ..., "iterations": ..., "tokens": ...},
#    ...}
#
# So: the record's own top-level `type` is "attachment", never "goal_status"
# itself; "goal_status" is a value of the nested `attachment.type`. The
# earlier guess looked for goal_status/goal_set/active_goal/activeGoal/
# goal_met as top-level keys on the record, which is why it could never have
# matched a real one: no such keys exist at that level, on either record.
# The set record additionally carries `attachment.sentinel: true` and no
# `reason`; the met record carries `attachment.reason`,
# `attachment.durationMs`, `attachment.iterations`, `attachment.tokens` and
# no `sentinel`. Only `attachment.type` and `attachment.met` are read below;
# the rest is noted here for a future reader, not consumed.
#
# Polarity, also measured rather than assumed: `met: false` is set and not
# yet satisfied, i.e. active. `met: true` is satisfied, and Claude Code
# auto-clears the goal at that point, i.e. not active.
#
# Not observed: whether `/goal clear` (clearing a goal early, before its
# condition is ever met) writes a transcript record at all, or what shape it
# has if it does. Nothing on this machine has ever run that command.


def _goal_state(record: dict) -> bool | None:
    """One transcript record's opinion on whether a goal is active.

    True means active (set, not yet met), False means not active (met, and
    therefore auto-cleared), None means this record carries no goal_status
    attachment, so the caller should keep looking at older records.
    """
    if not isinstance(record, dict):
        return None
    attachment = record.get("attachment")
    if not isinstance(attachment, dict):
        return None
    if attachment.get("type") != "goal_status":
        return None
    met = attachment.get("met")
    if not isinstance(met, bool):
        return None
    return not met


def goal_is_active(transcript_path: str, tail_bytes: int = TAIL_BYTES) -> bool:
    """Whether the transcript's most recent goal_status attachment shows a
    goal currently set and not yet met.

    Reads the same tail-limited slice as `last_usage_tokens`, for the same
    reason: this runs on every Stop and PreCompact, and transcripts reach
    megabytes. Returns False, the conservative default, whenever nothing in
    the tail carries a goal_status attachment: that degrades to the skill's
    behavior from before it knew about /goal at all, rather than guessing and
    risking a nudge that a goal never actually suppressed. See `_goal_state`
    above for the measured record shapes.
    """
    for record in _tail_records(transcript_path, tail_bytes):
        state = _goal_state(record)
        if state is not None:
            return state
    return False


def emit(event: str, context: str) -> dict:
    return {"hookSpecificOutput": {"hookEventName": event, "additionalContext": context}}


def run(handler) -> None:
    """Read stdin JSON, run the handler, print its dict, exit 0 no matter what.

    HANDOFF_DISABLED=1 short-circuits before the handler is ever called, so
    no adapter can nudge, inject, emit compaction instructions, or write a
    stamp while it is set. That stand-down is recorded (finding I4): the kill
    switch being on is easy to forget about days later, and this is the one
    stand-down reason none of the individual handlers can record themselves,
    since it preempts them.
    """
    try:
        raw = sys.stdin.read()
        if disabled():
            # Best-effort and isolated from the main parse below: this must
            # never be the reason a disabled adapter fails to exit cleanly.
            # Malformed stdin here just means the recording falls back to
            # cwd=None, which paths()/git_root() already handle the same way
            # as no --cwd at all.
            try:
                cwd = (json.loads(raw) if raw.strip() else {}).get("cwd")
            except ValueError:
                cwd = None
            hs.record_standdown(cwd, Path(sys.argv[0]).stem, "disabled")
        else:
            payload = json.loads(raw) if raw.strip() else {}
            result = handler(payload)
            if result:
                print(json.dumps(result))
    except BaseException:
        log(traceback.format_exc())
    raise SystemExit(0)
