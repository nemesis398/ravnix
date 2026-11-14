"""The three hook adapters, driven the way Claude Code drives them.

Each test runs a real adapter as a subprocess with a payload on stdin, and
`subprocess_env` pins its environment: the vault and the domain file are
fixtures, and the state root is the test's own temp dir. `run()` ends in
os._exit, so an adapter can never run inside the test process.

The fixture vault is written once for the module. It holds 300 filler notes,
because a word scores ln(N / df) and MIN_SCORE is 4.0: below about 55 active
notes nothing matches at all. It sits under the fixture HOME, so every header
names the memory folder as `~/vault/AI/memory`. The expected texts are
written out by hand.
"""
from __future__ import annotations

import ast
import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SKILL = Path(__file__).resolve().parents[1]
ADAPTERS = SKILL / "adapters" / "claude"
sys.path.insert(0, str(Path(__file__).resolve().parent))
from helpers import front, text, write_note  # noqa: E402
from subprocess_env import subprocess_env  # noqa: E402

START, PROMPT, FAILURE = "sessionstart.py", "userpromptsubmit.py", "posttoolfailure.py"
EVENTS = {START: "SessionStart", PROMPT: "UserPromptSubmit", FAILURE: "PostToolUseFailure"}
CAP = 9000

SHOWN = "~/vault/AI/memory"
PINNED_HEADER = f"Pinned memory (notes in {SHOWN}; open one only when its line is not enough):"
MATCH_HEADER = f"Memory that may apply to this prompt (notes in {SHOWN}):"
FAILURE_HEADER = f"Memory that may explain this failure (notes in {SHOWN}):"


def digest_header(domain: str) -> str:
    return f"Memory digest for {domain}, most recently verified first (notes in {SHOWN}):"


# The two fixture notes load_notes cannot use, as hook.log names them: the
# path, then the reason. The line number in the first reason is left open.
PROBLEMS = (
    ("AI/memory/broken-pinned.md",
     r"the frontmatter does not parse: line \d+: a value that starts with ` must be quoted"),
    ("AI/memory/plane-answers-in-json (conflicted copy 2026-10-16 120000).md",
     "a Nextcloud conflict copy, skipped: merge it into its note"),
)

DAILY_LINE = "- daily-note-lives-in-the-vault: Daily notes: daily-notes/ at the vault root, one per day."
PLANE_LINE = "- plane-answers-in-json: Plane answers every query in JSON, so ask for fields."
PINNED_TEXT = "\n".join([PINNED_HEADER, DAILY_LINE, PLANE_LINE])
UGREP_LINE = ("- ugrep-is-grep-in-the-bash-tool: In the Bash tool, grep is ugrep,"
              " so call command grep for GNU behavior.")
UGREP_TEXT = "\n".join([MATCH_HEADER, UGREP_LINE])
HOMELAB_TEXT = "\n".join([
    digest_header("homelab"),
    "- caddy-reloads-config-on-sighup: Caddy reloads its Caddyfile on SIGHUP without dropping"
    " connections.",
    "- traefik-labels-need-a-network: Traefik routes a container only when its labels name the"
    " shared network.",
])
SSH_ERROR = ("Exit code 255\nsign_and_send_pubkey: signing failed for ED25519-SK from agent:"
             " agent refused operation\nfatal: Could not read from remote repository.")
SSH_TEXT = "\n".join([
    FAILURE_HEADER,
    "- ssh-signing-needs-a-key-tap: A push that fails with `sign_and_send_pubkey: signing"
    " failed` needs a tap on the key.",
])

# The pinned note in the block form Obsidian writes when it rewrites a note,
# with a colon inside the quoted description (Review Focus 1).
BLOCK_FORM = """\
type: memory
status: active
domain:
  - obsidian
updated: 2026-10-12
description: "Daily notes: daily-notes/ at the vault root, one per day."
tags:
  - preference
  - pinned
"""

# Each digest note's line is 499 characters, so 8 of them fill DIGEST_BUDGET
# exactly (8 * 500 = 4000) and the 9th stays out. A digest block is then its
# 83-character header plus 4000, two of them with their separator make 8168,
# and a third would pass 9000. That leaves 830 for a match block after its
# separator: its 66-character header and the 600-character durian line fit,
# the 300-character one no longer does.
DIGEST_LINE = 499
BIG_DURIAN, SMALL_DURIAN = 600, 300


