#!/usr/bin/env bash
# Tests for claude-telemetry (packages/claude-telemetry), run by the check
# bin-claude-telemetry, and for the systemd units that ravnix generates for it
# (modules/common/scripts.nix; the check passes them in CLAUDE_TELEMETRY_UNITS).
#
# Why fixtures instead of the real transcripts: the script's contract is what
# it writes from a given tree of transcripts, settings and memory notes, and
# above all what it never writes. The privacy case plants one marker string in
# every place a transcript holds prompt, answer or tool text, in the secrets of
# ~/.claude.json and settings.json, and in a memory note whose broken
# frontmatter lint.py quotes, and then requires that the marker appears in no
# file the script wrote. The real tree could not prove that, because it holds
# no marker to look for.
#
# The environment is built from nothing (env -i): HOME is the sandbox, TZ=UTC,
# and PATH holds a link to python3 only, the one program the script runs, so a
# script that starts calling another tool fails here first. The memory area is
# a fixture vault under the sandbox HOME, read by a copy of the ai-memory
# lint.py. The ai-memory skill that owns the real one is not part of ravnix, so
# the lint is a stand-in (fixtures/ai-memory/scripts/lint.py) that prints the
# same shapes: a summary, and an ERROR that quotes the broken line.
#
# Run:  bash claude-telemetry.test.sh      (exit 0 = all green)
# CLAUDE_TELEMETRY_UNDER_TEST=<file> tests another copy, for mutation runs; by
# default it is the claude-telemetry on the PATH.
# The sandbox lives under ${TMPDIR:-/tmp} and is removed on exit. The whole
# run takes about 2 s.

# The ~ in the expected alerts is text the script prints, not a path.
# shellcheck disable=SC2088

set -uo pipefail

