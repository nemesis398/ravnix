"""claude-telemetry: read-only telemetry over Claude Code transcripts.

Three subcommands, each safe to rerun:

  extract  reads this machine's ~/.claude/projects and writes one row per
           session to <dir>/rows/<host>.jsonl: counts, sizes and names only,
           never prompt, answer or tool text
  state    writes this machine's autoDream flag, a few named settings keys and
           the claude shim's decisions to <dir>/state/<host>.json
  report   merges every host's rows and states with what the ai-memory
           skill's lint.py --summary counts in the vault's AI/ area, and
           writes <dir>/reports/<date>.md, <date>.json and alerts.json

<dir> is $CLAUDE_TELEMETRY_DIR, else <nextcloud.root>/claude-telemetry, with the
skill value nextcloud.root read from $RAVNIX_SKILL_VALUES (else
~/.config/ravnix/skill-values.json); with neither there is no folder, and
nothing is written. Each
machine runs extract and state on its own transcripts, so no machine reads
another's over SSH; the rows reach the reporting machine through Nextcloud.
Every file has one writer. A row is rewritten only when its transcript or one
of its subagent transcripts changed, and a row outlives its transcript, which
Claude Code deletes after cleanupPeriodDays.

Nothing is written outside <dir>. lint.py runs under python3 -B with
PYTHONDONTWRITEBYTECODE=1, so it leaves no __pycache__ in the skill, which
is a synced stow tree. A success prints one line on stderr and pushes
nothing anywhere; alerts.json is what the session pre-flight hook reads.
"""

import argparse
import collections
import datetime as dt
import glob
import json
import os
import re
import socket
import statistics
import subprocess
import sys
import time

LINT = "~/.claude/skills/ai-memory/scripts/lint.py"
LINT_TIMEOUT = 300          # lint.py gives markdownlint-cli2 120 s of its own
OLD_CAP_TOKENS = 295000     # where CLAUDE_AUTOCOMPACT_PCT_OVERRIDE=30 capped the window
OLD_CAP_BAND = 5000
WINDOW_TOKENS = 800000      # autoCompactWindow, decision 9
HUMAN_SOURCES = {"typed", "queued", "suggestion_accepted", "sdk"}
CONFLICT_MARKERS = ("_conflict-", "(conflicted copy", "(case clash from")
# Where a memory note lives: a project's own memory folder, and any folder of
# the CLAUDE_TELEMETRY_MEMORY_DIRS list (directory names, separated by colons)
# that the user's memory store is in or was in. Nothing else is built in.
_STORES = [d for d in os.environ.get("CLAUDE_TELEMETRY_MEMORY_DIRS", "").split(":") if d]
_STORE_NAMES = "|".join(re.escape(d) for d in _STORES)
MEMORY_PATH = re.compile(
    "(" + "".join(f"/{re.escape(d)}/|" for d in _STORES) + r"/\.claude/projects/[^/]+/memory/)")
RM_MEMORY = re.compile(
    r"(^|[;&|\s])(rm|git rm)\s[^;&|]*(" + (f"{_STORE_NAMES}|" if _STORES else "") + r"/memory/)[^;&|]*\.md")
COMMAND_NAME = re.compile(r"<command-name>/?([^<\s]+)</command-name>")
NAME = re.compile(r"[A-Za-z0-9][\w.:@/+-]{0,79}")


def skill_value(*keys):
    """A string from the skill values file (claude/README.md), or "" when the
    file, the key or the type is not there."""
    path = os.environ.get("RAVNIX_SKILL_VALUES") or os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
        "ravnix", "skill-values.json")
    try:
        with open(path, encoding="utf-8") as fh:
            value = json.load(fh)
        for key in keys:
            value = value[key]
    except (OSError, ValueError, KeyError, TypeError):
        return ""
    return value if isinstance(value, str) else ""


def default_dir():
    """The telemetry folder, or "" when nothing says where it is."""
    if os.environ.get("CLAUDE_TELEMETRY_DIR"):
        return os.environ["CLAUDE_TELEMETRY_DIR"]
    root = skill_value("nextcloud", "root")
    return os.path.join(root, "claude-telemetry") if root else ""


def folder(a, *parts):
    """A path inside the telemetry folder, which must be known by now."""
    if not a.dir:
        sys.exit("claude-telemetry: no telemetry folder: set CLAUDE_TELEMETRY_DIR, pass --dir, "
                 "or set nextcloud.root in ravnix.claude.skillValues")
    return os.path.join(a.dir, *parts)


def default_conflict_roots():
    """The folders scanned for Nextcloud conflict files: the colon-separated
    CLAUDE_TELEMETRY_CONFLICT_ROOTS, else the vault (VAULT_DIR, else the skill
    value vault.root), else none."""
    listed = [p for p in os.environ.get("CLAUDE_TELEMETRY_CONFLICT_ROOTS", "").split(":") if p]
    vault = os.environ.get("VAULT_DIR") or skill_value("vault", "root")
    return listed or ([vault] if vault else [])


def name(s):
    """A tool, skill, server or command name as recorded, or "?" for anything
    that is not shaped like a name, so no free text can ride in a name field."""
    return s if isinstance(s, str) and NAME.fullmatch(s) else "?"