def _sized(title: str, length: int, lead: str = "") -> str:
    """A quoted description that makes the note's line `length` characters."""
    return f'"{lead}{text(length - len(f"- {title}: ") - len(lead))}"'


def build_vault(memory: Path) -> None:
    shared = front(domain="[filler]", updated="2026-01-01",
                   description='"An unrelated filler note."')
    for i in range(300):
        write_note(memory, f"filler-{i:04d}.md", shared)
    write_note(memory, "plane-answers-in-json.md", front(
        domain="[plane]", updated="2026-10-10", tags="[reference, pinned]",
        description='"Plane answers every query in JSON, so ask for fields."'))
    write_note(memory, "daily-note-lives-in-the-vault.md", BLOCK_FORM)
    # Pinned too, and never injected: superseded, a conflict copy, and a note
    # whose frontmatter does not parse (a value that opens with a backtick).
    write_note(memory, "old-plane-rule.md", front(
        status="superseded", domain="[plane]", updated="2026-10-15",
        tags="[reference, pinned]", description='"Superseded: an old rule about Plane."'))
    write_note(memory, "plane-answers-in-json (conflicted copy 2026-10-16 120000).md", front(
        domain="[plane]", updated="2026-10-16", tags="[reference, pinned]",
        description='"A second version of the Plane note."'))
    write_note(memory, "broken-pinned.md", front(
        tags="[reference, pinned]", description="`unquoted` opens with a backtick"))
    write_note(memory, "caddy-reloads-config-on-sighup.md", front(
        domain="[homelab]", updated="2026-10-05",
        description='"Caddy reloads its Caddyfile on SIGHUP without dropping connections."'))
    write_note(memory, "traefik-labels-need-a-network.md", front(
        domain="[homelab]", updated="2026-09-20",
        description='"Traefik routes a container only when its labels name the shared network."'))
    write_note(memory, "ugrep-is-grep-in-the-bash-tool.md", front(
        domain="[fedora]", updated="2026-10-01",
        description='"In the Bash tool, grep is ugrep, so call command grep for GNU behavior."'))
    write_note(memory, "ssh-signing-needs-a-key-tap.md", front(
        domain="[git]", updated="2026-10-02", tags="[gotcha]",
        description='"A push that fails with `sign_and_send_pubkey: signing failed`'
                    ' needs a tap on the key."'))
    for domain in ("alpha", "bravo", "charlie"):
        for i in range(1, 10):
            title = f"{domain}-{i:02d}"
            write_note(memory, f"{title}.md", front(
                domain=f"[{domain}]", updated="2026-10-01",
                description=_sized(title, DIGEST_LINE)))
    write_note(memory, "big-durian.md", front(
        domain="[misc]", updated="2026-10-03",
        description=_sized("big-durian", BIG_DURIAN, "Durian. ")))
    write_note(memory, "small-durian.md", front(
        domain="[misc]", updated="2026-10-02",
        description=_sized("small-durian", SMALL_DURIAN, "Durian. ")))


DOMAINS = {"homelab": ["docker", "caddy"], "fedora": ["sway"],
           "alpha": ["apple"], "bravo": ["banana"], "charlie": ["cherry"]}

ROOT = Path()


def setUpModule() -> None:
    global ROOT
    ROOT = Path(tempfile.mkdtemp(prefix="ai-memory-adapters-"))
    build_vault(ROOT / "home" / "vault" / "AI" / "memory")
    (ROOT / "domains.json").write_text(json.dumps(DOMAINS), encoding="utf-8")


def tearDownModule() -> None:
    shutil.rmtree(ROOT, ignore_errors=True)


def start(session: str = "s1", source: str = "startup", **extra) -> dict:
    return {"session_id": session, "source": source, "cwd": ".", **extra}


def prompt(words: str, session: str = "s1", **extra) -> dict:
    return {"session_id": session, "prompt": words, "source": "user", **extra}


def failure(error: str, session: str = "s1", tool: str = "Bash", **extra) -> dict:
    return {"session_id": session, "tool_name": tool, "tool_input": {"command": "x"},
            "tool_use_id": "toolu_1", "error": error, **extra}