SELF=$(readlink -f "$0")
SCRIPT=$(readlink -f "${CLAUDE_TELEMETRY_UNDER_TEST:-$(type -P claude-telemetry)}")
UNITS=${CLAUDE_TELEMETRY_UNITS:-}
SKILL=${SELF%/*}/fixtures/ai-memory
[ -f "$SCRIPT" ] || { echo "missing $SCRIPT" >&2; exit 2; }
[ -f "$SKILL/scripts/lint.py" ] || { echo "missing $SKILL/scripts/lint.py" >&2; exit 2; }
for tool in env python3 grep touch stat; do
    type -P "$tool" >/dev/null || { echo "the tests need $tool, which is not installed" >&2; exit 2; }
done
ENV_BIN=$(type -P env) PY=$(type -P python3)

pass=0
fail=0
CASE="" PROBLEMS=""
RC=0 ERR=""

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/claude-telemetry-test.XXXXXX") || exit 2
ROOT=$(cd "$ROOT" && pwd -P)
trap 'rm -rf -- "$ROOT"' EXIT
TOOLS=$ROOT/tools H=$ROOT/home
TD=$H/Nextcloud/claude-telemetry VAULT=$H/vault
mkdir -p "$TOOLS" "$H"
ln -s "$PY" "$TOOLS/python3"
# The skill values of the sandbox user: the Nextcloud root, whose
# claude-telemetry folder is the default folder, and the vault.
mkdir -p "$H/.config/ravnix"
printf '{"nextcloud": {"root": "%s"}, "vault": {"root": "%s"}}\n' "$H/Nextcloud" "$VAULT" \
    >"$H/.config/ravnix/skill-values.json"

ok()  { pass=$((pass+1)); printf '  \033[32m✓\033[0m %s\n' "$CASE"; }
bad() { fail=$((fail+1)); printf '  \033[31m✗\033[0m %s\n     %s\n' "$CASE" "$1"
        printf 'exit %s\nstderr:\n%s\n' "$RC" "$ERR" | sed 's/^/       | /'; }
begin()   { CASE=$1; PROBLEMS=""; }
problem() { PROBLEMS+="${PROBLEMS:+; }$1"; }
verdict() { if [ -z "$PROBLEMS" ]; then ok; else bad "$PROBLEMS"; fi; }

# run <subcommand> [args...]: the script under env -i, with HOME the sandbox.
# It finds its folders through the skill values, as it does on a host:
# nextcloud.root for the telemetry folder, vault.root for the memory area and
# the conflict scan. RUN_ENV adds variables to one run.
RUN_ENV=()
run() {
    "$ENV_BIN" -i HOME="$H" TZ=UTC PATH="$TOOLS" CLAUDE_TELEMETRY_MEMORY_DIRS=old-store \
        "${RUN_ENV[@]}" "$PY" -B "$SCRIPT" "$@" \
        >"$ROOT/out" 2>"$ROOT/err"
    RC=$?
    ERR=$(<"$ROOT/err")
}

# q <jq-like python expression over R, the rows keyed by session>: prints it.
q() {
    "$PY" -B - "$TD/rows/testbox.jsonl" "$1" <<'EOF'
import json, sys
R = {}
for line in open(sys.argv[1]):
    r = json.loads(line)
    R[r["session"]] = r
print(json.dumps(eval(sys.argv[2]), sort_keys=True))
EOF
}
is() { local got; got=$(q "$1"); [ "$got" = "$2" ] || problem "$1 is $got, expected $2"; }

# --- the fixture home ---------------------------------------------------------------
# One project with an interactive session that has a subagent, and a headless
# session. MARKER stands for every piece of text a row must never carry.

MARKER=Zq7LeakCanary
"$PY" -B - "$H" "$MARKER" <<'EOF'
import json, os, sys
H, M = sys.argv[1], sys.argv[2]
P = os.path.join(H, ".claude/projects/-home-u-proj")
os.makedirs(os.path.join(P, "s-inter/subagents"), exist_ok=True)

def dump(path, recs):
    with open(path, "w") as fh:
        for r in recs:
            fh.write((r if isinstance(r, str) else json.dumps(r, separators=(",", ":"))) + "\n")

def base(t, ts, **kw):
    d = {"type": t, "timestamp": ts, "sessionId": "s", "entrypoint": kw.pop("ep", "cli"),
         "version": "2.1.282", "cwd": "/home/u/proj"}
    d.update(kw)
    return d

def usage(i, cw, cr, o):
    return {"input_tokens": i, "cache_creation_input_tokens": cw, "cache_read_input_tokens": cr,
            "output_tokens": o}

def att(ts, **a):
    return base("attachment", ts, attachment=a)

T = "2026-09-24T10:%02d:00.000Z"
inter = [
    att(T % 0, type="skill_listing", isInitial=True, skillCount=3, content=f"journal prose {M} " * 10,
        names=["journal", "prose", f"a leaky {M} name"]),
    att(T % 0, type="instructions", files=[
        {"path": "/home/u/.claude/CLAUDE.md", "type": "User", "content": f"{M} " * 30},
        {"path": "/home/u/.claude/projects/-home-u-proj/memory/MEMORY.md", "type": "AutoMem", "content": "x" * 50}]),
    att(T % 0, type="deferred_tools_delta", addedNames=["A", "B", f"{M}"], failedMcpServers=["coolify-live"]),
    att(T % 0, type="mcp_instructions_delta", addedNames=["plane-personal", "coolify-live"], addedBlocks=[M]),
    att(T % 0, type="hook_additional_context", content=[f"hook says {M}"]),
    base("user", T % 1, promptSource="typed", origin={"kind": "human"},
         message={"role": "user", "content": f"please do the thing {M}"}),
    base("assistant", T % 2, requestId="r1", effort="xhigh", message={
        "id": "m1", "model": "claude-opus-5-5", "role": "assistant", "usage": usage(1000, 2000, 3000, 10),
        "content": [{"type": "thinking", "thinking": f"thinking {M}"},
                    {"type": "text", "text": f"answer {M}"},
                    {"type": "tool_use", "id": "t1", "name": "Bash",
                     "input": {"command": f"rm ~/Nextcloud/old-store/x/{M}.md"}}]}),
    # The same API message split over two lines, as Claude Code writes it: counted once.
    base("assistant", T % 2, requestId="r1", message={
        "id": "m1", "model": "claude-opus-5-5", "role": "assistant", "usage": usage(1000, 2000, 3000, 10),
        "content": [{"type": "tool_use", "id": "t2", "name": "Skill", "input": {"skill": "journal", "args": M}},
                    {"type": "tool_use", "id": "t3", "name": "Skill", "input": {"skill": f"leak {M} text"}}]}),
    base("user", T % 3, sourceToolAssistantUUID="x", toolUseResult={"stdout": M},
         message={"role": "user", "content": [{"type": "tool_result", "tool_use_id": "t1", "content": f"out {M}"}]}),
    base("assistant", T % 4, requestId="r2", message={
        "id": "m2", "model": "claude-opus-5-5", "role": "assistant", "usage": usage(1, 8000, 999, 20),
        "content": [{"type": "tool_use", "id": "t4", "name": "Write",
                     "input": {"file_path": "/home/u/Nextcloud/old-store/-home-u-proj/new.md", "content": M}},
                    {"type": "tool_use", "id": "t5", "name": "mcp__plane-personal__workitem",
                     "input": {"action": "create", "name": M}}]}),
    base("user", T % 5, promptSource="typed", origin={"kind": "human"}, message={"role": "user",
         "content": f"<command-name>/effort</command-name><command-args>{M}</command-args>"}),
    base("user", T % 5, isMeta=True, message={"role": "user", "content": f"caveat {M}"}),
    base("user", T % 6, isCompactSummary=True, isVisibleInTranscriptOnly=True,
         message={"role": "user", "content": f"This session is being continued. {M}"}),
    base("system", T % 6, subtype="compact_boundary", content=M,
         compactMetadata={"trigger": "auto", "preTokens": 294000, "postTokens": 20000}),
    base("assistant", T % 7, isApiErrorMessage=True, message={
        "id": "e1", "model": "<synthetic>", "role": "assistant", "usage": usage(0, 0, 0, 0),
        "content": [{"type": "text", "text": "Prompt is too long"}]}),
    base("system", T % 8, subtype="memory_saved", verb="Improved", writtenPaths=[f"/m/{M}.md"]),
    base("system", T % 8, subtype="stop_hook_summary", hookErrors=[f"hook failed {M}"]),
    {"type": "ai-title", "aiTitle": f"title {M}", "sessionId": "s"},
    {"type": "last-prompt", "lastPrompt": f"last {M}", "sessionId": "s"},
    {"type": "queue-operation", "operation": "enqueue", "content": f"queued {M}", "timestamp": T % 9},
    f"not json at all {M}",
    base("user", T % 9, isSidechain=True, promptSource="typed",
         message={"role": "user", "content": f"a sidechain prompt {M}"}),
]
dump(os.path.join(P, "s-inter.jsonl"), inter)
dump(os.path.join(P, "s-inter/subagents/agent-a1.jsonl"), [
    base("assistant", T % 3, isSidechain=True, message={
        "id": "sa1", "model": "claude-opus-5-5", "role": "assistant", "usage": usage(100, 200, 300, 5),
        "content": [{"type": "text", "text": M},
                    {"type": "tool_use", "id": "u1", "name": "Read", "input": {"file_path": f"/{M}"}}]})])
dump(os.path.join(P, "s-head.jsonl"), [
    base("user", T % 30, ep="sdk-cli", promptSource="sdk", message={"role": "user", "content": f"ok {M}"}),
    base("assistant", T % 31, ep="sdk-cli", message={
        "id": "h1", "model": "claude-opus-5-5", "role": "assistant", "usage": usage(3, 40000, 0, 2),
        "content": [{"type": "text", "text": f"ok {M}"}]})])

# ~/.claude.json and settings.json, each with a secret next to the keys state reads.
json.dump({"oauthAccount": {"emailAddress": f"{M}@example.com"}, "primaryApiKey": M,
           "projects": {"/home/u/proj": {"history": [M]}},
           "cachedGrowthBookFeaturesAt": 1790315662835,
           "cachedGrowthBookFeatures": {
               "tengu_onyx_plover": {"enabled": False, "available": True, "minHours": 24, "minSessions": 3,
                                     "secretish": M},
               "tengu_hover_rest": False, "tengu_other": M}},
          open(os.path.join(H, ".claude.json"), "w"))
json.dump({"autoDreamEnabled": True, "cleanupPeriodDays": 90, "env": {"TOKEN": M},
           "permissions": {"allow": [M]}}, open(os.path.join(H, ".claude/settings.json"), "w"))
os.makedirs(os.path.join(H, ".local/state/claude-shim"))
with open(os.path.join(H, ".local/state/claude-shim/log"), "w") as fh:
    fh.write("2026-09-24T18:30:37+0200\troute\t-\t~/proj\tNextcloud syncs ~/proj\n")
    fh.write("2026-09-24T18:57:37+0200\tlocal\t-\t~/Git/x\t~/Git/x has uncommitted files\n")
EOF

# --- extract ---------------------------------------------------------------------

echo "extract"

begin "a first run parses both sessions into <dir>/rows/<host>.jsonl"
run extract --host testbox
[ "$RC" -eq 0 ] || problem "expected exit 0, got $RC"
[[ $ERR == *"2 parsed"*"0 reused"* ]] || problem "stderr does not say 2 parsed, 0 reused"
[ -f "$TD/rows/testbox.jsonl" ] || problem "no rows file under the default dir"
[ -s "$ROOT/out" ] && problem "it printed on stdout"
verdict

begin "no prompt, answer, tool input, tool result or title text reaches a row"
if grep -q "$MARKER" "$TD/rows/testbox.jsonl"; then
    problem "the marker is in the rows: $(grep -o ".\{60\}$MARKER.\{20\}" "$TD/rows/testbox.jsonl" | head -3 | tr '\n' '|')"
fi
verdict

begin "a name field that holds free text is recorded as ?"
is 'R["s-inter"]["skills"]' '{"?": 1, "journal": 1}'
is '"?" in R["s-inter"]["skill_names"]' 'true'
is 'R["s-inter"]["slash_commands"]' '{"effort": 1}'
verdict

begin "the first turn is input plus cache write plus cache read, and a split message counts once"
is 'R["s-inter"]["first_turn_tokens"]' '6000'
is 'R["s-inter"]["api_calls"]' '2'
is 'R["s-inter"]["peak_context"]' '9000'
is 'R["s-inter"]["tokens"]' '{"cache_creation": 10000, "cache_read": 3999, "input": 1001, "output": 30}'
is 'R["s-head"]["first_turn_tokens"]' '40003'
verdict

begin "interactive and headless are told apart by the entrypoint"
is 'R["s-inter"]["entrypoint"]' '"cli"'
is 'R["s-head"]["entrypoint"]' '"sdk-cli"'
verdict

begin "human turns: a typed prompt and a slash command, not meta, summaries, tool results or sidechains"
is 'R["s-inter"]["human_turns"]' '2'
is 'R["s-inter"]["first_turn_prior_prompts"]' '1'
verdict

begin "tools, MCP servers, memory writes and rm, and the session-start surface are counted"
is 'R["s-inter"]["tools"]' '{"Bash": 1, "Skill": 2, "Write": 1, "mcp__plane-personal__workitem": 1}'
is 'R["s-inter"]["mcp"]' '{"plane-personal": 1}'
is '[R["s-inter"]["memory_writes"], R["s-inter"]["memory_rm"]]' '[1, 1]'
is '[R["s-inter"]["deferred_tools"], R["s-inter"]["mcp_servers"], R["s-inter"]["mcp_failed"]]' '[3, 2, ["coolify-live"]]'
is '[R["s-inter"]["memory_index_chars"], R["s-inter"]["skill_listing_count"]]' '[50, 3]'
verdict

begin "a compaction, an API error, a dream notice and a hook error are recorded"
is 'R["s-inter"]["compactions"]' '[{"post": 20000, "pre": 294000, "trigger": "auto", "ts": "2026-09-24T10:06:00.000Z"}]'
is 'R["s-inter"]["api_errors"]' '{"prompt_too_long": 1}'
is 'R["s-inter"]["memory_saved"]' '[{"files": 1, "ts": "2026-09-24T10:08:00.000Z", "verb": "Improved"}]'
is 'R["s-inter"]["hook_errors"]' '1'
verdict

begin "subagent transcripts are summed into their parent's row"
is 'R["s-inter"]["subagents"]["files"]' '1'
is '[R["s-inter"]["subagents"]["input"], R["s-inter"]["subagents"]["tool_calls"]]' '[100, 1]'
verdict

begin "a second run reuses both rows and leaves the file alone"
touch -d '2026-01-01 00:00' "$TD/rows/testbox.jsonl"
run extract --host testbox
[[ $ERR == *"0 parsed"*"2 reused"* ]] || problem "stderr does not say 0 parsed, 2 reused"
[ "$(stat -c %Y "$TD/rows/testbox.jsonl")" = "$(date -d '2026-01-01 00:00' +%s)" ] ||
    problem "an unchanged rows file was rewritten, which costs a sync"
verdict

begin "a subagent that grew while its parent stood still gets its parent re-parsed"
cp "$H/.claude/projects/-home-u-proj/s-inter/subagents/agent-a1.jsonl" "$ROOT/a1"
sed 's/"sa1"/"sa2"/' "$ROOT/a1" >>"$H/.claude/projects/-home-u-proj/s-inter/subagents/agent-a1.jsonl"
touch -d '+1 min' "$H/.claude/projects/-home-u-proj/s-inter/subagents/agent-a1.jsonl"
run extract --host testbox
[[ $ERR == *"1 parsed"*"1 reused"* ]] || problem "stderr does not say 1 parsed, 1 reused"
is 'R["s-inter"]["subagents"]["input"]' '200'
verdict

begin "a transcript Claude Code deleted keeps its row, marked as gone"
rm -- "$H/.claude/projects/-home-u-proj/s-head.jsonl"
run extract --host testbox
[[ $ERR == *"1 kept after deletion"* ]] || problem "stderr does not say 1 kept after deletion"
is 'R["s-head"].get("transcript_gone")' 'true'
is 'R["s-head"]["first_turn_tokens"]' '40003'
verdict

begin "no .part file is left behind"
leftover=$(find "$TD" -name '*.part')
[ -z "$leftover" ] || problem "left $leftover"
verdict

begin "without --host the file is named after the hostname"
run extract
host=$("$PY" -c 'import socket; print(socket.gethostname().split(".")[0])')
[ -f "$TD/rows/$host.jsonl" ] || problem "no rows/$host.jsonl"
rm -f -- "$TD/rows/$host.jsonl"
verdict

begin "no transcripts at all is an empty rows file, not a failure"
run extract --host empty --projects "$ROOT/nowhere"
[ "$RC" -eq 0 ] || problem "expected exit 0, got $RC"
[ -f "$TD/rows/empty.jsonl" ] && [ ! -s "$TD/rows/empty.jsonl" ] || problem "expected an empty rows file"
rm -f -- "$TD/rows/empty.jsonl"
verdict

# --- where the telemetry folder comes from -----------------------------------------
# Nothing is built in: CLAUDE_TELEMETRY_DIR, else <nextcloud.root>/claude-telemetry
# from the skill values, else there is no folder and nothing is written.

begin "CLAUDE_TELEMETRY_DIR wins over the skill value"
RUN_ENV=(CLAUDE_TELEMETRY_DIR="$ROOT/elsewhere")
run extract --host envbox
RUN_ENV=()
[ "$RC" -eq 0 ] || problem "expected exit 0, got $RC"
[ -f "$ROOT/elsewhere/rows/envbox.jsonl" ] || problem "no rows file under CLAUDE_TELEMETRY_DIR"
[ ! -e "$TD/rows/envbox.jsonl" ] || problem "the skill value's folder was used as well"
verdict

begin "with no folder anywhere it says what to set, exits 1 and writes nothing"
mkdir -p "$ROOT/cwd"
printf '{"nextcloud": {"root": 5}, "vault": {"root": "%s"}}\n' "$VAULT" >"$ROOT/number-root.json"
for values in "$ROOT/nowhere.json" "$ROOT/number-root.json"; do
    RUN_ENV=(RAVNIX_SKILL_VALUES="$values")
    cd "$ROOT/cwd" || exit 2
    run extract --host nodir
    cd - >/dev/null || exit 2
    RUN_ENV=()
    [ "$RC" -eq 1 ] || problem "expected exit 1, got $RC for ${values##*/}"
    [[ $ERR == *CLAUDE_TELEMETRY_DIR*nextcloud.root* ]] || problem "the message does not name both settings for ${values##*/}"
