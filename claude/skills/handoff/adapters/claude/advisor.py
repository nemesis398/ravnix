# adapters/claude/advisor.py
"""The compaction advisor: whether this turn end is a good moment to compact
or to start fresh, and which of the two.

stop.py owns every gate and the stamp. This module only reads the transcript
records stop.py hands it and renders the line the user sees, and stop.py returns
that line as a bare systemMessage, so none of it ever reaches the model.

Everything here is a pure function over parsed records. A turn end that gets
this far costs one parse of the tail `_common` already reads and nothing else:
no subprocess, no network, no model turn.

Why these boundary signals and no others. Each one is a tool call the session
already makes when a piece of work ends, so it costs a string test on a record
that is in the tail anyway, and each is unambiguous about what happened:

- A git commit, or a vault commit through `vault-commit MESSAGE PATH...`,
  which is how a ravnix host commits the vault. The most common boundary by
  far, and its subject is the best one-line hint there is.
- A Plane work item closed or moved. The user's plan steps are sub-items, so a
  state change is a finished step, and the claimed parent closing is a
  finished stream.
- A todo step completed with TaskUpdate. TodoWrite is not read: across the
  1,065 transcripts on this machine on 2026-10-17 it was never called once.
- A journal entry, which is a session note in the vault's AI/sessions/, a
  stream released or claimed, or a handoff posted to the claimed parent. These
  say the work, not just a step, has ended or changed.
  A handoff is a comment that opens with `plane.HANDOFF_MARKER`. Any other
  comment on the parent is not one: a project with its own Plane hooks may
  want an evidence comment on its active item the moment work starts.

What is deliberately not read: the text of the conversation. Guessing from
prose whether a topic changed is the transcript scraping this design rejects,
and it would be wrong in exactly the cases where it matters.
"""
from __future__ import annotations

import json
import re

# A constant and a string test, no transport: the caller has already put
# scripts/ on sys.path, stop.py through _common and a project's own hook by hand.
import plane

# Above this share, the context is mostly tool calls and their output, which a
# compaction can drop at little cost, because all of it can be read again from
# disk. Below it, the context is mostly conversation, which a compaction summary
# flattens and a handoff keeps. Measured 2026-10-17 over the 30 largest
# transcripts on this machine, in the same 256 KiB tail: working sessions sat
# between 0.59 and 1.00 and discussion sessions between 0.00 and 0.17, so 0.5
# falls in the gap between the two clusters rather than on either.
TOOL_SHARE = 0.5

# A hint is there to be recognized, not read. A commit subject is capped at 72
# by convention, and a Plane item name is not capped at all.
HINT_CHARS = 60

# Every command below has to stand where a command starts: at the beginning, or
# after `&&`, `;`, `|`, a parenthesis or a newline. Anything looser matches a
# session that greps for these commands or reads the scripts, which is what a
# session working on them does all day.
AT_COMMAND = r"(?:^|[;&|(\n])\s*"
# `git commit`, and the same with global options in front of it, `git -C dir
# commit` being the form a session uses outside its own directory. `git log
# --grep commit` does not match: the word has to be the subcommand.
GIT_COMMIT = re.compile(
    AT_COMMAND + r"git(?:\s+-[Cc]\s+\S+|\s+--?[\w-]+(?:=\S+)?)*\s+commit\b")
# What git prints for a commit it made: "[main 1a2b3c4] subject", with
# "(root-commit)" or "detached HEAD" possibly inside the brackets.
COMMIT_LINE = re.compile(r"^\[[^\]\n]*\s([0-9a-f]{7,40})\]\s+(.+)$", re.M)
# What `git log --oneline` prints, which is how a `git commit -q` reports
# itself in most of these sessions. The newest commit comes first.
ONELINE = re.compile(r"^([0-9a-f]{7,40}) (\S.*)$", re.M)
# The message in the command itself, for when the output carries neither: the
# first line of a heredoc, else the first line of `-m`.
HEREDOC = re.compile(r"<<-?\s*['\"]?\w+['\"]?[^\n]*\n\s*([^\n]+)")
MESSAGE = re.compile(r"""\s-[a-zA-Z]*m\s*(["'])([^\n]*?)(?:\1|\n|$)""")
# An exit status of 0 does not prove a commit: these sessions routinely end a
# compound command with `echo rc=$?`, which hides a refused signature.
COMMIT_FAILED = ("fatal:", "nothing to commit", "nothing added to commit",
                 "commit failed")
