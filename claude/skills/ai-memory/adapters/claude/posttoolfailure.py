#!/usr/bin/env python3
# adapters/claude/posttoolfailure.py
"""PostToolUseFailure hook: the memory whose symptom is in the error.

A note's symptoms are the backticked spans of its description. When one of
them appears in the failed tool call's error, at most MAX_FAILURE_HITS notes
go out under the failure header, each once per session.

When no note's symptom is in the error, the failure is logged as a `miss`
and nothing is printed. The Sunday sweep groups the misses by `detail`, the
tool name and the first telling line of the error with every digit masked,
so the same failure with another port, line or pid groups as one. A failure
whose note the session already got is no miss: the memory exists, and the
context holds it.

A subagent and an interrupted call get nothing, and nothing is logged for
them. The script modules are imported inside the handler (see `_common`).
"""
from __future__ import annotations

import re

import _common

EVENT = "PostToolUseFailure"
DETAIL_MAX = 160
# The line Claude Code puts above a failed command's output.
_EXIT_CODE = re.compile(r"Exit code -?\d+")
_DIGIT = re.compile(r"\d")


def miss_detail(tool: str, error: str) -> str:
    """`tool: line`, where line is the first line of `error` that is neither
    blank nor `Exit code N`. Every digit becomes `#`, and the whole is cut at
    DETAIL_MAX characters. Just `tool` when there is no such line."""
    lines = (raw.strip() for raw in error.splitlines())
    first = next((s for s in lines if s and not _EXIT_CODE.fullmatch(s)), "")
    return _DIGIT.sub("#", f"{tool}: {first}" if first else tool)[:DETAIL_MAX]


def handle(payload: dict) -> dict | None:
    if _common.is_subagent(payload) or payload.get("is_interrupt"):
        return None
    import notes
    import retrieve
    import state

    session = str(payload.get("session_id") or "")
    error = payload.get("error")
    error = error if isinstance(error, str) else ""
    try:
        vault = notes.vault_root()
    except LookupError:  # vault.root is not set: the skill is off, quietly
        return None
    found, problems = notes.load_notes(vault / notes.MEMORY_DIR, vault)
    _common.log_problems(problems)
    given = set(state.seen(session)["injected"])
    hits = retrieve.match_failure(error, found, given)
    if hits:
        text = "\n".join([retrieve.header("failure", vault), *map(retrieve.line, hits)])
        rels = [note.rel for note in hits]
        state.remember(session, rels, [])
        state.log(EVENT, session, "failure", rels, chars=len(text))
        return _common.emit(EVENT, text)
    if not retrieve.match_failure(error, found, set()):
        tool = str(payload.get("tool_name") or "")
        state.log(EVENT, session, "miss", [], miss_detail(tool, error), chars=0)
    return None


if __name__ == "__main__":
    _common.run(handle)