done
[ -z "$(ls -A "$ROOT/cwd")" ] || problem "it wrote into the working directory: $(ls "$ROOT/cwd")"
verdict

begin "explicit --rows and --out need no folder"
RUN_ENV=(RAVNIX_SKILL_VALUES="$ROOT/nowhere.json")
run state --host nodir --out "$ROOT/explicit-state.json"
RUN_ENV=()
[ "$RC" -eq 0 ] || problem "expected exit 0, got $RC"
[ -f "$ROOT/explicit-state.json" ] || problem "no state file at --out"
verdict

# --- state ---------------------------------------------------------------------------

echo "state"

begin "state copies the named keys and nothing else"
run state --host testbox
[ "$RC" -eq 0 ] || problem "expected exit 0, got $RC"
if grep -q "$MARKER" "$TD/state/testbox.json" 2>/dev/null; then problem "the marker is in the state file"; fi
got=$("$PY" -c 'import json,sys; s=json.load(open(sys.argv[1])); print(json.dumps([s["flag_onyx_plover"], s["settings"]["autoDreamEnabled"], s["settings"]["cleanupPeriodDays"], len(s["shim_decisions"])], sort_keys=True))' "$TD/state/testbox.json")
[ "$got" = '[{"available": true, "enabled": false, "minHours": 24, "minSessions": 3}, true, 90, 2]' ] ||
    problem "state holds $got"
