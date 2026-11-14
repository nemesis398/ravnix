"""The Sunday sweep's report: candidates, archive proposals, recurring misses,
use, review queue.

Every test drives `sweep.py report` as a subprocess, with the vault and the
state root pinned under its own temp dir, and checks that the run wrote
nothing. Dates are built back from today, as the review queue counts its 90
days back from today.
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import unittest
from datetime import date, timedelta
from pathlib import Path

TESTS = Path(__file__).resolve().parent
SWEEP = TESTS.parent / "scripts" / "sweep.py"
sys.path.insert(0, str(TESTS))
from helpers import front, write_note  # noqa: E402
from notes import ARCHIVE_DIR, MEMORY_DIR, SESSIONS_DIR  # noqa: E402
from subprocess_env import subprocess_env  # noqa: E402

SECTIONS = ("Candidates", "Archive proposals", "Recurring failures without a memory", "Use",
            "Review queue")
EVENTS = {"pinned": "SessionStart", "match": "UserPromptSubmit", "digest": "UserPromptSubmit",
          "failure": "PostToolUseFailure", "miss": "PostToolUseFailure"}
A = f"{MEMORY_DIR}/a.md"
B = f"{MEMORY_DIR}/b.md"
C = f"{MEMORY_DIR}/c.md"


def session_front(updated: date) -> str:
    return ("type: session\n"
            "domain: [claude-code]\n"
            f"updated: {updated.isoformat()}\n"
            'description: "A session."\n'
            "generated: claude/1fa42edb-43a9-44f1-9267-40a0a1705555\n")


def session_body(candidates: list[str], findings: str = "- A finding.\n") -> str:
    """A session note's body in the writer's shape, `candidates` as bullets."""
    bullets = "".join(f"- {c}\n" for c in candidates)
    return ("# A session\n\nDay: a day\n\n## Done\n\n- Work.\n\n"
            f"## Findings\n\n{findings}\n## Memory candidates\n\n{bullets}\n"
            "## Next\n\n- More work.\n")


def section(out: str, name: str) -> list[str]:
    """The non-blank lines under `## name`, up to the next `## ` heading."""
    lines = out.splitlines()
    start = lines.index(f"## {name}")
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")),
               len(lines))
    return [row for row in lines[start + 1:end] if row.strip()]


def items(out: str, name: str) -> list[str]:
    """Only the `- ` lines of a section, without a section's note line."""
    return [row for row in section(out, name) if row.startswith("- ")]


class SweepCase(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.vault = self.tmp / "vault"
        self.vault.mkdir()
        self.memory = self.vault / MEMORY_DIR
        self.archive = self.vault / ARCHIVE_DIR
        self.sessions = self.vault / SESSIONS_DIR
        self.log_path = self.tmp / "state" / "injections.jsonl"
        self.today = date.today()
        self.since = self.ago(6)

    def ago(self, days: int) -> date:
        return self.today - timedelta(days=days)

    def session(self, name: str, updated: date, candidates: list[str]) -> None:
        write_note(self.sessions, name, session_front(updated), session_body(candidates))

    def memory_note(self, name: str, updated: date, status: str = "active",
                    folder: Path | None = None) -> None:
        write_note(folder or self.memory, name, front(updated=updated.isoformat(), status=status))

    def entry(self, reason: str, rels: tuple[str, ...] = (), session: str = "s1",
              days: int = 1, detail: str = "") -> dict:
        """A log line as `state.log` writes it, `days` before today."""
        return {"ts": f"{self.ago(days).isoformat()}T12:00:00+02:00", "session": session,
                "event": EVENTS[reason], "reason": reason, "rels": list(rels),
                "chars": 0 if reason == "miss" else 40, "detail": detail}

    def log(self, *entries: dict | str) -> None:
        """Append each entry as one line; a str goes in as it is."""
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        with self.log_path.open("a", encoding="utf-8") as fh:
            for entry in entries:
                fh.write((entry if isinstance(entry, str) else json.dumps(entry)) + "\n")

    def snapshot(self) -> dict:
        return {p: (p.stat().st_size, p.stat().st_mtime_ns) for p in self.tmp.rglob("*")}

    def run_sweep(self, *args: str, vault: bool = True) -> subprocess.CompletedProcess:
        """`sweep.py report --since <6 days ago>`, asserting it wrote nothing."""
        argv = [sys.executable, "-B", str(SWEEP), "report", "--since", self.since.isoformat()]
        if vault:
            argv += ["--vault", str(self.vault)]
        before = self.snapshot()
        done = subprocess.run([*argv, *args], capture_output=True, text=True, timeout=60,
                              env=subprocess_env(self.tmp, AI_MEMORY_VAULT=str(self.vault)))
        self.assertEqual(self.snapshot(), before, "the report wrote to the vault or the state")
        return done

    def report(self) -> str:
        done = self.run_sweep()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stderr, "")
        return done.stdout


