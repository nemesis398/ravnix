# tests/test_claude_adapters.py
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from datetime import datetime, timedelta
from pathlib import Path

ADAPTERS = Path(__file__).resolve().parents[1] / "adapters" / "claude"
sys.path.insert(0, str(ADAPTERS))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import _common  # noqa: E402
import plane  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
from subprocess_env import subprocess_env  # noqa: E402


# Claude Code's own printed hook-JSON validation-error schema dump, captured
# 2026-08-08 against a real compaction (verbatim failure quoted in
# precompact.py's docstring): hookSpecificOutput fields are documented only
# for these six events. There is no PreCompact entry: confirmed rejected
# outright, "Hook JSON output validation failed - (root): Invalid input" on
# every real compaction.
#
# SessionStart is not in that printed dump either, but is confirmed working
# in production independent of anything this build wrote to make it so: real
# hook_success + hook_additional_context attachment pairs, exit code 0, the
# additionalContext text actually delivered into the session, across four
# separate real sessions (this vault and another repository, "startup" and
# "clear" sources, pointer and full modes; see
# TestAdapterOutputConformsToTheHookSchema's docstring for the session IDs).
# So it is included below as a second, empirically-sourced entry: the
# printed schema is incomplete, not sessionstart.py.
DOCUMENTED_HOOK_SPECIFIC_FIELDS = {
    "PreToolUse": {"hookEventName", "permissionDecision", "permissionDecisionReason", "updatedInput"},
    "UserPromptSubmit": {"hookEventName", "additionalContext"},
    "PostToolUse": {"hookEventName", "additionalContext"},
    "PostToolBatch": {"hookEventName", "additionalContext"},
    "Stop": {"hookEventName", "additionalContext"},
    "SubagentStop": {"hookEventName", "additionalContext"},
    "SessionStart": {"hookEventName", "additionalContext"},  # empirical, see above
}

# Generic top-level fields Claude Code accepts alongside hookSpecificOutput
# on any hook event, per the same printed schema dump.
TOP_LEVEL_OPTIONAL_FIELDS = {
    "continue", "suppressOutput", "stopReason", "decision",
    "reason", "systemMessage", "terminalSequence", "permissionDecision",
}

# The two real /goal transcript records, measured 2026-08-09 against Claude
# Code 2.1.226 in this vault's own transcript
# (906c8782-6d30-40a3-ad4a-b47daa18a65e.jsonl), records 1483 and 1512
# respectively, read back verbatim from the raw file and trimmed only of
# envelope fields (parentUuid, uuid, timestamp, sessionId, cwd, version,
# gitBranch, slug, userType, entrypoint) that goal_is_active never reads.
# See _common._goal_state's comment for the full account of what each field
# means and what is and is not confirmed.
GOAL_SET_RECORD = {
    "type": "attachment",
    "attachment": {
        "type": "goal_status",
        "met": False,
        "sentinel": True,
        "condition": (
            "the file /tmp/claude-1000/-home-alice-Notes-"
            "Vault/906c8782-6d30-40a3-ad4a-b47daa18a65e/scratchpad/"
            "goal-probe-ALREADY-TRUE.txt exists"
        ),
    },
}

GOAL_MET_RECORD = {
    "type": "attachment",
    "attachment": {
        "type": "goal_status",
        "met": True,
        "condition": (
            "the file /tmp/claude-1000/-home-alice-Notes-"
            "Vault/906c8782-6d30-40a3-ad4a-b47daa18a65e/scratchpad/"
            "goal-probe-ALREADY-TRUE.txt exists"
        ),
        "reason": (
            "The file exists, confirmed by direct filesystem check in the "
            "transcript: `ls -la .../goal-probe-ALREADY-TRUE.txt` returned "
            "`-rw-r--r--. 1 alice alice 0 Aug  9 09:48`, and the "
            "assistant stated explicitly: `CONDITION HOLDS: the file exists`"
        ),
        "iterations": 1,
        "durationMs": 80894,
        "tokens": 4076,
    },
}


def assert_conforms_to_hook_schema(result: dict, testcase: unittest.TestCase) -> None:
    """Fail loudly if `result` is not something Claude Code documents (or, for
    SessionStart, has been empirically confirmed to) accept as hook output.

    Exists so a future adapter emitting an unsupported shape fails a test
    instead of shipping silently broken, the way precompact.py's PreCompact
    envelope did for an entire build (finding C1).
    """
    testcase.assertIsInstance(result, dict)
    top_level_unexpected = set(result.keys()) - {"hookSpecificOutput"} - TOP_LEVEL_OPTIONAL_FIELDS
    testcase.assertFalse(top_level_unexpected, f"unexpected top-level keys: {top_level_unexpected}")

    inner = result.get("hookSpecificOutput")
    if inner is None:
        return  # no hookSpecificOutput at all conforms trivially (e.g. a bare {"continue": false})
    testcase.assertIsInstance(inner, dict)
    event = inner.get("hookEventName")
    testcase.assertIn(
        event, DOCUMENTED_HOOK_SPECIFIC_FIELDS,
        f"{event!r} has no documented or empirically confirmed hookSpecificOutput shape",
    )
    allowed = DOCUMENTED_HOOK_SPECIFIC_FIELDS[event]
    unexpected = set(inner.keys()) - allowed
    testcase.assertFalse(unexpected, f"unexpected keys in hookSpecificOutput for {event}: {unexpected}")


class TestUsage(unittest.TestCase):
    def test_sums_the_three_input_fields_of_the_last_assistant_entry(self):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as fh:
            fh.write(json.dumps({"type": "user", "message": {"role": "user"}}) + "\n")
            fh.write(json.dumps({"type": "assistant", "message": {"usage": {
                "input_tokens": 2, "cache_creation_input_tokens": 4280,
                "cache_read_input_tokens": 217741}}}) + "\n")
            path = fh.name
        self.addCleanup(os.unlink, path)
        self.assertEqual(_common.last_usage_tokens(path), 222023)

    def test_missing_file_gives_none_rather_than_raising(self):
        self.assertIsNone(_common.last_usage_tokens("/nonexistent/transcript.jsonl"))

    def test_garbage_lines_are_skipped(self):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as fh:
            fh.write("not json\n")
            fh.write(json.dumps({"type": "assistant", "message": {"usage": {"input_tokens": 5}}}) + "\n")
            fh.write("also not json\n")
            path = fh.name
        self.addCleanup(os.unlink, path)
        self.assertEqual(_common.last_usage_tokens(path), 5)

    def test_a_later_non_assistant_record_does_not_win_over_an_earlier_assistant_one(self):
        # Reproduced: a real assistant entry at 100 tokens followed by a later
        # non-assistant record that happens to carry a top-level "usage" key
        # must not be mistaken for the current context size.
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as fh:
            fh.write(json.dumps({"type": "assistant", "message": {"usage": {"input_tokens": 100}}}) + "\n")
            fh.write(json.dumps({"type": "system", "usage": {"input_tokens": 999999}}) + "\n")
            path = fh.name
        self.addCleanup(os.unlink, path)
        self.assertEqual(_common.last_usage_tokens(path), 100)