verdict

begin "a missing ~/.claude.json and settings.json are recorded, not fatal"
run state --host bare --claude-json "$ROOT/none.json" --settings "$ROOT/none.json"
[ "$RC" -eq 0 ] || problem "expected exit 0, got $RC"
grep -q '"claude_json_error": "FileNotFoundError"' "$TD/state/bare.json" || problem "no claude_json_error"
rm -f -- "$TD/state/bare.json"
verdict

# --- report ------------------------------------------------------------------------

echo "report"

# The memory area: a fixture vault where lint.py's own default finds it under
# the sandbox HOME, and a copy of the skill's scripts where the script looks
# for them, so the bytecode case watches a copy and never the fixture. The
# copy has no domains.json, so lint.py checks no domain. AI/memory holds two
# gotchas (one pinned), a feedback and a reference note, plus one note whose
# frontmatter does not parse and holds the marker: lint.py quotes that line in
# its ERROR, so the report has to count the finding and never copy it. Beside
# the vault lies the old store as it stays after the cutover, with an index
# over its cap and a .consolidate-lock, neither of which may raise an alert.
LINT=$H/.claude/skills/ai-memory/scripts/lint.py
mkdir -p "${LINT%/*}"
cp -L -- "$SKILL"/scripts/*.py "${LINT%/*}/"
"$PY" -B - "$VAULT" "$MARKER" "$H/Nextcloud/old-store/-home-u-proj" <<'EOF'
import os, sys
V, M, OLD = sys.argv[1:4]
def note(rel, text):
    path = os.path.join(V, rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as fh:
        fh.write(text)
def memory(stem, tags, description):
    note(f"AI/memory/{stem}.md", "---\ntype: memory\nstatus: active\ndomain: [ai]\n"
         f"updated: 2026-09-20\ndescription: {description}\ntags: [{tags}]\n---\n\n# {stem}\n\nBody.\n")
memory("a-pinned-gotcha", "gotcha, pinned", "fails with `exit status 1` on start")
memory("a-gotcha", "gotcha", "prints `command not found` twice")
memory("a-feedback", "feedback", "say it once")
memory("a-reference", "reference", "the dashboard lives at one address")
note("AI/memory/a-broken.md", f"---\ntype: memory\n{M} is not a key\n---\n\n# Broken\n")
note("AI/sessions/2026-09-24 A session.md",
     "---\ntype: session\ndescription: a session\nupdated: 2026-09-24\n---\n\n# A session\n")
os.makedirs(OLD)
with open(os.path.join(OLD, "MEMORY.md"), "w") as fh:
    fh.write("\n".join("x" * 250 for _ in range(96)) + "\n")
open(os.path.join(OLD, ".consolidate-lock"), "w").write("4242")
EOF
mkdir -p "$VAULT/Notes"
touch -d '2026-09-24 09:00' "$VAULT/Notes/Note (conflicted copy 2026-09-24 090000).md"
# The laptop's state from the fixture files: flag available, key on.
run state --host laptopbox
rm -f -- "$TD/state/testbox.json"
printf '{"host": "build-box", "flag_onyx_plover": {"enabled": false}, "settings": {"autoDreamEnabled": false}}\n' \
    >"$TD/state/build-box.json"

NOW=2026-09-25T06:00:00+00:00

begin "a report writes the dated markdown and JSON and alerts.json"
run report --now "$NOW" --host reportbox
[ "$RC" -eq 0 ] || problem "expected exit 0, got $RC"
for f in 2026-09-25.md 2026-09-25.json alerts.json; do [ -f "$TD/reports/$f" ] || problem "no reports/$f"; done
[ -s "$ROOT/out" ] && problem "it printed on stdout"
ALERTS=$(<"$TD/reports/alerts.json")
verdict

has_alert()  { [[ $ALERTS == *"$1"* ]] || problem "no alert with \"$1\""; }
lacks_alert() { [[ $ALERTS != *"$1"* ]] || problem "an alert has \"$1\""; }

# mem <python expression over m, the report's memory section>: prints it.
mem() { "$PY" -c 'import json, sys; m = json.load(open(sys.argv[1]))["memory"]; print(json.dumps(eval(sys.argv[2]), sort_keys=True))' \
            "${2:-$TD/reports/2026-09-25.json}" "$1"; }

begin "the memory section holds the summary lint.py --summary prints for the vault"
LINT_OUT=$("$ENV_BIN" -i HOME="$H" TZ=UTC PATH="$TOOLS" "$PY" -B "$LINT" --summary)
want=$(printf '%s\n' "$LINT_OUT" | sed -e '/^ERROR /d' -e '/^WARN /d')
got=$("$PY" -c 'import json, sys; print("\n".join(json.load(open(sys.argv[1]))["memory"]["lint"]["summary"]))' \
    "$TD/reports/2026-09-25.json")
[ -n "$want" ] && [ "$got" = "$want" ] || problem "the report holds [$got], lint.py printed [$want]"
[[ $got == *"AI/memory: 4 notes, "* ]] || problem "AI/memory is not 4 notes"
[[ $got == *"kinds in AI/memory: gotcha 2, feedback 1, preference 0, reference 1"* ]] || problem "the kinds are not 2, 1, 0, 1"
[[ $got == *"pinned: 1 note, "* ]] || problem "pinned is not 1 note"
grep -qxF -- '- kinds in AI/memory: gotcha 2, feedback 1, preference 0, reference 1' "$TD/reports/2026-09-25.md" ||
    problem "the markdown does not list the kinds"
verdict

begin "lint.py's findings are counted by level with its exit code, and never copied"
[[ $LINT_OUT == *"ERROR AI/memory/a-broken.md: "*"$MARKER"* ]] ||
    problem "lint.py no longer quotes the broken note's marker, so the privacy case proves nothing here"
got=$(mem '[m["lint"]["exit"], m["lint"]["findings"]]')
[ "$got" = '[1, {"ERROR": 1, "WARN": 1}]' ] || problem "exit and findings are $got"
grep -qxF -- '- lint.py: 1 ERROR and 1 WARN, exit 1.' "$TD/reports/2026-09-25.md" ||
    problem "the markdown does not count the findings"
verdict

begin "lint.py runs without writing bytecode next to the skill"
pyc=$(find "$H/.claude/skills" -name __pycache__)
[ -z "$pyc" ] || problem "it wrote $pyc"
verdict

begin "the old store, still on disk with an index over its cap and a lock, raises nothing"
lacks_alert 'memory index'
lacks_alert 'memory set'
lacks_alert 'autoDream ran on'
lacks_alert 'deleted in git'
got=$(mem 'sorted(m)')
[ "$got" = '["dream_notices_window", "lint", "session_memory_rm_window", "session_memory_writes_window"]' ] ||
    problem "the memory section holds $got"
verdict

begin "the transcript counters stay: writes to the old store, rm on it and dream notices"
got=$(mem '[m["session_memory_writes_window"], m["session_memory_rm_window"], len(m["dream_notices_window"])]')
[ "$got" = '[1, 1, 1]' ] || problem "writes, rm and notices are $got"
grep -qxF -- '- Sessions wrote to the old memory store 1 times and removed a file from it with rm 1 times; autoDream completion notices: 1.' \
    "$TD/reports/2026-09-25.md" || problem "the markdown does not show the counters"
verdict

begin "autoDream can fire where the flag makes it available and the key is on, not elsewhere"
has_alert 'autoDream can fire on laptopbox'
lacks_alert 'autoDream can fire on build-box'
verdict

begin "an auto compaction at 294k after the fix, a prompt-too-long, and a new conflicted copy alert"
has_alert 'CLAUDE_AUTOCOMPACT_PCT_OVERRIDE is back (decision 9)'
has_alert '1 \"Prompt is too long\" error(s) in sessions active this week'
has_alert '1 new Nextcloud conflict file(s) this week'
verdict

begin "alerts.json names its host and report"
got=$("$PY" -c 'import json,sys; a=json.load(open(sys.argv[1])); print(a["host"], a["report"], a["generated_at"])' "$TD/reports/alerts.json")
[ "$got" = "reportbox 2026-09-25.md 2026-09-25T06:00:00+00:00" ] || problem "alerts.json says $got"
verdict

begin "the report carries no marker either"
if grep -rq "$MARKER" "$TD/reports"; then problem "the marker is in a report"; fi
verdict

begin "an auto compaction near 295k before the fix is history, not an alert"
run report --now "$NOW" --override-removed 2026-09-24T11:00:00+00:00
[[ $(<"$TD/reports/alerts.json") != *OVERRIDE* ]] || problem "it alerted on a compaction from before the fix"
verdict

# The vault still holds the broken note, so lint.py still finds an ERROR: a
# finding is shown in the report and never raises an alert.
begin "an all-clear run writes an empty alert list, and rewrites alerts.json even so"
mkdir -p "$ROOT/quiet"
touch -d '2026-01-01 00:00' "$TD/reports/alerts.json"
run report --now "$NOW" --rows --state --conflict-roots "$ROOT/quiet" --out-dir "$TD/reports"
[ "$RC" -eq 0 ] || problem "expected exit 0, got $RC"
got=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["alerts"])' "$TD/reports/alerts.json")
[ "$got" = "[]" ] || problem "alerts are $got"
[ "$(stat -c %Y "$TD/reports/alerts.json")" != "$(date -d '2026-01-01 00:00' +%s)" ] ||
    problem "alerts.json kept its old time, so its age would no longer mean anything"
grep -q '^None\.$' "$TD/reports/2026-09-25.md" || problem "the markdown does not say None. under Alerts"
[ "$(mem 'm["lint"]["findings"]["ERROR"]')" = 1 ] || problem "lint.py's ERROR is missing from this run"
verdict

begin "without the skill the report says lint.py gave no summary, and still succeeds without an alert"
mv -- "$H/.claude/skills/ai-memory" "$ROOT/skill-away"
run report --now "$NOW" --rows --state --conflict-roots "$ROOT/quiet" --out-dir "$ROOT/nolint"
mv -- "$ROOT/skill-away" "$H/.claude/skills/ai-memory"
[ "$RC" -eq 0 ] || problem "expected exit 0, got $RC"
got=$(mem 'm["lint"]' "$ROOT/nolint/2026-09-25.json")
[ "$got" = '{"exit": 2, "findings": {"ERROR": 0, "WARN": 0}, "summary": []}' ] || problem "lint is $got"
grep -qxF -- '- lint.py gave no summary, exit 2.' "$ROOT/nolint/2026-09-25.md" ||
    problem "the markdown does not say that lint.py gave no summary"
got=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["alerts"])' "$ROOT/nolint/alerts.json")
[ "$got" = "[]" ] || problem "alerts are $got"
verdict

# A copy of the script with LINT_TIMEOUT lowered to half a second, and a
# lint.py that sleeps ten: the report must give up on it, not wait.
begin "a lint.py that hangs past the timeout is reported as failed, and the report still succeeds"
sed 's/^LINT_TIMEOUT = .*/LINT_TIMEOUT = 0.5/' "$SCRIPT" >"$ROOT/claude-telemetry-fast"
grep -qxF 'LINT_TIMEOUT = 0.5' "$ROOT/claude-telemetry-fast" || problem "could not lower LINT_TIMEOUT in a copy"
mv -- "$H/.claude/skills/ai-memory" "$ROOT/skill-away"
mkdir -p "${LINT%/*}"
printf 'import time\ntime.sleep(10)\n' >"$LINT"
SCRIPT_UNDER_TEST=$SCRIPT SCRIPT=$ROOT/claude-telemetry-fast
started=$SECONDS
run report --now "$NOW" --rows --state --conflict-roots "$ROOT/quiet" --out-dir "$ROOT/hung"
took=$((SECONDS - started))
SCRIPT=$SCRIPT_UNDER_TEST
rm -rf -- "$H/.claude/skills/ai-memory"
mv -- "$ROOT/skill-away" "$H/.claude/skills/ai-memory"
[ "$RC" -eq 0 ] || problem "expected exit 0, got $RC"
[ "$took" -lt 5 ] || problem "the report waited $took s for lint.py"
got=$(mem 'm["lint"]' "$ROOT/hung/2026-09-25.json")
[ "$got" = '{"error": "TimeoutExpired"}' ] || problem "lint is $got"
grep -qxF -- '- lint.py failed: TimeoutExpired.' "$ROOT/hung/2026-09-25.md" ||
    problem "the markdown does not say that lint.py failed"
