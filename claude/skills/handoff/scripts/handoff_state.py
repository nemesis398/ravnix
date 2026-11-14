#!/usr/bin/env python3
"""The harness-agnostic brain behind the handoff skill.

Holds every decision the Claude Code hooks need to make: where a project's
handoff lives, whether the file on disk is still worth trusting, whether a token
count has crossed a nudge threshold, and what text to inject. The adapters
translate harness JSON to and from this module and do no arithmetic of their
own, which is what keeps them, and a project's own Plane hooks that import this module,
from drifting apart.

Stdlib only and no imports at call time, because this runs on every turn end
and must never fail to import.
"""
from __future__ import annotations

import hashlib
import json
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

import skill_values as sv

# Tuned for a compaction ceiling of 487,000 tokens, which is what
# `autoCompactWindow: 500000` leaves once the harness reserves its flat 13,000
# tokens for the summary. The pair before this one, 500,000 and 650,000, was
# tuned for an 800,000 window, and against this one both sat past the ceiling,
# so neither could ever fire. That is the same defect as the retune before it,
# where HARD sat exactly on a 300,000 ceiling, and the test that pins both
# bands below COMPACT_CEILING exists so it cannot come back a third time.
#
# The two are the compaction advisor's bands now (adapters/claude/advisor.py),
# not a soft and a hard reminder to write a handoff. From SOFT the advisor
# speaks only at a natural break in the work, because that is where compacting
# or starting fresh costs the least. From HARD it speaks regardless, which
# leaves 87,000 tokens before the harness compacts on its own terms: room for a
# handoff, or for a /compact whose focus the user chose.
#
# REARM stays at 100,000. Against a hard of 400,000 its next band is 500,000,
# past the ceiling, so each band fires at most once per compaction cycle. It
# stays because a larger window, or HANDOFF_HARD_TOKENS, brings it back into
# reach, and without it a long session would go silent after one reminder.
SOFT_DEFAULT = 200_000
HARD_DEFAULT = 400_000
REARM = 100_000
COMPACT_CEILING = 487_000
INJECT_CAP = 1500
TRUNCATION_MARKER = "\n[truncated, read the full file]"

# The sentence both nudges end with, and the reason the turn does not stop at
# the handoff. It lives here rather than in an adapter so that every hook that
# nudges shares one copy: a project's own Plane Stop hook imports it by absolute
# path.
CONTINUE_CLAUSE = (
    " Writing it does not end the turn. Once the handoff is written, work from "
    "that document as your context and carry straight on with its first "
    "unfinished next step, without waiting to be asked. Only from a handoff you "
    "actually wrote: if the skill stops you to ask the user something, that "
    "wins, and there is nothing to carry on into until it is answered."
)


def state_root() -> Path:
    """Run state, never the synced tree. HANDOFF_STATE_ROOT exists for tests."""
    override = os.environ.get("HANDOFF_STATE_ROOT")
    if override:
        return Path(override)
    return Path.home() / ".local" / "state" / "agent-handoff"