class Candidates(SweepCase):
    def test_candidates_are_listed_with_their_note(self):
        self.session("Alpha.md", self.ago(2), ["Hooks fail open.", "Stow links\n  per file."])
        self.session("Edge.md", self.since, ["Updated on the day itself."])
        self.session("Old.md", self.ago(7), ["Updated the day before."])
        out = self.report()
        self.assertEqual(section(out, "Candidates"), [
            "- Hooks fail open. | Alpha | first occurrence | promotion not recommended",
            "- Stow links per file. | Alpha | first occurrence | promotion not recommended",
            "- Updated on the day itself. | Edge | first occurrence | promotion not recommended",
        ])
        self.assertNotIn("A finding.", out)

    def test_a_candidate_in_two_notes_is_a_second_occurrence(self):
        self.session("Alpha.md", self.ago(1), ["The same  FACT.", "Only here.", "only here."])
        # Older than --since, so it lists nothing itself, but it still counts.
        self.session("Beta.md", self.ago(30), ["the same fact."])
        lines = section(self.report(), "Candidates")
        self.assertEqual(len(lines), 2, lines)
        self.assertTrue(lines[0].startswith("- The same FACT. | Alpha; Beta | second occurrence"),
                        lines[0])
        # Twice in one note is still one note.
        self.assertTrue(lines[1].startswith("- Only here. | Alpha | first occurrence"), lines[1])

    def test_a_second_occurrence_is_recommended_a_first_is_not(self):
        self.session("Alpha.md", self.ago(3), ["Seen twice.", "Seen once."])
        self.session("Beta.md", self.ago(1), ["Seen twice."])
        lines = section(self.report(), "Candidates")
        self.assertEqual(len(lines), 2, lines)
        self.assertTrue(lines[0].startswith("- Seen twice."), lines[0])
        self.assertTrue(lines[0].endswith(" | promotion recommended"), lines[0])
        self.assertTrue(lines[1].startswith("- Seen once."), lines[1])
        self.assertTrue(lines[1].endswith(" | promotion not recommended"), lines[1])

    def test_a_fenced_block_is_not_read_as_a_section(self):
        # Backtick fences only, as the session-note writer reads them: a
        # closing run as long as the opening one, so the inner ``` stays
        # inside the ```` fence, and a tilde line is no fence at all.
        body = ("# A session\n\n## Findings\n\n- A sample:\n\n"
                "````markdown\n```\n## Memory candidates\n\n- Inside a fence in Findings.\n"
                "```\n````\n\n"
                "## Memory candidates\n\n- First real one.\n\n"
                "```text\n## Next\n- Inside a fence in the candidates.\n```\n\n"
                "- Second real one.\n\n~~~\n- A tilde is no fence.\n\n~~~\n\n"
                "## Next\n\n- Not a candidate.\n")
        write_note(self.sessions, "Fenced.md", session_front(self.ago(1)), body)
        lines = section(self.report(), "Candidates")
        self.assertEqual([row.split(" | ")[0] for row in lines],
                         ["- First real one.", "- Second real one.", "- A tilde is no fence."])

    def test_an_unclosed_fence_is_read_like_the_writer_and_counted(self):
        # The writer ignores the fences of a scan that does not balance, so
        # the heading after an unclosed fence still opens the section.
        body = ("# A session\n\n## Findings\n\n```text\nnever closed\n\n"
                "## Memory candidates\n\n- Still found.\n\n## Next\n\n- More work.\n")
        write_note(self.sessions, "Unclosed.md", session_front(self.ago(1)), body)
        write_note(self.sessions, "Old.md", session_front(self.ago(30)), body)
        done = self.run_sweep()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual([row.split(" | ")[0] for row in section(done.stdout, "Candidates")],
                         ["- Still found."])
        # Only the note inside the window is named, once.
        self.assertEqual(done.stderr.splitlines(), [
            "sweep.py: an unclosed code fence in 1 session note, so check the candidates by hand",
        ])

    def test_a_lazy_line_continues_a_bullet_and_a_sub_bullet_stands_alone(self):
        body = ("# A session\n\n## Memory candidates\n\n"
                "- A bullet that wraps\nonto a lazy line.\n"
                "- A parent.\n  - A child of its own,\n    continued.\n\t* A tab child.\n"
                "- Harvested.\n%%journal:unsure%%\n→ [[Target]]\n\n"
                "Not after a bullet, so no candidate.\n\n## Next\n\n- More work.\n")
        write_note(self.sessions, "Nested.md", session_front(self.ago(1)), body)
        self.assertEqual([row.split(" | ")[0] for row in section(self.report(), "Candidates")], [
            "- A bullet that wraps onto a lazy line.",
            "- A parent.",
            "- A child of its own, continued.",
            "- A tab child.",
            "- Harvested.",
        ])


