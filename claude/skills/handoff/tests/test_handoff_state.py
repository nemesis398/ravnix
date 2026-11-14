import json as _json
import os
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import handoff_state as hs

BRAIN = Path(__file__).resolve().parents[1] / "scripts" / "handoff_state.py"

sys.path.insert(0, str(Path(__file__).resolve().parent))
from subprocess_env import subprocess_env  # noqa: E402


class TempState(unittest.TestCase):
    """Every test gets its own state root so nothing touches the real one."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.root = Path(self._tmp.name)
        os.environ["HANDOFF_STATE_ROOT"] = str(self.root / "state")
        self.addCleanup(self._tmp.cleanup)
        self.addCleanup(os.environ.pop, "HANDOFF_STATE_ROOT", None)

    def make_repo(self, name="proj"):
        repo = self.root / name
        repo.mkdir(parents=True)
        subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
        return repo


class TestRepoKey(TempState):
    def test_key_is_basename_plus_eight_hex(self):
        repo = self.make_repo("Notes-Vault")
        key = hs.repo_key(str(repo))
        self.assertTrue(key.startswith("Notes-Vault-"), key)
        self.assertEqual(len(key.rsplit("-", 1)[1]), 8)

    def test_subdirectory_collapses_to_the_repo_root(self):
        repo = self.make_repo("vault")
        sub = repo / "Apprenticeship notes"
        sub.mkdir()
        self.assertEqual(hs.repo_key(str(sub)), hs.repo_key(str(repo)))

    def test_same_basename_in_two_places_does_not_collide(self):
        a = self.make_repo("twin")
        b = self.root / "elsewhere"
        b.mkdir()
        second = b / "twin"
        second.mkdir()
        subprocess.run(["git", "init", "-q"], cwd=second, check=True)
        self.assertNotEqual(hs.repo_key(str(a)), hs.repo_key(str(second)))

    def test_non_git_directory_still_gets_a_key(self):
        plain = self.root / "loose"
        plain.mkdir()
        self.assertTrue(hs.repo_key(str(plain)).startswith("loose-"))


class TestPaths(TempState):
    def test_paths_hang_off_the_state_root(self):
        repo = self.make_repo("proj")
        p = hs.paths(str(repo))
        self.assertEqual(p["current"], p["dir"] / "current.md")
        self.assertEqual(p["archive"], p["dir"] / "archive")
        self.assertEqual(p["runtime"], p["dir"] / ".runtime")
        self.assertTrue(str(p["dir"]).startswith(str(self.root / "state")))


SAMPLE = """---
goal: Make vault-check pass on a clean tree
repo: /tmp/proj
branch: main
head: a034fa7
updated: 2026-08-08T17:04
---

# Handoff: vault-check

## Goal
Long form goal paragraph.

## Next steps
1. Run vault-check.
2. Fix the first ERROR.