def git_root(cwd: str | None = None) -> str | None:
    """The repo root, or None outside a repo. Two second cap: this runs per turn."""
    target = cwd or os.getcwd()
    try:
        done = subprocess.run(
            ["git", "-C", target, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=2,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if done.returncode != 0:
        return None
    return done.stdout.strip() or None


def project_owned(cwd: str | None = None) -> bool:
    """Whether the repository at `cwd` writes its own handoff elsewhere.

    A repo declares this with `.claude/handoff.json` holding
    `{"owner": "project"}`. Deliberately generic: this module never learns
    which tracker or file the project uses, only that it has one. Anything
    unreadable, unparseable, naming a different owner, or not a string, a
    path, or None reads as false, so the skill keeps working normally rather
    than silently going quiet or raising.
    """
    # git_root() below hands `cwd` straight to subprocess.run's argv, which
    # raises TypeError for anything that is not str/bytes/os.PathLike. Every
    # real caller already passes a string or None, but this function is new
    # in this task, so its own promise not to raise is worth guarding
    # explicitly rather than inherited by accident from git_root's callers
    # elsewhere in the skill.
    if cwd is not None and not isinstance(cwd, (str, os.PathLike)):
        return False
    root = git_root(cwd) or cwd
    if not root:
        return False
    try:
        raw = (Path(root) / ".claude" / "handoff.json").read_text(encoding="utf-8")
        return json.loads(raw).get("owner") == "project"
    except (OSError, ValueError, AttributeError):
        return False


def repo_key(cwd: str | None = None) -> str:
    """Basename for readability, hash for uniqueness.

    Keying on the git root rather than the cwd is what stops one project's
    handoffs fragmenting across every subdirectory it gets opened from.
    """
    root = git_root(cwd) or os.path.abspath(cwd or os.getcwd())
    digest = hashlib.sha256(root.encode("utf-8")).hexdigest()[:8]
    return f"{os.path.basename(root.rstrip('/')) or 'root'}-{digest}"


def paths(cwd: str | None = None) -> dict:
    key = repo_key(cwd)
    base = state_root() / key
    return {
        "key": key,
        "dir": base,
        "current": base / "current.md",
        "archive": base / "archive",
        "runtime": base / ".runtime",
    }


WORKSPACES_KEY = "handoff.workspaces"


def load_projects() -> dict:
    """The layout, `{"workspaces": ...}`, or {} if there is none.

    The skill value `handoff.workspaces` (claude/skills/README.md), or the
    file HANDOFF_PROJECTS names, which wins so tests never read the real
    layout. Never raises. A hook that cannot read the layout must still
    exit 0, and a caller that gets {} asks the user rather than guessing.
    """
    override = os.environ.get("HANDOFF_PROJECTS")
    if override:
        try:
            loaded = json.loads(Path(override).read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}
        return loaded if isinstance(loaded, dict) else {}
    workspaces = sv.get(WORKSPACES_KEY, dict)
    return {"workspaces": workspaces} if workspaces else {}


def default_workspace() -> str:
    """The workspace marked `"default": true`, else the only one, else ""."""
    spaces = load_projects().get("workspaces") or {}
    if not isinstance(spaces, dict):
        return ""
    marked = [slug for slug, ws in spaces.items()
              if isinstance(ws, dict) and ws.get("default") is True]
    if len(marked) == 1:
        return marked[0]
    return next(iter(spaces)) if len(spaces) == 1 and not marked else ""


def resolve_project(cwd: str | None) -> dict | None:
    """The directory's default project, or None.

    None is not a failure. It is what makes the model ask, which is the rule:
    the project follows the task, and the directory only suggests. The longest
    matching directory wins, so a mapped subtree beats its mapped parent
    instead of losing to whichever came first in the file.
    """
    if not cwd:
        return None
    try:
        here = Path(cwd).resolve()
    except (OSError, ValueError):
        return None
    best = None
    best_len = -1
    for slug, workspace in (load_projects().get("workspaces") or {}).items():
        for identifier, project in (workspace.get("projects") or {}).items():
            for candidate in project.get("dirs") or []:
                root = Path(candidate)
                if here == root or root in here.parents:
                    if len(str(root)) > best_len:
                        best_len = len(str(root))
                        best = {"workspace": slug, "identifier": identifier,
                                "id": project.get("id", ""),
                                "name": project.get("name", identifier)}
    return best


def sibling_projects(workspace: str, exclude_id: str) -> list[dict]:
    """The other projects in one workspace, for the fallback sweep.

    One workspace only. Two workspaces are different audiences, and a session
    in one has no business being handed another's board because its own
    project happened to be quiet.
    """
    out = []
    spaces = (load_projects().get("workspaces") or {}).get(workspace) or {}
    for identifier, project in (spaces.get("projects") or {}).items():
        if project.get("id") and project.get("id") != exclude_id:
            out.append({"identifier": identifier, "id": project["id"],
                        "name": project.get("name", identifier)})
    return out


STREAMS_DIR = "_streams"


def pointer_file(session: str) -> Path:
    """Keyed by session alone. The directory is not part of the identity.

    It used to live under `paths(cwd)["runtime"]`, which put the directory in
    the filename. `repo_key` only collapses subdirectories inside a git repo,
    and this tree is deliberately not one, so every subdirectory got its own
    key and its own empty pointer. Worse, AGENT declares two directories, and a
    claim in one was invisible from the other.

    The session id is already unique and the project is recorded in the
    pointer's contents, so the directory contributed nothing to identity except
    a way to miss. AGENT-25.
    """
    return state_root() / STREAMS_DIR / f"{session or 'unknown'}.pointer.json"


def read_pointer(session: str) -> dict:
    try:
        loaded = json.loads(pointer_file(session).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return loaded if isinstance(loaded, dict) else {}


def write_pointer(session: str, data: dict) -> None:
    target = pointer_file(session)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(target.name + ".tmp")
    tmp.write_text(json.dumps(data), encoding="utf-8")
    tmp.replace(target)


def clear_pointer(session: str) -> None:
    try:
        pointer_file(session).unlink()
    except OSError:
        pass


def latest_stream(project_id: str) -> dict:
    """The most recently claimed stream for one project, across all sessions.

    Only for telling a session the truth about what is already claimed. It is
    deliberately NOT a fallback that a session adopts: guessing which of
    several open streams is yours is how a session starts by confidently doing
    the wrong work, and that reasoning is the whole basis of the per-session
    pointer.

    Ordered by mtime, which is real time. Sorting these by any string a human
    wrote is the bug that picked the wrong handoff on 2026-08-23.
    """
    if not project_id:
        return {}
    folder = state_root() / STREAMS_DIR
    best, best_mtime = {}, -1.0
    try:
        candidates = list(folder.glob("*.pointer.json"))
    except OSError:
        return {}
    for path in candidates:
        try:
            mtime = path.stat().st_mtime
            loaded = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if not isinstance(loaded, dict) or loaded.get("project_id") != project_id:
            continue
        if mtime > best_mtime:
            best, best_mtime = loaded, mtime
    return best


def parse_frontmatter(text: str) -> dict:
    """Flat `key: value` pairs only.

    There is no YAML parser in the stdlib and the frontmatter is deliberately
    flat, so a list like `skills: [a, b]` stays the string "[a, b]". Nothing
    consumes it mechanically, so that is fine.
    """
    if not text.startswith("---\n"):
        return {}
    end = text.find("\n---", 4)
    if end == -1:
        return {}
    meta = {}
    for line in text[4:end].splitlines():
        if not line.strip() or line.startswith((" ", "\t", "#")):
            continue
        key, sep, value = line.partition(":")
        if not sep or not key.strip():
            continue
        meta[key.strip()] = value.strip()
    return meta


def section(text: str, name: str) -> str:
    """The body under one `## Heading`, up to the next one."""
    out, capture = [], False
    for line in text.splitlines():
        if line.startswith("## "):
            capture = line[3:].strip().casefold() == name.casefold()
            continue
        if capture:
            out.append(line)
    return "\n".join(out).strip()


def age_seconds(stamp: str | None, now: datetime | None = None) -> int | None:
    if not stamp:
        return None
    try:
        when = datetime.fromisoformat(stamp)
    except (ValueError, TypeError):
        return None
    reference = now if now is not None else datetime.now(when.tzinfo)
    try:
        return int((reference - when).total_seconds())
    except TypeError:
        # One side aware, one naive. Unknowable rather than wrong.
        return None


def read_handoff(cwd: str | None = None, now: datetime | None = None) -> dict:
    """Malformed reads as absent.

    A hook that raises on a half-written file is worse than one that says
    "no handoff", because the first breaks the session and the second only
    costs the nudge that would have fired anyway.
    """
    target = paths(cwd)["current"]
    blank = {"exists": False, "path": str(target), "meta": {}, "text": "", "age_seconds": None}
    try:
        text = target.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError):
        return blank
    meta = parse_frontmatter(text)
    if not meta.get("goal"):
        return blank
    return {
        "exists": True,
        "path": str(target),
        "meta": meta,
        "text": text,
        "age_seconds": age_seconds(meta.get("updated"), now),
    }


def thresholds() -> tuple[int, int]:
    def read(name: str, fallback: int) -> int:
        try:
            return int(os.environ[name])
        except (KeyError, ValueError):
            return fallback

    return read("HANDOFF_SOFT_TOKENS", SOFT_DEFAULT), read("HANDOFF_HARD_TOKENS", HARD_DEFAULT)


def verdict(tokens: int, last_fired: int = 0) -> tuple[str, int]:
    """Which nudge to fire, and the new high-water mark to stamp.

    The mark is what stops it nagging every turn once past a threshold, and
    the re-arm is what stops it going permanently silent at 400k in a session
    whose window lets it run on to 500k.

    Pure, and blind to whether the work is at a natural break. The Claude
    adapter gates "soft" on that itself, by not stamping the mark until it
    sees one, and a project's own Plane hook imports this unchanged and does not gate.
    """
    soft, hard = thresholds()
    if tokens >= hard:
        # The highest hard-band mark at or below the current count. Pinning the
        # mark to `hard` instead would leave a single large turn firing once per
        # skipped band on each of the turns that follow it.
        mark = hard + REARM * ((tokens - hard) // REARM)
        return ("hard", mark) if mark > last_fired else ("none", last_fired)
    if tokens >= soft > last_fired:
        return "soft", soft
    return "none", last_fired


def stamp_file(cwd: str | None, session: str) -> Path:
    return paths(cwd)["runtime"] / f"{session or 'unknown'}.json"


def read_stamp(cwd: str | None, session: str) -> dict:
    try:
        loaded = json.loads(stamp_file(cwd, session).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return loaded if isinstance(loaded, dict) else {}


def write_stamp(cwd: str | None, session: str, data: dict) -> None:
    """Write through a temp file so a crash cannot leave a half-written stamp.

    A truncated stamp reads back as {}, which would re-fire every nudge the
    session had already given.
    """
    target = stamp_file(cwd, session)
    target.parent.mkdir(parents=True, exist_ok=True)
    tmp = target.with_name(target.name + ".tmp")
    tmp.write_text(json.dumps(data), encoding="utf-8")
    tmp.replace(target)


def standdown_file(cwd: str | None = None) -> Path:
    return paths(cwd)["dir"] / "standdown.json"


def record_standdown(cwd: str | None, adapter: str, reason: str) -> None:
    """Overwrite the one record of the most recent stand-down for this repo.

    Not a log: an adapter reaches here on every turn end of every session,
    forever, so an append-only record would grow without bound. One
    overwritten file is enough to answer "is this working" without inferring
    it from silence, which is exactly what was missing when precompact.py
    emitted invalid JSON on every compaction and nothing noticed for an
    entire build.
    """
    target = standdown_file(cwd)
    target.parent.mkdir(parents=True, exist_ok=True)
    data = {"adapter": adapter, "reason": reason, "at": datetime.now().isoformat(timespec="seconds")}
    tmp = target.with_name(target.name + ".tmp")
    tmp.write_text(json.dumps(data), encoding="utf-8")
    tmp.replace(target)


def read_standdown(cwd: str | None = None) -> dict:
    try:
        loaded = json.loads(standdown_file(cwd).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return loaded if isinstance(loaded, dict) else {}


def handoff_mtime(cwd: str | None = None) -> float | None:
    """When current.md was last written, or None if it is not there.

    Deliberately the filesystem's mtime rather than the document's `updated:`
    frontmatter. The frontmatter records what the writer believed; the mtime
    records that a write actually happened, which is the thing the resume is
    waiting for.
    """
    try:
        return paths(cwd)["current"].stat().st_mtime
    except OSError:
        return None


def resume_ready(cwd: str | None, stamp: dict) -> bool:
    """Whether a handoff has been written since the nudge that asked for one.

    The single decision behind the resume. Four conditions,
    and all of them matter: a nudge must have fired (or this fires against a
    handoff nobody asked for), the file must be newer than that nudge (or a
    stale document from last week arms it), it must not have fired already
    (which is what makes it one-shot, and therefore safe to place above the
    stop_hook_active guard), and read_handoff must consider it real (or a
    current.md whose frontmatter lost its `goal:` key, e.g. to a malformed
    write, arms a resume into a handoff every other consumer of this module
    calls absent). The existence check is last because it is the only one of
    the four that pays for a file read and a frontmatter parse; the other
    three are cheap and already rule out most calls.
    """
    if stamp.get("resumed"):
        return False
    try:
        nudged_at = float(stamp.get("nudged_at", 0) or 0)
    except (TypeError, ValueError):
        return False
    if not nudged_at:
        return False
    written = handoff_mtime(cwd)
    if written is None or written <= nudged_at:
        return False
    return read_handoff(cwd)["exists"]


def doctor(cwd: str | None = None) -> int:
    """Human-readable status for the current repo. Not JSON: a human runs
    this at a terminal, nothing parses it.
    """
    p = paths(cwd)
    lines: list[str] = []

    loaded = read_handoff(cwd)
    if loaded["exists"]:
        age = loaded["age_seconds"]
        age_desc = f"{age}s old" if age is not None else "age unknown"
        lines.append(f"Handoff: {loaded['path']} ({age_desc})")
    else:
        lines.append("Handoff: none")

    runtime = p["runtime"]
    stamps = sorted(runtime.glob("*.json"), key=lambda f: f.stat().st_mtime) if runtime.is_dir() else []
    if stamps:
        latest = stamps[-1]
        session = latest.stem
        data = read_stamp(cwd, session)
        lines.append(f"Last session stamp: {session} last_fired={data.get('last_fired', 0)}")
    else:
        lines.append("Last session stamp: none recorded")

    standdown = read_standdown(cwd)
    if standdown:
        lines.append(
            f"Last stand-down: {standdown.get('adapter', '?')} "
            f"({standdown.get('reason', '?')}) at {standdown.get('at', '?')}"
        )
    else:
        lines.append("Last stand-down: none recorded")

    log_path = state_root() / "handoff.log"
    if log_path.is_file():
        try:
            tail = log_path.read_text(encoding="utf-8").splitlines()[-5:]
        except OSError:
            tail = []
        if tail:
            lines.append(f"Exception log ({log_path}, last {len(tail)} line(s), shared across repos):")
            lines.extend(f"  {line}" for line in tail)
        else:
            lines.append(f"Exception log: {log_path} exists but is empty")
    else:
        lines.append("Exception log: none recorded")

    print("\n".join(lines))
    return 0


def cap(text: str, limit: int = INJECT_CAP) -> str:
    """Cap `text` at `limit` characters, appending a marker when it truncates.

    len(cap(t, n)) <= n holds for every n >= 0. When `limit` is smaller than
    the marker there is no room to both keep content and say so, so the
    marker is dropped and the text is hard-truncated to `limit` instead.
    """
    if len(text) <= limit:
        return text
    if limit < len(TRUNCATION_MARKER):
        return text[:limit]
    return text[: limit - len(TRUNCATION_MARKER)].rstrip() + TRUNCATION_MARKER


def render_injection(handoff: dict, mode: str) -> str:
    """The text a harness injects. Byte-stable within a session, deliberately.

    Text injected more than once in a session busts the prompt cache if it
    changes between turns. Hence the absolute `updated:` timestamp and never a
    relative age.
    """
    if not handoff.get("exists"):
        return ""
    meta = handoff["meta"]
    goal = meta.get("goal", "(none recorded)")
    updated = meta.get("updated", "unknown")
    if mode == "pointer":
        return cap(
            f"A handoff for this project exists at {handoff['path']}, "
            f"last updated {updated}. Goal: {goal} "
            "Read it before continuing that work, and ignore it if this session "
            "is about something else."
        )
    # Directives first, extract last, and deliberately so. cap() truncates
    # from the end, so whatever sits last is what gets eaten. Putting the
    # next-steps extract there means a document too big to inline loses list
    # items rather than losing the instruction to go and read it.
    return cap(
        f"Handoff loaded. Read it in full now, at {handoff['path']}: that "
        "document is your context for this session, and everything below is "
        "only an extract from it. Files, Changes made and Tried and failed "
        "are not included here.\n"
        f"Goal: {goal}\n"
        f"Updated: {updated}  Branch: {meta.get('branch', '?')}  "
        f"HEAD: {meta.get('head', '?')}\n\n"
        "Run the document's Resume checks before acting. If one disagrees "
        "with the document, say so and stop rather than guessing. Otherwise "
        "begin its first unfinished next step now, without waiting to be "
        "asked.\n\n"
        "Resume checks:\n"
        f"{section(handoff['text'], 'Resume checks')}\n\n"
        "Next steps (extract, the document is authoritative):\n"
        f"{section(handoff['text'], 'Next steps')}"
    )


def selftest() -> int:
    """Exercise every moment against a throwaway state root.

    The adapters are built to fail silently, which is correct in a session and
    useless when debugging. This is the way to see what they would emit.
    """
    import tempfile

    checks: list[tuple[str, bool]] = []
    with tempfile.TemporaryDirectory() as tmp:
        previous = os.environ.get("HANDOFF_STATE_ROOT")
        os.environ["HANDOFF_STATE_ROOT"] = os.path.join(tmp, "state")
        try:
            repo = os.path.join(tmp, "proj")
            os.makedirs(repo)
            here = paths(repo)
            checks.append(("repo key resolves", bool(here["key"])))
            checks.append(("no handoff reads as absent", not read_handoff(repo)["exists"]))

            here["current"].parent.mkdir(parents=True, exist_ok=True)
            here["current"].write_text(
                "---\ngoal: selftest\nupdated: 2026-01-01T00:00\n---\n\n"
                "## Next steps\n1. Nothing.\n\n## Resume checks\ntrue\n",
                encoding="utf-8",
            )
            loaded = read_handoff(repo)
            checks.append(("handoff reads back", loaded["exists"]))
            checks.append(("full injection renders", "Read it in full" in render_injection(loaded, "full")))
            checks.append(("pointer injection renders", "current.md" in render_injection(loaded, "pointer")))
            checks.append(("soft fires once", verdict(210_000, 0)[0] == "soft"))
            checks.append(("soft stays quiet after", verdict(215_000, 200_000)[0] == "none"))
            checks.append(("hard re-arms", verdict(510_000, 400_000)[0] == "hard"))
            write_stamp(repo, "s", {"last_fired": 7})
            checks.append(("stamp round-trips", read_stamp(repo, "s").get("last_fired") == 7))
        finally:
            if previous is None:
                os.environ.pop("HANDOFF_STATE_ROOT", None)
            else:
                os.environ["HANDOFF_STATE_ROOT"] = previous

    for label, ok in checks:
        print(f"{'PASS' if ok else 'FAIL'}  {label}")
    return 0 if all(ok for _, ok in checks) else 1


def main(argv: list[str] | None = None) -> int:
    import argparse

    # The verbs read, verdict, inject, stamp and board are gone. Their one
    # caller was the OpenCode plugin, which shelled out to this CLI because it
    # could not import Python, and it was removed with OpenCode on 2026-10-03.
    # The Claude Code hooks and a project's own Plane hooks import this module.
    parser = argparse.ArgumentParser(prog="handoff_state")
    parser.add_argument("command", choices=["paths", "selftest", "doctor",
                                            "projects", "claim", "release"])
    parser.add_argument("--cwd")
    parser.add_argument("--session", default="")
    parser.add_argument("--workspace", default="")
    parser.add_argument("--project", default="")
    parser.add_argument("--parent", default="")
    parser.add_argument("--identifier", default="")
    args = parser.parse_args(argv)

    # claim and release write a session-keyed file, and pointer_file falls
    # back to "unknown" without a session, so two sessions claiming without
    # --session would overwrite each other's stream, which is precisely the
    # one-slot collision this design exists to remove. A missing one is a
    # usage error rather than quiet pollution of the real state root. paths,
    # projects, doctor and selftest write nothing session-keyed, so they stay
    # callable without one.
    if args.command in ("claim", "release") and not args.session:
        parser.error(f"--session is required for '{args.command}'")

    if args.command == "selftest":
        return selftest()
    if args.command == "doctor":
        return doctor(args.cwd)

    if args.command == "projects":
        if not load_projects():
            print(f"handoff_state: {sv.Missing(WORKSPACES_KEY)}", file=sys.stderr)
            return 2
        print(json.dumps({"resolved": resolve_project(args.cwd),
                          "layout": load_projects()}, indent=2))
        return 0

    if args.command == "claim":
        workspace = args.workspace or default_workspace()
        if not workspace:
            print(f"handoff_state: no --workspace and no default workspace: "
                  f"{sv.Missing(WORKSPACES_KEY)}", file=sys.stderr)
            return 2
        pointer = {"workspace": workspace, "project_id": args.project,
                   "parent_id": args.parent, "identifier": args.identifier}
        write_pointer(args.session, pointer)
        print(json.dumps(pointer))
        return 0

    if args.command == "release":
        clear_pointer(args.session)
        print(json.dumps({"released": True}))
        return 0

    if args.command == "paths":
        print(json.dumps({k: str(v) for k, v in paths(args.cwd).items()}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
