# tests/test_journal_state.py
import multiprocessing
import os
import queue
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
import journal_state as js  # noqa: E402


class StateCase(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.previous = os.environ.get("JOURNAL_STATE_ROOT")
        os.environ["JOURNAL_STATE_ROOT"] = os.path.join(self.tmp.name, "state")
        self.addCleanup(self._restore)
        self.repo = os.path.join(self.tmp.name, "proj")
        os.makedirs(self.repo)

    def _restore(self):
        if self.previous is None:
            os.environ.pop("JOURNAL_STATE_ROOT", None)
        else:
            os.environ["JOURNAL_STATE_ROOT"] = self.previous


class TestStamp(StateCase):
    def test_round_trips(self):
        js.write_stamp(self.repo, "s1", {"fired": True})
        self.assertTrue(js.read_stamp(self.repo, "s1").get("fired"))

    def test_absent_reads_as_empty(self):
        self.assertEqual(js.read_stamp(self.repo, "never"), {})

    def test_corrupt_reads_as_empty_rather_than_raising(self):
        js.write_stamp(self.repo, "s2", {"fired": True})
        js.stamp_file(self.repo, "s2").write_text("{not json", encoding="utf-8")
        self.assertEqual(js.read_stamp(self.repo, "s2"), {})

    def test_sessions_do_not_collide(self):
        js.write_stamp(self.repo, "a", {"fired": True})
        self.assertEqual(js.read_stamp(self.repo, "b"), {})

    def test_non_dict_json_array_reads_as_empty(self):
        # GAP 3: the isinstance(loaded, dict) guard in _read_json. Valid
        # JSON that parses to something other than an object -- an array --
        # must not be handed back as though it were a stamp.
        js.write_stamp(self.repo, "s3", {"fired": True})
        js.stamp_file(self.repo, "s3").write_text("[1, 2, 3]", encoding="utf-8")
        self.assertEqual(js.read_stamp(self.repo, "s3"), {})

    def test_non_dict_json_scalar_reads_as_empty(self):
        # Same guard, the other named failure mode: a bare scalar.
        js.write_stamp(self.repo, "s4", {"fired": True})
        js.stamp_file(self.repo, "s4").write_text("42", encoding="utf-8")
        self.assertEqual(js.read_stamp(self.repo, "s4"), {})

    def test_empty_session_falls_back_to_unknown_file(self):
        # GAP 3: the `or "unknown"` fallback for an empty session id.
        self.assertEqual(js.stamp_file(self.repo, "").name, "unknown.json")


class TestStanddown(StateCase):
    def test_records_and_reads_back(self):
        js.record_standdown(self.repo, "stop", "goal_active")
        self.assertEqual(js.read_standdown(self.repo).get("reason"), "goal_active")

    def test_stays_out_of_the_handoff_state_root(self):
        # The whole reason this module exists rather than reusing handoff's.
        js.record_standdown(self.repo, "stop", "goal_active")
        self.assertNotIn("agent-handoff", str(js.state_root()))

        # setUp pins JOURNAL_STATE_ROOT to a tempdir for every test in this
        # class, so the assertion above never exercises the un-overridden
        # branch of state_root(): it would pass even if that branch's
        # hardcoded fallback read "agent-handoff" instead of "agent-journal",
        # because this test never takes that branch. Clear the override and
        # check the real default directly, so a copy-paste of handoff's
        # default (or a stray read of HANDOFF_STATE_ROOT) actually fails
        # this test.
        os.environ.pop("JOURNAL_STATE_ROOT", None)
        self.assertIn("agent-journal", str(js.state_root()))
        self.assertNotIn("agent-handoff", str(js.state_root()))


class TestSessionSanitization(StateCase):
    """FINDING 2: `session` used raw as a path component escapes its
    directory. Both checks read `stamp_file`'s own computed path rather than
    performing a write, so a bug here is caught without ever touching
    anything outside the per-test tempdir even transiently.
    """

    def test_dotdot_traversal_stays_inside_the_repo_directory(self):
        target = js.stamp_file(self.repo, "../../escaped")
        self.assertEqual(target.parent, js.state_root() / js.repo_key(self.repo))

    def test_absolute_path_session_stays_inside_the_repo_directory(self):
        target = js.stamp_file(self.repo, "/etc/passwd")
        self.assertEqual(target.parent, js.state_root() / js.repo_key(self.repo))


class TestNoLeftoverTempFile(StateCase):
    def test_none_left_after_a_successful_write(self):
        js.write_stamp(self.repo, "s1", {"fired": True})
        directory = js.stamp_file(self.repo, "s1").parent
        leftovers = [p.name for p in directory.iterdir() if p.name != "s1.json"]
        self.assertEqual(leftovers, [])

    def test_none_left_after_a_failed_write(self):
        target = js.stamp_file(self.repo, "s1")
        with patch("journal_state.os.replace", side_effect=OSError("boom")):
            js.write_stamp(self.repo, "s1", {"fired": True})  # must not raise
        leftovers = list(target.parent.iterdir()) if target.parent.is_dir() else []
        self.assertEqual(leftovers, [])


def _race_worker(repo, iterations, result_queue):
    """Runs in a forked child process, hammering the same targets every
    other worker is hammering at the same instant: record_standdown's one
    file per repo, and a write_stamp session every worker shares on purpose.

    Reports the first exception's repr through the queue rather than the
    default multiprocessing behavior of printing a traceback to stderr and
    losing it -- the parent test needs an object it can assert on.
    """
    try:
        for i in range(iterations):
            js.record_standdown(repo, "worker", f"iteration-{i}")
            js.write_stamp(repo, "shared", {"i": i})
    except BaseException as exc:  # noqa: BLE001 - a race can raise anything
        result_queue.put(repr(exc))
    else:
        result_queue.put(None)


class TestConcurrency(StateCase):
    def test_concurrent_writers_do_not_raise(self):
        """FINDING 1. Reproduces the race measured directly against the
        pre-fix deterministic temp name: 8 processes hammering the same
        record_standdown target and the same write_stamp session at once
        produced 587 unhandled FileNotFoundError out of 3200 calls. This
        module's whole job is to be safe on a path that runs at every turn
        end, so "zero exceptions, valid content afterward" is the bar.
        """
        ctx = multiprocessing.get_context("fork")
        result_queue = ctx.Queue()
        workers = [
            ctx.Process(target=_race_worker, args=(self.repo, 300, result_queue))
            for _ in range(8)
        ]
        for w in workers:
            w.start()
        for w in workers:
            w.join(timeout=60)
            self.assertFalse(w.is_alive(), "a worker did not finish in time")

        results = []
        for _ in workers:
            try:
                results.append(result_queue.get(timeout=5))
            except queue.Empty:
                results.append("no result reported (worker crashed?)")
        failures = [r for r in results if r is not None]
        self.assertEqual(
            failures, [],
            f"{len(failures)} of {len(workers)} worker(s) raised: {failures[:3]}",
        )

        # Whichever worker wrote last, atomic replace guarantees the file on
        # disk is whole -- never half-written, never missing.
        standdown = js.read_standdown(self.repo)
        self.assertEqual(standdown.get("adapter"), "worker")
        self.assertIsInstance(standdown.get("reason"), str)
        stamp = js.read_stamp(self.repo, "shared")
        self.assertIsInstance(stamp.get("i"), int)


if __name__ == "__main__":
    unittest.main()
