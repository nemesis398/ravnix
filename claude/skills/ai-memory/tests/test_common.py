"""The harness every hook adapter runs under: it fails open.

`run()` is driven in a subprocess, the way Claude Code runs a hook, because it
always ends the process. Each test builds a one-off adapter from a handler
and pins the environment with `subprocess_env`, so nothing touches the real
state root.
"""
from __future__ import annotations

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SKILL = Path(__file__).resolve().parents[1]
ADAPTERS = SKILL / "adapters" / "claude"
sys.path.insert(0, str(ADAPTERS))
import _common  # noqa: E402
import state  # noqa: E402  (on the path through _common)

sys.path.insert(0, str(Path(__file__).resolve().parent))
from subprocess_env import subprocess_env  # noqa: E402

PAYLOAD = json.dumps({"session_id": "s1", "text": "Remember this."})

# Handlers for the one-off adapters. Each imports its script modules inside
# the handler, the way the real adapters must. `_common` is imported.
ECHO = '''
def handler(payload):
    return _common.emit("SessionStart", payload["text"])
'''

MARK = '''
def handler(payload):
    open(payload["marker"], "w").close()
    return _common.emit("SessionStart", "ran")
'''

REMEMBER = '''
def handler(payload):
    import state
    state.remember(payload["session_id"], ["AI/memory/a.md"], [])
    return _common.emit("SessionStart", "ran")
'''

WHERE = '''
def handler(payload):
    import state
    return _common.emit("SessionStart", state.__file__)
'''

CHATTY = '''
def handler(payload):
    print("debug")
    return _common.emit("SessionStart", "ran")
'''


def raising(exc: str) -> str:
    return f"def handler(payload):\n    raise {exc}\n"


def adapter(handler: str, adapters: Path = ADAPTERS) -> str:
    """The source of a hook adapter that runs `handler` under `run()`."""
    return (f"import sys\nsys.path.insert(0, {str(adapters)!r})\n"
            f"import _common\n{handler}\n_common.run(handler)\n")


class EmitTest(unittest.TestCase):
    def test_emit_caps_context_at_9000(self):
        for text, kept in (("short", "short"), ("x" * 9000, "x" * 9000),
                           ("y" * 9500, "y" * 9000)):
            with self.subTest(length=len(text)):
                self.assertEqual(_common.emit("UserPromptSubmit", text), {
                    "hookSpecificOutput": {
                        "hookEventName": "UserPromptSubmit",
                        "additionalContext": kept,
                    }})

    def test_a_payload_with_an_agent_id_is_a_subagent(self):
        self.assertTrue(_common.is_subagent({"agent_id": "a1", "session_id": "s1"}))
        for payload in ({}, {"agent_id": ""}, {"agent_id": None}, {"session_id": "s1"}):
            with self.subTest(payload=payload):
                self.assertFalse(_common.is_subagent(payload))

    def test_the_failure_log_finds_the_state_root_without_state(self):
        # _common keeps its own copy of the rule, so that a broken state.py
        # is still logged. The two copies must agree.
        with tempfile.TemporaryDirectory() as home:
            for env in ({"AI_MEMORY_STATE_ROOT": "/elsewhere/state"},
                        {"AI_MEMORY_STATE_ROOT": ""}, {}):
                with self.subTest(env=env), mock.patch.dict(os.environ, {"HOME": home}):
                    os.environ.pop("AI_MEMORY_STATE_ROOT", None)
                    os.environ.update(env)
                    self.assertEqual(_common.state_root(), state.state_root())


class RunTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.hook_log = self.tmp / "state" / "hook.log"

    def drive(self, handler: str, stdin: str = PAYLOAD, disabled: bool = False,
              stdout=subprocess.PIPE, adapters: Path = ADAPTERS,
              **env: str) -> subprocess.CompletedProcess:
        return subprocess.run(
            [sys.executable, "-B", "-c", adapter(handler, adapters)],
            input=stdin, stdout=stdout, stderr=subprocess.PIPE, text=True,
            env=subprocess_env(self.tmp, disabled=disabled, **env),
            cwd=self.tmp, timeout=30,
        )

    def assertQuiet(self, done: subprocess.CompletedProcess) -> None:
        """Exit 0 and nothing on either stream: what a failed hook must look like."""
        self.assertEqual((done.returncode, done.stdout, done.stderr), (0, "", ""))

    def test_a_handler_result_is_printed_as_one_json_line(self):
        done = self.drive(ECHO)
        self.assertEqual((done.returncode, done.stderr), (0, ""))
        self.assertEqual(done.stdout.count("\n"), 1)
        self.assertEqual(json.loads(done.stdout), _common.emit("SessionStart", "Remember this."))
        self.assertFalse(self.hook_log.exists())

    def test_a_handler_imports_the_skill_scripts(self):
        done = self.drive(WHERE)
        self.assertEqual(json.loads(done.stdout),
                         _common.emit("SessionStart", str(SKILL / "scripts" / "state.py")))

    def test_a_handler_that_prints_still_outputs_one_json_line(self):
        done = self.drive(CHATTY)
        self.assertEqual((done.returncode, done.stderr), (0, ""))
        self.assertEqual(done.stdout, json.dumps(_common.emit("SessionStart", "ran")) + "\n")

    def test_a_missing_state_module_fails_open(self):
        # A copy of the harness whose scripts/ lacks state.py, as a half
        # synced or mid-edit stow tree can leave it.
        skill = self.tmp / "skill"
        (skill / "scripts").mkdir(parents=True)
        (skill / "adapters" / "claude").mkdir(parents=True)
        shutil.copy(ADAPTERS / "_common.py", skill / "adapters" / "claude")
        self.assertQuiet(self.drive(REMEMBER, adapters=skill / "adapters" / "claude"))
        trace = self.hook_log.read_text(encoding="utf-8")
        self.assertIn("Traceback (most recent call last)", trace)
        self.assertIn("ModuleNotFoundError: No module named 'state'", trace)

    def test_malformed_stdin_exits_zero_prints_nothing_and_logs(self):
        for stdin in ("}{ not valid json", ""):
            with self.subTest(stdin=stdin):
                self.hook_log.unlink(missing_ok=True)
                self.assertQuiet(self.drive(ECHO, stdin=stdin))
                trace = self.hook_log.read_text(encoding="utf-8")
                self.assertIn("Traceback (most recent call last)", trace)
                self.assertIn("JSONDecodeError", trace)

    def test_a_raising_handler_exits_zero_and_logs_the_traceback(self):
        for exc, logged in (("RuntimeError('handler blew up')", "RuntimeError: handler blew up"),
                            ("SystemExit(2)", "SystemExit: 2"),
                            ("KeyboardInterrupt", "KeyboardInterrupt")):
            with self.subTest(exc=exc):
                self.hook_log.unlink(missing_ok=True)
                self.assertQuiet(self.drive(raising(exc)))
                trace = self.hook_log.read_text(encoding="utf-8")
                self.assertIn("Traceback (most recent call last)", trace)
                self.assertIn(logged, trace)

    def test_a_second_failure_appends_to_the_log(self):
        self.drive(raising("RuntimeError('first')"))
        self.drive(raising("RuntimeError('second')"))
        trace = self.hook_log.read_text(encoding="utf-8")
        self.assertLess(trace.index("RuntimeError: first"), trace.index("RuntimeError: second"))

    def test_an_unwritable_state_root_still_exits_zero(self):
        root = self.tmp / "not-a-dir"
        root.write_text("a file, not a directory\n", encoding="utf-8")
        self.assertQuiet(self.drive(REMEMBER, AI_MEMORY_STATE_ROOT=str(root)))
        self.assertEqual(root.read_text(encoding="utf-8"), "a file, not a directory\n")

    def test_the_kill_switch_skips_the_handler(self):
        on, off = self.tmp / "ran-on", self.tmp / "ran-off"
        done = self.drive(MARK, stdin=json.dumps({"marker": str(on)}))
        self.assertTrue(on.exists())
        self.assertEqual(json.loads(done.stdout), _common.emit("SessionStart", "ran"))

        self.assertQuiet(self.drive(MARK, stdin=json.dumps({"marker": str(off)}), disabled=True))
        self.assertFalse(off.exists())
        self.assertFalse(self.hook_log.exists())

    def test_a_closed_stdout_still_exits_zero(self):
        # Python exits 120 when its final flush of stdout fails, and a hook
        # sees that once Claude Code has stopped reading.
        read, write = os.pipe()
        os.close(read)
        try:
            done = self.drive(ECHO, stdout=write)
        finally:
            os.close(write)
        self.assertEqual((done.returncode, done.stderr), (0, ""))
        self.assertIn("BrokenPipeError", self.hook_log.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
