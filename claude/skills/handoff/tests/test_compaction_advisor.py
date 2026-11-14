# tests/test_compaction_advisor.py
"""The compaction advisor: its transcript reading, its choice, and the gates
stop.py puts around it.

The record shapes in the fixtures below are trimmed copies of real ones, read
on 2026-10-17 from transcripts on this machine: a Bash tool_use and its
tool_result, a Plane `workitem` update whose result is the item as JSON with
`completed_at`, a refused Plane call that comes back as "Error: ..." text with
`is_error` unset, a skill's text arriving as an `isMeta` user record, and the
`compact_boundary` system record a compaction writes.
"""
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ADAPTERS = Path(__file__).resolve().parents[1] / "adapters" / "claude"
sys.path.insert(0, str(ADAPTERS))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import _common  # noqa: E402
import advisor  # noqa: E402
import plane  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
from subprocess_env import subprocess_env  # noqa: E402

PARENT = "parent-uuid"


def prompt(text="go on"):
    return {"type": "user", "message": {"role": "user", "content": text}}


def say(text):
    return {"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}}


def use(tool_id, name, **args):
    return {"type": "assistant", "message": {"content": [
        {"type": "tool_use", "id": tool_id, "name": name, "input": args}]}}


def result(tool_id, content, is_error=False):
    block = {"type": "tool_result", "tool_use_id": tool_id, "content": content}
    if is_error:
        block["is_error"] = True
    return {"type": "user", "message": {"content": [block]}}


def usage(tokens):
    return {"type": "assistant", "message": {"usage": {"input_tokens": tokens}}}


def bash(tool_id, command, output, is_error=False):
    return [use(tool_id, "Bash", command=command), result(tool_id, output, is_error)]


def plane_update(tool_id, item_id, name, completed):
    item = {"result": {"id": item_id, "name": name,
                       "completed_at": "2026-10-17T09:00:00+02:00" if completed else None}}
    return [use(tool_id, "mcp__plane-personal__workitem", action="update",
                project_id="p", workitem_id=item_id, state="s-uuid"),
            result(tool_id, json.dumps(item))]


COMPACTION = {"type": "system", "subtype": "compact_boundary",
              "content": "Conversation compacted",
              "compactMetadata": {"trigger": "auto", "preTokens": 296619, "postTokens": 21082}}


def found(*records, parent=PARENT):
    return advisor.boundary(advisor.last_turn([prompt(), *records]), parent)


class TestLastTurn(unittest.TestCase):
    def test_it_starts_after_the_last_prompt(self):
        records = [prompt("first"), say("old"), prompt("second"), say("new")]
        self.assertEqual(advisor.last_turn(records), [say("new")])

    def test_a_tool_result_does_not_start_a_turn(self):
        records = [prompt(), *bash("t1", "true", "ok"), say("done")]
        self.assertEqual(len(advisor.last_turn(records)), 3)

    def test_a_loaded_skill_does_not_start_a_turn(self):
        # The skill's text arrives as a user record. Read as a prompt, it would
        # cut the turn in half and hide the commit made before it.
        skill = {"type": "user", "isMeta": True, "sourceToolUseID": "t2",
                 "message": {"content": [{"type": "text", "text": "Base directory for this skill"}]}}
        records = [prompt(), *bash("t1", 'git commit -m "x"', "[main 1a2b3c4] x"), skill]
        self.assertEqual(found(*records[1:])["kind"], "step")

    def test_a_compaction_ends_the_window_even_without_a_prompt_after_it(self):
        records = [prompt(), *bash("t1", 'git commit -m "x"', "[main 1a2b3c4] x"),
                   COMPACTION, say("summary follows")]
        self.assertEqual(advisor.last_turn(records), [say("summary follows")])

    def test_a_turn_longer_than_the_window_is_the_whole_window(self):
        records = [say("a"), say("b")]
        self.assertEqual(advisor.last_turn(records), records)


class TestCommitSignals(unittest.TestCase):
    def test_a_commit_is_a_step_and_its_subject_is_the_hint(self):
        got = found(*bash("t1", 'git commit -m "feat(x): ship it"',
                          "[main 1a2b3c4] feat(x): ship it\n 1 file changed"))
        self.assertEqual(got["kind"], "step")
        self.assertEqual(got["hint"], "commit 1a2b3c4 feat(x): ship it")
        self.assertEqual(got["commit"], "feat(x): ship it")

    def test_a_quiet_commit_is_read_from_the_log_line_after_it(self):
        # The form most of these sessions use: -q, then git log --oneline.
        got = found(*bash("t1", 'git commit -q -m "docs: a" && git log --oneline -2',
                          "rc=0\naed708c docs: a\n9f14af8 docs: older"))
        self.assertEqual(got["hint"], "commit aed708c docs: a")

    def test_a_heredoc_message_gives_the_subject_when_the_output_is_empty(self):
        command = "git commit -q -m \"$(cat <<'EOF'\nfix(y): mend it\n\nBody.\nEOF\n)\""
        self.assertEqual(found(*bash("t1", command, ""))["commit"], "fix(y): mend it")

    def test_a_plain_message_gives_the_subject_when_the_output_is_empty(self):
        command = 'git commit -q -m "chore: tidy\n\nCo-Authored-By: x"'
        self.assertEqual(found(*bash("t1", command, ""))["commit"], "chore: tidy")

    def test_a_commit_in_another_directory_counts(self):
        got = found(*bash("t1", 'git -C ~/Sync/dotfiles commit -q -m "a"', ""))
        self.assertEqual(got["kind"], "step")

    def test_a_failed_commit_is_no_boundary(self):
        self.assertIsNone(found(*bash("t1", 'git commit -m "a"', "Exit code 1", is_error=True)))

    def test_a_refused_signature_hidden_behind_an_exit_zero_is_no_boundary(self):
        # Measured: `git commit ...; echo rc=$?` reports is_error false while
        # git printed "fatal: failed to write commit object".
        output = "error: Couldn't find key in agent?\n\nfatal: failed to write commit object\nrc=128"
        self.assertIsNone(found(*bash("t1", 'git commit -m "a"; echo rc=$?', output)))

    def test_nothing_to_commit_is_no_boundary(self):
        self.assertIsNone(found(*bash("t1", "git commit -am x; true",
                                      "nothing to commit, working tree clean")))

    def test_searching_for_a_commit_command_is_no_commit(self):
        for command in ('grep -rn "git commit" .', "echo git commit"):
            with self.subTest(command=command):
                self.assertIsNone(found(*bash("t1", command, "SKILL.md:79: git commit")))

    def test_reading_history_is_no_boundary(self):
        for command in ("git log --grep commit", "git status --short", "git show HEAD"):
            with self.subTest(command=command):
                self.assertIsNone(found(*bash("t1", command, "1a2b3c4 feat: x")))

    def test_a_commit_before_the_last_prompt_is_no_boundary(self):
        records = [prompt(), *bash("t1", 'git commit -m "a"', "[main 1a2b3c4] a"),
                   prompt("next question"), say("an answer")]
        self.assertIsNone(advisor.boundary(advisor.last_turn(records), PARENT))

    def test_a_call_that_never_returned_is_no_boundary(self):
        # An interrupted tool call leaves a tool_use with no tool_result.
        self.assertIsNone(found(use("t1", "Bash", command='git commit -m "a"')))


class TestPlaneSignals(unittest.TestCase):
    def test_a_moved_sub_item_is_a_step(self):
        got = found(*plane_update("t1", "child", "F02: merge the plan", completed=False))
        self.assertEqual((got["kind"], got["hint"]), ("step", "moved F02: merge the plan"))

    def test_a_closed_sub_item_is_a_step(self):
        got = found(*plane_update("t1", "child", "F02: merge the plan", completed=True))
        self.assertEqual((got["kind"], got["hint"]), ("step", "closed F02: merge the plan"))

    def test_the_claimed_parent_closing_closes_the_stream(self):
        got = found(*plane_update("t1", PARENT, "Build the advisor", completed=True))
        self.assertEqual(got["kind"], "closed")

    def test_a_refused_plane_call_is_no_boundary(self):
        # Measured: the gateway returns this as text and leaves is_error unset.
        records = [use("t1", "mcp__plane-personal__workitem", action="update",
                       workitem_id="child", state="s"),
                   result("t1", [{"type": "text", "text": "Error: action 'update' does not take: fields."}])]
        self.assertIsNone(found(*records))

    def test_a_marked_comment_on_the_claimed_parent_is_the_handoff(self):
        records = [use("t1", "mcp__plane-personal__workitem_comment", action="create",
                       workitem_id=PARENT, comment_html=plane.HANDOFF_MARKER + "<h3>State</h3>"),
                   result("t1", '{"result": {"id": "c1"}}')]
        self.assertEqual(found(*records)["kind"], "handoff")

    def test_an_unmarked_comment_on_the_claimed_parent_is_no_handoff(self):
        # A project with its own Plane hooks wants an evidence comment on the active item when work
        # starts. Read as a handoff, it told the user to clear the session the
        # work had just begun in.
        records = [use("t1", "mcp__plane-work__workitem_comment", action="create",
                       workitem_id=PARENT, comment_html="<p>Started: branch cut.</p>"),
                   result("t1", '{"result": {"id": "c1"}}')]
        self.assertIsNone(found(*records))

    def test_the_marker_counts_only_where_the_comment_opens(self):
        records = [use("t1", "mcp__plane-personal__workitem_comment", action="create",
                       workitem_id=PARENT,
                       comment_html="<p>Quoting it:</p>" + plane.HANDOFF_MARKER),
                   result("t1", '{"result": {"id": "c1"}}')]
        self.assertIsNone(found(*records))

    def test_an_evidence_comment_on_a_step_is_no_boundary_by_itself(self):
        records = [use("t1", "mcp__plane-personal__workitem_comment", action="create",
                       workitem_id="child", comment_html="<p>Done.</p>"),
                   result("t1", '{"result": {"id": "c1"}}')]
        self.assertIsNone(found(*records))

    def test_without_a_claimed_stream_no_comment_is_a_handoff(self):
        records = [use("t1", "mcp__plane-personal__workitem_comment", action="create",
                       workitem_id=PARENT, comment_html="<p>x</p>"),
                   result("t1", '{"result": {"id": "c1"}}')]
        self.assertIsNone(found(*records, parent=""))


WRITE_SESSION_NOTE = ("python3 -B ~/.claude/skills/journal/scripts/session_note.py write "
                      "--title T --domain ai --description D --body-file /tmp/b.md")


class TestRavnixShapes(unittest.TestCase):
    """What a session on a ravnix host runs: the scripts by the store path of
    their interpreter, and the vault committed through vault-commit."""

    def test_a_store_python_still_counts_as_the_journal(self):
        command = ("/nix/store/abc-python3-3.13/bin/python3 -B "
                   "/home/a/.claude/skills/journal/scripts/session_note.py write --title T")
        got = found(*bash("t1", command, "created /v/AI/sessions/T.md"))
        self.assertEqual((got["kind"], got["hint"]), ("finished", "journal entry written"))

    def test_a_store_python_still_counts_as_a_release(self):
        command = "/nix/store/abc-python3/bin/python3 -B /s/handoff_state.py release --session s"
        self.assertEqual(found(*bash("t1", command, "{}"))["kind"], "closed")

    def test_vault_commit_is_a_commit(self):
        got = found(*bash("t1", "vault-commit 'docs(ai): add a session note' AI/sessions/T.md",
                          "[main 1a2b3c4] docs(ai): add a session note"))
        self.assertEqual(got["kind"], "step")
        self.assertIn("1a2b3c4", got["hint"])

    def test_a_queued_vault_commit_takes_its_message_from_the_command(self):
        got = found(*bash("t1", 'vault-commit "docs: queued note" AI/sessions/T.md',
                          "vault-commit: the server queued the commit"))
        self.assertEqual(got["kind"], "step")
        self.assertIn("docs: queued note", got["hint"])

    def test_a_failed_vault_commit_is_no_commit(self):
        self.assertIsNone(found(*bash("t1", "vault-commit 'x' a.md",
                                      "vault-commit: git commit failed (exit 1)",
                                      is_error=True)))

    def test_grepping_for_vault_commit_is_no_commit(self):
        self.assertIsNone(found(*bash("t1", "rg -n vault-commit SKILL.md", "SKILL.md:3: vault-commit")))


class TestOtherSignals(unittest.TestCase):
    def test_a_session_note_write_is_a_natural_break(self):
        for command in (WRITE_SESSION_NOTE,
                        "cd /x && python3 -B $HOME/.claude/skills/journal/scripts/"
                        "session_note.py write --title T --domain ai"):
            with self.subTest(command=command):
                got = found(*bash("t1", command, "created /v/AI/sessions/2026-10-17 T.md"))
                self.assertEqual((got["kind"], got["hint"]),
                                 ("finished", "journal entry written"))

    def test_an_edit_to_a_session_note_finishes_the_work(self):
        records = [use("t1", "Edit", file_path="/v/AI/sessions/2026-10-17 T.md",
                       old_string="a", new_string="b"),
                   result("t1", "ok")]
        self.assertEqual(found(*records)["kind"], "finished")

    def test_the_daily_note_is_no_longer_the_journal(self):
        for records in (bash("t1", "python3 -B ~/.claude/skills/journal/scripts/daily_note.py write --area x",
                             "written"),
                        [use("t1", "Edit", file_path="/v/daily-notes/Friday.md",
                             old_string="a", new_string="b"),
                         result("t1", "ok")]):
            with self.subTest(tool=records[0]["message"]["content"][0]["name"]):
                self.assertIsNone(found(*records))

    def test_releasing_the_stream_closes_it(self):
        got = found(*bash("t1", "python3 -B handoff_state.py release --session s", '{"released": true}'))
        self.assertEqual(got["kind"], "closed")

    def test_claiming_a_stream_is_a_change_of_topic(self):
        got = found(*bash("t1", "python3 -B handoff_state.py claim --session s --identifier TOOLS-13",
                          "{}"))
        self.assertEqual((got["kind"], got["hint"]), ("finished", "switched to TOOLS-13"))

    def test_reading_the_skills_scripts_is_no_boundary(self):
        # What a session working on these skills does all day.
        for command in ('grep -n "session_note.py write" SKILL.md',
                        "python3 -B session_note.py --help",
                        "sed -n 1,50p scripts/handoff_state.py | grep claim",
                        "sed -n 1,80p scripts/handoff_state.py | grep -n release"):
            with self.subTest(command=command):
                self.assertIsNone(found(*bash("t1", command, "79: claim release write")))

    def test_a_completed_todo_step_is_a_step(self):
        records = [use("t1", "TaskUpdate", taskId="1", status="completed"), result("t1", "ok")]
        self.assertEqual(found(*records)["kind"], "step")

    def test_starting_a_todo_step_is_no_boundary(self):
        records = [use("t1", "TaskUpdate", taskId="2", status="in_progress"), result("t1", "ok")]
        self.assertIsNone(found(*records))

    def test_the_stronger_signal_wins_and_the_commit_subject_survives(self):
        got = found(*bash("t1", 'git commit -m "feat: last piece"', "[main 1a2b3c4] feat: last piece"),
                    *bash("t2", WRITE_SESSION_NOTE, "written"))
        self.assertEqual(got["kind"], "finished")
        self.assertEqual(got["commit"], "feat: last piece")

    def test_an_ordinary_turn_is_no_boundary(self):
        self.assertIsNone(found(*bash("t1", "pytest -q", "3 passed"), say("All green.")))


class TestToolShare(unittest.TestCase):
    def test_tool_traffic_dominates_a_working_turn(self):
        records = [prompt("fix it"), *bash("t1", "cat big.log", "x" * 5000), say("Fixed.")]
        self.assertGreater(advisor.tool_share(records), advisor.TOOL_SHARE)

    def test_conversation_dominates_a_discussion(self):
        records = [prompt("y" * 3000), say("z" * 3000), *bash("t1", "ls", "a")]
        self.assertLess(advisor.tool_share(records), advisor.TOOL_SHARE)

    def test_nothing_to_count_is_none(self):
        self.assertIsNone(advisor.tool_share([usage(5)]))

    def test_what_a_compaction_dropped_does_not_count(self):
        records = [*bash("t1", "cat big.log", "x" * 50000), COMPACTION,
                   prompt("y" * 3000), say("z" * 3000)]
        self.assertLess(advisor.tool_share(records), advisor.TOOL_SHARE)

    def test_injected_text_counts_as_tool_traffic(self):
        skill = {"type": "user", "isMeta": True,
                 "message": {"content": [{"type": "text", "text": "s" * 5000}]}}
        self.assertGreater(advisor.tool_share([prompt("go"), skill]), advisor.TOOL_SHARE)


class TestRecommend(unittest.TestCase):
    STEP = {"kind": "step", "hint": "commit x", "commit": "x"}

    def test_the_table(self):
        cases = [
            ({"kind": "handoff"}, 0.9, "clear+resume"),
            ({"kind": "closed"}, 0.9, "clear"),
            ({"kind": "finished"}, 0.9, "handoff+clear"),
            ({"kind": "finished"}, 0.1, "handoff+clear"),
            (self.STEP, 0.9, "compact"),
            (self.STEP, 0.1, "handoff+compact"),
            (None, 0.9, "compact"),
            (None, 0.1, "handoff+compact"),
            (self.STEP, None, "compact"),
        ]
        for found_, share, want in cases:
            with self.subTest(found=found_, share=share):
                self.assertEqual(advisor.recommend(found_, share), want)

    def test_every_action_has_its_wording(self):
        actions = {advisor.recommend(f, s) for f, s in (
            ({"kind": "handoff"}, 1), ({"kind": "closed"}, 1), ({"kind": "finished"}, 1),
            (None, 1), (None, 0))}
        self.assertEqual(actions, set(advisor.SHORT))
        self.assertEqual(set(advisor.SHORT), set(advisor.WHY))


class TestRender(unittest.TestCase):
    def test_compact_is_ready_to_paste_with_the_stream_and_the_commit(self):
        step = {"kind": "step", "hint": "commit 1a2b3c4 feat: x", "commit": "feat: x"}
        text = advisor.render("soft", 231_400, ", on TOOLS-12", "TOOLS-12", step, "compact", 487_000)
        self.assertIn("231,400 tokens, on TOOLS-12", text)
        self.assertIn("Natural break: commit 1a2b3c4 feat: x.", text)
        self.assertIn('Suggest: /compact Focus on TOOLS-12; last commit "feat: x".', text)
        self.assertNotIn("487,000", text)

    def test_compact_without_a_stream_still_names_the_commit(self):
        self.assertEqual(advisor.suggestion("compact", "", "feat: x"),
                         '/compact Last commit "feat: x".')
        self.assertEqual(advisor.suggestion("compact", "", ""), "/compact")

    def test_a_clipped_hint_does_not_end_in_four_dots(self):
        long = {"kind": "step", "hint": advisor._clip("commit 1a2b3c4 " + "x" * 80), "commit": ""}
        text = advisor.render("soft", 1, "", "", long, "compact", 487_000)
        self.assertIn("...\n", text)
        self.assertNotIn("....", text)

    def test_hard_mid_work_says_why_it_speaks_without_a_break(self):
        text = advisor.render("hard", 412_000, "", "", None, "compact", 487_000)
        self.assertIn("No natural break yet", text)
        self.assertIn("487,000", text)

    def test_a_written_handoff_says_how_to_pick_it_up(self):
        text = advisor.render("soft", 1, "", "TOOLS-12", {"kind": "handoff", "hint": "handoff posted"},
                              "clear+resume", 487_000)
        self.assertIn('/clear, then say "resume TOOLS-12".', text)


class TestTheTailReaderStaysInTheTail(unittest.TestCase):
    """A transcript can run to hundreds of megabytes, and this runs at every
    turn end. Proven by counting the bytes actually read, not by timing."""

    def test_no_more_than_the_tail_is_ever_read(self):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as fh:
            filler = json.dumps(say("x" * 1000)) + "\n"
            fh.write(filler * 4000)  # about 4 MB in front of the tail
            fh.write(json.dumps(prompt()) + "\n" + json.dumps(usage(123)) + "\n")
            path = fh.name
        self.addCleanup(os.unlink, path)

        reads = []
        real_open = open

        class Counting:
            def __init__(self, fh):
                self.fh = fh

            def __enter__(self):
                return self

            def __exit__(self, *_exc):
                self.fh.close()

            def seek(self, *args):
                return self.fh.seek(*args)

            def tell(self):
                return self.fh.tell()

            def read(self, *args):
                data = self.fh.read(*args)
                reads.append(len(data))
                return data

        _common.open = lambda *a, **k: Counting(real_open(*a, **k))
        self.addCleanup(delattr, _common, "open")

        records = _common.tail_records(path)
        self.assertEqual(records[-1], usage(123))
        self.assertLessEqual(sum(reads), _common.TAIL_BYTES)


class TestStopDrivesTheAdvisor(unittest.TestCase):
    """stop.py end to end, as a subprocess, against a throwaway state root and
    with no session bus, so nothing pops on the user's desktop."""

    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        state = str(Path(self._tmp.name) / "state")
        os.environ["HANDOFF_STATE_ROOT"] = state
        self.addCleanup(os.environ.pop, "HANDOFF_STATE_ROOT", None)
        empty = Path(self._tmp.name) / "projects.json"
        empty.write_text("{}")
        self.env = subprocess_env(HANDOFF_STATE_ROOT=state, HANDOFF_PROJECTS=str(empty))
        self.repo = str(Path(self._tmp.name) / "repo")
        os.makedirs(self.repo)
        self.transcript = Path(self._tmp.name) / "t.jsonl"

    def stop(self, tokens, *turn, extra=None):
        records = [prompt(), *turn, usage(tokens)]
        self.transcript.write_text("".join(json.dumps(r) + "\n" for r in records))
        payload = {"session_id": "s1", "cwd": self.repo,
                   "transcript_path": str(self.transcript), **(extra or {})}
        done = subprocess.run([sys.executable, str(ADAPTERS / "stop.py")],
                              input=json.dumps(payload), capture_output=True,
                              text=True, env=self.env)
        self.assertEqual(done.returncode, 0, done.stderr)
        return json.loads(done.stdout) if done.stdout.strip() else None

    def commit(self, subject="feat: x"):
        return bash("t1", f'git commit -m "{subject}"', f"[main 1a2b3c4] {subject}")

    def stamp(self):
        return _common.hs.read_stamp(self.repo, "s1")

    def test_mid_work_in_the_soft_band_it_waits_and_stays_armed(self):
        self.assertIsNone(self.stop(250_000, *bash("t1", "pytest", "1 failed")))
        self.assertEqual(self.stamp().get("last_fired", 0), 0)
        self.assertEqual(_common.hs.read_standdown(self.repo)["reason"], "awaiting_boundary")

    def test_the_break_that_comes_later_is_the_one_it_speaks_at(self):
        self.assertIsNone(self.stop(250_000, *bash("t1", "pytest", "1 failed")))
        got = self.stop(260_000, *self.commit("fix: the failing test"))
        self.assertIn('/compact Last commit "fix: the failing test".', got["systemMessage"])
        self.assertEqual(self.stamp()["last_fired"], 200_000)

    def test_below_the_soft_band_a_break_says_nothing(self):
        self.assertIsNone(self.stop(150_000, *self.commit()))

    def test_once_per_band_and_the_hard_band_still_speaks(self):
        self.assertIsNotNone(self.stop(250_000, *self.commit()))
        self.assertIsNone(self.stop(300_000, *self.commit("feat: y")))
        hard = self.stop(410_000, *bash("t1", "pytest", "1 failed"))
        self.assertIn("No natural break yet", hard["systemMessage"])
        self.assertEqual(self.stamp()["last_fired"], 400_000)
        self.assertIsNone(self.stop(450_000, *self.commit("feat: z")))

    def test_it_re_arms_once_the_context_has_been_compacted(self):
        # No PreCompact ran here: the smaller context alone re-arms the bands.
        _common.hs.write_stamp(self.repo, "s1", {"last_fired": 400_000})
        self.assertIsNone(self.stop(30_000, say("after the compaction")))
        self.assertEqual(self.stamp()["last_fired"], 0)
        self.assertIsNotNone(self.stop(220_000, *self.commit()))

    def test_stop_hook_active_wins_even_at_a_break(self):
        _common.hs.write_stamp(self.repo, "s1", {"last_fired": 0})
        self.assertIsNone(self.stop(250_000, *self.commit(), extra={"stop_hook_active": True}))
        self.assertEqual(self.stamp(), {"last_fired": 0})

    def test_finished_work_gets_a_handoff_and_a_fresh_session(self):
        got = self.stop(250_000, *bash("t1", WRITE_SESSION_NOTE, "ok"))
        self.assertIn('say "handoff", then /clear.', got["systemMessage"])

    def test_a_discussion_gets_a_handoff_before_the_compaction(self):
        got = self.stop(250_000, say("w" * 4000), prompt("v" * 4000), *self.commit())
        self.assertIn('say "handoff", then /compact.', got["systemMessage"])

    def test_a_handoff_just_posted_gets_a_fresh_session_that_resumes_it(self):
        _common.hs.write_pointer("s1", {"identifier": "TOOLS-12", "parent_id": PARENT})
        got = self.stop(250_000,
                        use("t1", "mcp__plane-personal__workitem_comment", action="create",
                            workitem_id=PARENT,
                            comment_html=plane.HANDOFF_MARKER + "<h3>State</h3>"),
                        result("t1", '{"result": {"id": "c1"}}'))
        self.assertIn('/clear, then say "resume TOOLS-12".', got["systemMessage"])

    def test_it_never_costs_a_model_turn(self):
        for tokens, turn in ((250_000, self.commit()), (450_000, ())):
            with self.subTest(tokens=tokens):
                _common.hs.write_stamp(self.repo, "s1", {})
                got = self.stop(tokens, *turn)
                self.assertEqual(set(got), {"systemMessage"})


if __name__ == "__main__":
    unittest.main()
