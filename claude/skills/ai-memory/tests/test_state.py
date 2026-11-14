"""What a session already got, and the injection log."""
from __future__ import annotations

import json
import os
import sys
import tempfile
import time
import unittest
from datetime import datetime
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import state  # noqa: E402

A = "AI/memory/a.md"
B = "AI/memory/b.md"
C = "AI/memory/c.md"
UUID = "1fa42edb-43a9-44f1-9267-40a0a1705555"
DAY = 86400


class StateTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.root = self.tmp / "state"
        self.sessions = self.root / "sessions"
        env = mock.patch.dict(os.environ, {
            "AI_MEMORY_STATE_ROOT": str(self.root),
            "HOME": str(self.tmp / "home"),
        })
        env.start()
        self.addCleanup(env.stop)

    def files(self) -> list[Path]:
        """Every file anywhere under the temp dir, the state root's parent."""
        return sorted(p for p in self.tmp.rglob("*") if p.is_file())

    def age(self, path: Path, days: float) -> None:
        when = time.time() - days * DAY
        os.utime(path, (when, when))

    def test_the_state_root_defaults_under_home(self):
        default = self.tmp / "home" / ".local" / "state" / "ai-memory"
        self.assertEqual(state.state_root(), self.root)
        with mock.patch.dict(os.environ, {"AI_MEMORY_STATE_ROOT": ""}):
            self.assertEqual(state.state_root(), default)
            del os.environ["AI_MEMORY_STATE_ROOT"]
            self.assertEqual(state.state_root(), default)

    def test_remember_unions_and_seen_reads_back(self):
        self.assertEqual(state.seen(UUID), {"injected": [], "digested": []})
        state.remember(UUID, [B, A], ["vault"])
        state.remember(UUID, [A, C, C], ["vault", "homelab"])
        self.assertEqual(state.seen(UUID),
                         {"injected": [B, A, C], "digested": ["vault", "homelab"]})
        self.assertEqual(state.seen("other"), {"injected": [], "digested": []})
        # One file per session, named by its id, and no temp file left behind.
        self.assertEqual(self.files(), [self.sessions / f"{UUID}.json"])

    def test_forget_clears_a_session(self):
        state.remember("s1", [A], ["vault"])
        state.remember("s2", [B], [])
        state.forget("s1")
        self.assertEqual(state.seen("s1"), {"injected": [], "digested": []})
        self.assertEqual(state.seen("s2"), {"injected": [B], "digested": []})
        state.forget("never-seen")
        self.assertEqual(self.files(), [self.sessions / "s2.json"])

    def test_a_path_like_session_id_stays_inside_the_root(self):
        for session in ("../../x", "/tmp/abs", "..", "", "a/../../b", "x" * 1000):
            with self.subTest(session=session[:20]):
                state.remember(session, [A], ["vault"])
                written = self.files()
                self.assertEqual(len(written), 1, written)
                self.assertEqual(written[0].parent, self.sessions)
                self.assertEqual(state.seen(session), {"injected": [A], "digested": ["vault"]})
                state.forget(session)
                self.assertEqual(self.files(), [])

    def test_prune_drops_only_old_files(self):
        state.prune()  # no sessions directory yet: nothing to do
        for session in ("old", "recent", "fresh"):
            state.remember(session, [A], [])
        stray = self.sessions / ".old.abc123.tmp"  # a killed write's temp file
        stray.write_text("{", encoding="utf-8")
        state.log("SessionStart", "old", "pinned", [A], chars=10)
        (self.root / "hook.log").write_text("trace\n", encoding="utf-8")
        for path in (self.sessions / "old.json", stray,
                     self.root / "injections.jsonl", self.root / "hook.log"):
            self.age(path, 15)
        self.age(self.sessions / "recent.json", 13)

        state.prune(14)

        # Only sessions/ is pruned: the logs in the root keep their history.
        self.assertEqual(self.files(), [
            self.root / "hook.log",
            self.root / "injections.jsonl",
            self.sessions / "fresh.json",
            self.sessions / "recent.json",
        ])
        self.assertEqual(state.seen("old"), {"injected": [], "digested": []})

    def test_prune_skips_an_entry_it_cannot_remove(self):
        # SessionStart prunes before it injects, so one bad entry must not
        # stop every session start. A directory cannot be unlinked.
        for name in ("a-old", "z-old"):
            state.remember(name, [A], [])
            self.age(self.sessions / f"{name}.json", 15)
        stuck = self.sessions / "m-dir.json"
        stuck.mkdir()
        (stuck / "inside").write_text("x", encoding="utf-8")
        self.age(stuck, 15)

        state.prune(14)

        self.assertEqual(self.files(), [stuck / "inside"])
        self.assertTrue(stuck.is_dir())

    def test_log_appends_one_json_line_per_call(self):
        state.log("UserPromptSubmit", "../s1", "match", [A, B], chars=42)
        state.log("PostToolUseFailure", "../s1", "miss", [], "Bash: error on line #", chars=0)
        lines = (self.root / "injections.jsonl").read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines), 2)
        first, second = (json.loads(line) for line in lines)
        for entry in (first, second):
            self.assertEqual(list(entry),
                             ["ts", "session", "event", "reason", "rels", "chars", "detail"])
            self.assertIsNotNone(datetime.fromisoformat(entry["ts"]).tzinfo)
            self.assertEqual(entry["session"], "../s1")  # raw, not the file name
        self.assertEqual(
            {k: first[k] for k in ("event", "reason", "rels", "chars", "detail")},
            {"event": "UserPromptSubmit", "reason": "match", "rels": [A, B],
             "chars": 42, "detail": ""})
        self.assertEqual(
            {k: second[k] for k in ("event", "reason", "rels", "chars", "detail")},
            {"event": "PostToolUseFailure", "reason": "miss", "rels": [],
             "chars": 0, "detail": "Bash: error on line #"})

    def test_log_takes_only_the_five_reasons(self):
        for reason in ("pinned", "match", "digest", "failure", "miss"):
            state.log("SessionStart", "s1", reason, [], chars=0)
        with self.assertRaises(ValueError):
            state.log("SessionStart", "s1", "matched", [], chars=0)
        # chars has no default, so a call that forgets it fails loudly in
        # the adapter's tests instead of logging 0.
        with self.assertRaises(TypeError):
            state.log("SessionStart", "s1", "pinned", [A])
        with self.assertRaises(TypeError):
            state.log("SessionStart", "s1", "pinned", [A], "", 10)
        lines = (self.root / "injections.jsonl").read_text(encoding="utf-8").splitlines()
        self.assertEqual([json.loads(line)["reason"] for line in lines],
                         ["pinned", "match", "digest", "failure", "miss"])


if __name__ == "__main__":
    unittest.main()