got=$("$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["alerts"])' "$ROOT/hung/alerts.json")
[ "$got" = "[]" ] || problem "alerts are $got"
verdict

# --- where the conflict scan looks -----------------------------------------------
# CLAUDE_TELEMETRY_CONFLICT_ROOTS (colon-separated), else the vault, else nowhere.

conflicts() { # conflicts FILE: the report's total of conflict files
    "$PY" -c 'import json,sys; print(json.load(open(sys.argv[1]))["nextcloud_conflicts"]["total"])' "$1"
}
mkdir -p "$ROOT/confl1" "$ROOT/confl2"
touch "$ROOT/confl2/Note (conflicted copy 2026-09-24 090000).md" "$ROOT/confl2/b_conflict-1.md"

begin "CLAUDE_TELEMETRY_CONFLICT_ROOTS lists the folders to scan, and replaces the vault"
RUN_ENV=(CLAUDE_TELEMETRY_CONFLICT_ROOTS="$ROOT/confl1:$ROOT/confl2")
run report --now "$NOW" --rows --state --out-dir "$ROOT/roots"
RUN_ENV=()
[ "$RC" -eq 0 ] || problem "expected exit 0, got $RC"
[ "$(conflicts "$ROOT/roots/2026-09-25.json")" = 2 ] || problem "total is $(conflicts "$ROOT/roots/2026-09-25.json"), expected 2 from the listed folders alone"
verdict

begin "without the list the vault is scanned, and with no vault nothing is"
run report --now "$NOW" --rows --state --out-dir "$ROOT/vaultroot"
[ "$(conflicts "$ROOT/vaultroot/2026-09-25.json")" = 1 ] || problem "the vault's one conflict file was not counted"
printf '{}\n' >"$ROOT/empty-values.json"
RUN_ENV=(RAVNIX_SKILL_VALUES="$ROOT/empty-values.json")
run report --now "$NOW" --rows --state --out-dir "$ROOT/noroot"
RUN_ENV=()
[ "$RC" -eq 0 ] || problem "expected exit 0, got $RC"
[ "$(conflicts "$ROOT/noroot/2026-09-25.json")" = 0 ] || problem "something was scanned with no vault set"
verdict

# --- the units ---------------------------------------------------------------------
# The four units ravnix generates with the option claudeTelemetry.report on,
# as files in $CLAUDE_TELEMETRY_UNITS (the check passes them in).

echo "systemd units"

if [ -z "$UNITS" ] || [ ! -d "$UNITS" ]; then
    CASE="the units are passed in"
    RC=2 ERR="CLAUDE_TELEMETRY_UNITS names no directory"
    bad "the check has to pass the generated units in CLAUDE_TELEMETRY_UNITS"
else
    has_line()  { grep -qxF -- "$2" "$UNITS/$1" || problem "$1 lacks \"$2\""; }
    has_match() { grep -qE -- "$2" "$UNITS/$1" || problem "$1 has no line like \"$2\""; }
    lacks_line() { ! grep -q -- "$2" "$UNITS/$1" || problem "$1 has \"$2\""; }

    begin "no unit names a host: the report runs where the option is on, not by hostname"
    for u in "$UNITS"/claude-telemetry-*; do
        lacks_line "${u##*/}" ConditionHost
    done
    verdict

    begin "both services run at Nice 19 with idle I/O, oneshot"
    for s in extract report; do
        has_line "claude-telemetry-$s.service" Nice=19
        has_line "claude-telemetry-$s.service" IOSchedulingClass=idle
        has_line "claude-telemetry-$s.service" Type=oneshot
    done
    verdict

    begin "the services call the packaged script by its store path, not python3 from the PATH"
    has_match claude-telemetry-extract.service '^ExecStart=/nix/store/[^ ]+/bin/claude-telemetry extract$'
    has_match claude-telemetry-extract.service '^ExecStart=/nix/store/[^ ]+/bin/claude-telemetry state$'
    has_match claude-telemetry-report.service '^ExecStart=/nix/store/[^ ]+/bin/claude-telemetry report$'
    has_line claude-telemetry-extract.service "ExecStart=$SCRIPT extract"
    verdict

    begin "the report refreshes this machine's rows first"
    has_line claude-telemetry-report.service Wants=claude-telemetry-extract.service
    has_line claude-telemetry-report.service After=claude-telemetry-extract.service
    verdict

    begin "both timers are persistent, daily and weekly"
    for t in extract report; do
        has_line "claude-telemetry-$t.timer" Persistent=true
        has_line "claude-telemetry-$t.timer" WantedBy=timers.target
    done
    has_line claude-telemetry-extract.timer OnCalendar=daily
    has_line claude-telemetry-report.timer 'OnCalendar=Mon *-*-* 07:00:00'
    verdict

    if type -P systemd-analyze >/dev/null; then
        begin "systemd-analyze verify accepts all four"
        # The user manager wants a runtime directory to look at, even to verify.
        mkdir -p "$ROOT/xdg-run" && chmod 700 "$ROOT/xdg-run"
        out=$(XDG_RUNTIME_DIR="$ROOT/xdg-run" systemd-analyze --user verify "$UNITS"/claude-telemetry-*.service "$UNITS"/claude-telemetry-*.timer 2>&1)
        [ -z "$out" ] || problem "$out"
        verdict
    fi
fi

# --- summary ----------------------------------------------------------------------

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
