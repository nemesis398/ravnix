# tests/test_claude_stop.py
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "adapters" / "claude"))
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import _common  # noqa: E402
import stop  # noqa: E402
from subprocess_env import subprocess_env  # noqa: E402


def edit_turn():
    """One user turn whose assistant reply edits a file."""
    return [
        {"type": "user", "message": {"role": "user", "content": "do it"}},
        {"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "tool_use", "name": "Edit", "input": {"file_path": "/x/y.py"}}]}},
    ]


def quiet_turn():
    return [
        {"type": "user", "message": {"role": "user", "content": "why?"}},
        {"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "text", "text": "Because."}]}},
    ]


SESSION_NOTE = "/home/m/Vault/AI/sessions/2026-10-17 Stop hooks.md"
WRITER = "~/.claude/skills/journal/scripts/session_note.py"


def tool_turn(name, **args):
    """One user turn whose assistant reply makes one tool call."""
    return [
        {"type": "user", "message": {"role": "user", "content": "write it up"}},
        {"type": "assistant", "message": {"role": "assistant", "content": [
            {"type": "tool_use", "name": name, "input": args}]}},
    ]


def journal_turn():
    return tool_turn("Bash", command=(
        f"python3 -B {WRITER} write --title T --domain ai "
        "--description D --body-file /tmp/body.md"))


def goal_record(met: bool):
    return [{"type": "attachment",
             "attachment": {"type": "goal_status", "met": met, "condition": "x"}}]


class StopCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.previous = os.environ.get("JOURNAL_STATE_ROOT")
        os.environ["JOURNAL_STATE_ROOT"] = os.path.join(self.tmp.name, "state")
        self.addCleanup(self._restore)

    def _restore(self):
        if self.previous is None:
            os.environ.pop("JOURNAL_STATE_ROOT", None)
        else:
            os.environ["JOURNAL_STATE_ROOT"] = self.previous

    def transcript(self, *groups, entrypoint="cli"):
        """Every record carries `entrypoint`, the way Claude Code writes one:
        "cli" in an interactive session, "sdk-cli" under `claude -p`. None
        leaves the key out."""
        path = Path(self.tmp.name) / "t.jsonl"
        records = [r for group in groups for r in group]
        if entrypoint is not None:
            records = [{**r, "entrypoint": entrypoint} for r in records]
        path.write_text("\n".join(json.dumps(r) for r in records), encoding="utf-8")
        return str(path)

    def reason(self):
        """Why the last call stood down. Read once: the record is cleared, so
        a later call that records nothing cannot pass on a stale reason."""
        import journal_state as js
        reason = js.read_standdown(self.tmp.name).get("reason")
        js.standdown_file(self.tmp.name).unlink(missing_ok=True)
        return reason

    def payload(self, transcript, **extra):
        base = {"cwd": self.tmp.name, "session_id": "s1",
                "transcript_path": transcript}
        base.update(extra)
        return base


class TestFires(StopCase):
    def test_fires_after_two_quiet_turns_following_an_edit(self):
        t = self.transcript(edit_turn(), quiet_turn(), quiet_turn())
        out = stop.handle(self.payload(t))
        self.assertIsNotNone(out)
        self.assertEqual(out["hookSpecificOutput"]["additionalContext"], stop.NUDGE)

    def test_the_nudge_names_the_session_note(self):
        t = self.transcript(edit_turn(), quiet_turn(), quiet_turn())
        nudge = stop.handle(self.payload(t))["hookSpecificOutput"]["additionalContext"]
        self.assertIn("session note", nudge)
        self.assertIn("journal skill", nudge)
        self.assertNotIn("daily note", nudge)

    def test_only_once_per_session(self):
        t = self.transcript(edit_turn(), quiet_turn(), quiet_turn())
        self.assertIsNotNone(stop.handle(self.payload(t)))
        self.assertIsNone(stop.handle(self.payload(t)))


class TestWhatCountsAsJournalled(StopCase):
    """Work, then one more turn, then two quiet ones: the nudge fires unless
    that one turn counts as journalled."""

    def wound_down_after(self, turn):
        return self.transcript(edit_turn(), turn, quiet_turn(), quiet_turn())

    def test_a_session_note_write_counts_as_journalled(self):
        for session, turn in (
                ("s-cli", journal_turn()),
                ("s-home", tool_turn("Bash", command=(
                    "cd /x && python3 -B $HOME/.claude/skills/journal/scripts/"
                    "session_note.py write --title T --domain ai"))),
                ("s-write", tool_turn("Write", file_path=SESSION_NOTE, content="# T")),
                ("s-edit", tool_turn("Edit", file_path=SESSION_NOTE,
                                     old_string="a", new_string="b"))):
            with self.subTest(session=session):
                self.assertIsNone(stop.handle(self.payload(
                    self.wound_down_after(turn), session_id=session)))
                self.assertEqual(self.reason(), "already_journalled")

    def test_a_daily_note_edit_no_longer_counts(self):
        daily = "/home/m/Vault/daily-notes/Saturday, 17. Oct 2026 (W42).md"
        for session, turn in (
                ("s-edit", tool_turn("Edit", file_path=daily,
                                     old_string="a", new_string="b")),
                ("s-write", tool_turn("Bash", command=(
                    "python3 -B ~/.claude/skills/journal/scripts/daily_note.py "
                    "write --area A --title T")))):
            with self.subTest(session=session):
                out = stop.handle(self.payload(self.wound_down_after(turn),
                                               session_id=session))
                self.assertIsNotNone(out)

    def test_running_the_writer_without_writing_does_not_count(self):
        # What a session working on the journal skill does all day.
        for session, command in (
                ("s-help", f"python3 -B {WRITER} --help"),
                ("s-cat", f"cat {WRITER}"),
                ("s-grep", 'grep -n "session_note.py write" SKILL.md')):
            with self.subTest(command=command):
                out = stop.handle(self.payload(
                    self.wound_down_after(tool_turn("Bash", command=command)),
                    session_id=session))
                self.assertIsNotNone(out)


class TestOnlyAnInteractiveSessionIsNudged(StopCase):
    def test_a_headless_session_is_never_nudged(self):
        t = self.transcript(edit_turn(), quiet_turn(), quiet_turn(),
                            entrypoint="sdk-cli")
        self.assertIsNone(stop.handle(self.payload(t)))
        self.assertEqual(self.reason(), "not_interactive")

    def test_a_transcript_without_an_entrypoint_is_never_nudged(self):
        missing = str(Path(self.tmp.name) / "missing.jsonl")
        empty = Path(self.tmp.name) / "empty.jsonl"
        empty.write_text("", encoding="utf-8")
        unmarked = self.transcript(edit_turn(), quiet_turn(), quiet_turn(),
                                   entrypoint=None)
        for session, transcript in (("s-unmarked", unmarked),
                                    ("s-empty", str(empty)),
                                    ("s-missing", missing)):
            with self.subTest(session=session):
                self.assertIsNone(stop.handle(self.payload(
                    transcript, session_id=session)))
                self.assertEqual(self.reason(), "not_interactive")

    def test_the_newest_entrypoint_decides(self):
        # A `claude -p --resume` appends headless records to an interactive
        # transcript, and an interactive resume does the reverse.
        def marked(value):
            return {"type": "user", "entrypoint": value}
        unmarked = {"type": "file-history-snapshot"}
        self.assertFalse(_common.is_interactive(
            [marked("cli"), marked("sdk-cli"), unmarked]))
        self.assertTrue(_common.is_interactive(
            [marked("sdk-cli"), marked("cli"), unmarked]))


class TestStandsDown(StopCase):
    def test_not_while_work_is_still_running(self):
        t = self.transcript(edit_turn(), quiet_turn())
        self.assertIsNone(stop.handle(self.payload(t)))

    def test_not_when_nothing_was_modified(self):
        t = self.transcript(quiet_turn(), quiet_turn(), quiet_turn())
        self.assertIsNone(stop.handle(self.payload(t)))

    def test_not_when_the_session_already_journalled(self):
        t = self.transcript(edit_turn(), journal_turn(), quiet_turn(), quiet_turn())
        self.assertIsNone(stop.handle(self.payload(t)))

    def test_not_when_a_stop_hook_is_holding_the_turn_open(self):
        t = self.transcript(edit_turn(), quiet_turn(), quiet_turn())
        self.assertIsNone(stop.handle(self.payload(t, stop_hook_active=True)))

    def test_not_during_a_live_goal_run(self):
        t = self.transcript(edit_turn(), quiet_turn(), quiet_turn(),
                            goal_record(met=False))
        self.assertIsNone(stop.handle(self.payload(t)))

    def test_fires_again_once_the_goal_is_met(self):
        t = self.transcript(edit_turn(), quiet_turn(), quiet_turn(),
                            goal_record(met=True))
        self.assertIsNotNone(stop.handle(self.payload(t)))

    def test_a_missing_transcript_is_silent(self):
        self.assertIsNone(stop.handle(self.payload(None)))

    def test_records_why_it_stood_down(self):
        t = self.transcript(edit_turn(), quiet_turn(), quiet_turn())
        stop.handle(self.payload(t, stop_hook_active=True))
        self.assertEqual(self.reason(), "stop_hook_active")


class TestNeverBreaksTheTurn(StopCase):
    def _drive(self, payload, **env):
        return subprocess.run(
            [sys.executable, "-B", str(ROOT / "adapters" / "claude" / "stop.py")],
            input=json.dumps(payload), capture_output=True, text=True,
            env=subprocess_env(**env))

    def test_garbage_stdin_still_exits_zero(self):
        done = subprocess.run(
            [sys.executable, "-B", str(ROOT / "adapters" / "claude" / "stop.py")],
            input="not json at all", capture_output=True, text=True,
            env=subprocess_env())
        self.assertEqual(done.returncode, 0)
        self.assertEqual(done.stdout.strip(), "")

    def test_the_kill_switch_silences_it(self):
        t = self.transcript(edit_turn(), quiet_turn(), quiet_turn())
        done = self._drive(self.payload(t), disabled=True)
        self.assertEqual(done.returncode, 0)
        self.assertEqual(done.stdout.strip(), "")


if __name__ == "__main__":
    unittest.main()


class TestRavnixShapes(StopCase):
    """What a session on a ravnix host runs: the writer through the store
    path of its python3, and the vault committed with vault-commit, which
    changes files as `git commit` does (modules/glue/vault.nix)."""

    def test_a_store_python_write_counts_as_journalled(self):
        turn = tool_turn("Bash", command=(
            "/nix/store/abc-python3-3.13/bin/python3 -B "
            "/home/a/.claude/skills/journal/scripts/session_note.py write --title T"))
        path = self.transcript(edit_turn(), turn, quiet_turn(), quiet_turn())
        self.assertIsNone(stop.handle(self.payload(path, session_id="s-store")))
        self.assertEqual(self.reason(), "already_journalled")

    def test_a_vault_commit_counts_as_a_change(self):
        commit = tool_turn("Bash", command="vault-commit 'docs: note' AI/sessions/T.md")
        self.assertEqual(_common.turns(self.transcript(commit))[0]["modified"], True)

    def test_a_git_commit_still_counts_as_a_change(self):
        commit = tool_turn("Bash", command="git commit -m x")
        self.assertEqual(_common.turns(self.transcript(commit))[0]["modified"], True)

    def test_a_vault_commit_alone_then_quiet_turns_nudges(self):
        commit = tool_turn("Bash", command="vault-commit 'docs: note' notes/x.md")
        out = stop.handle(self.payload(self.transcript(commit, quiet_turn(), quiet_turn()),
                                       session_id="s-vc"))
        self.assertIsNotNone(out)