class ArchiveProposals(SweepCase):
    NAME = "Archive proposals"

    def test_an_archive_bullet_is_a_proposal_and_no_candidate(self):
        self.memory_note("pkill-kills-the-shell.md", self.ago(20))
        self.session("Alpha.md", self.ago(1), [
            "archive [[pkill-kills-the-shell]]: the harness no longer wraps commands in bash -c.",
            "A real candidate.",
        ])
        out = self.report()
        self.assertEqual(section(out, self.NAME), [
            "- pkill-kills-the-shell | the harness no longer wraps commands in bash -c. | Alpha"
            " | the note is active in AI/memory | archive recommended",
        ])
        self.assertEqual([row.split(" | ")[0] for row in section(out, "Candidates")],
                         ["- A real candidate."])

    def test_a_missing_or_archived_note_is_not_recommended(self):
        self.memory_note("retired.md", self.ago(20), status="superseded", folder=self.archive)
        self.memory_note("stray.md", self.ago(20), status="superseded")
        self.session("Alpha.md", self.ago(2), [
            "Archive [[Nowhere]]: it was never true.",
            "archive [[retired|the old rule]]: it is wrong.",
            "archive [[stray]]: wrong as well.",
        ])
        self.assertEqual(section(self.report(), self.NAME), [
            "- Nowhere | it was never true. | Alpha | no memory note by that name"
            " | archive not recommended",
            "- retired | it is wrong. | Alpha | already archived in AI/archive"
            " | archive not recommended",
            "- stray | wrong as well. | Alpha | its status is superseded, not active"
            " | archive not recommended",
        ])

    def test_only_recent_session_notes_propose_and_a_proposal_is_never_a_second_occurrence(self):
        self.memory_note("a.md", self.ago(20))
        self.session("Alpha.md", self.ago(1), ["archive [[a]]: wrong.", "archive [[a]]: wrong."])
        self.session("Beta.md", self.ago(3), ["archive [[a]]: wrong."])
        self.session("Old.md", self.ago(30), ["archive [[a]]: stale."])
        out = self.report()
        self.assertEqual(section(out, self.NAME), [
            "- a | wrong. | Alpha | the note is active in AI/memory | archive recommended",
            "- a | wrong. | Beta | the note is active in AI/memory | archive recommended",
        ])
        self.assertTrue(section(out, "Candidates")[0].startswith("None: "))

    def test_a_bullet_that_only_mentions_archive_stays_a_candidate(self):
        self.session("Alpha.md", self.ago(1), ["Archive copies in Nextcloud keep their links.",
                                               "archive [[]]: names nothing."])
        out = self.report()
        self.assertEqual([row.split(" | ")[0] for row in section(out, "Candidates")],
                         ["- Archive copies in Nextcloud keep their links.",
                          "- archive [[]]: names nothing."])
        self.assertTrue(section(out, self.NAME)[0].startswith("None: "))