## Resume checks
git status --short
vault-check
"""


class TestReadHandoff(TempState):
    def write_current(self, repo, text=SAMPLE):
        current = hs.paths(str(repo))["current"]
        current.parent.mkdir(parents=True, exist_ok=True)
        current.write_text(text, encoding="utf-8")
        return current

    def test_missing_file_reads_as_absent(self):
        repo = self.make_repo()
        self.assertFalse(hs.read_handoff(str(repo))["exists"])

    def test_frontmatter_becomes_a_flat_dict(self):
        repo = self.make_repo()
        self.write_current(repo)
        meta = hs.read_handoff(str(repo))["meta"]
        self.assertEqual(meta["branch"], "main")
        self.assertEqual(meta["goal"], "Make vault-check pass on a clean tree")

    def test_malformed_frontmatter_reads_as_absent_not_as_a_crash(self):
        repo = self.make_repo()
        self.write_current(repo, "no frontmatter here at all\n")
        self.assertFalse(hs.read_handoff(str(repo))["exists"])

    def test_frontmatter_without_a_goal_reads_as_absent(self):
        repo = self.make_repo()
        self.write_current(repo, "---\nbranch: main\n---\n\nbody\n")
        self.assertFalse(hs.read_handoff(str(repo))["exists"])

    def test_section_extracts_one_heading_only(self):
        self.assertEqual(
            hs.section(SAMPLE, "Next steps"),
            "1. Run vault-check.\n2. Fix the first ERROR.",
        )

    def test_section_is_case_insensitive_and_misses_return_empty(self):
        self.assertNotEqual(hs.section(SAMPLE, "next STEPS"), "")
        self.assertEqual(hs.section(SAMPLE, "Nonexistent"), "")

    def test_age_is_computed_from_the_updated_field(self):
        now = datetime(2026, 8, 8, 19, 4)
        self.assertEqual(hs.age_seconds("2026-08-08T17:04", now), 7200)

    def test_unparseable_timestamp_gives_none_rather_than_raising(self):
        self.assertIsNone(hs.age_seconds("not a date"))
        self.assertIsNone(hs.age_seconds(None))

    def test_read_handoff_reports_age(self):
        repo = self.make_repo()
        self.write_current(repo)
        got = hs.read_handoff(str(repo), now=datetime(2026, 8, 8, 17, 4) + timedelta(hours=3))
        self.assertEqual(got["age_seconds"], 10800)


class TestVerdict(TempState):
    def test_below_soft_says_nothing(self):
        self.assertEqual(hs.verdict(150_000, 0), ("none", 0))

    def test_crossing_soft_fires_once(self):
        self.assertEqual(hs.verdict(210_000, 0), ("soft", 200_000))

    def test_soft_does_not_repeat_within_its_band(self):
        self.assertEqual(hs.verdict(300_000, 200_000), ("none", 200_000))

    def test_crossing_hard_fires(self):
        self.assertEqual(hs.verdict(410_000, 200_000), ("hard", 400_000))

    def test_a_burst_past_both_skips_straight_to_hard(self):
        self.assertEqual(hs.verdict(410_000, 0), ("hard", 400_000))

    def test_after_hard_it_rearms_every_hundred_thousand(self):
        self.assertEqual(hs.verdict(450_000, 400_000), ("none", 400_000))
        self.assertEqual(hs.verdict(510_000, 400_000), ("hard", 500_000))
        self.assertEqual(hs.verdict(605_000, 500_000), ("hard", 600_000))

    def test_a_large_single_turn_jump_marks_the_band_it_actually_landed_in(self):
        # Reproduces the review finding: pinning the mark to `hard` on any
        # overshoot made the next turn, at only slightly higher tokens, fire
        # "hard" again, because the mark undercounted where the burst landed.
        first = hs.verdict(550_000, 0)
        self.assertEqual(first, ("hard", 500_000))
        self.assertEqual(hs.verdict(555_000, first[1]), ("none", 500_000))

    def test_a_burst_past_several_rearm_bands_fires_exactly_once(self):
        first = hs.verdict(1_000_000, 0)
        self.assertEqual(first, ("hard", 1_000_000))
        self.assertEqual(hs.verdict(1_005_000, first[1]), ("none", 1_000_000))

    def test_env_overrides_the_thresholds(self):
        os.environ["HANDOFF_SOFT_TOKENS"] = "50000"
        self.addCleanup(os.environ.pop, "HANDOFF_SOFT_TOKENS", None)
        self.assertEqual(hs.verdict(60_000, 0), ("soft", 50_000))

    def test_a_junk_env_value_falls_back_instead_of_raising(self):
        os.environ["HANDOFF_SOFT_TOKENS"] = "banana"
        self.addCleanup(os.environ.pop, "HANDOFF_SOFT_TOKENS", None)
        self.assertEqual(hs.thresholds(), (200_000, 400_000))


class TestBothBandsFitUnderTheCompactionCeiling(unittest.TestCase):
    """Twice now a retune left a band where it could never fire.

    Against a 300,000 ceiling HARD sat exactly on it, and against the 487,000
    that `autoCompactWindow: 500000` leaves, the 500,000 and 650,000 pair sat
    past it, so the reminder went silent without a word. These pin the
    arithmetic rather than the numbers, so a third retune that breaks it fails
    here instead of in a session.
    """

    def test_soft_comes_before_hard(self):
        self.assertLess(hs.SOFT_DEFAULT, hs.HARD_DEFAULT)

    def test_hard_comes_before_the_compaction_point(self):
        self.assertLess(hs.HARD_DEFAULT, hs.COMPACT_CEILING)

    def test_hard_fires_at_most_once_per_compaction_cycle(self):
        # The first re-arm band lies past the ceiling, so a session hears the
        # hard advice once and then compacts, rather than twice in 87,000.
        self.assertGreater(hs.HARD_DEFAULT + hs.REARM, hs.COMPACT_CEILING)


class TestStamps(TempState):
    def test_missing_stamp_reads_as_empty(self):
        repo = self.make_repo()
        self.assertEqual(hs.read_stamp(str(repo), "sess-1"), {})

    def test_stamp_round_trips(self):
        repo = self.make_repo()
        hs.write_stamp(str(repo), "sess-1", {"last_fired": 200_000})
        self.assertEqual(hs.read_stamp(str(repo), "sess-1")["last_fired"], 200_000)

    def test_corrupt_stamp_reads_as_empty_rather_than_raising(self):
        repo = self.make_repo()
        target = hs.stamp_file(str(repo), "sess-1")
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("{not json", encoding="utf-8")
        self.assertEqual(hs.read_stamp(str(repo), "sess-1"), {})

    def test_sessions_do_not_share_a_stamp(self):
        repo = self.make_repo()
        hs.write_stamp(str(repo), "a", {"last_fired": 1})
        hs.write_stamp(str(repo), "b", {"last_fired": 2})
        self.assertEqual(hs.read_stamp(str(repo), "a")["last_fired"], 1)


class TestStanddown(TempState):
    """I4: every quiet path used to leave no trace. precompact.py's own
    invalid-JSON defect (finding C1) survived an entire build looking healthy
    for exactly this reason: nothing recorded that it was happening. This is
    a single overwritten record, not a log, because the adapters run on every
    turn end of every session forever and a per-turn append would grow
    without bound."""

    def test_missing_standdown_reads_as_empty(self):
        repo = self.make_repo()
        self.assertEqual(hs.read_standdown(str(repo)), {})

    def test_standdown_round_trips(self):
        repo = self.make_repo()
        hs.record_standdown(str(repo), "stop", "goal_active")
        got = hs.read_standdown(str(repo))
        self.assertEqual(got["adapter"], "stop")
        self.assertEqual(got["reason"], "goal_active")
        self.assertIn("at", got)

    def test_recording_again_overwrites_rather_than_accumulates(self):
        repo = self.make_repo()
        for i in range(5):
            hs.record_standdown(str(repo), "stop", f"reason-{i}")
        got = hs.read_standdown(str(repo))
        self.assertEqual(got["reason"], "reason-4")
        self.assertIsInstance(got, dict)

    def test_corrupt_standdown_reads_as_empty_rather_than_raising(self):
        repo = self.make_repo()
        target = hs.standdown_file(str(repo))
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("{not json", encoding="utf-8")
        self.assertEqual(hs.read_standdown(str(repo)), {})


class TestInjection(TempState):
    def write_current(self, repo, text=SAMPLE):
        current = hs.paths(str(repo))["current"]
        current.parent.mkdir(parents=True, exist_ok=True)
        current.write_text(text, encoding="utf-8")

    def test_absent_handoff_injects_nothing(self):
        repo = self.make_repo()
        self.assertEqual(hs.render_injection(hs.read_handoff(str(repo)), "full"), "")

    def test_pointer_names_the_path_and_an_absolute_timestamp(self):
        repo = self.make_repo()
        self.write_current(repo)
        text = hs.render_injection(hs.read_handoff(str(repo)), "pointer")
        self.assertIn("current.md", text)
        self.assertIn("2026-08-08T17:04", text)

    def test_injection_never_contains_a_relative_age(self):
        # A relative age changes every turn, so text injected more than once in
        # a session would bust the prompt cache every time it was repeated.
        repo = self.make_repo()
        self.write_current(repo)
        for mode in ("pointer", "full"):
            text = hs.render_injection(hs.read_handoff(str(repo)), mode)
            for banned in ("ago", "hours old", "minutes"):
                self.assertNotIn(banned, text.casefold())

    def test_full_carries_next_steps_and_resume_checks(self):
        repo = self.make_repo()
        self.write_current(repo)
        text = hs.render_injection(hs.read_handoff(str(repo)), "full")
        self.assertIn("Run vault-check.", text)
        self.assertIn("git status --short", text)

    def test_full_is_capped(self):
        repo = self.make_repo()
        self.write_current(repo, SAMPLE.replace("1. Run vault-check.", "x" * 4000))
        self.assertLessEqual(len(hs.render_injection(hs.read_handoff(str(repo)), "full")), hs.INJECT_CAP)

    def test_cap_never_exceeds_the_limit_even_when_the_limit_is_smaller_than_the_marker(self):
        # Reproduces the review finding: the truncation marker was hardcoded
        # at 45 reserved characters while actually being 32, so a limit below
        # 45 drove the slice index negative and trimmed from the wrong end.
        # cap("y" * 5000, 44) returned 5031 characters instead of at most 44.
        for limit in (0, 1, 10, 31, 32, 33, 44, 45, 100):
            with self.subTest(limit=limit):
                self.assertLessEqual(len(hs.cap("y" * 5000, limit)), limit)


class TestFullInjectionGivesAnInstruction(unittest.TestCase):
    """The write side names the next action and the resume side did not.

    The cap is 1500 characters against a current.md that was 19,728 bytes on
    2026-08-16, so the extract is roughly 8% of the document. Every directive
    therefore has to precede the extract, or truncation eats the instruction
    and leaves the fragment.
    """

    def handoff(self, next_steps: str) -> dict:
        text = (f"---\ngoal: ship it\nupdated: 2026-08-16T10:00\n"
                f"branch: main\nhead: abc123\n---\n\n"
                f"## Next steps\n{next_steps}\n\n"
                f"## Resume checks\n- run the suite\n")
        return {"exists": True, "path": "/tmp/current.md",
                "meta": hs.parse_frontmatter(text), "text": text,
                "age_seconds": 60}

    def test_it_tells_the_model_to_read_the_whole_document(self):
        out = hs.render_injection(self.handoff("1. go"), "full")
        self.assertIn("/tmp/current.md", out)
        self.assertIn("Read it in full", out)

    def test_it_names_the_next_action(self):
        out = hs.render_injection(self.handoff("1. go"), "full")
        self.assertIn("first unfinished next step", out)
        self.assertIn("without waiting to be asked", out)

    def test_it_keeps_the_stop_and_say_so_exception(self):
        out = hs.render_injection(self.handoff("1. go"), "full")
        self.assertIn("say so and stop", out)

    def test_directives_survive_truncation_of_a_huge_next_steps_list(self):
        out = hs.render_injection(self.handoff("1. go\n" * 2000), "full")
        self.assertLessEqual(len(out), hs.INJECT_CAP)
        self.assertIn("Read it in full", out)
        self.assertIn("first unfinished next step", out)
        self.assertIn(hs.TRUNCATION_MARKER.strip(), out)

    def test_the_pointer_mode_is_unchanged(self):
        out = hs.render_injection(self.handoff("1. go"), "pointer")
        self.assertIn("ignore it if this session is about something else", out)


class TestCli(TempState):
    def run_cli(self, *args):
        script = Path(hs.__file__)
        done = subprocess.run([sys.executable, str(script), *args],
                              capture_output=True, text=True, env=subprocess_env())
        return done.returncode, done.stdout.strip()

    def test_paths_prints_json(self):
        repo = self.make_repo()
        code, out = self.run_cli("paths", "--cwd", str(repo))
        self.assertEqual(code, 0)
        self.assertIn("current", _json.loads(out))

    def test_selftest_exits_zero(self):
        code, _ = self.run_cli("selftest")
        self.assertEqual(code, 0)

    def test_claim_without_session_is_rejected(self):
        # The same review finding that once guarded verdict and stamp, which
        # went with OpenCode: a missing --session silently fell back to a
        # shared "unknown" file in the real state root. For claim that means
        # two sessions overwriting each other's stream.
        code, _ = self.run_cli("claim", "--project", "u-tools",
                               "--identifier", "TOOLS-1")
        self.assertEqual(code, 2)

    def test_release_without_session_is_rejected(self):
        code, _ = self.run_cli("release")
        self.assertEqual(code, 2)

    def test_other_commands_do_not_require_session(self):
        # The requirement is scoped to claim and release, the commands that
        # write a session-keyed file. paths and doctor never touch one and
        # must stay callable without one.
        repo = self.make_repo()
        for args in (("paths", "--cwd", str(repo)),
                     ("doctor", "--cwd", str(repo))):
            with self.subTest(args=args):
                code, _ = self.run_cli(*args)
                self.assertEqual(code, 0)

    def test_doctor_exits_zero_on_a_repo_with_nothing_recorded(self):
        repo = self.make_repo()
        code, out = self.run_cli("doctor", "--cwd", str(repo))
        self.assertEqual(code, 0)
        self.assertIn("Handoff: none", out)
        self.assertIn("none recorded", out.casefold())

    def test_doctor_reports_handoff_existence_and_age(self):
        repo = self.make_repo()
        current = hs.paths(str(repo))["current"]
        current.parent.mkdir(parents=True, exist_ok=True)
        current.write_text(SAMPLE, encoding="utf-8")
        code, out = self.run_cli("doctor", "--cwd", str(repo))
        self.assertEqual(code, 0)
        self.assertIn(str(current), out)

    def test_doctor_reports_the_last_standdown(self):
        repo = self.make_repo()
        hs.record_standdown(str(repo), "stop", "goal_active")
        code, out = self.run_cli("doctor", "--cwd", str(repo))
        self.assertIn("stop", out)
        self.assertIn("goal_active", out)

    def test_doctor_reports_a_session_stamp(self):
        repo = self.make_repo()
        hs.write_stamp(str(repo), "sess-doctor", {"last_fired": 200_000})
        code, out = self.run_cli("doctor", "--cwd", str(repo))
        self.assertIn("sess-doctor", out)
        self.assertIn("200000", out)

    def test_doctor_output_is_plain_text_not_json(self):
        repo = self.make_repo()
        code, out = self.run_cli("doctor", "--cwd", str(repo))
        with self.assertRaises(_json.JSONDecodeError):
            _json.loads(out)

    def test_doctor_reports_log_content_when_present(self):
        # The exception log is process-wide (state_root()/handoff.log), not
        # per repo: there is no repo tag on a traceback dump to filter by.
        # doctor surfaces it anyway, because a log nothing ever looks at is
        # exactly the gap that let precompact.py's invalid JSON survive a
        # whole build unnoticed (finding I4).
        repo = self.make_repo()
        log_path = hs.state_root() / "handoff.log"
        log_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.write_text("Traceback (most recent call last):\nSomeError: boom\n", encoding="utf-8")
        code, out = self.run_cli("doctor", "--cwd", str(repo))
        self.assertIn("SomeError: boom", out)


class TestResumeReady(TempState):
    """A handoff written after the nudge is what arms the resume, and it arms
    exactly once.
    """

    def write_handoff(self, repo, mtime: float) -> None:
        target = hs.paths(repo)["current"]
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("---\ngoal: ship it\n---\n\n## Next steps\n1. go\n",
                          encoding="utf-8")
        os.utime(target, (mtime, mtime))

    def test_no_nudge_means_never_ready(self):
        repo = str(self.make_repo())
        self.write_handoff(repo, 2000.0)
        self.assertFalse(hs.resume_ready(repo, {}))

    def test_handoff_older_than_the_nudge_is_not_ready(self):
        repo = str(self.make_repo())
        self.write_handoff(repo, 1000.0)
        self.assertFalse(hs.resume_ready(repo, {"nudged_at": 2000.0}))

    def test_handoff_written_after_the_nudge_is_ready(self):
        repo = str(self.make_repo())
        self.write_handoff(repo, 3000.0)
        self.assertTrue(hs.resume_ready(repo, {"nudged_at": 2000.0}))

    def test_already_resumed_is_never_ready_again(self):
        repo = str(self.make_repo())
        self.write_handoff(repo, 3000.0)
        stamp = {"nudged_at": 2000.0, "resumed": True}
        self.assertFalse(hs.resume_ready(repo, stamp))

    def test_missing_handoff_is_not_ready(self):
        repo = str(self.make_repo())
        self.assertFalse(hs.resume_ready(repo, {"nudged_at": 2000.0}))

    def test_a_string_nudged_at_still_works(self):
        # The `stamp --set k=v` CLI verb, removed with OpenCode on 2026-10-03,
        # wrote every value as a string, and stamps it wrote can still sit in
        # the state root carrying "2000.0" rather than 2000.0.
        repo = str(self.make_repo())
        self.write_handoff(repo, 3000.0)
        self.assertTrue(hs.resume_ready(repo, {"nudged_at": "2000.0"}))

    def test_a_junk_nudged_at_is_not_ready_rather_than_raising(self):
        repo = str(self.make_repo())
        self.write_handoff(repo, 3000.0)
        self.assertFalse(hs.resume_ready(repo, {"nudged_at": "soon"}))


class TestResumeReadyRequiresARealHandoff(TempState):
    """A current.md can exist on disk, newer than the nudge, and still be
    nothing read_handoff calls real: frontmatter missing `goal:` reads back
    as exists=False (see read_handoff's docstring). resume_ready used to ask
    only handoff_mtime, a raw stat() with no opinion on content, so it could
    answer True for a file every other consumer of the brain calls absent.
    A model writing 20 KB of frontmatter and prose is exactly the actor
    likely to drop that key, and the consequence was stop.py resuming into,
    and burning its one-shot stamp on, a handoff the rest of the system
    reports as not there.
    """

    def test_malformed_frontmatter_does_not_arm_the_resume(self):
        repo = str(self.make_repo())
        target = hs.paths(repo)["current"]
        target.parent.mkdir(parents=True, exist_ok=True)
        # `notgoal`, not `goal`: parse_frontmatter still reads a pair here,
        # so this is the wrong-key slip the finding names, not a file that
        # fails to parse at all.
        target.write_text("---\nnotgoal: nope\n---\n\n## Next steps\n1. go\n",
                          encoding="utf-8")
        os.utime(target, (3000.0, 3000.0))
        # Sanity: if read_handoff ever started calling this real, the
        # assertion below would stop testing anything.
        self.assertFalse(hs.read_handoff(repo)["exists"])
        self.assertFalse(hs.resume_ready(repo, {"nudged_at": 2000.0}))

    def test_handoff_mtime_itself_keeps_its_own_contract(self):
        # The fix belongs inside resume_ready. handoff_mtime is a thin "when
        # was this file last written" helper other things may rely on, and
        # must keep answering from the raw stat() alone, blind to content.
        repo = str(self.make_repo())
        target = hs.paths(repo)["current"]
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text("---\nnotgoal: nope\n---\n\n## Next steps\n1. go\n",
                          encoding="utf-8")
        os.utime(target, (3000.0, 3000.0))
        self.assertEqual(hs.handoff_mtime(repo), 3000.0)


class TestContinueClauseIsShared(unittest.TestCase):
    def test_the_brain_owns_the_clause(self):
        self.assertIn("does not end the turn", hs.CONTINUE_CLAUSE)
        self.assertIn("next step", hs.CONTINUE_CLAUSE)


class TestProjectOwned(unittest.TestCase):
    """Design spec 2026-08-23-plane-integration-design.md §5.2: a repo
    declares that it writes its own handoff elsewhere by carrying
    `.claude/handoff.json` with `{"owner": "project"}`. Deliberately generic
    -- this module never learns which tracker or file the project uses, only
    that it has one -- so no HANDOFF_STATE_ROOT sandbox is needed here:
    project_owned() never touches state_root(), only the given cwd."""

    def test_project_owned_is_false_without_a_marker(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertFalse(hs.project_owned(tmp))

    def test_project_owned_is_true_when_the_marker_claims_it(self):
        with tempfile.TemporaryDirectory() as tmp:
            claude = Path(tmp) / ".claude"
            claude.mkdir()
            (claude / "handoff.json").write_text('{"owner": "project"}', encoding="utf-8")
            self.assertTrue(hs.project_owned(tmp))

    def test_a_marker_naming_another_owner_does_not_stand_down(self):
        with tempfile.TemporaryDirectory() as tmp:
            claude = Path(tmp) / ".claude"
            claude.mkdir()
            (claude / "handoff.json").write_text('{"owner": "skill"}', encoding="utf-8")
            self.assertFalse(hs.project_owned(tmp))

    def test_a_corrupt_marker_does_not_stand_down(self):
        with tempfile.TemporaryDirectory() as tmp:
            claude = Path(tmp) / ".claude"
            claude.mkdir()
            (claude / "handoff.json").write_text("{not json", encoding="utf-8")
            self.assertFalse(hs.project_owned(tmp))

    # Fix round 1: project_owned's own never-raise promise. git_root() hands
    # `cwd` straight to subprocess.run's argv, which raises TypeError for
    # anything that is not str/bytes/os.PathLike -- one test per input class,
    # so the guard's contract is explicit rather than implied by the four
    # tests above (which only ever pass a str).

    def test_none_input_is_false_without_a_marker_and_does_not_raise(self):
        # None means "use the real process cwd" (git_root's own fallback).
        # That must not depend on wherever this suite happens to be invoked
        # from, so chdir into a fresh, marker-free, non-git directory for the
        # duration of the call rather than trust the runner's real location.
        with tempfile.TemporaryDirectory() as tmp:
            previous = os.getcwd()
            os.chdir(tmp)
            self.addCleanup(os.chdir, previous)
            self.assertFalse(hs.project_owned(None))

    def test_str_input_legitimately_finds_a_marker(self):
        with tempfile.TemporaryDirectory() as tmp:
            claude = Path(tmp) / ".claude"
            claude.mkdir()
            (claude / "handoff.json").write_text('{"owner": "project"}', encoding="utf-8")
            self.assertTrue(hs.project_owned(tmp))

    def test_path_input_legitimately_finds_a_marker(self):
        # os.PathLike, not just str: subprocess.run and Path() both accept a
        # Path object directly, so this must work end to end, not merely
        # fail to raise.
        with tempfile.TemporaryDirectory() as tmp:
            claude = Path(tmp) / ".claude"
            claude.mkdir()
            (claude / "handoff.json").write_text('{"owner": "project"}', encoding="utf-8")
            self.assertTrue(hs.project_owned(Path(tmp)))

    def test_int_input_is_false_and_does_not_raise(self):
        self.assertFalse(hs.project_owned(42))

    def test_float_input_is_false_and_does_not_raise(self):
        self.assertFalse(hs.project_owned(4.2))

    def test_bool_input_is_false_and_does_not_raise(self):
        # bool is an int subclass in Python; called out separately from the
        # int case because that is the classic trap for an isinstance guard
        # written the other way around (e.g. excluding int would still let a
        # bool through).
        self.assertFalse(hs.project_owned(True))

    def test_list_input_is_false_and_does_not_raise(self):
        self.assertFalse(hs.project_owned(["not", "a", "path"]))

    def test_dict_input_is_false_and_does_not_raise(self):
        self.assertFalse(hs.project_owned({"not": "a path"}))


if __name__ == "__main__":
    unittest.main()


class TestResolveProject(unittest.TestCase):
    """The directory is a suggestion, never a decision. The rule that decides
    when to ask lives in SKILL.md; this only has to answer honestly, including
    answering None, because None is what makes the model ask."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        cfg = Path(self._tmp.name) / "projects.json"
        cfg.write_text(_json.dumps({"workspaces": {"personal": {
            "default": True,
            "projects": {
                "VAULT": {"id": "u-vault", "name": "Vault", "dirs": ["/w/vault"]},
                "TOOLS": {"id": "u-tools", "name": "Tools",
                          "dirs": ["/w/dotfiles", "/w/tools"]},
                "LIFE": {"id": "u-life", "name": "Life", "dirs": []}}}}}))
        os.environ["HANDOFF_PROJECTS"] = str(cfg)
        self.addCleanup(os.environ.pop, "HANDOFF_PROJECTS", None)

    def test_an_exact_directory_resolves(self):
        got = hs.resolve_project("/w/vault")
        self.assertEqual(got["identifier"], "VAULT")
        self.assertEqual(got["workspace"], "personal")
        self.assertEqual(got["id"], "u-vault")

    def test_a_subdirectory_resolves_to_its_ancestor(self):
        self.assertEqual(hs.resolve_project("/w/vault/SAP")["identifier"], "VAULT")

    def test_a_second_directory_on_the_same_project_resolves(self):
        self.assertEqual(hs.resolve_project("/w/tools")["identifier"], "TOOLS")

    def test_the_longest_matching_directory_wins(self):
        """Otherwise a nested tree resolves to whichever parent came first in
        the file, which is a silent wrong answer rather than a visible one."""
        cfg = _json.loads(Path(os.environ["HANDOFF_PROJECTS"]).read_text())
        cfg["workspaces"]["personal"]["projects"]["TOOLS"]["dirs"].append("/w/vault/.agents")
        Path(os.environ["HANDOFF_PROJECTS"]).write_text(_json.dumps(cfg))
        self.assertEqual(hs.resolve_project("/w/vault/.agents/x")["identifier"], "TOOLS")

    def test_an_unmapped_directory_resolves_to_nothing(self):
        self.assertIsNone(hs.resolve_project("/somewhere/else"))

    def test_no_cwd_resolves_to_nothing(self):
        self.assertIsNone(hs.resolve_project(None))

    def test_a_missing_config_resolves_to_nothing_rather_than_raising(self):
        os.environ["HANDOFF_PROJECTS"] = "/nonexistent/projects.json"
        self.assertIsNone(hs.resolve_project("/w/vault"))
        self.assertEqual(hs.load_projects(), {})


class TestPerSessionPointer(unittest.TestCase):
    """One slot per repository is what this design removes. Two sessions in one
    directory must be able to hold two different streams at once."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        os.environ["HANDOFF_STATE_ROOT"] = str(Path(self._tmp.name) / "state")
        self.addCleanup(os.environ.pop, "HANDOFF_STATE_ROOT", None)
        self.repo = str(Path(self._tmp.name) / "repo")
        os.makedirs(self.repo)

    def test_an_unset_pointer_reads_as_empty(self):
        self.assertEqual(hs.read_pointer("s1"), {})

    def test_a_written_pointer_reads_back(self):
        hs.write_pointer("s1", {"workspace": "personal",
                                           "project_id": "u-tools",
                                           "parent_id": "i-1",
                                           "identifier": "TOOLS-12"})
        self.assertEqual(hs.read_pointer("s1")["identifier"], "TOOLS-12")

    def test_two_sessions_in_one_directory_hold_different_streams(self):
        hs.write_pointer("s1", {"identifier": "TOOLS-12"})
        hs.write_pointer("s2", {"identifier": "VAULT-3"})
        self.assertEqual(hs.read_pointer("s1")["identifier"], "TOOLS-12")
        self.assertEqual(hs.read_pointer("s2")["identifier"], "VAULT-3")

    def test_clearing_one_session_leaves_the_other(self):
        hs.write_pointer("s1", {"identifier": "TOOLS-12"})
        hs.write_pointer("s2", {"identifier": "VAULT-3"})
        hs.clear_pointer("s1")
        self.assertEqual(hs.read_pointer("s1"), {})
        self.assertEqual(hs.read_pointer("s2")["identifier"], "VAULT-3")

    def test_a_claim_is_visible_from_the_projects_other_directory(self):
        """The test TOOLS-25 names as the one that does not exist.

        TOOLS declares both ~/Sync/dotfiles and ~/src/tools. One
        session claiming in one of them must be readable from the other, or a
        session started in the second silently has no stream while the board
        prints "No stream claimed". The session is the identity; the directory
        is not.
        """
        other = str(Path(self._tmp.name) / "second-declared-dir")
        os.makedirs(other)
        hs.write_pointer("s1", {"identifier": "TOOLS-11"})
        self.assertEqual(
            hs.read_pointer("s1").get("identifier"), "TOOLS-11")

    def test_a_claim_is_visible_from_a_subdirectory_of_the_same_tree(self):
        """repo_key falls back to the literal path outside a git repo, and
        ~/Sync/dotfiles is deliberately not one, so every subdirectory got
        its own key and its own empty pointer."""
        sub = str(Path(self.repo) / "scripts")
        os.makedirs(sub)
        hs.write_pointer("s1", {"identifier": "TOOLS-11"})
        self.assertEqual(
            hs.read_pointer("s1").get("identifier"), "TOOLS-11")


class TestSiblingProjects(TempState):
    """Which projects the fallback sweep is allowed to read. One workspace only:
    the two workspaces' boards are different audiences, and a session in the
    vault has no business being shown another audience's board."""

    def setUp(self):
        super().setUp()
        cfg = self.root / "projects.json"
        cfg.write_text(_json.dumps({"workspaces": {
            "personal": {"default": True, "projects": {
                "VAULT": {"id": "u-vault", "name": "Vault", "dirs": ["/w/vault"]},
                "TOOLS": {"id": "u-tools", "name": "Tools", "dirs": []},
                "LAB": {"id": "u-lab", "name": "Homelab", "dirs": []}}},
            "work": {"projects": {
                "CLIENT": {"id": "u-client", "name": "Client", "dirs": []}}}}}))
        os.environ["HANDOFF_PROJECTS"] = str(cfg)
        self.addCleanup(os.environ.pop, "HANDOFF_PROJECTS", None)

    def test_the_others_in_the_same_workspace_come_back(self):
        got = hs.sibling_projects("personal", "u-vault")
        self.assertEqual([p["identifier"] for p in got], ["TOOLS", "LAB"])

    def test_the_project_itself_is_excluded(self):
        self.assertNotIn("u-vault",
                         [p["id"] for p in hs.sibling_projects("personal", "u-vault")])

    def test_another_workspace_is_never_swept(self):
        self.assertNotIn("CLIENT",
                         [p["identifier"] for p in hs.sibling_projects("personal", "u-vault")])

    def test_an_unknown_workspace_sweeps_nothing(self):
        self.assertEqual(hs.sibling_projects("nope", "u-vault"), [])


class TestLayoutFromSkillValues(TempState):
    """The layout is the skill value `handoff.workspaces`, not a file in the
    skill: ravnix renders it from the private flake (claude/skills/README.md).
    HANDOFF_PROJECTS stays the tests' seam and wins over the value."""

    LAYOUT = {"home": {"default": True, "projects": {
        "NOTES": {"id": "u-notes", "name": "Notes", "dirs": ["/w/notes"]}}},
        "work": {"projects": {"CLIENT": {"id": "u-client", "name": "Client", "dirs": []}}}}

    def setUp(self):
        super().setUp()
        self.values = self.root / "skill-values.json"
        os.environ["RAVNIX_SKILL_VALUES"] = str(self.values)
        self.addCleanup(os.environ.pop, "RAVNIX_SKILL_VALUES", None)
        os.environ.pop("HANDOFF_PROJECTS", None)

    def write(self, values):
        self.values.write_text(_json.dumps(values), encoding="utf-8")

    def run_cli(self, *args):
        env = subprocess_env(HANDOFF_STATE_ROOT=str(self.root / "state"),
                             RAVNIX_SKILL_VALUES=str(self.values))
        env.pop("HANDOFF_PROJECTS", None)
        return subprocess.run([sys.executable, "-B", str(BRAIN), *args],
                              capture_output=True, text=True, env=env)

    def test_the_layout_is_the_skill_value(self):
        self.write({"handoff": {"workspaces": self.LAYOUT}})
        self.assertEqual(hs.load_projects(), {"workspaces": self.LAYOUT})
        self.assertEqual(hs.resolve_project("/w/notes/x")["identifier"], "NOTES")

    def test_no_value_is_no_layout(self):
        self.write({})
        self.assertEqual(hs.load_projects(), {})
        self.assertIsNone(hs.resolve_project("/w/notes"))

    def test_a_layout_that_is_not_an_object_is_no_layout(self):
        self.write({"handoff": {"workspaces": ["home"]}})
        self.assertEqual(hs.load_projects(), {})

    def test_the_file_seam_wins(self):
        self.write({"handoff": {"workspaces": self.LAYOUT}})
        seam = self.root / "projects.json"
        seam.write_text(_json.dumps({"workspaces": {}}), encoding="utf-8")
        os.environ["HANDOFF_PROJECTS"] = str(seam)
        self.addCleanup(os.environ.pop, "HANDOFF_PROJECTS", None)
        self.assertEqual(hs.load_projects(), {"workspaces": {}})

    def test_the_default_workspace_is_the_one_marked(self):
        self.write({"handoff": {"workspaces": self.LAYOUT}})
        self.assertEqual(hs.default_workspace(), "home")

    def test_a_single_workspace_is_the_default(self):
        self.write({"handoff": {"workspaces": {"only": {"projects": {}}}}})
        self.assertEqual(hs.default_workspace(), "only")

    def test_two_unmarked_workspaces_have_no_default(self):
        self.write({"handoff": {"workspaces": {"a": {}, "b": {}}}})
        self.assertEqual(hs.default_workspace(), "")

    def test_projects_without_the_value_stops_and_names_the_key(self):
        self.write({})
        done = self.run_cli("projects", "--cwd", "/w/notes")
        self.assertEqual(done.returncode, 2, done.stderr)
        self.assertIn("set `handoff.workspaces` in your ravnix skill values", done.stderr)
        self.assertEqual(done.stdout, "")

    def test_projects_with_the_value_resolves(self):
        self.write({"handoff": {"workspaces": self.LAYOUT}})
        done = self.run_cli("projects", "--cwd", "/w/notes")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(_json.loads(done.stdout)["resolved"]["workspace"], "home")

    def test_claim_takes_the_default_workspace(self):
        self.write({"handoff": {"workspaces": self.LAYOUT}})
        done = self.run_cli("claim", "--session", "s1", "--project", "u-notes",
                            "--parent", "i1", "--identifier", "NOTES-1")
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(_json.loads(done.stdout)["workspace"], "home")

    def test_claim_without_any_workspace_stops_and_names_the_key(self):
        self.write({})
        done = self.run_cli("claim", "--session", "s1", "--project", "u-notes")
        self.assertEqual(done.returncode, 2)
        self.assertIn("set `handoff.workspaces` in your ravnix skill values", done.stderr)
        self.assertFalse((self.root / "state" / "_streams" / "s1.pointer.json").exists())

    def test_claim_names_a_workspace_explicitly_without_the_value(self):
        self.write({})
        done = self.run_cli("claim", "--session", "s1", "--workspace", "home",
                            "--project", "u-notes")
        self.assertEqual(done.returncode, 0, done.stderr)

    def test_the_continue_clause_names_no_one(self):
        self.assertIn("the user", hs.CONTINUE_CLAUSE)


if __name__ == "__main__":
    unittest.main()