# `vault-commit MESSAGE PATH...` (ravnix's modules/glue/vault.nix), the only
# way a vault skill commits on a ravnix host. Its message is the first word,
# quoted or bare. On the laptop it may answer that the server queued the
# commit, with no sha, so the message comes from the command.
VAULT_COMMIT = re.compile(AT_COMMAND + r"vault-commit\s+(?:(['\"])([^\n]*?)\1|([^\s'\"]+))")

# The two skills' scripts, run the way their SKILL.md files run them, with the
# verb right after the script. The interpreter may be named by a path, as
# ravnix renders it: the store path of its python3.
SCRIPT = AT_COMMAND + r"(?:\S*python3?(?:\s+-\S+)*\s+)?\S*"
JOURNAL = re.compile(SCRIPT + r"session_note\.py\s+write\b")
RELEASE = re.compile(SCRIPT + r"handoff_state\.py\s+release\b")
CLAIM = re.compile(SCRIPT + r"handoff_state\.py\s+claim\b")
IDENTIFIER = re.compile(r"--identifier[=\s]+['\"]?([\w-]+)")

# Which signal wins when one turn carries several. The stronger statement about
# the work wins, and among equals the later one, since it is the newer news.
RANK = {"step": 1, "finished": 2, "closed": 3, "handoff": 3}

# The short form, for the desktop notification.
SHORT = {
    "compact": "/compact",
    "handoff+compact": "handoff, then /compact",
    "handoff+clear": "handoff, then /clear",
    "clear+resume": "/clear",
    "clear": "/clear",
}

WHY = {
    "compact": "The work goes on, and most of the context is old tool output.",
    "handoff+compact": ("The work goes on, but the context is mostly "
                        "conversation, which a summary flattens."),
    "handoff+clear": ("That piece of work looks finished, so start fresh "
                      "instead of compacting."),
    "clear+resume": ("The handoff holds where the work stands, so start "
                     "fresh from it."),
    "clear": "The stream is closed, so nothing needs handing off.",
}

RULE = "─" * 62


def _clip(text: str, limit: int = HINT_CHARS) -> str:
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 3].rstrip() + "..."


def _blocks(record: dict, kind: str):
    message = record.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if isinstance(content, list):
        for block in content:
            if isinstance(block, dict) and block.get("type") == kind:
                yield block


def _text(block: dict) -> str:
    """A tool result's text, whichever of its two shapes it came in."""
    content = block.get("content")
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(str(part.get("text", "")) for part in content
                         if isinstance(part, dict))
    return ""


def _is_prompt(record: dict) -> bool:
    """Whether this record is the user starting a turn.

    A tool result is a user record too, and so is the text of a skill the
    model loaded, or a subagent's report arriving. Both of the latter carry
    `isMeta`, and counting either as a prompt would cut a turn in half and
    hide the commit made before it.
    """
    if record.get("type") != "user" or record.get("isMeta"):
        return False
    message = record.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    if isinstance(content, str):
        return True
    return isinstance(content, list) and not any(_blocks(record, "tool_result"))


def since_compaction(records: list[dict]) -> list[dict]:
    """The records after the newest compaction boundary in the window.

    Anything before it is no longer in the context, so it can neither be the
    turn that just ended nor count toward what the context is made of.
    """
    for index in range(len(records) - 1, -1, -1):
        record = records[index]
        if record.get("type") == "system" and record.get("subtype") == "compact_boundary":
            return records[index + 1:]
    return records


def last_turn(records: list[dict]) -> list[dict]:
    """The records since the user's last prompt, oldest first.

    With no prompt in the window, the turn is longer than the window and all
    of it is the turn. A signal near its start can then be missed, which errs
    toward saying nothing.
    """
    records = since_compaction(records)
    for index in range(len(records) - 1, -1, -1):
        if _is_prompt(records[index]):
            return records[index + 1:]
    return records