class TestGoalIsActive(unittest.TestCase):
    """B3. The shape /goal writes was measured 2026-08-09 against a real run
    on Claude Code 2.1.226 (see GOAL_SET_RECORD and GOAL_MET_RECORD above
    for the two real records this measurement produced, and
    _common._goal_state's comment for the full account). Replaces an
    earlier version of this class that encoded a guess: five top-level key
    names read from strings in the installed binary, none of which turned
    out to exist on a real record."""

    def _transcript(self, *records: dict) -> str:
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as fh:
            for record in records:
                fh.write(json.dumps(record) + "\n")
            path = fh.name
        self.addCleanup(os.unlink, path)
        return path

    def test_set_record_alone_reads_as_active(self):
        self.assertTrue(_common.goal_is_active(self._transcript(GOAL_SET_RECORD)))

    def test_met_record_alone_reads_as_not_active(self):
        self.assertFalse(_common.goal_is_active(self._transcript(GOAL_MET_RECORD)))

    def test_met_record_newer_than_set_record_reads_as_not_active(self):
        path = self._transcript(GOAL_SET_RECORD, GOAL_MET_RECORD)
        self.assertFalse(_common.goal_is_active(path))

    def test_set_record_newer_than_met_record_reads_as_active(self):
        # What a second /goal in the same session looks like: an earlier
        # goal already ran to completion (met), and a fresh one was set
        # after it. The newer record has to win.
        path = self._transcript(GOAL_MET_RECORD, GOAL_SET_RECORD)
        self.assertTrue(_common.goal_is_active(path))

    def test_no_goal_records_reads_as_not_active(self):
        path = self._transcript(
            {"type": "assistant", "message": {"usage": {"input_tokens": 5}}},
            {"type": "user", "message": {"role": "user"}},
        )
        self.assertFalse(_common.goal_is_active(path))

    def test_unreadable_path_reads_as_not_active(self):
        self.assertFalse(_common.goal_is_active("/nonexistent/transcript.jsonl"))

    def test_unrelated_attachment_type_alone_reads_as_not_active(self):
        # A real record shape from the same transcript (line 1478): an
        # attachment whose type is something other than goal_status. Must
        # not be misread as decisive in either direction.
        reminder = {"type": "attachment", "attachment": {
            "type": "total_tokens_reminder", "text": "<total_tokens>1 left</total_tokens>"}}
        self.assertFalse(_common.goal_is_active(self._transcript(reminder)))

    def test_unrelated_attachment_type_does_not_shadow_an_older_set_record(self):
        # The reminder attachment is newer (later in the file) than the real
        # goal_status record. If it were misread as decisive instead of
        # skipped, this would return the wrong answer.
        reminder = {"type": "attachment", "attachment": {
            "type": "total_tokens_reminder", "text": "<total_tokens>1 left</total_tokens>"}}
        path = self._transcript(GOAL_SET_RECORD, reminder)
        self.assertTrue(_common.goal_is_active(path))

    def test_goal_state_reads_the_set_shape_directly(self):
        self.assertIs(_common._goal_state(GOAL_SET_RECORD), True)

    def test_goal_state_reads_the_met_shape_directly(self):
        self.assertIs(_common._goal_state(GOAL_MET_RECORD), False)

    def test_goal_state_returns_none_for_a_record_with_no_attachment(self):
        self.assertIsNone(_common._goal_state({"type": "assistant"}))

    def test_goal_state_returns_none_when_met_is_missing_or_not_boolean(self):
        self.assertIsNone(_common._goal_state(
            {"type": "attachment", "attachment": {"type": "goal_status"}}))
        self.assertIsNone(_common._goal_state(
            {"type": "attachment", "attachment": {"type": "goal_status", "met": "false"}}))


class TestAdaptersNeverFail(unittest.TestCase):
    """The one non-negotiable property: a hook must not break a session."""

    def setUp(self):
        # Point the adapters at a throwaway state root. Without this the tests
        # write stamps into the real ~/.local/state/agent-handoff.
        self._tmp = tempfile.TemporaryDirectory()
        self.env = subprocess_env(HANDOFF_STATE_ROOT=str(Path(self._tmp.name) / "state"))
        self.addCleanup(self._tmp.cleanup)

    def drive(self, script, payload):
        return subprocess.run(
            [sys.executable, str(ADAPTERS / script)],
            input=json.dumps(payload), capture_output=True, text=True, env=self.env,
        )

    def test_every_adapter_exits_zero_on_garbage_input(self):
        for script in ("stop.py", "precompact.py", "sessionstart.py"):
            with self.subTest(script=script):
                done = subprocess.run([sys.executable, str(ADAPTERS / script)],
                                      input="}{ not json", capture_output=True,
                                      text=True, env=self.env)
                self.assertEqual(done.returncode, 0, done.stderr)

    def test_every_adapter_exits_zero_on_an_empty_payload(self):
        for script in ("stop.py", "precompact.py", "sessionstart.py"):
            with self.subTest(script=script):
                self.assertEqual(self.drive(script, {}).returncode, 0)

    def test_stop_is_silent_below_the_threshold(self):
        with tempfile.TemporaryDirectory() as tmp:
            transcript = Path(tmp) / "t.jsonl"
            transcript.write_text(json.dumps(
                {"type": "assistant", "message": {"usage": {"input_tokens": 1000}}}) + "\n")
            done = self.drive("stop.py", {
                "session_id": "s1", "cwd": tmp, "transcript_path": str(transcript)})
            self.assertEqual(done.returncode, 0)
            self.assertEqual(done.stdout.strip(), "")


class TestKillSwitch(unittest.TestCase):
    """B2: HANDOFF_DISABLED=1 silences all three adapters. The check lives
    once in _common.run, so none of the three can drift from the others, and
    it gives the user a way to turn the whole skill off for a session without
    touching settings.json or unstowing anything."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        os.environ["HANDOFF_STATE_ROOT"] = str(Path(self._tmp.name) / "state")
        self.addCleanup(self._tmp.cleanup)
        self.addCleanup(os.environ.pop, "HANDOFF_STATE_ROOT", None)
        self.repo = str(Path(self._tmp.name) / "repo")
        os.makedirs(self.repo)

    def drive(self, script, payload, disabled, extra=None):
        return subprocess.run(
            [sys.executable, str(ADAPTERS / script)],
            input=json.dumps(payload), capture_output=True, text=True,
            env=subprocess_env(disabled=disabled, **(extra or {})),
        )

    def test_stop_produces_no_nudge_when_disabled(self):
        transcript = Path(self._tmp.name) / "t.jsonl"
        transcript.write_text(json.dumps(
            {"type": "assistant", "message": {"usage": {"input_tokens": 999_999}}}) + "\n")
        payload = {"session_id": "s1", "cwd": self.repo, "transcript_path": str(transcript)}
        # Prove the fixture would fire without the switch, so the disabled
        # assertion below is actually proving something.
        self.assertNotEqual(self.drive("stop.py", payload, disabled=False).stdout.strip(), "")
        # The baseline call above stamped a high-water mark that would silence
        # a second call on its own; reset it so the disabled call starts from
        # the same state the baseline one did, and any silence it produces is
        # actually attributable to the switch.
        _common.hs.write_stamp(self.repo, "s1", {})
        done = self.drive("stop.py", payload, disabled=True)
        self.assertEqual(done.returncode, 0)
        self.assertEqual(done.stdout.strip(), "")

    def test_precompact_emits_nothing_and_writes_no_stamp_when_disabled(self):
        payload = {"session_id": "s1", "cwd": self.repo}
        # Prove the fixture would touch the stamp without the switch, so the
        # disabled assertion below is actually proving something. precompact.py
        # never writes to stdout regardless of the switch now (there is no
        # supported channel for it to use, see its docstring), so the stamp
        # write is what HANDOFF_DISABLED actually has to suppress here.
        self.drive("precompact.py", payload, disabled=False)
        self.assertEqual(_common.hs.read_stamp(self.repo, "s1"), {"last_fired": 0})
        # Reset before the real assertion so it only reflects the disabled call.
        _common.hs.write_stamp(self.repo, "s1", {"last_fired": 999})
        done = self.drive("precompact.py", payload, disabled=True)
        self.assertEqual(done.returncode, 0)
        self.assertEqual(done.stdout.strip(), "")
        self.assertEqual(_common.hs.read_stamp(self.repo, "s1"), {"last_fired": 999})

    def test_sessionstart_emits_nothing_when_disabled(self):
        # sessionstart renders the board now, not a local file, so the fixture
        # has to reach one or the baseline below silently stops proving
        # anything and the disabled assertion passes against a hook that was
        # never going to speak. An unreachable gateway is the cheapest fixture
        # that still makes it speak: it emits the explicit unreachable notice.
        cfg = Path(self._tmp.name) / "projects.json"
        cfg.write_text(json.dumps({"workspaces": {"personal": {
            "default": True, "projects": {"AGENT": {
                "id": "u-agent", "name": "Agents", "dirs": [self.repo]}}}}}))
        extra = {"HANDOFF_PROJECTS": str(cfg), "PLANE_API_TOKEN": "test-token",
                 "PLANE_MCP_URL": "http://127.0.0.1:1/unreachable"}
        payload = {"session_id": "s1", "cwd": self.repo, "source": "startup"}
        self.assertNotEqual(
            self.drive("sessionstart.py", payload, disabled=False,
                       extra=extra).stdout.strip(), "")
        done = self.drive("sessionstart.py", payload, disabled=True, extra=extra)
        self.assertEqual(done.returncode, 0)
        self.assertEqual(done.stdout.strip(), "")


class TestStopHonorsStopHookActive(unittest.TestCase):
    """B1: the harness's documented contract for Stop/SubagentStop hooks is to
    check stop_hook_active and return success while it is true. This covers
    /goal, agents, and skills alike, since all of them keep a session running
    through repeated Stop hook firings."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        os.environ["HANDOFF_STATE_ROOT"] = str(Path(self._tmp.name) / "state")
        self.addCleanup(self._tmp.cleanup)
        self.addCleanup(os.environ.pop, "HANDOFF_STATE_ROOT", None)
        self.repo = str(Path(self._tmp.name) / "repo")
        os.makedirs(self.repo)

    def drive(self, payload):
        return subprocess.run(
            [sys.executable, str(ADAPTERS / "stop.py")],
            input=json.dumps(payload), capture_output=True, text=True, env=subprocess_env(),
        )

    def test_no_nudge_and_no_stamp_change_even_far_past_the_hard_threshold(self):
        transcript = Path(self._tmp.name) / "t.jsonl"
        transcript.write_text(json.dumps(
            {"type": "assistant", "message": {"usage": {"input_tokens": 999_999}}}) + "\n")
        _common.hs.write_stamp(self.repo, "s1", {"last_fired": 250_000})

        done = self.drive({
            "session_id": "s1", "cwd": self.repo, "transcript_path": str(transcript),
            "stop_hook_active": True,
        })

        self.assertEqual(done.returncode, 0)
        self.assertEqual(done.stdout.strip(), "")
        # The high-water mark must be untouched, not merely "not raised
        # further": a suppressed turn must not be the one that consumes the
        # threshold crossing, or the nudge would never fire once the loop ends.
        self.assertEqual(_common.hs.read_stamp(self.repo, "s1"), {"last_fired": 250_000})