class AdapterCase(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.state = self.tmp / "state"

    def drive(self, script: str, payload: dict, adapters: Path = ADAPTERS,
              **env: str) -> subprocess.CompletedProcess:
        pinned = {"AI_MEMORY_VAULT": str(ROOT / "home" / "vault"),
                  "AI_MEMORY_DOMAINS": str(ROOT / "domains.json"),
                  "HOME": str(ROOT / "home")}
        return subprocess.run(
            [sys.executable, "-B", str(adapters / script)],
            input=json.dumps(payload), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, env=subprocess_env(self.tmp, **{**pinned, **env}),
            cwd=self.tmp, timeout=30,
        )

    def context(self, script: str, payload: dict, **env: str) -> str:
        """The additionalContext the adapter emits, after checking the shape."""
        done = self.drive(script, payload, **env)
        self.assertEqual((done.returncode, done.stderr), (0, ""))
        self.assertEqual(done.stdout.count("\n"), 1, done.stdout)
        output = json.loads(done.stdout)
        self.assertEqual(list(output), ["hookSpecificOutput"])
        specific = output["hookSpecificOutput"]
        self.assertEqual(set(specific), {"hookEventName", "additionalContext"})
        self.assertEqual(specific["hookEventName"], EVENTS[script])
        self.assertIsInstance(specific["additionalContext"], str)
        self.assertLessEqual(len(specific["additionalContext"]), CAP)
        return specific["additionalContext"]

    def assertQuiet(self, done: subprocess.CompletedProcess) -> None:
        """Exit 0 and nothing on either stream."""
        self.assertEqual((done.returncode, done.stdout, done.stderr), (0, "", ""))

    def logged(self) -> list[dict]:
        path = self.state / "injections.jsonl"
        if not path.exists():
            return []
        return [json.loads(row) for row in path.read_text(encoding="utf-8").splitlines()]

    def hook_log(self) -> str:
        path = self.state / "hook.log"
        return path.read_text(encoding="utf-8") if path.exists() else ""


class SessionStartTest(AdapterCase):
    def test_sessionstart_injects_pinned_lines_under_the_header(self):
        # Newest first. The superseded note, the conflict copy and the note
        # that does not parse are pinned too, and none of them shows.
        self.assertEqual(self.context(START, start()), PINNED_TEXT)
        [entry] = self.logged()
        self.assertEqual(
            {k: entry[k] for k in ("session", "event", "reason", "rels", "chars", "detail")},
            {"session": "s1", "event": "SessionStart", "reason": "pinned",
             "rels": ["AI/memory/daily-note-lives-in-the-vault.md",
                      "AI/memory/plane-answers-in-json.md"],
             "chars": len(PINNED_TEXT), "detail": ""})
        self.assertNotIn("Traceback", self.hook_log())

    def test_sessionstart_reads_a_block_form_pinned_note(self):
        lines = self.context(START, start()).split("\n")
        self.assertIn(DAILY_LINE, lines)

    def test_sessionstart_after_compact_injects_again(self):
        self.assertEqual(self.context(START, start()), PINNED_TEXT)
        self.assertEqual(self.context(PROMPT, prompt("ugrep")), UGREP_TEXT)
        # A resume keeps its transcript, which already holds the lines.
        self.assertQuiet(self.drive(START, start(source="resume")))
        self.assertQuiet(self.drive(PROMPT, prompt("ugrep")))
        # A compaction lost them, so everything goes out again.
        self.assertEqual(self.context(START, start(source="compact")), PINNED_TEXT)
        self.assertEqual(self.context(PROMPT, prompt("ugrep")), UGREP_TEXT)
        self.assertEqual([e["reason"] for e in self.logged()],
                         ["pinned", "match", "pinned", "match"])

    def test_an_unlistable_sessions_dir_still_gets_the_pinned_lines(self):
        # Write and search permission, no read: a session file can be read
        # and written by name, but prune() cannot list the directory.
        sessions = self.state / "sessions"
        sessions.mkdir(parents=True)
        sessions.chmod(0o300)
        self.addCleanup(sessions.chmod, 0o700)
        self.assertEqual(self.context(START, start()), PINNED_TEXT)
        self.assertQuiet(self.drive(START, start(source="resume")))

    def test_a_new_session_and_a_fork_get_the_pinned_lines(self):
        self.context(START, start("s1"))
        for session, source in (("s2", "startup"), ("s3", "fork"), ("s4", "clear")):
            with self.subTest(source=source):
                self.assertEqual(self.context(START, start(session, source)), PINNED_TEXT)


class PromptTest(AdapterCase):
    def test_prompt_injects_a_domain_digest_once_per_session(self):
        # `docker` and `caddy` touch homelab. `caddy` also matches the caddy
        # note, which the digest already holds, so no match block follows.
        self.assertEqual(self.context(PROMPT, prompt("Why does docker restart caddy every night?")),
                         HOMELAB_TEXT)
        # The second prompt touches homelab again: matches only, no digest.
        self.assertEqual(self.context(PROMPT, prompt("docker again, and ugrep")), UGREP_TEXT)
        digest, match = self.logged()
        self.assertEqual(
            {k: digest[k] for k in ("event", "reason", "rels", "chars", "detail")},
            {"event": "UserPromptSubmit", "reason": "digest",
             "rels": ["AI/memory/caddy-reloads-config-on-sighup.md",
                      "AI/memory/traefik-labels-need-a-network.md"],
             "chars": len(HOMELAB_TEXT), "detail": "homelab"})
        self.assertEqual(
            {k: match[k] for k in ("event", "reason", "rels", "chars")},
            {"event": "UserPromptSubmit", "reason": "match",
             "rels": ["AI/memory/ugrep-is-grep-in-the-bash-tool.md"], "chars": len(UGREP_TEXT)})

    def test_prompt_never_repeats_a_note_in_one_session(self):
        self.context(START, start("s1"))
        # The Plane note came in pinned, so only the ugrep note matches.
        self.assertEqual(self.context(PROMPT, prompt("plane json fields ugrep", "s1")),
                         UGREP_TEXT)
        self.assertQuiet(self.drive(PROMPT, prompt("plane json fields ugrep", "s1")))
        self.assertQuiet(self.drive(PROMPT, prompt("ugrep", "s1")))
        # Another session has been given nothing yet.
        self.assertEqual(self.context(PROMPT, prompt("plane json fields ugrep", "s2")),
                         "\n".join([MATCH_HEADER, PLANE_LINE, UGREP_LINE]))

    def test_a_wakeup_prompt_gets_nothing(self):
        for source in ("system", "loop_wakeup", "schedule_wakeup", "poll_event"):
            with self.subTest(source=source):
                self.assertQuiet(self.drive(PROMPT, prompt("ugrep", source, source=source)))
        self.assertEqual(self.logged(), [])
        # A prompt the user typed, or one from a headless run, does get it.
        for source in ("user", "sdk"):
            with self.subTest(source=source):
                self.assertEqual(self.context(PROMPT, prompt("ugrep", source, source=source)),
                                 UGREP_TEXT)

    def test_digests_stop_before_the_context_cap(self):
        alpha = [f"AI/memory/alpha-{i:02d}.md" for i in range(1, 9)]
        bravo = [f"AI/memory/bravo-{i:02d}.md" for i in range(1, 9)]
        context = self.context(PROMPT, prompt("apple banana cherry docker durian"))
        # alpha and bravo fill 8168 characters. charlie would pass 9000, so
        # it waits, and so does homelab after it, small as its digest is. Of
        # the two durian lines only the first still fits.
        self.assertTrue(context.startswith(digest_header("alpha") + "\n- alpha-01: "))
        self.assertIn("\n\n" + digest_header("bravo") + "\n- bravo-01: ", context)
        self.assertNotIn("charlie", context)
        self.assertNotIn("homelab", context)
        self.assertNotIn("alpha-09", context)
        self.assertIn("\n\n" + MATCH_HEADER + "\n- big-durian: Durian. ", context)
        self.assertNotIn("small-durian", context)
        # The two digests make 8168, then a separator and the match block.
        self.assertEqual(len(context), 8168 + 2 + len(MATCH_HEADER) + 1 + BIG_DURIAN)
        self.assertEqual([(e["reason"], e["detail"], e["rels"]) for e in self.logged()],
                         [("digest", "alpha", alpha), ("digest", "bravo", bravo),
                          ("match", "", ["AI/memory/big-durian.md"])])
        # charlie was left undigested and the small durian note unmatched.
        context = self.context(PROMPT, prompt("apple cherry durian"))
        self.assertTrue(context.startswith(digest_header("charlie") + "\n- charlie-01: "))
        self.assertIn("\n\n" + MATCH_HEADER + "\n- small-durian: Durian. ", context)
        self.assertNotIn("alpha", context)
        self.assertNotIn("big-durian", context)
        self.assertEqual([(e["reason"], e["detail"]) for e in self.logged()[3:]],
                         [("digest", "charlie"), ("match", "")])


class FailureTest(AdapterCase):
    def test_failure_injects_the_matching_symptom(self):
        self.assertEqual(self.context(FAILURE, failure(SSH_ERROR)), SSH_TEXT)
        [entry] = self.logged()
        self.assertEqual(
            {k: entry[k] for k in ("event", "reason", "rels", "chars", "detail")},
            {"event": "PostToolUseFailure", "reason": "failure",
             "rels": ["AI/memory/ssh-signing-needs-a-key-tap.md"],
             "chars": len(SSH_TEXT), "detail": ""})

    def test_a_repeated_failure_is_neither_injected_again_nor_a_miss(self):
        self.context(FAILURE, failure(SSH_ERROR))
        self.assertQuiet(self.drive(FAILURE, failure(SSH_ERROR)))
        self.assertEqual([e["reason"] for e in self.logged()], ["failure"])

    def test_a_failure_inside_a_subagent_injects_and_logs_nothing(self):
        for error in (SSH_ERROR, "Exit code 1\nno memory names this"):
            with self.subTest(error=error):
                self.assertQuiet(self.drive(FAILURE, failure(error, agent_id="a1")))
        self.assertEqual(self.logged(), [])
        self.assertEqual(self.hook_log(), "")

    def test_an_interrupted_tool_call_gets_nothing(self):
        for error in (SSH_ERROR, "Exit code 130\ninterrupted"):
            with self.subTest(error=error):
                self.assertQuiet(self.drive(FAILURE, failure(error, is_interrupt=True)))
        self.assertEqual(self.logged(), [])

    def test_an_unmatched_failure_is_logged_as_a_miss_with_digits_masked(self):
        long_line = "line 42 " + "x" * 200
        cases = (
            ("Exit code 1\n\n  Error: port 8080 is taken since 12:30, pid 4711  \nmore",
             "Bash", "Bash: Error: port #### is taken since ##:##, pid ####"),
            ("Exit code 2", "Bash", "Bash"),
            (long_line, "Read", ("Read: line ## " + "x" * 200)[:160]),
            ("File has not been read yet. Read it first before writing to it.", "Write",
             "Write: File has not been read yet. Read it first before writing to it."),
        )
        for i, (error, tool, _) in enumerate(cases):
            self.assertQuiet(self.drive(FAILURE, failure(error, f"s{i}", tool)))
        self.assertEqual(
            [{k: e[k] for k in ("session", "event", "reason", "rels", "chars", "detail")}
             for e in self.logged()],
            [{"session": f"s{i}", "event": "PostToolUseFailure", "reason": "miss", "rels": [],
              "chars": 0, "detail": detail} for i, (_, _, detail) in enumerate(cases)])
        self.assertEqual(len(self.logged()[2]["detail"]), 160)


class EveryAdapterTest(AdapterCase):
    HITS = ((START, start()), (PROMPT, prompt("ugrep")), (FAILURE, failure(SSH_ERROR)))
    TEXTS = {START: PINNED_TEXT, PROMPT: UGREP_TEXT, FAILURE: SSH_TEXT}

    def test_each_adapter_logs_the_notes_it_could_not_read(self):
        # One line per problem, stamp, script, path and reason, and never
        # the note's body. What goes out is the same as without the log.
        for script, payload in self.HITS:
            with self.subTest(script=script):
                (self.state / "hook.log").unlink(missing_ok=True)
                self.assertEqual(self.context(script, payload), self.TEXTS[script])
                lines = self.hook_log().splitlines()
                self.assertEqual(len(lines), len(PROBLEMS), lines)
                for row, (rel, reason) in zip(lines, PROBLEMS):
                    self.assertRegex(row, rf"^\S+ {re.escape(script)} {re.escape(rel)}: {reason}$")
                self.assertNotIn("Fact.", self.hook_log())

    def test_a_hook_log_that_cannot_be_written_costs_no_injection(self):
        (self.state / "hook.log").mkdir(parents=True)
        for script, payload in self.HITS:
            with self.subTest(script=script):
                self.assertEqual(self.context(script, payload), self.TEXTS[script])

    def test_output_is_valid_hook_json(self):
        # context() checks the shape: one JSON line, hookEventName equal to
        # the event, additionalContext a string within the cap.
        for script, payload in self.HITS:
            with self.subTest(script=script):
                self.assertTrue(self.context(script, payload))

    def test_subagents_get_nothing_from_any_hook(self):
        for script, payload in self.HITS:
            with self.subTest(script=script):
                self.assertQuiet(self.drive(script, {**payload, "agent_id": "a1"}))
        self.assertEqual(self.logged(), [])
        self.assertEqual(self.hook_log(), "")

    def test_a_missing_vault_prints_nothing_and_exits_zero(self):
        # As mid-sync: no notes, which is no error, so hook.log stays empty.
        gone = str(self.tmp / "no-vault")
        for script, payload in self.HITS:
            with self.subTest(script=script):
                self.assertQuiet(self.drive(script, payload, AI_MEMORY_VAULT=gone))
        self.assertEqual(self.hook_log(), "")
        self.assertEqual([e["reason"] for e in self.logged()], ["miss"])

    def test_an_unwritable_state_root_fails_open(self):
        root = self.tmp / "not-a-dir"
        root.write_text("a file, not a directory\n", encoding="utf-8")
        for script, payload in self.HITS:
            with self.subTest(script=script):
                self.assertQuiet(self.drive(script, payload, AI_MEMORY_STATE_ROOT=str(root)))
        self.assertEqual(root.read_text(encoding="utf-8"), "a file, not a directory\n")

    def test_each_adapter_fails_open_without_its_script_modules(self):
        # The stow tree mid-sync: the adapters are there, scripts/ is empty.
        skill = self.tmp / "skill"
        (skill / "scripts").mkdir(parents=True)
        copied = skill / "adapters" / "claude"
        copied.mkdir(parents=True)
        for name in ("_common.py", *EVENTS):
            shutil.copy(ADAPTERS / name, copied)
        for script, payload in self.HITS:
            with self.subTest(script=script):
                self.assertQuiet(self.drive(script, payload, adapters=copied))
        trace = self.hook_log()
        for script in EVENTS:
            self.assertIn(f" {script}\nTraceback (most recent call last)", trace)
        self.assertEqual(trace.count("ModuleNotFoundError: No module named"), 3)
        self.assertEqual(self.logged(), [])


def module_level_imports(tree: ast.AST) -> list[str]:
    """The top-level names imported where a module runs on import: anywhere
    but inside a function body."""
    names: list[str] = []

    def visit(node: ast.AST) -> None:
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda)):
                continue
            if isinstance(child, ast.Import):
                names.extend(alias.name.split(".")[0] for alias in child.names)
            elif isinstance(child, ast.ImportFrom):
                names.append("." if child.level else (child.module or "").split(".")[0])
            visit(child)

    visit(tree)
    return names


