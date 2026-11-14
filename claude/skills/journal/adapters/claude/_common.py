# adapters/claude/_common.py
"""Shared plumbing for the Claude Code journal adapter.

The one rule: whatever goes wrong, exit 0 and stay quiet. A hook that raises
blocks a turn, and a journal entry is not worth a broken session.

The transcript readers below are deliberately a copy of the ones in
handoff/adapters/claude/_common.py rather than an import. They read a Claude
Code protocol, not a handoff internal, and each skill has to keep working
when the other is removed. The measured goal_status record shapes, including
the polarity of `met`, are documented at handoff/adapters/claude/_common.py
lines 101 to 136; that comment is the source of truth and is not restated
here.
"""
from __future__ import annotations

import json
import os
import re
import sys
import traceback
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import journal_state as js  # noqa: E402

TAIL_BYTES = 262_144

# What counts as journalled: the session note's writer run with its verb, or an
# edit to a note in the vault's AI/sessions/. The command has to stand where a
# command starts, at the beginning or after `&&`, `;`, `|`, a parenthesis or a
# newline, with the verb right after the script. Anything looser counts a
# session that greps for the command, prints the script or asks it for --help,
# which is what a session working on this skill does all day. The pattern is a
# copy of the advisor's in handoff/adapters/claude/advisor.py, not an import,
# for the reason in this module's docstring.
#
# The interpreter may be named by a path, as ravnix renders it into SKILL.md:
# the store path of its python3.
SESSION_NOTE_WRITE = re.compile(
    r"(?:^|[;&|(\n])\s*(?:\S*python3?(?:\s+-\S+)*\s+)?\S*session_note\.py\s+write\b")
# A vault commit on a ravnix host, `vault-commit MESSAGE PATH...`
# (modules/glue/vault.nix), changes files as `git commit` does. Matched where
# a command starts, so a session that greps for it does not count.
VAULT_COMMIT = re.compile(r"(?:^|[;&|(\n])\s*vault-commit\s")
SESSION_NOTES = "/AI/sessions/"


def disabled() -> bool:
    """JOURNAL_DISABLED=1 and nothing else means off."""
    return os.environ.get("JOURNAL_DISABLED") == "1"


def log(message: str) -> None:
    try:
        target = js.state_root() / "journal.log"
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("a", encoding="utf-8") as fh:
            fh.write(message.rstrip() + "\n")
    except Exception:
        pass


def _tail_records(path: str, tail_bytes: int = TAIL_BYTES):
    """Parsed records from the tail of the transcript, oldest of the window first.

    Only the tail is read: transcripts reach megabytes and this runs on every
    turn end. Oldest-first because turn structure only reads forwards.
    """
    try:
        with open(path, "rb") as fh:
            fh.seek(0, os.SEEK_END)
            size = fh.tell()
            fh.seek(max(0, size - tail_bytes))
            chunk = fh.read().decode("utf-8", "ignore")
    except OSError:
        return
    for line in chunk.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            yield json.loads(line)
        except ValueError:
            continue


def _goal_state(record: dict) -> bool | None:
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


def goal_is_active(transcript_path: str) -> bool:
    """Whether the most recent goal_status attachment shows a live goal.

    False whenever nothing in the tail carries one, which degrades to the
    behavior from before this skill knew about /goal rather than guessing.
    """
    state = False
    for record in _tail_records(transcript_path):
        opinion = _goal_state(record)
        if opinion is not None:
            state = opinion
    return state


def _tool_uses(record: dict):
    message = record.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if not isinstance(content, list):
        return
    for block in content:
        if isinstance(block, dict) and block.get("type") == "tool_use":
            yield block


def turns(transcript_path: str) -> list[dict]:
    """One dict per user turn: {"modified": bool, "journalled": bool}.

    A turn is the stretch between two real user messages, so a tool result
    does not open a new one. This is what "the last two turns changed
    nothing" is measured against.
    """
    out: list[dict] = []
    for record in _tail_records(transcript_path):
        if record.get("type") == "user":
            message = record.get("message")
            content = message.get("content") if isinstance(message, dict) else None
            is_result = isinstance(content, list) and any(
                isinstance(b, dict) and b.get("type") == "tool_result"
                for b in content)
            if not is_result:
                out.append({"modified": False, "journalled": False})
            continue
        if record.get("type") != "assistant" or not out:
            continue
        for block in _tool_uses(record):
            name = block.get("name")
            args = block.get("input") or {}
            if name in ("Edit", "Write", "NotebookEdit"):
                out[-1]["modified"] = True
                if SESSION_NOTES in str(args.get("file_path", "")):
                    out[-1]["journalled"] = True
            elif name == "Bash":
                command = str(args.get("command", ""))
                if "git commit" in command or VAULT_COMMIT.search(command):
                    out[-1]["modified"] = True
                if SESSION_NOTE_WRITE.search(command):
                    out[-1]["journalled"] = True
    return out


def is_interactive(transcript_lines) -> bool:
    """Whether the newest record carrying `entrypoint` says "cli".

    `transcript_lines` are the transcript's parsed records, oldest first, as
    `_tail_records` yields them. Claude Code stamps `entrypoint` on every user,
    assistant, attachment and system record: "cli" in an interactive session,
    "sdk-cli" under `claude -p` (measured 2026-10-17 over 239 transcripts: 211
    and 28). The newest one decides, because a resume can run the same
    transcript the other way. No record with the key, which covers an empty or
    unreadable transcript, reads as headless: a nudge nobody reads costs a
    turn, and a nudge missed costs nothing.
    """
    entrypoint = None
    for record in transcript_lines:
        if isinstance(record, dict) and "entrypoint" in record:
            entrypoint = record["entrypoint"]
    return entrypoint == "cli"


def emit(event: str, context: str) -> dict:
    return {"hookSpecificOutput": {"hookEventName": event,
                                   "additionalContext": context}}


def run(handler) -> None:
    """Read stdin JSON, run the handler, print its dict, exit 0 no matter what."""
    try:
        raw = sys.stdin.read()
        if disabled():
            try:
                cwd = (json.loads(raw) if raw.strip() else {}).get("cwd")
            except ValueError:
                cwd = None
            js.record_standdown(cwd, Path(sys.argv[0]).stem, "disabled")
        else:
            payload = json.loads(raw) if raw.strip() else {}
            result = handler(payload)
            if result:
                print(json.dumps(result))
    except BaseException:
        log(traceback.format_exc())
    raise SystemExit(0)