class TestStopStandsDownForActiveGoal(unittest.TestCase):
    """B3: while a /goal run is in progress, stop.py must behave exactly as
    if this skill were absent, the same as it does for stop_hook_active."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        os.environ["HANDOFF_STATE_ROOT"] = str(Path(self._tmp.name) / "state")
        self.addCleanup(self._tmp.cleanup)
        self.addCleanup(os.environ.pop, "HANDOFF_STATE_ROOT", None)
        self.repo = str(Path(self._tmp.name) / "repo")
        os.makedirs(self.repo)

    def drive(self, payload):
        return subprocess.run(
            [sys.executable, str(ADAPTERS / "stop.py")],
            input=json.dumps(payload), capture_output=True, text=True, env=subprocess_env(),
        )

    def test_no_nudge_past_the_hard_threshold_while_a_goal_is_active(self):
        transcript = Path(self._tmp.name) / "t.jsonl"
        with transcript.open("w", encoding="utf-8") as fh:
            fh.write(json.dumps(
                {"type": "assistant", "message": {"usage": {"input_tokens": 999_999}}}) + "\n")
            fh.write(json.dumps(GOAL_SET_RECORD) + "\n")
        _common.hs.write_stamp(self.repo, "s1", {"last_fired": 250_000})

        done = self.drive({
            "session_id": "s1", "cwd": self.repo, "transcript_path": str(transcript),
        })

        self.assertEqual(done.returncode, 0)
        self.assertEqual(done.stdout.strip(), "")
        self.assertEqual(_common.hs.read_stamp(self.repo, "s1"), {"last_fired": 250_000})


class TestPrecompactStandsDownForActiveGoal(unittest.TestCase):
    """B3, amended by the final whole-branch review (finding I2): a
    compaction that lands during a /goal run must not overwrite the summary,
    but the high-water mark reset is unconditional and must still happen.
    The hook is advisory only: the harness's own compaction proceeds
    regardless of what this hook returns, so context drops to near zero
    whether or not the goal check fires. The old behavior skipped the reset
    on this branch, leaving the mark stale against a context that had
    already dropped, the fire-once-then-silent-forever shape the reset
    exists to prevent, surviving in the one branch that skipped it."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        os.environ["HANDOFF_STATE_ROOT"] = str(Path(self._tmp.name) / "state")
        self.addCleanup(self._tmp.cleanup)
        self.addCleanup(os.environ.pop, "HANDOFF_STATE_ROOT", None)
        self.repo = str(Path(self._tmp.name) / "repo")
        os.makedirs(self.repo)

    def drive(self, payload):
        return subprocess.run(
            [sys.executable, str(ADAPTERS / "precompact.py")],
            input=json.dumps(payload), capture_output=True, text=True, env=subprocess_env(),
        )

    def test_no_compaction_instructions_while_a_goal_is_active(self):
        transcript = Path(self._tmp.name) / "t.jsonl"
        transcript.write_text(json.dumps(GOAL_SET_RECORD) + "\n")

        done = self.drive({
            "session_id": "s1", "cwd": self.repo, "transcript_path": str(transcript),
        })

        self.assertEqual(done.returncode, 0)
        self.assertEqual(done.stdout.strip(), "")

    def test_the_stamp_still_resets_while_a_goal_is_active(self):
        # Start from a real high-water mark, not an absent stamp, so the
        # assertion below proves the reset actually fired rather than merely
        # observing an untouched, still-empty file.
        transcript = Path(self._tmp.name) / "t.jsonl"
        transcript.write_text(json.dumps(GOAL_SET_RECORD) + "\n")
        _common.hs.write_stamp(self.repo, "s1", {"last_fired": 250_000})

        done = self.drive({
            "session_id": "s1", "cwd": self.repo, "transcript_path": str(transcript),
        })

        self.assertEqual(done.returncode, 0)
        self.assertEqual(_common.hs.read_stamp(self.repo, "s1"), {"last_fired": 0})