def _commit(command: str, output: str) -> tuple[str, str]:
    """(short sha, subject) of the commit a command made, either may be ""."""
    for pattern in (COMMIT_LINE, ONELINE):
        hit = pattern.search(output)
        if hit:
            return hit.group(1)[:7], hit.group(2).strip()
    hit = HEREDOC.search(command)
    if hit:
        return "", hit.group(1).strip()
    hit = MESSAGE.search(command)
    if hit and not hit.group(2).startswith("$("):
        return "", hit.group(2).strip()
    return "", ""


def _plane_result(output: str) -> dict:
    try:
        loaded = json.loads(output)
    except ValueError:
        return {}
    if not isinstance(loaded, dict):
        return {}
    item = loaded.get("result", loaded)
    return item if isinstance(item, dict) else {}


def _signals(use: dict, result: dict | None, parent_id: str):
    """(kind, hint, commit subject) for each boundary one tool call made.

    A call with no result, or an error for one, made nothing happen, so it
    signals nothing. The Plane gateway reports a refused call as text that
    starts with "Error" and leaves `is_error` unset, which is why that string
    is checked as well.
    """
    if result is None or result.get("is_error"):
        return
    name = str(use.get("name", ""))
    args = use.get("input") if isinstance(use.get("input"), dict) else {}
    output = _text(result)

    if name == "Bash":
        command = str(args.get("command", ""))
        if JOURNAL.search(command):
            yield "finished", "journal entry written", ""
        if RELEASE.search(command):
            yield "closed", "stream released", ""
        elif CLAIM.search(command):
            claimed = IDENTIFIER.search(command)
            yield ("finished",
                   f"switched to {claimed.group(1)}" if claimed else "new stream claimed",
                   "")
        vault = VAULT_COMMIT.search(command)
        if (GIT_COMMIT.search(command) or vault) and not any(m in output for m in COMMIT_FAILED):
            sha, subject = _commit(command, output)
            if not subject and vault:
                subject = (vault.group(2) or vault.group(3) or "").strip()
            subject = _clip(subject)
            label = " ".join(part for part in ("commit", sha, subject) if part)
            yield "step", label, subject
        return

    if name in ("Edit", "Write", "NotebookEdit"):
        if "/AI/sessions/" in str(args.get("file_path", "")):
            yield "finished", "journal entry written", ""
        return

    if name == "TaskUpdate":
        if args.get("status") == "completed":
            yield "step", "todo step done", ""
        return

    if not name.startswith("mcp__plane") or output.lstrip().startswith("Error"):
        return
    target = args.get("workitem_id")
    is_parent = bool(parent_id) and target == parent_id
    if name.endswith("__workitem_comment"):
        if (args.get("action") == "create" and is_parent
                and plane.is_handoff(args.get("comment_html"))):
            yield "handoff", "handoff posted", ""
        return
    if name.endswith("__workitem") and args.get("action") == "update" and args.get("state"):
        item = _plane_result(output)
        label = _clip(str(item.get("name") or "")) or "a work item"
        if not item.get("completed_at"):
            yield "step", f"moved {label}", ""
        elif is_parent:
            yield "closed", f"closed {label}", ""
        else:
            yield "step", f"closed {label}", ""


def boundary(turn: list[dict], parent_id: str = "") -> dict | None:
    """The natural break the last turn ended on, or None if it ended mid-work.

    `parent_id` is the claimed stream's parent item, from the session's
    pointer. It is what tells a handoff from an evidence comment on a step,
    and the stream closing from one sub-item closing.
    """
    results = {}
    for record in turn:
        for block in _blocks(record, "tool_result"):
            results[block.get("tool_use_id")] = block
    best = None
    subject = ""
    for record in turn:
        if record.get("type") != "assistant":
            continue
        for use in _blocks(record, "tool_use"):
            for kind, hint, commit in _signals(use, results.get(use.get("id")), parent_id):
                subject = commit or subject
                if best is None or RANK[kind] >= RANK[best[0]]:
                    best = (kind, hint)
    if best is None:
        return None
    return {"kind": best[0], "hint": best[1], "commit": subject}