class RecurringFailures(SweepCase):
    NAME = "Recurring failures without a memory"
    GREP = "Bash: grep: regular expression too big at line #"

    def test_a_miss_in_one_session_is_not_recurring(self):
        self.log(self.entry("miss", session="s1", days=1, detail=self.GREP),
                 self.entry("miss", session="s1", days=2, detail=self.GREP),
                 self.entry("failure", (A,), session="s2", days=1))
        out = self.report()
        lines = section(out, self.NAME)
        self.assertEqual(len(lines), 1, lines)
        self.assertTrue(lines[0].startswith("None: "), lines[0])
        self.assertNotIn("regular expression", out)

    def test_a_miss_in_two_sessions_is_recurring(self):
        other = "Bash: ls: cannot access '-x'"
        self.log(self.entry("miss", session="s1", days=3, detail=self.GREP),
                 self.entry("miss", session="s2", days=1, detail=self.GREP),
                 self.entry("miss", session="s2", days=2, detail=self.GREP),
                 self.entry("miss", session="s3", days=1, detail=other))
        self.assertEqual(section(self.report(), self.NAME), [
            f"- {self.GREP} | 2 sessions, 3 misses, last {self.ago(1)}",
        ])

    def test_a_recurring_miss_counts_the_whole_log_but_needs_one_since_the_date(self):
        undock = "Bash: login failed after undocking"
        stale = "Bash: a failure that stopped"
        self.log(self.entry("miss", session="s1", days=40, detail=undock),
                 self.entry("miss", session="s2", days=2, detail=undock),
                 self.entry("miss", session="s1", days=40, detail=stale),
                 self.entry("miss", session="s2", days=30, detail=stale))
        self.assertEqual(section(self.report(), self.NAME), [
            f"- {undock} | 2 sessions, 2 misses, last {self.ago(2)}",
        ])


class Use(SweepCase):
    def test_use_counts_by_reason(self):
        for rel in (A, B):
            self.memory_note(Path(rel).name, self.ago(1))
        self.log(self.entry("pinned", (A, B), session="s1", days=1),
                 self.entry("pinned", (A,), session="s2", days=2),
                 self.entry("match", (A,), session="s2", days=2),
                 self.entry("digest", (B,), session="s1", days=1, detail="claude-code"),
                 self.entry("failure", (B,), session="s3", days=0),
                 self.entry("match", (B,), session="s1", days=6),  # on --since: counted
                 self.entry("match", (C,), session="s1", days=7),  # the day before: not
                 self.entry("miss", session="s3", days=0, detail="Bash: x"))
        self.assertEqual(section(self.report(), "Use"), [
            f"- {B}: 4 (pinned 1, match 1, digest 1, failure 1)",
            f"- {A}: 3 (pinned 2, match 1)",
        ])

    def test_a_path_with_no_note_is_marked_in_use_and_in_the_queue(self):
        # An injected note since renamed or moved leaves its old path in the log.
        self.memory_note("a.md", self.ago(200))
        self.log(self.entry("match", (A,), days=1),
                 self.entry("match", (B,), days=1),
                 self.entry("pinned", (B,), days=100))
        out = self.report()
        self.assertEqual(section(out, "Use"), [
            f"- {A}: 1 (match 1)",
            f"- {B} (no such note): 1 (match 1)",
        ])
        self.assertIn("name 1 path with no note, so a renamed or moved note may show "
                      "no injection here", section(out, "Review queue")[0])


class ReviewQueue(SweepCase):
    def test_review_queue_is_older_than_90_days_oldest_first(self):
        self.memory_note("young.md", self.ago(10))
        self.memory_note("edge.md", self.ago(90))
        self.memory_note("old.md", self.ago(91))
        self.memory_note("oldest.md", self.ago(400))
        self.memory_note("superseded.md", self.ago(300), status="superseded")
        # Active, so only its folder keeps it out: the queue reads AI/memory alone.
        self.memory_note("retired.md", self.ago(300), status="active", folder=self.archive)
        lines = items(self.report(), "Review queue")
        self.assertEqual([row.split(" | ")[0] for row in lines],
                         [f"- {MEMORY_DIR}/oldest.md", f"- {MEMORY_DIR}/old.md"])
        self.assertIn(f" | updated {self.ago(400)}, 400 days ago | ", lines[0])

    def test_an_unused_old_note_is_recommended_for_archive_a_used_one_is_not(self):
        for name in ("unused", "used", "used-long-ago"):
            self.memory_note(f"{name}.md", self.ago(200))
        self.log(self.entry("match", (f"{MEMORY_DIR}/used.md",), session="s1", days=30),
                 self.entry("pinned", (f"{MEMORY_DIR}/used.md",), session="s2", days=31),
                 self.entry("pinned", (f"{MEMORY_DIR}/used-long-ago.md",), days=120))
        lines = {row.split(" | ")[0][2:]: row for row in items(self.report(), "Review queue")}
        self.assertEqual(len(lines), 3, lines)
        self.assertTrue(lines[f"{MEMORY_DIR}/unused.md"].endswith(
            " | no injection in 90 days | archive recommended"))
        self.assertTrue(lines[f"{MEMORY_DIR}/used-long-ago.md"].endswith(
            " | no injection in 90 days | archive recommended"))
        self.assertTrue(lines[f"{MEMORY_DIR}/used.md"].endswith(
            " | 2 injections in 90 days | archive not recommended"))

    def test_a_log_shorter_than_90_days_is_named_in_the_review_queue(self):
        self.memory_note("old.md", self.ago(200))
        lines = section(self.report(), "Review queue")
        self.assertEqual(len(lines), 2, lines)
        self.assertIn("no injection log", lines[0])
        old = f"{MEMORY_DIR}/old.md"
        self.log(self.entry("match", (old,), days=5))
        lines = section(self.report(), "Review queue")
        self.assertEqual(len(lines), 2, lines)
        self.assertIn(f"The log only goes back to {self.ago(5)}", lines[0])
        self.log(self.entry("match", (old,), days=100))
        self.assertEqual(len(section(self.report(), "Review queue")), 1)


