#!/usr/bin/env python3
# adapters/claude/userpromptsubmit.py
"""UserPromptSubmit hook: the memory a prompt points at.

Two kinds of block, in this order:

- A digest for each domain the prompt touches through one of its keywords
  and that the session has not had a digest of, in name order. A digest
  that would push the text past CONTEXT_CAP is not added, and neither is
  any after it. Those domains stay undigested, so a later prompt that
  touches them gets their digest. A domain whose notes the session has all
  seen already has nothing to give and stays undigested too.
- The matches, at most MAX_MATCHES within MATCH_BUDGET, never a note the
  session already got or a digest above holds. When the digests leave too
  little room, the lowest-ranked matches are left out, so no line is ever
  cut off and the log names only what went out.

Nothing is repeated within a session (see `state`). A subagent gets nothing,
nor does a prompt Claude Code generated itself: a system message or one of
the wakeups. A headless `-p` prompt (`sdk`) is treated like a typed one.
The script modules are imported inside the handler (see `_common`).
"""
from __future__ import annotations

import _common

EVENT = "UserPromptSubmit"
SKIPPED_SOURCES = frozenset({"system", "loop_wakeup", "schedule_wakeup", "poll_event"})


def _joined(blocks: list[str]) -> str:
    return "\n\n".join(blocks)


def handle(payload: dict) -> dict | None:
    if _common.is_subagent(payload) or payload.get("source") in SKIPPED_SOURCES:
        return None
    prompt = payload.get("prompt")
    if not isinstance(prompt, str) or not prompt.strip():
        return None
    import notes
    import retrieve
    import state

    session = str(payload.get("session_id") or "")
    try:
        vault = notes.vault_root()
    except LookupError:  # vault.root is not set: the skill is off, quietly
        return None
    found, problems = notes.load_notes(vault / notes.MEMORY_DIR, vault)
    _common.log_problems(problems)
    domains = notes.load_domains()
    seen = state.seen(session)
    taken = set(seen["injected"])
    blocks: list[str] = []

    def block(head: str, chosen: list) -> str:
        return "\n".join([head, *map(retrieve.line, chosen)])

    def fits(new: str) -> bool:
        return len(_joined([*blocks, new])) <= _common.CONTEXT_CAP

    digests: list[tuple[str, list[str], str]] = []
    touched = retrieve.touched_domains(retrieve.tokens(prompt), domains)
    for domain in sorted(touched - set(seen["digested"])):
        chosen = retrieve.digest(domain, found, taken)
        if not chosen:
            continue
        digested = block(retrieve.header("digest", vault, domain), chosen)
        if not fits(digested):
            break
        blocks.append(digested)
        rels = [note.rel for note in chosen]
        taken.update(rels)
        digests.append((domain, rels, digested))

    hits = retrieve.match_prompt(prompt, found, domains, taken)
    head = retrieve.header("match", vault)
    while hits and not fits(block(head, hits)):
        hits.pop()
    matched = block(head, hits)
    if hits:
        blocks.append(matched)

    if not blocks:
        return None
    match_rels = [note.rel for note in hits]
    state.remember(session, [rel for _, rels, _ in digests for rel in rels] + match_rels,
                   [domain for domain, _, _ in digests])
    for domain, rels, digested in digests:
        state.log(EVENT, session, "digest", rels, domain, chars=len(digested))
    if hits:
        state.log(EVENT, session, "match", match_rels, chars=len(matched))
    return _common.emit(EVENT, _joined(blocks))


if __name__ == "__main__":
    _common.run(handle)