def tool_share(records: list[dict]) -> float | None:
    """How much of the context since the last compaction is tool traffic.

    A proxy, counted in characters of the window rather than tokens of the
    context. Tool calls, their results and text the harness injected
    (`isMeta`: loaded skills, subagent reports) count as tool traffic,
    because all of it can be had again. What the user and the model wrote to each
    other counts as conversation. Thinking is left out of both, because the
    transcript often holds only its signature.
    """
    tool = talk = 0
    for record in since_compaction(records):
        if record.get("type") not in ("user", "assistant"):
            continue
        injected = bool(record.get("isMeta"))
        message = record.get("message")
        content = message.get("content") if isinstance(message, dict) else None
        if isinstance(content, str):
            if injected:
                tool += len(content)
            else:
                talk += len(content)
            continue
        if not isinstance(content, list):
            continue
        for block in content:
            if not isinstance(block, dict):
                continue
            kind = block.get("type")
            if kind == "tool_result":
                tool += len(_text(block))
            elif kind == "tool_use":
                tool += len(json.dumps(block.get("input"), ensure_ascii=False))
            elif kind == "text":
                size = len(str(block.get("text", "")))
                if injected:
                    tool += size
                else:
                    talk += size
    total = tool + talk
    return tool / total if total else None


def recommend(found: dict | None, share: float | None) -> str:
    """Which of the five actions fits. A key of SHORT and WHY.

    A finished piece of work wants a fresh session, and a handoff first unless
    one was just written or the stream is closed. Work that goes on wants a
    compaction, because that is the continuation SessionStart is built for,
    and a handoff before it only when the context is mostly conversation,
    which is the part a compaction summary loses. No share at all reads as
    tool traffic, the common case by a wide margin.
    """
    kind = (found or {}).get("kind")
    if kind == "handoff":
        return "clear+resume"
    if kind == "closed":
        return "clear"
    if kind == "finished":
        return "handoff+clear"
    if share is not None and share < TOOL_SHARE:
        return "handoff+compact"
    return "compact"


def suggestion(action: str, identifier: str, commit: str) -> str:
    """The ready-to-use line: something the user can type or paste as it stands.

    The /compact argument names only the focus, the stream and where the work
    got to. What a summary keeps is the business of the Compact Instructions
    in CLAUDE.md, which steer every compaction, so repeating them here would
    only make the line longer and the two drift apart.
    """
    if action == "compact":
        parts = [f"Focus on {identifier}"] if identifier else []
        if commit:
            parts.append(f'last commit "{commit}"')
        if not parts:
            return "/compact"
        focus = "; ".join(parts)
        return f"/compact {focus[0].upper()}{focus[1:]}."
    if action == "handoff+compact":
        return 'say "handoff", then /compact. The handoff is reloaded after it.'
    if action == "handoff+clear":
        return 'say "handoff", then /clear.'
    if action == "clear+resume" and identifier:
        return f'/clear, then say "resume {identifier}".'
    return "/clear."


def render(level: str, tokens: int, stream: str, identifier: str,
           found: dict | None, action: str, ceiling: int) -> str:
    """The systemMessage. Several lines with a rule around it, for the reason
    in stop.py's header: a single line was rendered and never seen."""
    if found:
        hint = found["hint"]
        reason = f"Natural break: {hint}" + ("" if hint.endswith(".") else ".")
        if level == "hard":
            reason += f" Auto-compaction comes at about {ceiling:,}."
    else:
        reason = f"No natural break yet, and auto-compaction comes at about {ceiling:,}."
    lines = [f"Context at {tokens:,} tokens{stream}.", reason, WHY[action],
             "Suggest: " + suggestion(action, identifier,
                                      (found or {}).get("commit", ""))]
    return "\n" + RULE + "\n" + "\n".join("  " + line for line in lines) + "\n" + RULE