def write_atomic(path, text):
    """Writes through a *.part file, which the Nextcloud client never uploads,
    and leaves an unchanged file alone, so a quiet day causes no sync."""
    try:
        with open(path, encoding="utf-8") as fh:
            if fh.read() == text:
                return False
    except OSError:
        pass
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    tmp = f"{path}.{os.getpid()}.part"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    os.replace(tmp, path)
    return True


# ---------------------------------------------------------------- extract

def usage_total(u):
    return (u.get("input_tokens") or 0) + (u.get("cache_creation_input_tokens") or 0) \
        + (u.get("cache_read_input_tokens") or 0)


def api_error_class(text):
    t = text.lower()
    if "prompt is too long" in t or ("context" in t and "exceed" in t):
        return "prompt_too_long"
    if "connection" in t:
        return "connection"
    if "overloaded" in t or "529" in t:
        return "overloaded"
    if "rate limit" in t or "429" in t:
        return "rate_limit"
    return "other"


def text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(c.get("text", "") for c in content
                        if isinstance(c, dict) and c.get("type") == "text")
    return ""


def is_human(o, content):
    origin = (o.get("origin") or {}).get("kind")
    if origin == "human" or o.get("promptSource") in HUMAN_SOURCES:
        return True
    if origin is not None or o.get("promptSource") is not None:
        return False
    # Transcripts from before origin and promptSource existed.
    if o.get("isCompactSummary") or o.get("isVisibleInTranscriptOnly"):
        return False
    return isinstance(content, str) and not content.lstrip().startswith(("<", "[Request interrupted"))