class Robustness(SweepCase):
    def test_a_malformed_log_line_or_unreadable_note_is_skipped_and_counted(self):
        self.log(self.entry("pinned", (A,), days=1),
                 "not json",
                 "[1, 2]",
                 json.dumps({**self.entry("match", (A,)), "ts": "soon"}),
                 json.dumps({k: v for k, v in self.entry("match", (A,)).items() if k != "rels"}),
                 self.entry("match", (A,), days=1))
        self.session("Good.md", self.ago(1), ["Still listed."])
        write_note(self.sessions, "Broken.md", "description: `a reserved backtick`\n")
        write_note(self.sessions, "Undated.md", session_front(self.ago(1)).replace(
            f"updated: {self.ago(1).isoformat()}", "updated: soon"))
        self.memory_note("a.md", self.ago(1))
        (self.memory / "bare.md").write_text("No frontmatter at all.\n", encoding="utf-8")
        done = self.run_sweep()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(done.stderr.splitlines(),
                         ["sweep.py: skipped 4 malformed log lines and 3 notes it could not read"])
        self.assertEqual(section(done.stdout, "Use"), [f"- {A}: 2 (pinned 1, match 1)"])
        self.assertEqual([row.split(" | ")[0] for row in section(done.stdout, "Candidates")],
                         ["- Still listed."])

    def test_a_missing_log_and_empty_folders_give_one_line_sections(self):
        for make in (False, True):
            with self.subTest(folders_exist=make):
                if make:
                    for folder in (self.memory, self.sessions, self.archive):
                        folder.mkdir(parents=True)
                done = self.run_sweep(vault=False)  # the vault from AI_MEMORY_VAULT
                self.assertEqual(done.returncode, 0, done.stderr)
                self.assertEqual(done.stderr, "")
                for name in SECTIONS:
                    lines = section(done.stdout, name)
                    self.assertEqual(len(lines), 1, (name, lines))
                    self.assertTrue(lines[0].startswith("None: "), lines[0])
                self.assertIn(str(self.log_path), section(done.stdout, "Use")[0])

    def test_a_log_that_cannot_be_read_is_reported_and_the_sections_still_print(self):
        self.memory_note("old.md", self.ago(200))
        self.log_path.mkdir(parents=True)  # a directory where the log should be
        done = self.run_sweep()
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertNotIn("Traceback", done.stderr)
        self.assertEqual(len(done.stderr.splitlines()), 1, done.stderr)
        self.assertTrue(done.stderr.startswith(f"sweep.py: cannot read {self.log_path}: "),
                        done.stderr)
        for name in ("Recurring failures without a memory", "Use"):
            self.assertEqual(section(done.stdout, name),
                             [f"None: the injection log at {self.log_path} cannot be read "
                              f"(Is a directory)."])
        queue = section(done.stdout, "Review queue")
        self.assertIn("cannot be read", queue[0])
        self.assertTrue(queue[1].endswith(" | archive recommended"), queue[1])

    def test_a_bad_date_or_a_missing_vault_is_a_usage_error(self):
        bad = subprocess.run([sys.executable, "-B", str(SWEEP), "report", "--since", "soon"],
                             capture_output=True, text=True, timeout=60,
                             env=subprocess_env(self.tmp, AI_MEMORY_VAULT=str(self.vault)))
        self.assertEqual(bad.returncode, 2)
        self.assertIn("soon", bad.stderr)
        gone = self.run_sweep("--vault", str(self.tmp / "nowhere"))
        self.assertEqual(gone.returncode, 2)
        self.assertIn("nowhere", gone.stderr)


if __name__ == "__main__":
    unittest.main()
