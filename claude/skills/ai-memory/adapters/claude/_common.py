# adapters/claude/_common.py
"""The harness every ai-memory hook adapter runs under.

The hooks run on every prompt and every failed tool call of every Claude Code
session on this machine, so the one rule is to fail open. Whatever goes
wrong, a hook prints nothing, exits 0 and appends the traceback to `hook.log`
in the state root. A note the hook could not read goes there too, one line
each, so a note that drops out of the hooks leaves a trace. A
UserPromptSubmit hook that exits 2 blocks the prompt, and one that prints
anything but a JSON line breaks the turn, so `run` catches BaseException: a
handler's `sys.exit(2)` is caught too.

The scripts in the stow tree are live code, synced through Nextcloud and
edited while the hooks are registered, so any of them can be missing or
half written when a hook fires. An import fails open only inside `run`.
So adapters import their script modules (`state`, `notes`, `retrieve`)
inside the handler, never at module level, and this module imports none
of them.

Same shape as the handoff skill's `adapters/claude/_common.py`.
"""
from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import traceback
from collections.abc import Callable
from datetime import datetime
from pathlib import Path
from typing import NoReturn

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))

# Below Claude Code's limit of 10,000 characters for a hook's additionalContext.
CONTEXT_CAP = 9000


def disabled() -> bool:
    """The kill switch: `AI_MEMORY_DISABLED=1`, and nothing else, means off."""
    return os.environ.get("AI_MEMORY_DISABLED") == "1"


def is_subagent(payload: dict) -> bool:
    """Whether the hook fired inside a subagent, which gets no memory."""
    return bool(payload.get("agent_id"))


def emit(event: str, text: str) -> dict:
    """The hook output that adds `text` to the context, cut at CONTEXT_CAP."""
    return {"hookSpecificOutput": {"hookEventName": event, "additionalContext": text[:CONTEXT_CAP]}}


def state_root() -> Path:
    """`state.state_root()`, repeated here so a broken `state.py` is logged too.

    A test holds the two to the same answer.
    """
    override = os.environ.get("AI_MEMORY_STATE_ROOT")
    if override:
        return Path(override)
    return Path.home() / ".local" / "state" / "ai-memory"


def _append(text: str) -> None:
    """Append `text` to `hook.log` in the state root, creating the root."""
    root = state_root()
    root.mkdir(parents=True, exist_ok=True)
    with (root / "hook.log").open("a", encoding="utf-8") as fh:
        fh.write(text)


def _stamp() -> str:
    """The time and the hook's script name that open every hook.log entry."""
    return f"{datetime.now().astimezone().isoformat(timespec='seconds')} {Path(sys.argv[0]).name}"


def _log_failure() -> None:
    """Append the exception being handled to `hook.log`, under a stamp.

    A failure to log is swallowed as well: the hook still has to exit 0 when
    the state root cannot be written.
    """
    try:
        _append(f"{_stamp()}\n{traceback.format_exc().rstrip()}\n")
    except BaseException:
        pass


def log_problems(problems: list[tuple[str, str]]) -> None:
    """Append each (rel, reason) pair from `notes.load_notes` to `hook.log`.

    One line each, under the stamp, with the path and the reason and never
    the note's text. A failure to log is swallowed, so it never costs the
    hook what it injects.
    """
    if not problems:
        return
    try:
        stamp = _stamp()
        _append("".join(f"{stamp} {rel}: {' '.join(reason.split())}\n"
                        for rel, reason in problems))
    except BaseException:
        pass


def run(handler: Callable[[dict], dict | None]) -> NoReturn:
    """Run `handler` on the payload from stdin and exit 0, whatever happens.

    stdin is read first, also under the kill switch, which then skips the
    rest. The payload has to be JSON. Whatever the handler prints itself is
    dropped, so its result is the only thing on stdout, as one JSON line, and
    None prints nothing. Anything raised on the way is logged, never printed.
    """
    try:
        raw = sys.stdin.read()
        if not disabled():
            with contextlib.redirect_stdout(io.StringIO()):
                result = handler(json.loads(raw))
            if result:
                print(json.dumps(result), flush=True)
    except BaseException:
        _log_failure()
    # Not SystemExit(0): when the flush of stdout at exit fails, as it does
    # once the reader has closed the pipe, Python exits 120. os._exit skips
    # that flush, and the line was flushed above.
    os._exit(0)