def scan_subagents(session_dir):
    """Token sums and counts over one session's subagent transcripts."""
    out = {"files": 0, "api_calls": 0, "tool_calls": 0,
           "input": 0, "cache_creation": 0, "cache_read": 0, "output": 0}
    sub = os.path.join(session_dir, "subagents")
    if not os.path.isdir(sub):
        return out
    for fname in os.listdir(sub):
        if not fname.endswith(".jsonl"):
            continue
        out["files"] += 1
        seen = set()
        with open(os.path.join(sub, fname), encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if '"type":"assistant"' not in line:
                    continue
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                m = o.get("message") or {}
                for c in m.get("content") or []:
                    if isinstance(c, dict) and c.get("type") == "tool_use":
                        out["tool_calls"] += 1
                mid = m.get("id") or o.get("requestId")
                u = m.get("usage")
                if not u or mid in seen or m.get("model") == "<synthetic>":
                    continue
                seen.add(mid)
                out["api_calls"] += 1
                out["input"] += u.get("input_tokens") or 0
                out["cache_creation"] += u.get("cache_creation_input_tokens") or 0
                out["cache_read"] += u.get("cache_read_input_tokens") or 0
                out["output"] += u.get("output_tokens") or 0
    return out


def scan_session(path, host, project):
    """One row for one top-level transcript. Counts and names only."""
    st = os.stat(path)
    r = {
        "host": host, "project": project,
        "session": os.path.basename(path)[:-6],
        "size": st.st_size, "mtime": int(st.st_mtime),
        "first_ts": None, "last_ts": None,
        "entrypoints": collections.Counter(), "versions": collections.Counter(),
        "models": collections.Counter(), "effort": None,
        "human_turns": 0, "slash_commands": collections.Counter(),
        "api_calls": 0, "tool_calls": 0, "tools": collections.Counter(),
        "mcp": collections.Counter(), "skills": collections.Counter(),
        "first_turn_tokens": None, "first_turn_prior_prompts": None,
        "peak_context": 0, "compactions": [],
        "api_errors": collections.Counter(), "hook_errors": 0,
        "tokens": {"input": 0, "cache_creation": 0, "cache_read": 0, "output": 0},
        "skill_listing_chars": None, "skill_listing_count": None, "skill_names": None,
        "deferred_tools": None, "mcp_servers": None, "mcp_failed": [],
        "instruction_chars": None, "memory_index_chars": None,
        "memory_writes": 0, "memory_rm": 0, "memory_saved": [],
        "worktree": "--claude-worktrees-" in project,
        "probe": project.startswith("-tmp-"),
    }
    seen_ids = set()
    prompts_before_first = 0
    ts_re = re.compile(r'"timestamp":"([^"]+)"')
    with open(path, encoding="utf-8", errors="replace") as fh:
        for line in fh:
            # Most bytes are tool results and reminders: note the time, skip the rest.
            if ('"type":"user"' in line and '"tool_result"' in line and '"promptSource"' not in line) \
                    or ('"type":"attachment"' in line and not any(k in line for k in (
                        '"skill_listing"', '"instructions"', '"deferred_tools_delta"',
                        '"mcp_instructions_delta"'))):
                m = ts_re.search(line)
                if m:
                    r["first_ts"] = r["first_ts"] or m.group(1)
                    r["last_ts"] = m.group(1)
                continue
            try:
                o = json.loads(line)
            except ValueError:
                continue
            if not isinstance(o, dict):
                continue
            ts = o.get("timestamp")
            if isinstance(ts, str):
                r["first_ts"] = r["first_ts"] or ts
                r["last_ts"] = ts
            if "entrypoint" in o:
                r["entrypoints"][name(o["entrypoint"])] += 1
            if "version" in o:
                r["versions"][name(o["version"])] += 1
            if r["effort"] is None and o.get("effort"):
                r["effort"] = name(o["effort"])
            t = o.get("type")
            side = o.get("isSidechain")
            if t == "user" and not o.get("isMeta") and not side:
                content = (o.get("message") or {}).get("content")
                for cmd in COMMAND_NAME.findall(text_of(content)):
                    r["slash_commands"][name(cmd)] += 1
                if is_human(o, content):
                    r["human_turns"] += 1
                    if r["first_turn_tokens"] is None:
                        prompts_before_first += 1
            elif t == "assistant" and not side:
                m = o.get("message") or {}
                if o.get("isApiErrorMessage"):
                    r["api_errors"][api_error_class(text_of(m.get("content")))] += 1
                    continue
                for c in m.get("content") or []:
                    if not isinstance(c, dict) or c.get("type") != "tool_use":
                        continue
                    tool = name(c.get("name"))
                    inp = c.get("input") if isinstance(c.get("input"), dict) else {}
                    r["tool_calls"] += 1
                    r["tools"][tool] += 1
                    if tool.startswith("mcp__"):
                        r["mcp"][name(tool.split("__")[1])] += 1
                    if tool == "Skill":
                        r["skills"][name(inp.get("skill"))] += 1
                    fp = inp.get("file_path")
                    if tool in ("Write", "Edit") and isinstance(fp, str) and MEMORY_PATH.search(fp):
                        r["memory_writes"] += 1
                    cmd = inp.get("command")
                    if tool == "Bash" and isinstance(cmd, str) and RM_MEMORY.search(cmd):
                        r["memory_rm"] += 1
                mid = m.get("id") or o.get("requestId")
                u = m.get("usage")
                if not isinstance(u, dict) or m.get("model") == "<synthetic>" or mid in seen_ids:
                    continue
                seen_ids.add(mid)
                r["api_calls"] += 1
                r["models"][name(m.get("model"))] += 1
                tot = usage_total(u)
                if r["first_turn_tokens"] is None:
                    r["first_turn_tokens"] = tot
                    r["first_turn_prior_prompts"] = prompts_before_first
                r["peak_context"] = max(r["peak_context"], tot)
                r["tokens"]["input"] += u.get("input_tokens") or 0
                r["tokens"]["cache_creation"] += u.get("cache_creation_input_tokens") or 0
                r["tokens"]["cache_read"] += u.get("cache_read_input_tokens") or 0
                r["tokens"]["output"] += u.get("output_tokens") or 0
            elif t == "system":
                sub = o.get("subtype")
                if sub == "compact_boundary":
                    cm = o.get("compactMetadata") or {}
                    r["compactions"].append({"ts": ts, "trigger": name(cm.get("trigger")),
                                             "pre": cm.get("preTokens") if isinstance(cm.get("preTokens"), int) else None,
                                             "post": cm.get("postTokens") if isinstance(cm.get("postTokens"), int) else None})
                elif sub == "stop_hook_summary":
                    r["hook_errors"] += len(o.get("hookErrors") or [])
                elif sub == "memory_saved":
                    # autoDream's completion notice carries verb "Improved"; its
                    # own fork writes no transcript (skipTranscript).
                    r["memory_saved"].append({"ts": ts, "verb": name(o.get("verb")),
                                              "files": len(o.get("writtenPaths") or [])})
            elif t == "attachment":
                a = o.get("attachment") or {}
                at = a.get("type")
                if at == "skill_listing" and a.get("isInitial") and r["skill_listing_chars"] is None:
                    r["skill_listing_chars"] = len(a.get("content") or "")
                    r["skill_listing_count"] = a.get("skillCount")
                    r["skill_names"] = sorted({name(n) for n in a.get("names") or []})
                elif at == "instructions" and r["instruction_chars"] is None:
                    files = [f for f in a.get("files") or [] if isinstance(f, dict)]
                    r["instruction_chars"] = sum(len(f.get("content") or "") for f in files)
                    r["memory_index_chars"] = sum(len(f.get("content") or "") for f in files
                                                  if f.get("type") == "AutoMem")
                elif at == "deferred_tools_delta":
                    if r["deferred_tools"] is None:
                        r["deferred_tools"] = len(a.get("addedNames") or [])
                    for s in a.get("failedMcpServers") or []:
                        n = name(s if isinstance(s, str) else (s or {}).get("name"))
                        if n not in r["mcp_failed"]:
                            r["mcp_failed"].append(n)
                elif at == "mcp_instructions_delta" and r["mcp_servers"] is None:
                    r["mcp_servers"] = len(a.get("addedNames") or [])
    r["subagents"] = scan_subagents(path[:-6])
    for k in ("entrypoints", "versions", "models", "slash_commands", "tools", "mcp",
              "skills", "api_errors"):
        r[k] = dict(r[k])
    r["entrypoint"] = max(r["entrypoints"], key=r["entrypoints"].get) if r["entrypoints"] else None
    return r


def signature(path, st):
    """Size and mtime of a transcript and of its subagent transcripts, which
    keep growing while the parent waits and its own file stands still."""
    sig = [st.st_size, int(st.st_mtime)]
    sub = os.path.join(path[:-6], "subagents")
    if os.path.isdir(sub):
        for n in os.listdir(sub):
            if n.endswith(".jsonl"):
                s2 = os.stat(os.path.join(sub, n))
                sig[0] += s2.st_size
                sig[1] = max(sig[1], int(s2.st_mtime))
    return sig


def cmd_extract(a):
    t0 = time.monotonic()
    rows_path = a.rows or folder(a, "rows", f"{a.host}.jsonl")
    old = {}
    if os.path.exists(rows_path):
        with open(rows_path, encoding="utf-8") as fh:
            for line in fh:
                try:
                    row = json.loads(line)
                    old[(row["project"], row["session"])] = row
                except (ValueError, KeyError, TypeError):
                    continue
    rows, parsed, reused, nbytes = [], 0, 0, 0
    projects = os.path.expanduser(a.projects)
    for project in sorted(os.listdir(projects)) if os.path.isdir(projects) else []:
        pdir = os.path.join(projects, project)
        if not os.path.isdir(pdir):
            continue
        for fname in sorted(os.listdir(pdir)):
            if not fname.endswith(".jsonl"):
                continue
            path = os.path.join(pdir, fname)
            st = os.stat(path)
            sig = signature(path, st)
            prev = old.pop((project, fname[:-6]), None)
            if prev and prev.get("sig") == sig and prev.get("host") == a.host:
                rows.append(prev)
                reused += 1
                continue
            row = scan_session(path, a.host, project)
            row["sig"] = sig
            rows.append(row)
            parsed += 1
            nbytes += st.st_size
    # A row whose transcript is gone (cleanupPeriodDays) is kept: it is the history.
    kept = list(old.values())
    for row in kept:
        row["transcript_gone"] = True
    rows.extend(kept)
    write_atomic(rows_path, "".join(json.dumps(r, sort_keys=True) + "\n" for r in rows))
    print(f"claude-telemetry extract {a.host}: {parsed} parsed ({nbytes / 1e6:.1f} MB), "
          f"{reused} reused, {len(kept)} kept after deletion, {time.monotonic() - t0:.1f} s",
          file=sys.stderr)


# ------------------------------------------------------------------ state

def cmd_state(a):
    """Named keys only. Nothing else is copied out of ~/.claude.json."""
    s = {"host": a.host, "taken_at": dt.datetime.now(dt.timezone.utc).isoformat()}
    try:
        with open(os.path.expanduser(a.claude_json), encoding="utf-8") as fh:
            cj = json.load(fh)
        feats = cj.get("cachedGrowthBookFeatures") or {}
        onyx = feats.get("tengu_onyx_plover")
        s["flag_onyx_plover"] = {k: onyx.get(k) for k in ("enabled", "available", "minHours",
                                                          "minSessions", "remoteEnabled") if k in onyx} \
            if isinstance(onyx, dict) else onyx
        s["flag_hover_rest"] = feats.get("tengu_hover_rest")
        s["flags_cached_at"] = cj.get("cachedGrowthBookFeaturesAt")
    except (OSError, ValueError, AttributeError) as e:
        s["claude_json_error"] = type(e).__name__
    try:
        settings = os.path.expanduser(a.settings)
        with open(settings, encoding="utf-8") as fh:
            sj = json.load(fh)
        s["settings"] = {k: sj.get(k) for k in ("autoDreamEnabled", "autoMemoryEnabled",
                                                 "cleanupPeriodDays", "autoCompactWindow",
                                                 "autoCompactEnabled", "effortLevel", "model")}
        s["settings_is_link"] = os.path.islink(settings)
    except (OSError, ValueError, AttributeError) as e:
        s["settings_error"] = type(e).__name__
    log = os.path.expanduser(a.shim_log)
    decisions = []
    for f in (log + ".1", log):
        if os.path.exists(f):
            with open(f, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    p = line.rstrip("\n").split("\t")
                    if len(p) >= 5:
                        decisions.append({"ts": p[0], "decision": p[1], "reason": p[4][:200]})
    s["shim_decisions"] = decisions
    write_atomic(a.out or folder(a, "state", f"{a.host}.json"),
                 json.dumps(s, indent=1, sort_keys=True) + "\n")


# ----------------------------------------------------------------- report

def parse_ts(s):
    if not isinstance(s, str) or not s:
        return None
    try:
        t = dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None
    return t if t.tzinfo else t.replace(tzinfo=dt.timezone.utc)


def dist(values):
    v = sorted(x for x in values if x is not None)
    if not v:
        return {"n": 0}
    p90 = v[min(len(v) - 1, int(round(0.9 * (len(v) - 1))))]
    return {"n": len(v), "median": statistics.median(v), "min": v[0], "max": v[-1], "p90": p90}


def memory_lint():
    """What lint.py --summary prints for the vault's AI/ area, at lint.py's
    own default vault. Its summary lines are kept as printed, so lint.py stays
    the one place that knows their format. Its findings are only counted by
    their level prefix, never copied: a finding can quote a note, a broken
    frontmatter line or a private address, and the report syncs. Nothing
    here raises an alert: vault-check already reports every finding."""
    env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
    try:
        done = subprocess.run([sys.executable, "-B", os.path.expanduser(LINT), "--summary"],
                              capture_output=True, text=True, encoding="utf-8", errors="replace",
                              env=env, timeout=LINT_TIMEOUT)
    except (OSError, subprocess.SubprocessError) as e:
        return {"error": type(e).__name__}
    findings = {"ERROR": 0, "WARN": 0}
    summary = []
    for line in done.stdout.splitlines():
        level = line.split(" ", 1)[0]
        if level in findings:
            findings[level] += 1
        elif line.strip():
            summary.append(line)
    return {"exit": done.returncode, "findings": findings, "summary": summary}


def conflict_report(roots, since):
    found = []
    home = os.path.expanduser("~")
    for root in roots:
        for dp, dns, fns in os.walk(root):
            dns[:] = [d for d in dns if d not in (".git", "node_modules", "__pycache__", ".trash")
                      and not (d == "worktrees" and dp.endswith("/.claude"))]
            for n in fns + dns:
                if any(m in n for m in CONFLICT_MARKERS):
                    p = os.path.join(dp, n)
                    m = dt.datetime.fromtimestamp(os.lstat(p).st_mtime, dt.timezone.utc)
                    found.append({"path": "~" + p[len(home):] if p.startswith(home + "/") else p,
                                  "mtime": m.isoformat(), "new": m >= since})
    return {"total": len(found), "new_in_window": sum(f["new"] for f in found), "files": found}


def dream_can_fire(state):
    f = state.get("flag_onyx_plover") or {}
    f = f if isinstance(f, dict) else {}
    settings = state.get("settings") or {}
    available = f.get("enabled") is True or f.get("available") is True
    key = settings.get("autoDreamEnabled")
    memory_on = settings.get("autoMemoryEnabled") is not False
    on = memory_on and available and (key if key is not None else f.get("enabled") is True)
    return {"available": available, "settings_key": key, "would_fire": bool(on),
            "min_hours": f.get("minHours", 24), "min_sessions": f.get("minSessions", 5)}


def cmd_report(a):
    t0 = time.monotonic()
    now = parse_ts(a.now) if a.now else dt.datetime.now(dt.timezone.utc)
    since = now - dt.timedelta(days=a.window_days)
    routing = parse_ts(a.routing_since)
    removed = parse_ts(a.override_removed)
    row_files = a.rows if a.rows is not None else sorted(glob.glob(folder(a, "rows", "*.jsonl")))
    state_files = a.state if a.state is not None else sorted(glob.glob(folder(a, "state", "*.json")))
    out_dir = a.out_dir or folder(a, "reports")
    rows = []
    for f in row_files:
        with open(f, encoding="utf-8") as fh:
            for line in fh:
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    continue
    states = []
    for f in state_files:
        try:
            with open(f, encoding="utf-8") as fh:
                states.append(json.load(fh))
        except (OSError, ValueError):
            continue
    for r in rows:
        r["_first"] = parse_ts(r.get("first_ts"))
        r["_last"] = parse_ts(r.get("last_ts"))
    real = [r for r in rows if r["_first"] and r["_last"] and r.get("api_calls", 0) > 0]
    win = [r for r in real if r["_last"] >= since]
    hosts = sorted({r["host"] for r in rows} | {s.get("host") for s in states if s.get("host")})

    def method(r):
        return "interactive" if r.get("entrypoint") == "cli" else \
            "headless" if r.get("entrypoint") == "sdk-cli" else (r.get("entrypoint") or "?")

    rep = {"generated_at": now.isoformat(), "window_start": since.isoformat(),
           "window_days": a.window_days, "hosts": hosts}

    cov = {}
    for h in hosts:
        hr = [r for r in real if r["host"] == h]
        firsts = [r["_first"] for r in hr if not r.get("transcript_gone")]
        cov[h] = {"sessions_retained": len(hr),
                  "sessions_in_window": sum(1 for r in win if r["host"] == h),
                  "transcript_mb": round(sum(r.get("size", 0) for r in hr) / 1e6, 1),
                  "oldest_transcript": min(firsts).isoformat() if firsts else None,
                  "rows_whose_transcript_is_gone": sum(1 for r in hr if r.get("transcript_gone"))}
    rep["coverage"] = cov

    route = {}
    for label, sel in (("window", win), ("since_routing", [r for r in real if r["_first"] >= routing])):
        c = collections.Counter((r["host"], method(r)) for r in sel if not r.get("probe"))
        route[label] = {f"{h}/{m}": n for (h, m), n in sorted(c.items())}
    shim = collections.Counter()
    for s in states:
        for d in s.get("shim_decisions", []):
            t = parse_ts(d.get("ts"))
            if t and t >= since:
                shim[f'{s.get("host")}:{d.get("decision")}'] += 1
    route["shim_decisions_in_window"] = dict(shim)
    rep["routing"] = route

    floor = {}
    for r in real:
        # A first answer after more than one prompt carries history, not the floor.
        if not r.get("first_turn_tokens") or (r.get("first_turn_prior_prompts") or 0) > 1:
            continue
        key = f'{r["host"]}/{method(r)}/{r["project"]}'
        floor.setdefault(key, {"all": [], "window": []})
        floor[key]["all"].append(r["first_turn_tokens"])
        if r["_first"] >= since:
            floor[key]["window"].append(r["first_turn_tokens"])
    rep["first_turn_floor"] = {k: {"retained": dist(v["all"]), "window": dist(v["window"])}
                               for k, v in sorted(floor.items())}
    surf = {}
    for h in hosts:
        for m in ("interactive", "headless"):
            sel = [r for r in real if r["host"] == h and method(r) == m and r["_first"] >= since] \
                or [r for r in real if r["host"] == h and method(r) == m]
            surf[f"{h}/{m}"] = {k: dist([r.get(k) for r in sel]) for k in (
                "skill_listing_chars", "skill_listing_count", "deferred_tools", "mcp_servers",
                "instruction_chars", "memory_index_chars")}
    rep["always_on_surface"] = surf

    def near_old(c):
        return c["trigger"] == "auto" and c["pre"] and abs(c["pre"] - OLD_CAP_TOKENS) <= OLD_CAP_BAND

    comps = [dict(c, host=r["host"], session=r["session"], _t=parse_ts(c.get("ts")))
             for r in real for c in r.get("compactions", [])]
    wcomps = [c for c in comps if c["_t"] and c["_t"] >= since]
    errs = collections.Counter()
    for r in win:
        errs.update(r.get("api_errors", {}))
    rep["compaction"] = {
        "window": {"count": len(wcomps),
                   "by_trigger": dict(collections.Counter(c["trigger"] for c in wcomps)),
                   "pre_tokens_auto": dist([c["pre"] for c in wcomps if c["trigger"] == "auto"]),
                   "pre_tokens_manual": dist([c["pre"] for c in wcomps if c["trigger"] == "manual"]),
                   "auto_near_295k_any": sum(1 for c in wcomps if near_old(c)),
                   "auto_near_295k_after_fix": sum(1 for c in wcomps if near_old(c) and c["_t"] >= removed),
                   "auto_at_or_above_800k": sum(1 for c in wcomps if c["trigger"] == "auto"
                                                and (c["pre"] or 0) >= WINDOW_TOKENS)},
        "retained": {"count": len(comps),
                     "by_trigger": dict(collections.Counter(c["trigger"] for c in comps)),
                     "auto_near_295k": sum(1 for c in comps if near_old(c)),
                     "last_auto_near_295k": max((c["ts"] for c in comps if near_old(c)), default=None)},
        "peak_context_window": {"max": max((r.get("peak_context", 0) for r in win), default=0),
                                "sessions_over_295k": sum(1 for r in win if r.get("peak_context", 0) > OLD_CAP_TOKENS),
                                "sessions_over_500k": sum(1 for r in win if r.get("peak_context", 0) > 500000),
                                "sessions_over_800k": sum(1 for r in win if r.get("peak_context", 0) > WINDOW_TOKENS)},
        "api_errors_window": dict(errs),
    }

    inter = [r for r in win if method(r) == "interactive" and not r.get("probe")]
    rep["session_length"] = {h: {
        "human_turns": dist([r.get("human_turns") for r in inter if r["host"] == h]),
        "api_calls": dist([r.get("api_calls") for r in inter if r["host"] == h]),
        "hours": dist([round((r["_last"] - r["_first"]).total_seconds() / 3600, 2)
                       for r in inter if r["host"] == h]),
        "subagent_transcripts": sum(r.get("subagents", {}).get("files", 0) for r in win if r["host"] == h),
        "worktree_sessions": sum(1 for r in win if r["host"] == h and r.get("worktree")),
    } for h in hosts}

    sk, sl, tl, mc = (collections.Counter() for _ in range(4))
    for r in win:
        sk.update(r.get("skills", {}))
        sl.update(r.get("slash_commands", {}))
        tl.update(r.get("tools", {}))
        mc.update(r.get("mcp", {}))
    listed = {}
    for h in hosts:
        latest = max((r for r in real if r["host"] == h and r.get("skill_names")),
                     key=lambda r: r["_first"], default=None)
        if latest:
            used = collections.Counter()
            for r in real:
                if r["host"] == h:
                    used.update(r.get("skills", {}))
                    used.update({k.split(":")[-1]: v for k, v in r.get("slash_commands", {}).items()})
            listed[h] = {"listed": len(latest["skill_names"]),
                         "unused_over_retention": sorted(n for n in latest["skill_names"]
                                                         if not used.get(n) and not used.get(n.split(":")[-1]))}
    rep["skills"] = {"skill_tool_window": dict(sk.most_common()),
                     "slash_commands_window": dict(sl.most_common()), "listing": listed}
    fail_rate = {}
    for h in hosts:
        sel = [r for r in inter if r["host"] == h and r.get("mcp_servers")]
        c = collections.Counter(s for r in sel for s in r.get("mcp_failed", []))
        fail_rate[h] = {"interactive_sessions": len(sel),
                        "failed_at_start": {k: f"{v}/{len(sel)}" for k, v in c.most_common()}}
    rep["tools"] = {"top_window": dict(tl.most_common(25)), "mcp_calls_window": dict(mc.most_common()),
                    "mcp_failure_rate": fail_rate}

    tok = {}
    for h in hosts:
        t = collections.Counter()
        for r in win:
            if r["host"] == h:
                t.update(r.get("tokens", {}))
                sub = r.get("subagents", {})
                t.update({k: sub.get(k, 0) for k in ("input", "cache_creation", "cache_read", "output")})
        tok[h] = dict(t)
    rep["tokens_window"] = tok

    ver = {}
    for h in hosts:
        sel = [r for r in win if r["host"] == h]
        v, m, e = collections.Counter(), collections.Counter(), collections.Counter()
        for r in sel:
            v.update(r.get("versions", {}).keys())
            m.update(r.get("models", {}))
            e[str(r.get("effort"))] += 1
        ver[h] = {"versions": dict(v), "models": dict(m), "effort": dict(e),
                  "hook_errors": sum(r.get("hook_errors", 0) for r in sel)}
    rep["harness"] = ver

    # The session counters read the transcripts, so they are history. They
    # count writes to the old store, which nothing writes once auto memory is
    # off: falling to zero is what shows the cutover held.
    rep["memory"] = {
        "lint": memory_lint(),
        "session_memory_writes_window": sum(r.get("memory_writes", 0) for r in win),
        "session_memory_rm_window": sum(r.get("memory_rm", 0) for r in win),
        "dream_notices_window": [dict(n, host=r["host"], project=r["project"]) for r in win
                                 for n in r.get("memory_saved", []) if n.get("verb") == "Improved"],
    }
    rep["autodream"] = {s.get("host"): dream_can_fire(s) for s in states if s.get("host")}
    rep["nextcloud_conflicts"] = conflict_report([os.path.expanduser(p) for p in a.conflict_roots], since)

    # Alerts: only what the spec and the user's decisions say to act on.
    alerts = []
    if rep["compaction"]["window"]["auto_near_295k_after_fix"]:
        alerts.append("an auto-compaction near 295k this week: CLAUDE_AUTOCOMPACT_PCT_OVERRIDE is back (decision 9)")
    if errs.get("prompt_too_long"):
        alerts.append(f'{errs["prompt_too_long"]} "Prompt is too long" error(s) in sessions active this week')
    for h, d in rep["autodream"].items():
        if d["would_fire"]:
            alerts.append(f"autoDream can fire on {h}: diff the store after its first run (decision 16)")
    if rep["nextcloud_conflicts"]["new_in_window"]:
        alerts.append(f'{rep["nextcloud_conflicts"]["new_in_window"]} new Nextcloud conflict file(s) this week')
    rep["alerts"] = alerts
    rep["report_seconds"] = round(time.monotonic() - t0, 2)

    day = now.date().isoformat()
    write_atomic(os.path.join(out_dir, f"{day}.json"),
                 json.dumps(rep, indent=1, sort_keys=True, default=str) + "\n")
    write_atomic(os.path.join(out_dir, f"{day}.md"), render_md(rep))
    # alerts.json is rewritten on every run, even unchanged: its age is the heartbeat.
    body = json.dumps({"generated_at": rep["generated_at"], "host": a.host,
                       "report": f"{day}.md", "alerts": alerts}, indent=1) + "\n"
    os.makedirs(out_dir, exist_ok=True)
    tmp = os.path.join(out_dir, f"alerts.json.{os.getpid()}.part")
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(body)
    os.replace(tmp, os.path.join(out_dir, "alerts.json"))
    print(f"claude-telemetry report: {len(rows)} rows, {len(win)} sessions in the window, "
          f"{len(alerts)} alert(s), {rep['report_seconds']} s", file=sys.stderr)


def fmt(d, key="median"):
    return "n=0" if not d or not d.get("n") else \
        f'{d[key]:,.0f} (n={d["n"]}, {d["min"]:,.0f} to {d["max"]:,.0f})'


def render_md(rep):
    L = [f"# Claude Code telemetry, {rep['generated_at'][:10]}", "",
         f"Window: the {rep['window_days']} days from {rep['window_start'][:16]} UTC. "
         f"Hosts: {', '.join(rep['hosts']) or 'none'}.", ""]
    L += ["## Alerts", ""] + ([f"- {x}" for x in rep["alerts"]] or ["None."]) + [""]
    L += ["## Coverage", "", "| Host | Retained | In window | MB | Oldest transcript |",
          "| --- | --- | --- | --- | --- |"]
    for h, c in rep["coverage"].items():
        L.append(f"| {h} | {c['sessions_retained']} | {c['sessions_in_window']} | "
                 f"{c['transcript_mb']} | {(c['oldest_transcript'] or '')[:10]} |")
    L += ["", "## Where sessions ran", ""]
    for label, d in rep["routing"].items():
        L.append(f"- {label}: " + (", ".join(f"{k} {v}" for k, v in d.items()) or "none"))
    L += ["", "## First-turn floor (never compare interactive with headless)", "",
          "| Host / method / project | Window median | Retained median |", "| --- | --- | --- |"]
    for k, v in rep["first_turn_floor"].items():
        if "/-tmp-" in k:
            continue    # probe directories stay in the JSON only
        if v["retained"]["n"] >= 2 or v["window"]["n"]:
            L.append(f"| {k} | {fmt(v['window'])} | {fmt(v['retained'])} |")
    c = rep["compaction"]
    w = c["window"]
    L += ["", "## Compaction and context", "",
          f"- This window: {w['count']} compactions {w['by_trigger']}, {w['auto_near_295k_any']} auto near "
          f"295k ({w['auto_near_295k_after_fix']} after the fix), {w['auto_at_or_above_800k']} auto at 800k "
          f"or above; manual ones at {fmt(w['pre_tokens_manual'])}.",
          f"- Retained: {c['retained']['count']} compactions, {c['retained']['auto_near_295k']} auto near "
          f"295k, the last on {(c['retained']['last_auto_near_295k'] or 'none')[:10]}.",
          f"- Peak context this window: max {c['peak_context_window']['max']:,}; sessions over 295k: "
          f"{c['peak_context_window']['sessions_over_295k']}, over 500k: "
          f"{c['peak_context_window']['sessions_over_500k']}, over 800k: "
          f"{c['peak_context_window']['sessions_over_800k']}.",
          f"- API errors this window: {c['api_errors_window'] or 'none'}.", "",
          "## Interactive session length", "",
          "| Host | Human turns | API calls | Hours | Subagents | Worktree sessions |",
          "| --- | --- | --- | --- | --- | --- |"]
    for h, s in rep["session_length"].items():
        L.append(f"| {h} | {fmt(s['human_turns'])} | {fmt(s['api_calls'])} | {fmt(s['hours'])} | "
                 f"{s['subagent_transcripts']} | {s['worktree_sessions']} |")
    mem, lint = rep["memory"], rep["memory"]["lint"]
    L += ["", "## Memory", "", "What `lint.py --summary` counts in the vault's `AI/` area:", ""]
    L += [f"- {x}" for x in lint.get("summary", [])]
    if "error" in lint:
        L.append(f"- lint.py failed: {lint['error']}.")
    elif not lint["summary"]:
        L.append(f"- lint.py gave no summary, exit {lint['exit']}.")
    else:
        L.append(f"- lint.py: {lint['findings']['ERROR']} ERROR and {lint['findings']['WARN']} WARN, "
                 f"exit {lint['exit']}.")
    L += [f"- Sessions wrote to the old memory store {mem['session_memory_writes_window']} times and "
          f"removed a file from it with rm {mem['session_memory_rm_window']} times; autoDream "
          f"completion notices: {len(mem['dream_notices_window'])}.", "",
          "## autoDream", ""]
    for h, d in rep["autodream"].items():
        L.append(f"- {h}: available {d['available']}, key {d['settings_key']}, can fire {d['would_fire']}, "
                 f"gates {d['min_hours']} h and {d['min_sessions']} sessions.")
    mr = rep["tools"]["mcp_failure_rate"]
    L += ["", "## Skills and tools this window", "",
          "- Skill tool: " + (", ".join(f"{k} {v}" for k, v in rep["skills"]["skill_tool_window"].items()) or "none"),
          "- Slash commands: " + (", ".join(f"{k} {v}" for k, v in rep["skills"]["slash_commands_window"].items()) or "none"),
          "- MCP calls: " + (", ".join(f"{k} {v}" for k, v in rep["tools"]["mcp_calls_window"].items()) or "none"),
          "- Interactive sessions whose MCP server failed at start: " +
          ("; ".join(f"{h} {d['failed_at_start'] or 'none'}" for h, d in mr.items()) or "none")]
    for h, d in rep["skills"]["listing"].items():
        L.append(f"- {h}: {d['listed']} skills listed, {len(d['unused_over_retention'])} never invoked "
                 "on the main thread of a retained session.")
    L += ["", "## Tokens this window", "", "| Host | Input | Cache write | Cache read | Output |",
          "| --- | --- | --- | --- | --- |"]
    for h, t in rep["tokens_window"].items():
        L.append(f"| {h} | {t.get('input', 0):,} | {t.get('cache_creation', 0):,} | "
                 f"{t.get('cache_read', 0):,} | {t.get('output', 0):,} |")
    nc = rep["nextcloud_conflicts"]
    L += ["", f"Nextcloud conflict files: {nc['total']}, {nc['new_in_window']} new this window.", ""]
    return "\n".join(L)


def main():
    host = socket.gethostname().split(".")[0]
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--dir", default=default_dir(),
                        help="the telemetry folder (default: $CLAUDE_TELEMETRY_DIR, else "
                             "<nextcloud.root>/claude-telemetry from the skill values)")
    common.add_argument("--host", default=host, help=f"this machine's name in file names (default: {host})")
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sp = p.add_subparsers(dest="cmd", required=True)
    e = sp.add_parser("extract", parents=[common], help="rows from this machine's transcripts")
    e.add_argument("--projects", default="~/.claude/projects")
    e.add_argument("--rows", help="default: <dir>/rows/<host>.jsonl")
    s = sp.add_parser("state", parents=[common], help="this machine's autoDream flag and settings")
    s.add_argument("--claude-json", default="~/.claude.json")
    s.add_argument("--settings", default="~/.claude/settings.json")
    s.add_argument("--shim-log", default=os.path.join(
        os.environ.get("XDG_STATE_HOME") or "~/.local/state", "claude-shim", "log"))
    s.add_argument("--out", help="default: <dir>/state/<host>.json")
    r = sp.add_parser("report", parents=[common], help="the weekly report over every host")
    r.add_argument("--rows", nargs="*", help="default: <dir>/rows/*.jsonl")
    r.add_argument("--state", nargs="*", help="default: <dir>/state/*.json")
    r.add_argument("--conflict-roots", nargs="*", default=default_conflict_roots(),
                   help="folders scanned for Nextcloud conflict files (default: "
                        "$CLAUDE_TELEMETRY_CONFLICT_ROOTS, else the vault)")
    r.add_argument("--window-days", type=int, default=7)
    r.add_argument("--routing-since", default="2026-09-24T18:29:00+02:00",
                   help="when the claude shim started routing to the workstation")
    r.add_argument("--override-removed", default="2026-09-18T15:00:00+00:00",
                   help="when CLAUDE_AUTOCOMPACT_PCT_OVERRIDE left settings.json")
    r.add_argument("--now", help="report as of this ISO time (tests)")
    r.add_argument("--out-dir", help="default: <dir>/reports")
    a = p.parse_args()
    {"extract": cmd_extract, "state": cmd_state, "report": cmd_report}[a.cmd](a)


if __name__ == "__main__":
    main()