class TestPrecompactStopsEmittingInvalidJson(unittest.TestCase):
    """Claude Code has no PreCompact variant of hookSpecificOutput. Measured
    2026-08-08 against a real compaction: emitting one failed every time with
    "Hook JSON output validation failed - (root): Invalid input", and the
    harness's own printed schema lists variants only for PreToolUse,
    UserPromptSubmit, PostToolUse, PostToolBatch, and Stop/SubagentStop. So
    this hook must default to complete silence, while still resetting the
    high-water mark that a compaction always invalidates."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        os.environ["HANDOFF_STATE_ROOT"] = str(Path(self._tmp.name) / "state")
        self.addCleanup(self._tmp.cleanup)
        self.addCleanup(os.environ.pop, "HANDOFF_STATE_ROOT", None)
        self.repo = str(Path(self._tmp.name) / "repo")
        os.makedirs(self.repo)

    def drive(self, payload, extra_env=None):
        env = subprocess_env(**(extra_env or {}))
        return subprocess.run(
            [sys.executable, str(ADAPTERS / "precompact.py")],
            input=json.dumps(payload), capture_output=True, text=True, env=env,
        )

    def write_current(self):
        current = _common.hs.paths(self.repo)["current"]
        current.parent.mkdir(parents=True, exist_ok=True)
        updated = datetime.now().strftime("%Y-%m-%dT%H:%M")
        current.write_text(
            f"---\ngoal: resume this\nupdated: {updated}\n---\n\n"
            "## Next steps\n1. Keep going.\n\n## Resume checks\ntrue\n",
            encoding="utf-8",
        )

    def test_no_stdout_by_default_with_a_handoff_present(self):
        self.write_current()
        done = self.drive({"session_id": "s1", "cwd": self.repo})
        self.assertEqual(done.returncode, 0)
        self.assertEqual(done.stdout, "")

    def test_no_stdout_by_default_without_a_handoff(self):
        done = self.drive({"session_id": "s1", "cwd": self.repo})
        self.assertEqual(done.returncode, 0)
        self.assertEqual(done.stdout, "")

    def test_last_fired_still_resets_to_zero(self):
        _common.hs.write_stamp(self.repo, "s1", {"last_fired": 250_000})
        self.drive({"session_id": "s1", "cwd": self.repo})
        self.assertEqual(_common.hs.read_stamp(self.repo, "s1").get("last_fired"), 0)

    def test_precompacted_is_never_written(self):
        _common.hs.write_stamp(self.repo, "s1", {"last_fired": 250_000})
        self.drive({"session_id": "s1", "cwd": self.repo})
        self.assertNotIn("precompacted", _common.hs.read_stamp(self.repo, "s1"))

    def test_raw_env_var_still_writes_instructions_to_stdout(self):
        # Untested but harmless, so it stays available: HANDOFF_PRECOMPACT_RAW=1
        # is not the default, and this is the one path that still writes text.
        done = self.drive({"session_id": "s1", "cwd": self.repo},
                           extra_env={"HANDOFF_PRECOMPACT_RAW": "1"})
        self.assertEqual(done.returncode, 0)
        # Text updated with Task 9: precompact names the active stream now, and
        # with none claimed it says so. The property this test guards is
        # unchanged, that the raw path is the one path still writing text.
        self.assertIn("No stream is claimed", done.stdout)


class TestAdapterOutputConformsToTheHookSchema(unittest.TestCase):
    """Fix 3: nothing previously asserted that an adapter's emitted JSON
    actually matches what Claude Code accepts. That is the gap that let
    precompact.py's PreCompact envelope ship and fail silently on every real
    compaction (finding C1): "Hook JSON output validation failed - (root):
    Invalid input", undetected for an entire build because nothing checked.

    DOCUMENTED_HOOK_SPECIFIC_FIELDS below is Claude Code's own printed
    validation-error schema dump, captured 2026-08-08 against a real
    compaction (see precompact.py's docstring for the verbatim failure): it
    lists hookSpecificOutput fields only for PreToolUse, UserPromptSubmit,
    PostToolUse, PostToolBatch, and Stop/SubagentStop. There is no PreCompact
    entry, confirmed rejected outright.

    There is also no SessionStart entry in that dump, but SessionStart
    injection is confirmed working in production, independent of anything
    this build wrote: real hook_success + hook_additional_context attachment
    pairs, exit code 0, the additionalContext text actually delivered into
    the session, across four separate real sessions in the transcript
    history (session d3d471cf in this vault, source "clear"; session
    ff5fcfca and f0d0027c in another repository, both "clear"/"startup"; and
    session 8877ebd3 in this vault, source "startup", pointer mode) spanning
    three different repos and both pointer and full injection modes. So the
    printed schema is incomplete, not sessionstart.py: SessionStart is
    included below as a second, empirically-sourced entry rather than from
    Claude Code's own dump."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        os.environ["HANDOFF_STATE_ROOT"] = str(Path(self._tmp.name) / "state")
        self.addCleanup(self._tmp.cleanup)
        self.addCleanup(os.environ.pop, "HANDOFF_STATE_ROOT", None)
        self.repo = str(Path(self._tmp.name) / "repo")
        os.makedirs(self.repo)

    def drive(self, script, payload, env=None):
        return subprocess.run(
            [sys.executable, str(ADAPTERS / script)],
            input=json.dumps(payload), capture_output=True, text=True,
            env=env or subprocess_env(),
        )

    def test_the_validator_rejects_the_known_bad_precompact_shape(self):
        # Reproduces finding C1 as a unit test on the validator itself: this
        # exact envelope is what the earlier build emitted for PreCompact,
        # and what Claude Code rejected on every real compaction.
        bad = {"hookSpecificOutput": {"hookEventName": "PreCompact", "additionalContext": "x"}}
        with self.assertRaises(AssertionError):
            assert_conforms_to_hook_schema(bad, self)

    def test_the_validator_rejects_an_unexpected_field_on_a_known_event(self):
        # Defense in depth for a future adapter change: a field Claude Code
        # never documented for Stop must fail loudly, not ship silently.
        bad = {"hookSpecificOutput": {
            "hookEventName": "Stop", "additionalContext": "x", "mystery": True}}
        with self.assertRaises(AssertionError):
            assert_conforms_to_hook_schema(bad, self)

    def test_the_validator_accepts_a_known_good_stop_shape(self):
        good = {"hookSpecificOutput": {"hookEventName": "Stop", "additionalContext": "x"}}
        assert_conforms_to_hook_schema(good, self)  # must not raise

    def test_stop_output_conforms(self):
        transcript = Path(self._tmp.name) / "t.jsonl"
        transcript.write_text(json.dumps(
            {"type": "assistant", "message": {"usage": {"input_tokens": 999_999}}}) + "\n")
        done = self.drive("stop.py", {
            "session_id": "s1", "cwd": self.repo, "transcript_path": str(transcript)})
        result = json.loads(done.stdout)
        assert_conforms_to_hook_schema(result, self)
        # stop.py speaks to the user now, so it emits a bare systemMessage and no
        # hookSpecificOutput at all. Asserting the absence is the point: that
        # field is what re-invokes the model.
        self.assertIn("systemMessage", result)
        self.assertNotIn("hookSpecificOutput", result)

    def test_sessionstart_output_conforms(self):
        # sessionstart renders the board now. An unreachable gateway is the
        # cheapest fixture that still makes it emit, and it exercises the
        # branch that must never look like an empty board.
        cfg = Path(self._tmp.name) / "projects.json"
        cfg.write_text(json.dumps({"workspaces": {"personal": {
            "default": True, "projects": {"AGENT": {
                "id": "u-agent", "name": "Agents", "dirs": [self.repo]}}}}}))
        env = subprocess_env(HANDOFF_PROJECTS=str(cfg), PLANE_API_TOKEN="test-token",
                             PLANE_MCP_URL="http://127.0.0.1:1/unreachable")
        done = self.drive("sessionstart.py", {
            "session_id": "s1", "cwd": self.repo, "source": "startup"}, env=env)
        result = json.loads(done.stdout)
        assert_conforms_to_hook_schema(result, self)
        self.assertEqual(result["hookSpecificOutput"]["hookEventName"], "SessionStart")

    def test_precompact_never_emits_a_json_envelope_at_all(self):
        # PreCompact has no documented, or empirically confirmed, shape at
        # all: the only way this hook conforms is by staying silent. See
        # TestPrecompactStopsEmittingInvalidJson for the fuller coverage of
        # that; this test exists so this class states the claim about
        # precompact.py explicitly rather than by omission.
        done = self.drive("precompact.py", {"session_id": "s1", "cwd": self.repo})
        self.assertEqual(done.stdout, "")


class TestStandDownIsRecorded(unittest.TestCase):
    """I4: every quiet path used to leave no trace. precompact.py's own
    invalid-JSON defect (finding C1) survived an entire build looking
    healthy for exactly this reason: nothing recorded that it was firing on
    every compaction. Each stand-down for a reason other than "nothing to
    do" now overwrites one small per-repo record (never an unbounded log),
    so --doctor can answer "is this working" without inferring it from
    silence. A plain verdict of "none" is deliberately not recorded: that is
    the routine, expected outcome on most turns, not a stand-down."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        os.environ["HANDOFF_STATE_ROOT"] = str(Path(self._tmp.name) / "state")
        self.addCleanup(self._tmp.cleanup)
        self.addCleanup(os.environ.pop, "HANDOFF_STATE_ROOT", None)
        self.repo = str(Path(self._tmp.name) / "repo")
        os.makedirs(self.repo)

    def drive(self, script, payload, env=None):
        # subprocess_env pins HANDOFF_DISABLED rather than inheriting it: this
        # class's whole point is telling apart specific stand-down reasons, so
        # it must not be at the mercy of whatever the ambient shell happens to
        # have set (this machine's real shell carries HANDOFF_DISABLED=1 for
        # the duration of this rebuild, which would otherwise make every call
        # here record "disabled" regardless of what is under test).
        if env is None:
            env = subprocess_env()
        return subprocess.run(
            [sys.executable, str(ADAPTERS / script)],
            input=json.dumps(payload), capture_output=True, text=True, env=env,
        )

    def test_stop_records_stop_hook_active(self):
        self.drive("stop.py", {"session_id": "s1", "cwd": self.repo, "stop_hook_active": True})
        got = _common.hs.read_standdown(self.repo)
        self.assertEqual(got["adapter"], "stop")
        self.assertEqual(got["reason"], "stop_hook_active")

    def test_stop_records_missing_transcript(self):
        self.drive("stop.py", {"session_id": "s1", "cwd": self.repo})
        got = _common.hs.read_standdown(self.repo)
        self.assertEqual(got["reason"], "no_transcript")

    def test_stop_records_active_goal(self):
        transcript = Path(self._tmp.name) / "t.jsonl"
        transcript.write_text(json.dumps(GOAL_SET_RECORD) + "\n")
        self.drive("stop.py", {"session_id": "s1", "cwd": self.repo, "transcript_path": str(transcript)})
        got = _common.hs.read_standdown(self.repo)
        self.assertEqual(got["reason"], "goal_active")

    def test_stop_records_no_usage(self):
        transcript = Path(self._tmp.name) / "t.jsonl"
        transcript.write_text(json.dumps({"type": "user", "message": {"role": "user"}}) + "\n")
        self.drive("stop.py", {"session_id": "s1", "cwd": self.repo, "transcript_path": str(transcript)})
        got = _common.hs.read_standdown(self.repo)
        self.assertEqual(got["reason"], "no_usage")

    def test_stop_does_not_record_a_plain_verdict_none(self):
        transcript = Path(self._tmp.name) / "t.jsonl"
        transcript.write_text(json.dumps(
            {"type": "assistant", "message": {"usage": {"input_tokens": 1000}}}) + "\n")
        self.drive("stop.py", {"session_id": "s1", "cwd": self.repo, "transcript_path": str(transcript)})
        self.assertEqual(_common.hs.read_standdown(self.repo), {})

    def test_precompact_records_active_goal(self):
        transcript = Path(self._tmp.name) / "t.jsonl"
        transcript.write_text(json.dumps(GOAL_SET_RECORD) + "\n")
        self.drive("precompact.py", {"session_id": "s1", "cwd": self.repo, "transcript_path": str(transcript)})
        got = _common.hs.read_standdown(self.repo)
        self.assertEqual(got["adapter"], "precompact")
        self.assertEqual(got["reason"], "goal_active")

    def test_disabled_is_recorded_regardless_of_which_adapter(self):
        env = subprocess_env(disabled=True)
        self.drive("sessionstart.py", {"session_id": "s1", "cwd": self.repo}, env=env)
        got = _common.hs.read_standdown(self.repo)
        self.assertEqual(got["adapter"], "sessionstart")
        self.assertEqual(got["reason"], "disabled")

    def test_disabled_with_garbage_input_still_exits_zero(self):
        # The disabled branch does its own best-effort parse (only to recover
        # a cwd for the recording), separate from the handler's normal parse.
        # Garbage stdin must not turn that into a second, un-caught failure.
        env = subprocess_env(disabled=True)
        done = subprocess.run(
            [sys.executable, str(ADAPTERS / "stop.py")],
            input="}{ not valid json", capture_output=True, text=True, env=env,
        )
        self.assertEqual(done.returncode, 0)

    def test_a_later_standdown_overwrites_an_earlier_one(self):
        self.drive("stop.py", {"session_id": "s1", "cwd": self.repo, "stop_hook_active": True})
        self.drive("stop.py", {"session_id": "s1", "cwd": self.repo})
        got = _common.hs.read_standdown(self.repo)
        self.assertEqual(got["reason"], "no_transcript")


class TestStandDownForProjectOwnership(unittest.TestCase):
    """Design spec 2026-08-23-plane-integration-design.md §5.2/§7, first
    direction: a repo carrying `.claude/handoff.json` with
    `{"owner": "project"}` writes its own handoff elsewhere, so every global
    adapter must stand down before any of its own logic runs -- not merely
    end up emitting nothing, but never touch the stamp or read a transcript
    either -- and record it through the same record_standdown every other
    stand-down reason already uses."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        os.environ["HANDOFF_STATE_ROOT"] = str(Path(self._tmp.name) / "state")
        self.addCleanup(self._tmp.cleanup)
        self.addCleanup(os.environ.pop, "HANDOFF_STATE_ROOT", None)
        self.repo = str(Path(self._tmp.name) / "repo")
        os.makedirs(self.repo)
        claude_dir = Path(self.repo) / ".claude"
        claude_dir.mkdir()
        (claude_dir / "handoff.json").write_text('{"owner": "project"}', encoding="utf-8")

    def drive(self, script, payload, env=None):
        if env is None:
            env = subprocess_env()
        return subprocess.run(
            [sys.executable, str(ADAPTERS / script)],
            input=json.dumps(payload), capture_output=True, text=True, env=env,
        )

    def test_sessionstart_stands_down_instead_of_injecting_a_fresh_handoff(self):
        # A fresh handoff on a continuation source would normally earn the
        # full injection (TestSessionStartFreshnessGate). The marker must
        # override that, not merely coincide with there being nothing to do.
        current = _common.hs.paths(self.repo)["current"]
        current.parent.mkdir(parents=True, exist_ok=True)
        recent = datetime.now().strftime("%Y-%m-%dT%H:%M")
        current.write_text(
            f"---\ngoal: unrelated work\nupdated: {recent}\n---\n\n"
            "## Next steps\n1. go\n\n## Resume checks\ntrue\n", encoding="utf-8")

        done = self.drive("sessionstart.py", {"session_id": "s1", "cwd": self.repo, "source": "compact"})

        self.assertEqual(done.returncode, 0)
        self.assertEqual(done.stdout.strip(), "")
        got = _common.hs.read_standdown(self.repo)
        self.assertEqual(got["adapter"], "sessionstart")
        self.assertEqual(got["reason"], "project_owned")

    def test_stop_stands_down_before_touching_the_stamp(self):
        # Tokens far past HARD_DEFAULT would normally fire the hard nudge and
        # rewrite the stamp (last_fired, nudged_at, resumed). Asserting the
        # stamp is untouched proves the check runs before verdict() is ever
        # consulted, not just that no nudge text happened to reach stdout.
        _common.hs.write_stamp(self.repo, "s1", {"last_fired": 50_000})
        transcript = Path(self._tmp.name) / "t.jsonl"
        transcript.write_text(json.dumps(
            {"type": "assistant", "message": {"usage": {"input_tokens": 999_999}}}) + "\n")

        done = self.drive("stop.py", {
            "session_id": "s1", "cwd": self.repo, "transcript_path": str(transcript),
        })

        self.assertEqual(done.returncode, 0)
        self.assertEqual(done.stdout.strip(), "")
        self.assertEqual(_common.hs.read_stamp(self.repo, "s1"), {"last_fired": 50_000})
        got = _common.hs.read_standdown(self.repo)
        self.assertEqual(got["adapter"], "stop")
        self.assertEqual(got["reason"], "project_owned")

    def test_precompact_stands_down_before_the_otherwise_unconditional_reset(self):
        # precompact.py's own reset is documented as unconditional -- it runs
        # even on the goal_active branch -- specifically so the mark never
        # goes stale. The ownership check must still pre-empt it completely:
        # a project-owned repo manages its own thresholds elsewhere, so this
        # adapter's reset would just be a second, uncoordinated writer of the
        # same stamp file.
        _common.hs.write_stamp(self.repo, "s1", {"last_fired": 250_000})

        done = self.drive("precompact.py", {"session_id": "s1", "cwd": self.repo})

        self.assertEqual(done.returncode, 0)
        self.assertEqual(_common.hs.read_stamp(self.repo, "s1"), {"last_fired": 250_000})
        got = _common.hs.read_standdown(self.repo)
        self.assertEqual(got["adapter"], "precompact")
        self.assertEqual(got["reason"], "project_owned")


class TestBehaviorIsUnchangedWithoutTheOwnershipMarker(unittest.TestCase):
    """Design spec 2026-08-23-plane-integration-design.md §7, second
    direction: marker absent means behavior is byte-identical to today.
    Exercises one representative, otherwise-firing branch per adapter with
    no `.claude/handoff.json` anywhere and asserts the ordinary, pre-existing
    result still happens exactly as before -- the regression this guards
    against is the project_owned check wired backwards (e.g.
    `if not hs.project_owned(...)`), which would stand every project down
    instead of none and would otherwise pass every other test in this file
    unnoticed, since none of them carry the marker either."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        os.environ["HANDOFF_STATE_ROOT"] = str(Path(self._tmp.name) / "state")
        self.addCleanup(self._tmp.cleanup)
        self.addCleanup(os.environ.pop, "HANDOFF_STATE_ROOT", None)
        self.repo = str(Path(self._tmp.name) / "repo")
        os.makedirs(self.repo)

    def drive(self, script, payload, env=None):
        if env is None:
            env = subprocess_env()
        return subprocess.run(
            [sys.executable, str(ADAPTERS / script)],
            input=json.dumps(payload), capture_output=True, text=True, env=env,
        )

    def test_sessionstart_still_renders_the_board(self):
        # Was test_sessionstart_still_injects_a_fresh_handoff_in_full. The
        # adapter no longer injects a local handoff, so the old name described
        # behavior that does not exist. The guarantee is unchanged: with no
        # marker present the adapter still acts, which is what catches a
        # project_owned check wired backwards.
        # sessionstart renders the board now. An unreachable gateway is the
        # cheapest fixture that still makes it emit, and it exercises the
        # branch that must never look like an empty board.
        cfg = Path(self._tmp.name) / "projects.json"
        cfg.write_text(json.dumps({"workspaces": {"personal": {
            "default": True, "projects": {"AGENT": {
                "id": "u-agent", "name": "Agents", "dirs": [self.repo]}}}}}))
        env = subprocess_env(HANDOFF_PROJECTS=str(cfg), PLANE_API_TOKEN="test-token",
                             PLANE_MCP_URL="http://127.0.0.1:1/unreachable")

        done = self.drive("sessionstart.py",
                          {"session_id": "s1", "cwd": self.repo, "source": "compact"},
                          env=env)

        self.assertEqual(done.returncode, 0)
        text = json.loads(done.stdout)["hookSpecificOutput"]["additionalContext"]
        self.assertIn("AGENT", text)
        self.assertEqual(_common.hs.read_standdown(self.repo), {})

    def test_stop_still_fires_the_hard_nudge_past_the_hard_threshold(self):
        transcript = Path(self._tmp.name) / "t.jsonl"
        transcript.write_text(json.dumps(
            {"type": "assistant", "message": {"usage": {"input_tokens": 999_999}}}) + "\n")

        done = self.drive("stop.py", {
            "session_id": "s1", "cwd": self.repo, "transcript_path": str(transcript),
        })

        self.assertEqual(done.returncode, 0)
        text = json.loads(done.stdout)["systemMessage"]
        self.assertIn("Context at 999,999 tokens", text)
        self.assertIn("Suggest:", text)
        self.assertEqual(_common.hs.read_standdown(self.repo), {})

    def test_precompact_still_resets_the_high_water_mark_unconditionally(self):
        _common.hs.write_stamp(self.repo, "s1", {"last_fired": 250_000})

        done = self.drive("precompact.py", {"session_id": "s1", "cwd": self.repo})

        self.assertEqual(done.returncode, 0)
        self.assertEqual(_common.hs.read_stamp(self.repo, "s1"), {"last_fired": 0})
        self.assertEqual(_common.hs.read_standdown(self.repo), {})


class TestStopRemindsTheUserAndDoesNotReInvokeTheModel(unittest.TestCase):
    """Writing is manual now. The threshold tells the user, and the turn ends.

    The property under test is the absence of additionalContext, because that
    field is what re-invokes the model, and re-invoking it is precisely what
    "only when I say so" rules out.

    Since the advisor, the soft band speaks only at a natural break, so the
    fixtures that mean to reach it end their turn on a commit.
    """

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.env = subprocess_env(
            HANDOFF_STATE_ROOT=str(Path(self._tmp.name) / "state"))
        self.repo = str(Path(self._tmp.name) / "repo")
        os.makedirs(self.repo)

    def drive(self, tokens, session="s1", commit=False):
        transcript = Path(self._tmp.name) / f"{session}.jsonl"
        records = [{"type": "user", "message": {"role": "user", "content": "go on"}}]
        if commit:
            records += [
                {"type": "assistant", "message": {"content": [
                    {"type": "tool_use", "id": "t1", "name": "Bash",
                     "input": {"command": 'git commit -m "feat(x): ship it"'}}]}},
                {"type": "user", "message": {"content": [
                    {"type": "tool_result", "tool_use_id": "t1",
                     "content": "[main 1a2b3c4] feat(x): ship it"}]}},
            ]
        records.append({"type": "assistant",
                        "message": {"usage": {"input_tokens": tokens}}})
        transcript.write_text("".join(json.dumps(r) + "\n" for r in records))
        done = subprocess.run(
            [sys.executable, str(ADAPTERS / "stop.py")],
            input=json.dumps({"session_id": session, "cwd": self.repo,
                              "transcript_path": str(transcript)}),
            capture_output=True, text=True, env=self.env)
        return done

    def test_the_soft_threshold_emits_a_system_message(self):
        done = self.drive(250_000, commit=True)
        result = json.loads(done.stdout)
        self.assertIn("systemMessage", result)
        self.assertIn("/compact", result["systemMessage"])

    def test_it_never_emits_additional_context(self):
        for tokens, commit in ((250_000, True), (450_000, False)):
            with self.subTest(tokens=tokens):
                result = json.loads(self.drive(tokens, f"s{tokens}", commit).stdout)
                self.assertNotIn("hookSpecificOutput", result)

    def test_the_output_still_conforms_to_the_hook_schema(self):
        assert_conforms_to_hook_schema(
            json.loads(self.drive(250_000, commit=True).stdout), self)

    def test_the_hard_threshold_names_the_compaction_point(self):
        self.assertIn("487,000", json.loads(self.drive(450_000).stdout)["systemMessage"])

    def test_it_is_silent_below_the_threshold(self):
        self.assertEqual(self.drive(1_000, commit=True).stdout.strip(), "")

    def test_it_fires_once_per_band_rather_than_every_turn(self):
        self.assertNotEqual(self.drive(250_000, commit=True).stdout.strip(), "")
        self.assertEqual(self.drive(255_000, commit=True).stdout.strip(), "")

    def test_the_reminder_names_the_active_stream_when_one_is_set(self):
        # _common.hs is handoff_state; this is the idiom the rest of the file
        # already uses for reaching the brain in-process.
        os.environ["HANDOFF_STATE_ROOT"] = self.env["HANDOFF_STATE_ROOT"]
        self.addCleanup(os.environ.pop, "HANDOFF_STATE_ROOT", None)
        _common.hs.write_pointer("s1", {"identifier": "AGENT-12"})
        self.assertIn("AGENT-12", json.loads(self.drive(450_000).stdout)["systemMessage"])


class _HangingGateway:
    """A gateway that accepts and then never answers.

    The point is to exercise the read budget rather than to assert it. The
    earlier version of the test below pointed at 127.0.0.1:1, which refuses on
    the instant, so it measured a connection being refused and would have
    passed with any budget at all, including one of ten minutes.
    """

    def __enter__(self):
        self._srv = socket.socket()
        self._srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._srv.bind(("127.0.0.1", 0))
        self._srv.listen(16)
        self._held = []
        self._thread = threading.Thread(target=self._accept, daemon=True)
        self._thread.start()
        return f"http://127.0.0.1:{self._srv.getsockname()[1]}/mcp"

    def _accept(self):
        while True:
            try:
                conn, _ = self._srv.accept()
            except OSError:
                return
            self._held.append(conn)     # held open on purpose, never written to

    def __exit__(self, *_exc):
        self._srv.close()
        for conn in self._held:
            try:
                conn.close()
            except OSError:
                pass


class TestSessionStartRendersTheBoard(unittest.TestCase):
    """Four outcomes, and the fourth is the one that matters most: an
    unreachable board and an empty board must never render alike, or a session
    concludes there is no work and invents some."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.repo = str(Path(self._tmp.name) / "repo")
        os.makedirs(self.repo)
        cfg = Path(self._tmp.name) / "projects.json"
        cfg.write_text(json.dumps({"workspaces": {"personal": {
            "default": True, "projects": {"AGENT": {
                "id": "u-agent", "name": "Agents", "dirs": [self.repo]}}}}}))
        self.env = subprocess_env(
            HANDOFF_STATE_ROOT=str(Path(self._tmp.name) / "state"),
            HANDOFF_PROJECTS=str(cfg),
            PLANE_API_TOKEN="test-token",
            PLANE_MCP_URL="http://127.0.0.1:1/unreachable")

    def drive(self, source="startup", env=None):
        return subprocess.run(
            [sys.executable, str(ADAPTERS / "sessionstart.py")],
            input=json.dumps({"session_id": "s1", "cwd": self.repo,
                              "source": source}),
            capture_output=True, text=True, env=env or self.env)

    def test_an_unreachable_board_says_so_in_those_words(self):
        done = self.drive()
        self.assertEqual(done.returncode, 0, done.stderr)
        text = json.loads(done.stdout)["hookSpecificOutput"]["additionalContext"]
        self.assertIn("unreachable", text.lower())

    def test_an_unreachable_board_does_not_render_as_an_empty_one(self):
        text = json.loads(self.drive().stdout)["hookSpecificOutput"]["additionalContext"]
        # Match the empty render's actual sentence, not the looser "no open
        # work". That substring also occurs inside the unreachable message's
        # own warning, "Do not conclude there is no open work", which states
        # the opposite of the thing being guarded against, so the loose needle
        # fails a correct implementation. Asserting both halves is stricter
        # than the original: the empty phrasing absent, the warning present.
        self.assertNotIn("No open work items", text)
        self.assertIn("NOT an empty board", text)

    def test_it_exits_zero_and_applies_the_budget_when_plane_hangs(self):
        with _HangingGateway() as url:
            started = time.monotonic()
            done = self.drive(env=dict(self.env, PLANE_MCP_URL=url))
            elapsed = time.monotonic() - started
        self.assertEqual(done.returncode, 0, done.stderr)
        # Both bounds carry weight. The upper one catches a hook that wedges a
        # session start. The lower one catches a budget that is not reaching
        # the call at all, which is the failure the refused-connection version
        # of this test could not see, because it never waited for anything.
        self.assertGreater(elapsed, plane.TIMEOUT * 0.5,
                           "returned too fast to have waited for the budget")
        self.assertLess(elapsed, plane.TIMEOUT + 4.0,
                        "the hook outran its own budget")

    def test_an_unmapped_directory_emits_nothing(self):
        env = dict(self.env)
        env["HANDOFF_PROJECTS"] = "/nonexistent.json"
        self.assertEqual(self.drive(env=env).stdout.strip(), "")

    def test_the_output_conforms_to_the_hook_schema(self):
        assert_conforms_to_hook_schema(json.loads(self.drive().stdout), self)


class TestPrecompactNamesTheStream(unittest.TestCase):
    """PreCompact cannot steer the compaction summary: hookSpecificOutput has
    no PreCompact variant and every real compaction rejected it. What it can
    still do is reset the stamp, which keeps the next threshold relative to a
    freshly compacted context rather than absolute."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.env = subprocess_env(
            HANDOFF_STATE_ROOT=str(Path(self._tmp.name) / "state"),
            HANDOFF_PRECOMPACT_RAW="1")
        self.repo = str(Path(self._tmp.name) / "repo")
        os.makedirs(self.repo)

    def test_the_raw_text_names_the_active_stream(self):
        os.environ["HANDOFF_STATE_ROOT"] = self.env["HANDOFF_STATE_ROOT"]
        self.addCleanup(os.environ.pop, "HANDOFF_STATE_ROOT", None)
        _common.hs.write_pointer("s1", {"identifier": "AGENT-12"})
        done = subprocess.run(
            [sys.executable, str(ADAPTERS / "precompact.py")],
            input=json.dumps({"session_id": "s1", "cwd": self.repo}),
            capture_output=True, text=True, env=self.env)
        self.assertIn("AGENT-12", done.stdout)

    def test_with_no_stream_it_says_there_is_nothing_to_come_back_to(self):
        done = subprocess.run(
            [sys.executable, str(ADAPTERS / "precompact.py")],
            input=json.dumps({"session_id": "s1", "cwd": self.repo}),
            capture_output=True, text=True, env=self.env)
        self.assertIn("No stream is claimed", done.stdout)

    def test_it_still_emits_no_json_at_all(self):
        env = dict(self.env)
        env.pop("HANDOFF_PRECOMPACT_RAW")
        done = subprocess.run(
            [sys.executable, str(ADAPTERS / "precompact.py")],
            input=json.dumps({"session_id": "s1", "cwd": self.repo}),
            capture_output=True, text=True, env=env)
        self.assertEqual(done.stdout.strip(), "")


class TestTheHookSpendsTheMeasuredBudget(unittest.TestCase):
    """The hook used to declare its own 2.0, one module away from the constant
    the transport defaults to. Both were 2.0, so nothing showed, and raising
    one of them would have moved it while leaving the other where it was."""

    def test_the_hook_does_not_declare_a_budget_of_its_own(self):
        sys.path.insert(0, str(ADAPTERS))
        import sessionstart
        self.assertEqual(sessionstart.TIMEOUT, plane.TIMEOUT)


class TestSessionStartSaysWhatItCouldNotSee(unittest.TestCase):
    """A cap that says nothing reads exactly like a complete board. Worse, the
    open-state filter runs after the fetch, so a truncated read can come back
    with no open items at all while the work is sitting on a later page. That
    renders as "No open work items in this project", which is the same lie the
    unreachable branch exists to prevent."""

    def _render(self, items):
        import plane  # noqa: F401  (kept for symmetry with the fixtures below)
        import sessionstart
        return sessionstart._render(
            {"identifier": "CLIENT", "name": "Client", "workspace": "work"},
            items, {}, None)

    def _items(self, rows, truncated=False, total=None):
        import plane
        got = plane.OpenItems(rows)
        got.truncated = truncated
        got.total = total
        return got

    def test_a_complete_board_carries_no_warning(self):
        text = self._render(self._items(
            [{"name": "Rotate the token", "state_name": "Todo"}], total=1))
        self.assertNotIn("NOT the whole board", text)

    def test_a_truncated_board_says_so_and_names_the_total(self):
        text = self._render(self._items(
            [{"name": "Rotate the token", "state_name": "Todo"}],
            truncated=True, total=640))
        self.assertIn("NOT the whole board", text)
        self.assertIn("640", text)

    def test_a_truncated_read_with_no_open_items_is_not_an_empty_board(self):
        text = self._render(self._items([], truncated=True, total=640))
        self.assertIn("NOT the whole board", text)


class TestSessionStartLooksFurtherOnlyWhenItMust(unittest.TestCase):
    """The sweep costs one read per project, measured at 0.62s and 0.78s against
    the live gateway with six personal projects, and there is no workspace-level
    list to replace it with: that call answers HTTP 404. So it has to stay off
    the normal path and run only in the case that actually misleads, an empty
    local board with no stream claimed."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.repo = str(Path(self._tmp.name) / "repo")
        os.makedirs(self.repo)
        cfg = Path(self._tmp.name) / "projects.json"
        cfg.write_text(json.dumps({"workspaces": {"personal": {
            "default": True, "projects": {
                "VAULT": {"id": "u-vault", "name": "Vault", "dirs": [self.repo]},
                "AGENT": {"id": "u-agent", "name": "Agents", "dirs": []}}}}}))
        for key, value in (("HANDOFF_PROJECTS", str(cfg)),
                           ("HANDOFF_STATE_ROOT", str(Path(self._tmp.name) / "state")),
                           ("PLANE_API_TOKEN", "test-token")):
            os.environ[key] = value
            self.addCleanup(os.environ.pop, key, None)
        import plane
        import sessionstart
        self.plane, self.sessionstart = plane, sessionstart
        self.addCleanup(setattr, plane, "open_items", plane.open_items)
        self.addCleanup(setattr, plane, "open_elsewhere", plane.open_elsewhere)
        self.swept = []
        plane.open_elsewhere = lambda slug, projects, timeout=2.0: (
            self.swept.append(projects) or [{"identifier": "AGENT", "count": 14}])

    def _run(self):
        got = self.sessionstart.handle({"session_id": "s1", "cwd": self.repo,
                                        "source": "startup"})
        return (got or {}).get("hookSpecificOutput", {}).get("additionalContext", "")

    def test_a_populated_board_never_sweeps(self):
        self.plane.open_items = lambda *a, **k: [{"name": "x", "state_name": "Todo"}]
        self._run()
        self.assertEqual(self.swept, [])

    def test_an_empty_board_with_a_stream_already_claimed_never_sweeps(self):
        from _common import hs
        hs.write_pointer("s1", {"identifier": "AGENT-11",
                                           "workspace": "personal",
                                           "project_id": "u-agent",
                                           "parent_id": "p1"})
        self.plane.open_items = lambda *a, **k: []
        self._run()
        self.assertEqual(self.swept, [])

    def test_an_empty_unclaimed_board_names_where_the_open_streams_are(self):
        self.plane.open_items = lambda *a, **k: []
        text = self._run()
        self.assertEqual(len(self.swept), 1)
        self.assertIn("AGENT", text)
        self.assertIn("14", text)


class TestTheReminderIsVisibleWithoutTouchingTheModel(unittest.TestCase):
    """AGENT-18 failed on 2026-08-25, and not on the half anyone worried about.

    The reminder fired at 200k and again at 300k, the model correctly ignored
    both, and the user could not find either line afterwards. A one-line
    systemMessage at the end of a turn is indistinguishable from scrollback in
    a long session. The design proved the line renders, which turns out not to
    be the same question as whether it is seen.

    These tests pin both halves of the fix and, more importantly, the rule the
    fix must not break on its way past.
    """

    def test_the_terminal_reminder_is_more_than_one_line(self):
        import advisor
        step = {"kind": "step", "hint": "commit 1a2b3c4 x", "commit": "x"}
        for level, found in (("soft", step), ("hard", None)):
            with self.subTest(level=level):
                text = advisor.render(level, 1, "", "", found, "compact", 487_000)
                self.assertGreater(len(text.strip().splitlines()), 1)

    def test_the_notification_names_the_token_count_and_the_stream(self):
        import stop
        joined = " ".join(stop.notify_argv("hard", 312000, ", on AGENT-11", "/compact"))
        self.assertIn("312,000", joined)
        self.assertIn("AGENT-11", joined)
        self.assertIn("/compact", joined)

    def test_a_hard_reminder_is_critical_and_a_soft_one_is_not(self):
        import stop
        self.assertIn("critical", stop.notify_argv("hard", 1, "", "/compact"))
        self.assertNotIn("critical", stop.notify_argv("soft", 1, "", "/compact"))

    def test_no_session_bus_means_nothing_is_spawned(self):
        # A cron run, a headless run or an ssh session has no bus, and a hook
        # that shells out anyway costs a process and a stderr line per turn.
        import stop
        saved = os.environ.pop("DBUS_SESSION_BUS_ADDRESS", None)
        if saved is not None:
            self.addCleanup(os.environ.__setitem__,
                            "DBUS_SESSION_BUS_ADDRESS", saved)
        self.addCleanup(setattr, stop.subprocess, "run", stop.subprocess.run)
        stop.subprocess.run = lambda *a, **k: self.fail("spawned with no bus")
        self.assertIsNone(stop.notify("hard", 1, "", "/compact"))

    def test_a_notification_that_fails_never_reaches_the_caller(self):
        # A hook must never break a session, and a missing notify-send or a
        # dead daemon is not a reason to lose the reminder itself.
        import stop
        os.environ.setdefault("DBUS_SESSION_BUS_ADDRESS", "unix:path=/nonexistent")
        self.addCleanup(setattr, stop.subprocess, "run", stop.subprocess.run)

        def boom(*a, **k):
            raise OSError("notify-send is not installed")
        stop.subprocess.run = boom
        self.assertIsNone(stop.notify("hard", 1, "", "/compact"))


class TestTheSuiteCannotPopNotifications(unittest.TestCase):
    """Running the tests must not put anything on the user's screen.

    Found on 2026-08-25 by the fix that caused it. The moment stop.py learned
    to notify, the soft-threshold tests began firing real desktop
    notifications, two per run: they drive stop.py as a subprocess, the child
    inherited the session bus, and 250,000 tokens crosses the soft threshold.
    dunst's own history is what gave it away, holding two notifications nobody
    had asked for.

    Same shape as the HANDOFF_DISABLED problem this module was written for, so
    it belongs in the same place rather than in one test's setUp: any driven
    adapter can notify, not only the one that does today.
    """

    def test_a_driven_process_is_handed_no_session_bus(self):
        self.assertEqual(subprocess_env().get("DBUS_SESSION_BUS_ADDRESS"), "")

    def test_a_test_that_means_to_set_a_bus_still_can(self):
        env = subprocess_env(DBUS_SESSION_BUS_ADDRESS="unix:path=/deliberate")
        self.assertEqual(env["DBUS_SESSION_BUS_ADDRESS"], "unix:path=/deliberate")


class TestAClearedSessionIsAFreshStartThatDoesNotLie(unittest.TestCase):
    """AGENT-25's second half, and it is a different defect from its first.

    `/clear` mints a NEW session id, so the pointer written by the session
    before it is never found. Verified 2026-08-25: the cleared session was
    f89622c1 while the pointer on disk named 2b8c4f37, same cwd, same key.
    Compaction is NOT affected — 17 real compactions in ~/.claude/projects all
    kept one session id — so the fix is not to make `/clear` a continuation but
    to stop pretending it is one.

    Two things follow. A cleared session must not be handed the previous
    session's handoff, because `/clear` means a clean slate. And the render
    must stop saying "No stream claimed" when a stream plainly is claimed for
    this project, because that sentence is simply false and it is what sends
    the next session off to claim a second stream on the same work.
    """

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.repo = str(Path(self._tmp.name) / "repo")
        os.makedirs(self.repo)
        cfg = Path(self._tmp.name) / "projects.json"
        cfg.write_text(json.dumps({"workspaces": {"personal": {
            "default": True, "projects": {"AGENT": {
                "id": "u-agent", "name": "Agents", "dirs": [self.repo]}}}}}))
        for key, value in (("HANDOFF_PROJECTS", str(cfg)),
                           ("HANDOFF_STATE_ROOT", str(Path(self._tmp.name) / "state")),
                           ("PLANE_API_TOKEN", "test-token")):
            os.environ[key] = value
            self.addCleanup(os.environ.pop, key, None)
        import plane
        import sessionstart
        self.plane, self.sessionstart = plane, sessionstart
        self.addCleanup(setattr, plane, "open_items", plane.open_items)
        self.addCleanup(setattr, plane, "newest_comment", plane.newest_comment)
        plane.open_items = lambda *a, **k: [{"name": "x", "state_name": "Todo"}]
        self.fetched = []
        plane.newest_comment = lambda slug, pid, parent, timeout=2.0: (
            self.fetched.append(parent) or "<p>the previous handoff</p>")

    def _run(self, session, source):
        got = self.sessionstart.handle({"session_id": session, "cwd": self.repo,
                                        "source": source})
        return (got or {}).get("hookSpecificOutput", {}).get("additionalContext", "")

    def _claim(self, session):
        from _common import hs
        hs.write_pointer(session, {"identifier": "AGENT-11", "workspace": "personal",
                                   "project_id": "u-agent", "parent_id": "p1"})

    def test_a_compacted_session_still_gets_its_handoff(self):
        # The half that works and must keep working: same session id across a
        # compaction, so the pointer is found and the comment is fetched.
        self._claim("s1")
        text = self._run("s1", "compact")
        self.assertEqual(self.fetched, ["p1"])
        self.assertIn("the previous handoff", text)

    def test_clear_is_not_a_continuation_even_when_the_pointer_is_found(self):
        # Deliberately the SAME session id, so the pointer resolves and the
        # only thing standing between it and a fetch is whether "clear" counts
        # as a continuation. Written the realistic way round — a new session id
        # after the clear — this passes on the unfixed code too, because the
        # pointer is simply missing, and it would prove nothing.
        self._claim("s1")
        self._run("s1", "clear")
        self.assertEqual(self.fetched, [])

    def test_a_cleared_session_names_the_stream_instead_of_denying_it(self):
        self._claim("old-session")
        text = self._run("new-session", "clear")
        self.assertIn("AGENT-11", text)
        self.assertNotIn("No stream claimed", text)

    def test_a_genuinely_unclaimed_board_still_says_so(self):
        # The honest line must not fire when nothing anywhere is claimed, or it
        # becomes noise that names a stream that does not exist.
        text = self._run("new-session", "startup")
        self.assertIn("No stream claimed", text)