class StructureTest(unittest.TestCase):
    def test_the_adapters_are_the_three_registered_hooks(self):
        self.assertEqual(sorted(p.name for p in ADAPTERS.glob("*.py") if p.name != "_common.py"),
                         sorted(EVENTS))

    def test_adapters_import_only_common_and_the_stdlib_at_module_level(self):
        # A script module imported at module level fails before run() can
        # catch it: exit 1, a traceback on stderr, nothing in hook.log.
        allowed = set(sys.stdlib_module_names) | {"__future__", "_common"}
        for script in EVENTS:
            with self.subTest(script=script):
                tree = ast.parse((ADAPTERS / script).read_text(encoding="utf-8"))
                top = module_level_imports(tree)
                self.assertIn("_common", top)
                self.assertEqual([name for name in top if name not in allowed], [])
                every = {alias.name for node in ast.walk(tree) if isinstance(node, ast.Import)
                         for alias in node.names}
                self.assertIn("state", every)

    def test_the_import_scan_sees_a_module_level_script_import(self):
        source = ("import json\nimport _common\nif True:\n    import state\n"
                  "def handle(payload):\n    import notes\n")
        self.assertEqual(module_level_imports(ast.parse(source)), ["json", "_common", "state"])


if __name__ == "__main__":
    unittest.main()


class WithoutTheVaultValue(AdapterCase):
    """No AI_MEMORY_VAULT and no `vault.root`: every hook stays quiet and
    logs nothing, because a skill that is not set up is no failure."""

    def test_each_hook_is_quiet_and_logs_nothing(self):
        for script, payload in ((START, start()), (PROMPT, prompt("docker caddy")),
                                (FAILURE, failure("Exit code 144"))):
            with self.subTest(script=script):
                self.assertQuiet(self.drive(script, payload, AI_MEMORY_VAULT=""))
        self.assertEqual(self.hook_log(), "")

    def test_the_value_names_the_vault(self):
        (self.tmp / "skill-values.json").write_text(
            json.dumps({"vault": {"root": str(ROOT / "home" / "vault")}}), encoding="utf-8")
        self.assertEqual(self.context(START, start(), AI_MEMORY_VAULT=""), PINNED_TEXT)
