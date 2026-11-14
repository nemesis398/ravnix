# tests/test_daily_note.py
import json
import subprocess
import os
import sys
import tempfile
import unittest
from datetime import date
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
import daily_note as dn  # noqa: E402

TEMPLATE = """## ✅ Today

- [ ] 

## \U0001f4dd Capture

*(dump anything, `/scribe` sorts it into real notes later)*

## \U0001f5d2️ Logbook

*(one line: what you did today, feeds [[{{date:GGGG-[W]WW}}]]; create the weekly via Calendar's week number, not this link)*

- 
"""


PROTECTED = "## \U0001f5d2\ufe0f Logbook"

# The pure splice tests read the protected section too; the whole module runs
# with the value, and VaultCase writes its own copy per test.
_MODULE_VALUES = tempfile.TemporaryDirectory()


def setUpModule():
    path = Path(_MODULE_VALUES.name) / "skill-values.json"
    path.write_text(json.dumps({"journal": {"protectedSection": PROTECTED}}), encoding="utf-8")
    os.environ["RAVNIX_SKILL_VALUES"] = str(path)


def tearDownModule():
    os.environ.pop("RAVNIX_SKILL_VALUES", None)
    _MODULE_VALUES.cleanup()


class VaultCase(unittest.TestCase):
    """A throwaway vault, so no test can touch the real one."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.vault = Path(self.tmp.name)
        (self.vault / "daily-notes").mkdir()
        (self.vault / "templates").mkdir()
        (self.vault / "templates" / "Daily Note.md").write_text(TEMPLATE, encoding="utf-8")
        self.previous = os.environ.get("JOURNAL_VAULT")
        os.environ["JOURNAL_VAULT"] = str(self.vault)
        self.addCleanup(self._restore)

        # The section of the daily note that is the user's alone, a skill
        # value. The fixtures below hold it as the Logbook.
        self.values = Path(self.tmp.name) / "skill-values.json"
        self.values.write_text(json.dumps(
            {"journal": {"protectedSection": PROTECTED}}), encoding="utf-8")
        self.previous_values = os.environ.get("RAVNIX_SKILL_VALUES")
        os.environ["RAVNIX_SKILL_VALUES"] = str(self.values)
        self.addCleanup(self._restore_values)

        # Pinned the same way JOURNAL_VAULT is: without this, every
        # write_entry in the suite flocks the real
        # ~/.local/state/agent-journal/notes.lock and creates that
        # directory on a machine that has never journaled, and can block
        # on a live Stop-hook write.
        self.state = tempfile.TemporaryDirectory()
        self.addCleanup(self.state.cleanup)
        self.previous_state = os.environ.get("JOURNAL_STATE_ROOT")
        os.environ["JOURNAL_STATE_ROOT"] = self.state.name
        self.addCleanup(self._restore_state)

    def _restore_values(self):
        if self.previous_values is None:
            os.environ.pop("RAVNIX_SKILL_VALUES", None)
        else:
            os.environ["RAVNIX_SKILL_VALUES"] = self.previous_values

    def _restore(self):
        if self.previous is None:
            os.environ.pop("JOURNAL_VAULT", None)
        else:
            os.environ["JOURNAL_VAULT"] = self.previous

    def _restore_state(self):
        if self.previous_state is None:
            os.environ.pop("JOURNAL_STATE_ROOT", None)
        else:
            os.environ["JOURNAL_STATE_ROOT"] = self.previous_state


class TestNoteName(VaultCase):
    def test_matches_the_vault_convention(self):
        self.assertEqual(
            dn.note_name(date(2026, 8, 9)), "Sunday, 09. Aug 2026 (W32).md"
        )

    def test_monday_rolls_the_iso_week(self):
        self.assertEqual(
            dn.note_name(date(2026, 8, 10)), "Monday, 10. Aug 2026 (W33).md"
        )

    def test_january_first_can_belong_to_the_previous_iso_year(self):
        # 2027-01-01 is a Friday in ISO week 53 of 2026. A note named W01
        # here would sort into the wrong weekly Logbook.
        self.assertEqual(
            dn.note_name(date(2027, 1, 1)), "Friday, 01. Jan 2027 (W53).md"
        )

    def test_a_single_digit_iso_week_is_not_padded(self):
        # "[W]W" in the vault's own .obsidian/daily-notes.json is moment's
        # *unpadded* week token. daily-notes/Friday, 13. Feb 2026 (W7).md is
        # the proof: "(W07)" from a padded implementation would silently
        # start a second note for the same day.
        self.assertEqual(
            dn.note_name(date(2026, 2, 13)), "Friday, 13. Feb 2026 (W7).md"
        )

    def test_is_not_affected_by_the_time_locale(self):
        # strftime("%A") follows LC_TIME and would yield "Sonntag" here.
        import locale
        try:
            locale.setlocale(locale.LC_TIME, "de_DE.UTF-8")
        except locale.Error:
            self.skipTest("de_DE.UTF-8 not generated on this machine")
        try:
            self.assertEqual(
                dn.note_name(date(2026, 8, 9)), "Sunday, 09. Aug 2026 (W32).md"
            )
        finally:
            locale.setlocale(locale.LC_TIME, "C")


class TestIsoWeekLabel(VaultCase):
    def test_new_years_day_can_belong_to_the_previous_iso_year(self):
        # 2027-01-01 is a Friday in ISO week 53 of 2026. Using d.year here
        # instead of isocalendar().year would silently produce "2027-W53",
        # a week that does not exist.
        self.assertEqual(dn.iso_week_label(date(2027, 1, 1)), "2026-W53")

    def test_late_december_can_belong_to_the_next_iso_year(self):
        # The boundary runs both ways: the ISO year can also run ahead of
        # the calendar year. Measured, not assumed:
        # date(2024, 12, 30).isocalendar() == (year=2025, week=1, weekday=1)
        self.assertEqual(dn.iso_week_label(date(2024, 12, 30)), "2025-W01")

    def test_stays_padded_for_a_date_whose_note_name_is_not(self):
        # note_name and iso_week_label now deliberately disagree on padding
        # for the same date -- pinned apart so a later reader does not
        # assume they match. iso_week_label feeds the Logbook
        # wikilink, a convention the weekly logbook notes
        # already uses padded, and must not change.
        self.assertEqual(dn.iso_week_label(date(2026, 2, 13)), "2026-W07")
        self.assertEqual(dn.note_name(date(2026, 2, 13)), "Friday, 13. Feb 2026 (W7).md")


class TestEnsureNote(VaultCase):
    def test_creates_from_the_template_and_expands_the_week(self):
        path, created = dn.ensure_note(date(2026, 8, 9))
        self.assertTrue(created)
        text = path.read_text(encoding="utf-8")
        self.assertIn("2026-W32", text)
        self.assertNotIn("{{date:", text)
        self.assertIn("## \U0001f4dd Capture", text)

    def test_writes_the_iso_year_not_the_calendar_year_into_the_wikilink(self):
        # Same boundary as TestIsoWeekLabel, but constrained at the level
        # that actually matters: the wikilink ensure_note splices in.
        path, _ = dn.ensure_note(date(2027, 1, 1))
        text = path.read_text(encoding="utf-8")
        self.assertIn("2026-W53", text)
        self.assertNotIn("2027-W53", text)

    def test_is_idempotent_and_never_overwrites(self):
        path, _ = dn.ensure_note(date(2026, 8, 9))
        path.write_text("hand written\n", encoding="utf-8")
        again, created = dn.ensure_note(date(2026, 8, 9))
        self.assertFalse(created)
        self.assertEqual(again.read_text(encoding="utf-8"), "hand written\n")


# German short tokens, moment's `monthsShort`. Six of these -- "Jan.",
# "Feb.", "Apr.", "Aug.", "Sep.", "Nov." -- happen to fall out of the
# English table too once trailing period and case are stripped, so they
# would still resolve with _MONTHS_DE_SHORT and _MONTHS_DE_LONG both
# emptied. Included for completeness, but they prove nothing on their own.
# The rest of this table -- "März", "Mai", "Juni", "Juli", "Okt.", "Dez." --
# cannot: nothing in the English table matches them.
GERMAN_SHORT_MONTHS = (
    ("Jan.", 1), ("Feb.", 2), ("März", 3), ("Apr.", 4), ("Mai", 5),
    ("Juni", 6), ("Juli", 7), ("Aug.", 8), ("Sep.", 9), ("Okt.", 10),
    ("Nov.", 11), ("Dez.", 12),
)

# The full German names. None of these can be matched by the English
# table on its own -- even the ones that share a short form with it
# ("August", "September", ...) are the wrong length and spelling once
# stripped and casefolded.
GERMAN_LONG_MONTHS = (
    ("Januar", 1), ("Februar", 2), ("März", 3), ("April", 4), ("Mai", 5),
    ("Juni", 6), ("Juli", 7), ("August", 8), ("September", 9),
    ("Oktober", 10), ("November", 11), ("Dezember", 12),
)


class TestMonthIndex(unittest.TestCase):
    """Pins `_month_index`'s German tables directly.

    `_month_index` is only ever reached through a note the iPhone wrote in
    German -- every other fixture in this suite is English -- so a table
    emptied by a later edit would pass all 63 of the rest of the tests and
    go unnoticed. This is the one test that actually exercises it.
    """

    def test_every_german_short_and_long_token_resolves(self):
        for token, expected in GERMAN_SHORT_MONTHS + GERMAN_LONG_MONTHS:
            with self.subTest(token=token):
                self.assertEqual(dn._month_index(token), expected)


class TestResolveNote(VaultCase):
    """The same day gets a German or an English filename depending on
    which device -- the iPhone or the desktop -- wrote it first.
    """

    def test_a_german_named_note_is_found_and_extended_not_duplicated(self):
        de_name = "Montag, 10. Aug. 2026 (W33).md"
        de_path = self.vault / "daily-notes" / de_name
        de_path.write_text("## \U0001f4dd Capture\n\n", encoding="utf-8")
        dn.write_entry(date(2026, 8, 10), "Claude Code", "\U0001f4ac Q", "Body.")
        notes = list((self.vault / "daily-notes").glob("*.md"))
        self.assertEqual(len(notes), 1)
        self.assertEqual(notes[0].name, de_name)
        self.assertIn("Body.", de_path.read_text(encoding="utf-8"))

    def test_no_existing_note_creates_the_canonical_english_name(self):
        what = dn.write_entry(date(2026, 8, 10), "Claude Code", "\U0001f4ac Q", "Body.")
        self.assertEqual(what, "created")
        canonical = dn.note_path(date(2026, 8, 10))
        self.assertTrue(canonical.exists())
        self.assertEqual(canonical.name, "Monday, 10. Aug 2026 (W33).md")

    def test_a_note_with_the_wrong_weekday_in_its_name_is_still_resolved(self):
        # 2026-07-30 is a Thursday; this filename says Wednesday, the same
        # mismatch already present in the real vault (see
        # daily-notes/Wednesday, 30. Jul 2026 (W31).md). The weekday and
        # the week number are not trustworthy; only day, month and year are.
        bad_name = "Wednesday, 30. Jul 2026 (W31).md"
        (self.vault / "daily-notes" / bad_name).write_text(
            "## \U0001f4dd Capture\n\n", encoding="utf-8")
        resolved = dn.resolve_note(date(2026, 7, 30))
        self.assertEqual(resolved.name, bad_name)

    def test_two_matches_prefer_the_canonical_english_name(self):
        de_name = "Montag, 10. Aug. 2026 (W33).md"
        en_name = dn.note_name(date(2026, 8, 10))
        # Sorts alphabetically before en_name, so the assertion actually
        # exercises "prefer canonical" rather than getting lucky on
        # lexicographic order (en_name already sorts before de_name on
        # its own).
        decoy = "AAA decoy, 10. Aug 2026 (W33).md"
        for name in (de_name, en_name, decoy):
            (self.vault / "daily-notes" / name).write_text(
                "## \U0001f4dd Capture\n\n", encoding="utf-8")
        resolved = dn.resolve_note(date(2026, 8, 10))
        self.assertEqual(resolved.name, en_name)

    def test_two_matches_without_the_canonical_name_resolve_deterministically(self):
        # Two notes for one day is already a broken state; resolving must
        # not make it worse by picking a different one on each run.
        a = "Montag, 10. Aug. 2026 (W33).md"
        b = "Montag, 10. Aug 2026 (W33).md"  # a plausible alternate rendering, no period
        for name in (a, b):
            (self.vault / "daily-notes" / name).write_text(
                "## \U0001f4dd Capture\n\n", encoding="utf-8")
        first = dn.resolve_note(date(2026, 8, 10))
        second = dn.resolve_note(date(2026, 8, 10))
        self.assertEqual(first, second)
        self.assertEqual(first.name, sorted([a, b])[0])


class TestResolveNoteAgainstRecordedNames(VaultCase):
    """Ground truth from a real vault: a phone with a German locale named
    10 August 2026 `Montag, 10. Aug. 2026 (W33).md`, recorded here as a
    fixture so the suite never reads a real vault.
    """

    def setUp(self):
        super().setUp()
        (self.vault / "daily-notes" / "Montag, 10. Aug. 2026 (W33).md").write_text(
            "## \u2705 Today\n", encoding="utf-8")

    def test_resolves_the_real_german_named_note_for_today(self):
        resolved = dn.resolve_note(date(2026, 8, 10))
        self.assertEqual(resolved.name, "Montag, 10. Aug. 2026 (W33).md")

    def test_falls_back_to_english_once_the_german_note_is_removed(self):
        (self.vault / "daily-notes" / "Montag, 10. Aug. 2026 (W33).md").unlink()
        resolved = dn.resolve_note(date(2026, 8, 10))
        self.assertEqual(resolved.name, "Monday, 10. Aug 2026 (W33).md")


FULL = """## ✅ Today

- [ ] 

## \U0001f4dd Capture

### Client work

#### \U0001f317 Dunkelmodus

Erster Absatz.

### Claude Code

#### \U0001f3af /goal is a session Stop hook

Probed with a condition that was already true.

## \U0001f5d2️ Logbook

- Signaturkarte erweitert.

→ [[2026-W32]]
"""

# The 13. Feb note: a raw paste with no Capture heading anywhere.
BARE = "Some pasted text with no headings at all.\n"


class TestSplice(unittest.TestCase):
    def test_new_entry_in_an_existing_area(self):
        out, what = dn.splice(FULL, "Claude Code", "\U0001f4ac Questions", "Body.")
        self.assertEqual(what, "appended")
        self.assertIn("#### \U0001f4ac Questions", out)
        # It lands inside Claude Code, not after the Logbook heading.
        self.assertLess(out.index("#### \U0001f4ac Questions"),
                        out.index("## \U0001f5d2️ Logbook"))
        self.assertGreater(out.index("#### \U0001f4ac Questions"),
                           out.index("### Claude Code"))

    def test_new_area_is_appended_inside_capture(self):
        out, what = dn.splice(FULL, "Junior Academy", "\U0001f3eb Module", "Body.")
        self.assertEqual(what, "appended")
        self.assertIn("### Junior Academy", out)
        self.assertLess(out.index("### Junior Academy"),
                        out.index("## \U0001f5d2️ Logbook"))

    def test_same_title_extends_rather_than_repeating_the_heading(self):
        out, what = dn.splice(FULL, "Client work",
                              "\U0001f31e Dunkelmodus", "Zweiter Absatz.")
        self.assertEqual(what, "extended")
        self.assertEqual(out.count("Dunkelmodus"), 1)
        self.assertIn("Erster Absatz.", out)
        self.assertIn("Zweiter Absatz.", out)

    def test_extension_matches_despite_a_different_emoji(self):
        # The model picks the emoji freshly each time; the title is the identity.
        _, what = dn.splice(FULL, "Client work",
                            "✨ dunkelmodus", "Noch einer.")
        self.assertEqual(what, "extended")

    def test_a_note_without_a_capture_heading_gets_one(self):
        out, what = dn.splice(BARE, "Claude Code", "\U0001f4ac Questions", "Body.")
        self.assertEqual(what, "created")
        self.assertIn("## \U0001f4dd Capture", out)
        self.assertIn("Some pasted text", out)

    def test_capture_is_inserted_before_the_logbook(self):
        note = "## ✅ Today\n\n## \U0001f5d2️ Logbook\n\n- One.\n"
        out, _ = dn.splice(note, "Claude Code", "\U0001f4ac Q", "Body.")
        self.assertLess(out.index("## \U0001f4dd Capture"),
                        out.index("## \U0001f5d2️ Logbook"))

    def test_the_logbook_is_never_touched(self):
        # The section is byte-for-byte identical before and after: not just
        # "still contains its bullet" but "nothing else landed in it either".
        before = FULL[FULL.index("## \U0001f5d2️ Logbook"):]
        out, _ = dn.splice(FULL, "Claude Code", "\U0001f4ac Q", "Body.")
        after = out[out.index("## \U0001f5d2️ Logbook"):]
        self.assertEqual(after, before)


# Byte-sensitive on purpose: built with explicit "\n" rather than a triple
# quote, so the two trailing spaces on the hard-break line and the exact
# count of blank lines cannot be silently reformatted away.
NOTE_WITH_HARD_BREAK = (
    "## ✅ Today\n"
    "\n"
    "## \U0001f4dd Capture\n"
    "\n"
    "### Claude Code\n"
    "\n"
    "#### Existing\n"
    "\n"
    "Body.\n"
    "\n"
    "## \U0001f5d2️ Logbook\n"
    "\n"
    "- Line with a hard break.  \n"  # trailing two spaces: a Markdown break
    "\n"
    "\n"  # a deliberate double blank line
    "- Second bullet.\n"
)

# An entry whose own body contains a line that starts with "#### " -- but
# fenced this time, the way a paste of markdown documentation actually
# looks in this vault. Round 1 tested this unfenced and asserted the
# addition landed after the whole thing; round 2's ruling made that the
# wrong answer for the unfenced case (an unfenced "#### " is knowingly
# treated as a real heading -- see `_entry_end`) and fencing is what
# actually resolves the ambiguity, so this fixture and test replace it.
#
# Round 2's version made this the only entry in its area, which happens to
# make "always insert at area_end" (round 1's bug) produce the exact same
# output as fence-aware, per-entry placement -- the fixture could not tell
# the two apart. A real sibling entry after the fence is what does: round
# 1's bug would land the addition after `Sibling paragraph.` instead of
# before `#### Sibling entry`.
ENTRY_WITH_FENCED_PASTE = """## ✅ Today

## \U0001f4dd Capture

### Claude Code

#### \U0001f3af Pasted paste

Intro line.

```
#### Not a real heading, pasted inside a fence
```

Trailing paragraph that is the entry's real last line.

#### \U0001f4ac Sibling entry

Sibling paragraph.

## \U0001f5d2️ Logbook

- One.
"""

# A 3-backtick example fenced inside a 4-backtick outer fence -- an ordinary
# way to document fenced-code syntax itself. CommonMark's rule (a closer
# must be at least as long as its opener) is what keeps the inner run from
# reading as the end of the outer fence. The inner example's own body is a
# "#### "-looking line on purpose: a naive same-length-blind toggle closes
# the outer fence two lines too early on this fixture (opener, then the
# inner ```markdown info-string line, an even count so it happens to net
# out "closed" by the time the fence ends) and would read that inner line
# as unfenced content -- and it starts with "#### ", so a length-blind scan
# stops there instead of at the entry's real end. A fixture without that
# inner heading-looking line would not observably fail against that bug,
# because nothing in the wrongly-unfenced gap would look like a stop.
ENTRY_WITH_NESTED_FENCE = (
    "## ✅ Today\n"
    "\n"
    "## \U0001f4dd Capture\n"
    "\n"
    "### Claude Code\n"
    "\n"
    "#### \U0001f4d6 Fence example\n"
    "\n"
    "Here is how a fenced entry looks in a raw paste:\n"
    "\n"
    "````\n"
    "```markdown\n"
    "#### Not a real heading, inside the inner example\n"
    "```\n"
    "````\n"
    "\n"
    "Trailing paragraph that is the entry's real last line.\n"
    "\n"
    "## \U0001f5d2️ Logbook\n"
    "\n"
    "- One.\n"
)

# An entry that opens a fence and never closes it, followed by a genuine
# sibling entry in the same area -- the fence must not be trusted to mean
# "everything after this is content" all the way to `area_end`.
ENTRY_WITH_UNCLOSED_FENCE = """## ✅ Today

## \U0001f4dd Capture

### Claude Code

#### \U0001f4dd Unclosed fence

Whoops, forgot to close this:

```
some code that never gets closed

#### \U0001f4ac Sibling entry

Sibling paragraph.

## \U0001f5d2️ Logbook

- One.
"""


class TestSpliceLeavesUntouchedTextAlone(unittest.TestCase):
    """Regression tests for a `_tidy` pass that used to rewrite the whole
    document, and for an entry-end scan that used to stop at any line
    starting with "#### " regardless of whether it was a real heading.
    """

    def test_logbook_survives_a_hard_break_and_a_blank_run_byte_for_byte(self):
        before = NOTE_WITH_HARD_BREAK[NOTE_WITH_HARD_BREAK.index("## \U0001f5d2️ Logbook"):]
        out, _ = dn.splice(NOTE_WITH_HARD_BREAK, "Claude Code", "\U0001f4ac New", "Addendum.")
        after = out[out.index("## \U0001f5d2️ Logbook"):]
        self.assertEqual(after, before)

    def test_crlf_lines_the_splice_did_not_touch_keep_their_line_ending(self):
        crlf = NOTE_WITH_HARD_BREAK.replace("\n", "\r\n")
        before = crlf[crlf.index("## \U0001f5d2️ Logbook"):]
        out, _ = dn.splice(crlf, "Claude Code", "\U0001f4ac New", "Addendum.")
        after = out[out.index("## \U0001f5d2️ Logbook"):]
        self.assertEqual(after, before)
        self.assertIn("\r\n", after)

    def test_every_line_outside_the_inserted_block_is_untouched(self):
        # Stronger than "the Logbook survives": nothing the splice did
        # not generate itself may change, including everything before the
        # insertion point too.
        prefix = FULL[:FULL.index("### Claude Code")]
        suffix = FULL[FULL.index("## \U0001f5d2️ Logbook"):]
        out, what = dn.splice(FULL, "Claude Code", "\U0001f4ac Questions", "Body.")
        self.assertEqual(what, "appended")
        self.assertTrue(out.startswith(prefix))
        self.assertTrue(out.endswith(suffix))

    def test_a_fenced_paste_inside_an_entrys_body_is_not_mistaken_for_a_heading(self):
        out, what = dn.splice(ENTRY_WITH_FENCED_PASTE, "Claude Code",
                              "\U0001f3af Pasted paste", "Addition.")
        self.assertEqual(what, "extended")
        real_last = "Trailing paragraph that is the entry's real last line."
        fenced_line = "#### Not a real heading, pasted inside a fence"
        sibling_heading = "#### \U0001f4ac Sibling entry"
        # The fenced line is still exactly where it was: after the intro,
        # before the entry's real trailing paragraph.
        self.assertLess(out.index(fenced_line), out.index(real_last))
        # The addition landed after the entry's real content -- after the
        # whole fence -- and before the sibling, not after its paragraph
        # (which is what round 1's "always area_end" bug would have done).
        self.assertLess(out.index(real_last), out.index("Addition."))
        self.assertLess(out.index("Addition."), out.index(sibling_heading))
        self.assertLess(out.index(sibling_heading), out.index("Sibling paragraph."))

    def test_a_longer_outer_fence_protects_a_shorter_inner_example(self):
        out, what = dn.splice(ENTRY_WITH_NESTED_FENCE, "Claude Code",
                              "\U0001f4d6 Fence example", "Addendum.")
        self.assertEqual(what, "extended")
        fence_block = ("````\n```markdown\n"
                       "#### Not a real heading, inside the inner example\n"
                       "```\n````")
        real_last = "Trailing paragraph that is the entry's real last line."
        # The whole outer fence, inner 3-backtick run included, comes out
        # byte-identical -- the inner run must not have been read as
        # closing the outer, shorter-would-be-illegal fence early.
        self.assertIn(fence_block, out)
        self.assertLess(out.index(fence_block), out.index(real_last))
        # The addition landed after the entry's real end, past the whole
        # fence, not spliced into the middle of it.
        self.assertLess(out.index(real_last), out.index("Addendum."))


# Two, then three, "#### " entries under one area: the ordinary shape of a
# real daily note (the vault's own 09 Aug 2026 note has four under one area
# and three under another), not an edge case.
TWO_ENTRIES = """## ✅ Today

## \U0001f4dd Capture

### Claude Code

#### \U0001f3af Entry A

Paragraph A.

#### \U0001f4ac Entry B

Paragraph B.

## \U0001f5d2️ Logbook

- One.
"""

THREE_ENTRIES = """## ✅ Today

## \U0001f4dd Capture

### Claude Code

#### \U0001f3af Entry A

Paragraph A.

#### \U0001f4ac Entry B

Paragraph B.

#### \U0001f9e9 Entry C

Paragraph C.

## \U0001f5d2️ Logbook

- One.
"""

# A second area after the one being extended, so "no following area is
# disturbed" is an assertion about real content, not an absence of content.
MULTI_AREA = """## ✅ Today

## \U0001f4dd Capture

### Claude Code

#### \U0001f3af Entry A

Paragraph A.

#### \U0001f4ac Entry B

Paragraph B.

#### \U0001f9e9 Entry C

Paragraph C.

### Another Area

#### \U0001f4cc Something Else

Unrelated content.

## \U0001f5d2️ Logbook

- One.
"""


class TestSpliceExtendsWithinMultiEntryAreas(unittest.TestCase):
    """`entry_end` used to collapse to `area_end`, which correctly capped a
    runaway scan but also erased the boundary between sibling entries: every
    extension landed at the end of the *area*, not the end of the entry
    being extended. These pin the entry-level boundary back down.
    """

    def test_extending_the_first_of_two_entries_lands_before_the_second(self):
        out, what = dn.splice(TWO_ENTRIES, "Claude Code", "\U0001f3af Entry A", "More A.")
        self.assertEqual(what, "extended")
        self.assertLess(out.index("Paragraph A."), out.index("More A."))
        self.assertLess(out.index("More A."), out.index("#### \U0001f4ac Entry B"))
        self.assertLess(out.index("#### \U0001f4ac Entry B"), out.index("Paragraph B."))

    def test_extending_the_middle_of_three_entries_lands_before_the_third(self):
        out, what = dn.splice(THREE_ENTRIES, "Claude Code", "\U0001f4ac Entry B", "More B.")
        self.assertEqual(what, "extended")
        self.assertLess(out.index("Paragraph B."), out.index("More B."))
        self.assertLess(out.index("More B."), out.index("#### \U0001f9e9 Entry C"))
        self.assertLess(out.index("#### \U0001f9e9 Entry C"), out.index("Paragraph C."))

    def test_extending_the_last_entry_lands_at_the_areas_end_undisturbing_the_next_area(self):
        before = MULTI_AREA[MULTI_AREA.index("### Another Area"):]
        out, what = dn.splice(MULTI_AREA, "Claude Code", "\U0001f9e9 Entry C", "More C.")
        self.assertEqual(what, "extended")
        self.assertLess(out.index("Paragraph C."), out.index("More C."))
        self.assertLess(out.index("More C."), out.index("### Another Area"))
        after = out[out.index("### Another Area"):]
        self.assertEqual(after, before)

    def test_an_unclosed_fence_falls_back_instead_of_swallowing_the_sibling(self):
        out, what = dn.splice(ENTRY_WITH_UNCLOSED_FENCE, "Claude Code",
                              "\U0001f4dd Unclosed fence", "Addendum.")
        self.assertEqual(what, "extended")
        sibling_heading = "#### \U0001f4ac Sibling entry"
        # An unopened-and-never-closed fence must not swallow the sibling:
        # the addition lands before the sibling's heading, not after its
        # paragraph -- the round-1 symptom, on a narrower trigger.
        self.assertLess(out.index("Addendum."), out.index(sibling_heading))
        self.assertLess(out.index(sibling_heading), out.index("Sibling paragraph."))


# The fenced blocks below are shared between the fixtures that embed them
# and the assertions that check they came back byte-identical, so the two
# cannot drift apart into a test that checks a slightly different string
# than the one the fixture actually contains.
FENCE_WITH_H3 = (
    "```markdown\n"
    "### Fixed\n"
    "\n"
    "- A crash on load.\n"
    "```\n"
)

FENCE_WITH_H2 = (
    "```markdown\n"
    "## [1.0.0] - 2026-08-09\n"
    "\n"
    "- First release.\n"
    "```\n"
)


def _note_with(fence: str) -> str:
    """A two-entry area whose first entry's body carries `fence`.

    The sibling entry sits *after* the fence on purpose: that is what makes
    a boundary truncated inside the fence observable. Both outer boundaries
    are computed from the first line that looks like a heading, so a "### "
    line in the fence truncates the area and a "## " line truncates the
    Capture section -- and in either case the sibling then falls outside
    the searched range.
    """
    return (
        "## ✅ Today\n"
        "\n"
        "## \U0001f4dd Capture\n"
        "\n"
        "### Claude Code\n"
        "\n"
        "#### \U0001f4c4 Changelog excerpt\n"
        "\n"
        "From the upstream release notes:\n"
        "\n"
        + fence +
        "\n"
        "Trailing paragraph that is the entry's real last line.\n"
        "\n"
        "#### \U0001f4ac Sibling entry\n"
        "\n"
        "Sibling paragraph.\n"
        "\n"
        "## \U0001f5d2️ Logbook\n"
        "\n"
        "- One.\n"
    )


# A changelog excerpt and a quoted release note: the two ordinary reasons a
# daily-note entry's body contains a fenced line starting with "### " or
# "## ". Neither is exotic; both were enough to corrupt the note.
NOTE_WITH_FENCED_H3 = _note_with(FENCE_WITH_H3)
NOTE_WITH_FENCED_H2 = _note_with(FENCE_WITH_H2)


class TestSpliceBoundariesAreFenceAware(unittest.TestCase):
    """`capture_end` and `area_end` were computed by a fence-blind scan
    while only the entry scan honored fences, so a fenced "### " or "## "
    line in any entry's body truncated the outer boundaries mid-fence. The
    consequence was not misplacement but corruption: the target entry fell
    outside the truncated range and was reported not found, a duplicate
    "#### " heading plus the new body was spliced literally inside the code
    block, splitting it, and the real entry was left untouched further down.
    """

    def _extend_the_sibling(self, note: str) -> tuple[str, str]:
        return dn.splice(note, "Claude Code", "\U0001f4ac Sibling entry",
                         "Addition.")

    def _assert_landed_under_the_real_sibling(self, out: str) -> None:
        # Exactly one heading with this title: a scan that cannot see the
        # real entry writes a second one instead of extending it.
        self.assertEqual(out.count("#### \U0001f4ac Sibling entry"), 1)
        self.assertLess(out.index("Sibling paragraph."), out.index("Addition."))
        self.assertLess(out.index("Addition."),
                        out.index("## \U0001f5d2️ Logbook"))

    def test_a_fenced_h3_line_does_not_truncate_the_area(self):
        out, what = self._extend_the_sibling(NOTE_WITH_FENCED_H3)
        self.assertEqual(what, "extended")
        self._assert_landed_under_the_real_sibling(out)

    def test_a_fenced_h2_line_does_not_truncate_the_capture_section(self):
        out, what = self._extend_the_sibling(NOTE_WITH_FENCED_H2)
        self.assertEqual(what, "extended")
        self._assert_landed_under_the_real_sibling(out)

    def test_the_fenced_content_is_byte_identical_after_the_splice(self):
        for label, note, fence in (
            ("### inside the fence", NOTE_WITH_FENCED_H3, FENCE_WITH_H3),
            ("## inside the fence", NOTE_WITH_FENCED_H2, FENCE_WITH_H2),
        ):
            with self.subTest(label):
                out, _ = self._extend_the_sibling(note)
                # Contiguous and once: a heading spliced into the middle of
                # the fence breaks the run into two pieces, neither of which
                # equals it.
                self.assertIn(fence, out)
                self.assertEqual(out.count(fence), 1)


# The shape of `daily-notes/Tuesday, 28. Jul 2026 (W31).md`: the full
# structure, a Capture section, no Logbook, and no trailing newline, so
# the last area ends at the end of the file and every insertion into it
# lands at `len(lines)`. Not an edge case: 4 of the 14 daily notes in this
# vault have no trailing newline, and that one has this exact shape today.
#
# Built by concatenation and deliberately NOT ending in "\n". The last line
# is a separate constant so the assertions cannot drift from the fixture.
LAST_LINE_NO_NEWLINE = "- A cleanup command killed the live tmux server."

NOTE_WITHOUT_TRAILING_NEWLINE = (
    "## ✅ Today\n"
    "\n"
    "## \U0001f4dd Capture\n"
    "\n"
    "### Laptop\n"
    "\n"
    "#### \U0001f50e Found while working\n"
    "\n"
    + LAST_LINE_NO_NEWLINE
)


class TestSpliceIntoANoteWithoutATrailingNewline(unittest.TestCase):
    """`splitlines(keepends=True)` leaves the final line of such a note with
    no terminator, so an insertion at `len(lines)` used to be concatenated
    straight onto it. The heading stopped being a heading, the previous
    paragraph was polluted, and because `startswith("#### ")` cannot see a
    glued heading, the next run wrote a second entry with the same title and
    orphaned the body of the first -- the round-4 duplicate-content symptom
    reached by another route.
    """

    def _append(self, note: str, body: str) -> tuple[str, str]:
        return dn.splice(note, "Laptop", "\U0001f9ed Neuer Eintrag", body)

    def test_the_heading_starts_its_own_line_and_the_previous_line_survives(self):
        out, what = self._append(NOTE_WITHOUT_TRAILING_NEWLINE, "Erster Absatz.")
        self.assertEqual(what, "appended")
        self.assertIn("\n#### \U0001f9ed Neuer Eintrag", out)
        # The previous line kept its own text and gained only a terminator.
        self.assertIn(LAST_LINE_NO_NEWLINE + "\n", out)
        self.assertNotIn(LAST_LINE_NO_NEWLINE + "#", out)
        # Everything above the insertion point is byte-identical, so the
        # repair really is confined to the missing terminator.
        self.assertTrue(out.startswith(NOTE_WITHOUT_TRAILING_NEWLINE))

    def test_the_added_terminator_matches_the_notes_own_convention(self):
        crlf = NOTE_WITHOUT_TRAILING_NEWLINE.replace("\n", "\r\n")
        out, what = self._append(crlf, "Erster Absatz.")
        self.assertEqual(what, "appended")
        # The terminator the repair added is the note's own, not a bare \n.
        self.assertIn(LAST_LINE_NO_NEWLINE + "\r\n", out)
        self.assertIn("\r\n#### \U0001f9ed Neuer Eintrag\r\n", out)
        # And the whole file stays CRLF: strike the CRLF pairs out and no
        # lone LF may be left anywhere, inserted block included.
        self.assertNotIn("\n", out.replace("\r\n", ""))

    def test_two_runs_extend_instead_of_writing_a_second_heading(self):
        once, first = self._append(NOTE_WITHOUT_TRAILING_NEWLINE, "Erster Absatz.")
        twice, second = self._append(once, "Zweiter Absatz.")
        self.assertEqual(first, "appended")
        # The second run can only see the heading if it starts a line.
        self.assertEqual(second, "extended")
        self.assertEqual(twice.count("#### \U0001f9ed Neuer Eintrag"), 1)
        self.assertLess(twice.index("Erster Absatz."), twice.index("Zweiter Absatz."))


class TestWriteEntry(VaultCase):
    def test_writes_through_to_the_note(self):
        what = dn.write_entry(date(2026, 8, 9), "Claude Code", "\U0001f4ac Q", "Body.")
        self.assertEqual(what, "created")
        text = dn.note_path(date(2026, 8, 9)).read_text(encoding="utf-8")
        self.assertIn("### Claude Code", text)
        self.assertIn("Body.", text)

    def test_the_unsure_marker_is_an_obsidian_comment(self):
        dn.write_entry(date(2026, 8, 9), "Claude Code", "\U0001f4ac Q", "Body.",
                       unsure=True)
        text = dn.note_path(date(2026, 8, 9)).read_text(encoding="utf-8")
        self.assertIn("%%journal:unsure%%", text)

    def test_concurrent_writers_both_survive(self):
        # Without the lock this is a lost update: both read the same note and
        # the second write clobbers the first.
        import concurrent.futures as cf
        dn.ensure_note(date(2026, 8, 9))
        titles = [f"\U0001f4ac Entry {i}" for i in range(8)]
        with cf.ThreadPoolExecutor(max_workers=8) as pool:
            list(pool.map(
                lambda t: dn.write_entry(date(2026, 8, 9), "Claude Code", t, "Body."),
                titles))
        text = dn.note_path(date(2026, 8, 9)).read_text(encoding="utf-8")
        for t in titles:
            self.assertIn(t, text)

    def test_write_entry_leaves_untouched_lines_byte_identical(self):
        # Stronger than "the write went through": every line of the note
        # that was not part of the new entry must survive a real write on
        # disk byte-for-byte, including its line ending -- the guarantee
        # `splice` gives in memory has to still hold after write_entry's
        # read/splice/replace round trip through the filesystem.
        crlf = FULL.replace("\n", "\r\n")
        target, _ = dn.ensure_note(date(2026, 8, 9))
        target.write_text(crlf, encoding="utf-8")
        before_prefix = crlf[:crlf.index("### Claude Code")]
        before_suffix = crlf[crlf.index("## \U0001f5d2️ Logbook"):]
        dn.write_entry(date(2026, 8, 9), "Claude Code", "\U0001f4ac Questions", "Body.")
        # newline="": the default text mode would normalize the file's own
        # \r\n back to \n on this read too, which would make a CRLF-built
        # expectation unable to match even a correct implementation.
        after = target.read_text(encoding="utf-8", newline="")
        self.assertTrue(after.startswith(before_prefix))
        self.assertTrue(after.endswith(before_suffix))
        self.assertIn("\r\n", after)

    def test_the_write_replaces_atomically_through_a_distinct_temp_file(self):
        # "tmp = target" -- skipping the temp file and writing straight
        # over the note -- would make this call os.replace(target, target)
        # instead of a real rename. Spying on the real os.replace (and
        # still calling through to it) pins the property in this task's
        # own title without racing threads against each other for it.
        dn.ensure_note(date(2026, 8, 9))
        real_replace = os.replace
        calls = []

        def spy(src, dst):
            calls.append((Path(src), Path(dst)))
            return real_replace(src, dst)

        with mock.patch("daily_note.os.replace", side_effect=spy):
            dn.write_entry(date(2026, 8, 9), "Claude Code", "\U0001f4ac Q", "Body.")
        self.assertEqual(len(calls), 1)
        src, dst = calls[0]
        self.assertEqual(dst, dn.note_path(date(2026, 8, 9)))
        self.assertNotEqual(src, dst)

    def test_the_temp_file_is_nextcloud_excluded_and_does_not_leak(self):
        # A bare "*.tmp" is not on Nextcloud's sync-exclude list (only
        # "~*.tmp" is) -- a stray one would sync to the vault and to the
        # phone, which is exactly what lock_path's own docstring keeps the
        # lock file itself from doing.
        target, _ = dn.ensure_note(date(2026, 8, 9))
        real_replace = os.replace
        captured = {}

        def spy(src, dst):
            captured["src"] = Path(src)
            self.assertTrue(Path(src).exists())
            return real_replace(src, dst)

        with mock.patch("daily_note.os.replace", side_effect=spy):
            dn.write_entry(date(2026, 8, 9), "Claude Code", "\U0001f4ac Q", "Body.")
        src = captured["src"]
        # Same directory as the note, so the replace stays an atomic
        # rename rather than a cross-filesystem copy.
        self.assertEqual(src.parent, target.parent)
        self.assertTrue(src.name.endswith(".part"), src.name)
        self.assertFalse(src.exists())  # renamed away, not leaked
        leftover = [p for p in target.parent.iterdir()
                   if p.name.endswith(".part") or p.name.endswith(".tmp")]
        self.assertEqual(leftover, [])

    def test_reports_extended_for_a_repeated_title(self):
        dn.write_entry(date(2026, 8, 9), "Claude Code", "\U0001f4ac Q", "First.")
        what = dn.write_entry(date(2026, 8, 9), "Claude Code", "\U0001f4ac Q", "Second.")
        self.assertEqual(what, "extended")

    def test_reports_appended_for_a_new_area_in_an_existing_note(self):
        dn.write_entry(date(2026, 8, 9), "Claude Code", "\U0001f4ac Q", "Body.")
        what = dn.write_entry(date(2026, 8, 9), "Laptop", "\U0001f527 Fix", "Body.")
        self.assertEqual(what, "appended")

    def test_the_notes_mode_is_unchanged_by_a_write(self):
        # mkstemp creates at 0600; every other file in the vault is 0644.
        # Forcing the mode here (rather than trusting the machine's umask
        # to already land on 0644) is what makes the assertion deterministic.
        target, _ = dn.ensure_note(date(2026, 8, 9))
        target.chmod(0o644)
        dn.write_entry(date(2026, 8, 9), "Claude Code", "\U0001f4ac Q", "Body.")
        self.assertEqual(target.stat().st_mode & 0o777, 0o644)


class TestLockPath(VaultCase):
    def test_lock_path_is_outside_the_vault(self):
        # The project's hardest constraint here: a lock file inside the
        # vault would sync to Nextcloud and to the phone and show up in
        # Obsidian's file list, per lock_path's own docstring.
        path = dn.lock_path()
        self.assertNotIn(dn.vault_root(), path.parents)


class TestRecentAreas(VaultCase):
    def test_collects_headings_from_the_last_two_weeks(self):
        for day, area in ((3, "Client work"), (8, "Laptop")):
            dn.write_entry(date(2026, 8, day), area, "\U0001f4ac T", "Body.")
        found = dn.recent_areas(date(2026, 8, 9), days=14)
        self.assertIn("Client work", found)
        self.assertIn("Laptop", found)

    def test_ignores_notes_older_than_the_window(self):
        dn.write_entry(date(2026, 7, 1), "Ancient", "\U0001f4ac T", "Body.")
        self.assertNotIn("Ancient", dn.recent_areas(date(2026, 8, 9), days=14))

    def test_collects_areas_from_a_german_named_note(self):
        # recent_areas must resolve the same way ensure_note does, or it
        # silently skips a real note just because it was written by the
        # iPhone in German.
        de_name = "Montag, 10. Aug. 2026 (W33).md"
        (self.vault / "daily-notes" / de_name).write_text(
            "## \U0001f4dd Capture\n\n### Laptop\n\n#### \U0001f527 Fix\n\nBody.\n",
            encoding="utf-8")
        found = dn.recent_areas(date(2026, 8, 10), days=14)
        self.assertIn("Laptop", found)

    def test_a_fenced_area_does_not_invent_a_heading_and_does_not_cut_collection_short(self):
        # Errs both ways when unguarded: a fenced "### " invents an area
        # the user never made, and a fenced "## " reads as leaving Capture and
        # drops every real area below it.
        note = (
            "## ✅ Today\n"
            "\n"
            "## \U0001f4dd Capture\n"
            "\n"
            "### Real Area Before\n"
            "\n"
            "#### \U0001f4dd Entry\n"
            "\n"
            "Paste with fenced headings:\n"
            "\n"
            "```\n"
            "### Fake Area From A Fence\n"
            "## Fake Capture Exit From A Fence\n"
            "```\n"
            "\n"
            "Trailing paragraph.\n"
            "\n"
            "### Real Area After\n"
            "\n"
            "#### \U0001f4dd Another Entry\n"
            "\n"
            "More text.\n"
            "\n"
            "## \U0001f5d2️ Logbook\n"
            "\n"
            "- One.\n"
        )
        target, _ = dn.ensure_note(date(2026, 8, 9))
        target.write_text(note, encoding="utf-8")
        found = dn.recent_areas(date(2026, 8, 9), days=14)
        self.assertNotIn("Fake Area From A Fence", found)
        self.assertIn("Real Area Before", found)
        self.assertIn("Real Area After", found)

    def test_most_recent_areas_come_first(self):
        dn.write_entry(date(2026, 8, 3), "Older Area", "\U0001f4ac A", "Body.")
        dn.write_entry(date(2026, 8, 9), "Newer Area", "\U0001f4ac B", "Body.")
        found = dn.recent_areas(date(2026, 8, 9), days=14)
        self.assertLess(found.index("Newer Area"), found.index("Older Area"))

    def test_an_area_used_on_multiple_days_appears_once(self):
        dn.write_entry(date(2026, 8, 2), "Claude Code", "\U0001f4ac A", "Body.")
        dn.write_entry(date(2026, 8, 9), "Claude Code", "\U0001f4ac B", "Body.")
        found = dn.recent_areas(date(2026, 8, 9), days=14)
        self.assertEqual(found.count("Claude Code"), 1)

    def test_the_window_includes_thirteen_days_back(self):
        dn.write_entry(date(2026, 7, 27), "Edge Area", "\U0001f4ac A", "Body.")
        self.assertIn("Edge Area", dn.recent_areas(date(2026, 8, 9), days=14))

    def test_the_window_excludes_fourteen_days_back(self):
        dn.write_entry(date(2026, 7, 26), "Too Old Area", "\U0001f4ac A", "Body.")
        self.assertNotIn("Too Old Area", dn.recent_areas(date(2026, 8, 9), days=14))


class TestCli(VaultCase):
    def _run(self, *args):
        import subprocess
        return subprocess.run(
            [sys.executable, "-B", str(SCRIPTS / "daily_note.py"), *args],
            capture_output=True, text=True, env=dict(os.environ))

    def test_dry_run_writes_nothing_and_prints_the_note(self):
        body = self.vault / "body.md"
        body.write_text("Body.\n", encoding="utf-8")
        done = self._run("write", "--area", "Claude Code", "--title", "\U0001f4ac Q",
                         "--body-file", str(body), "--date", "2026-08-09", "--dry-run")
        self.assertEqual(done.returncode, 0)
        self.assertIn("### Claude Code", done.stdout)
        self.assertFalse(dn.note_path(date(2026, 8, 9)).exists())

    def test_a_missing_body_file_is_exit_two_not_a_traceback(self):
        done = self._run("write", "--area", "A", "--title", "T",
                         "--body-file", "/nonexistent", "--date", "2026-08-09")
        self.assertEqual(done.returncode, 2)
        self.assertNotIn("Traceback", done.stdout)

    def test_path_subcommand_prints_the_note_path(self):
        done = self._run("path", "--date", "2026-08-09")
        self.assertEqual(done.returncode, 0)
        self.assertIn("Sunday, 09. Aug 2026 (W32).md", done.stdout)

    def test_write_with_unsure_marks_the_entry_on_disk(self):
        body = self.vault / "body.md"
        body.write_text("Body.\n", encoding="utf-8")
        done = self._run("write", "--area", "Claude Code", "--title", "\U0001f4ac Q",
                         "--body-file", str(body), "--date", "2026-08-09", "--unsure")
        self.assertEqual(done.returncode, 0)
        text = dn.note_path(date(2026, 8, 9)).read_text(encoding="utf-8")
        self.assertIn("%%journal:unsure%%", text)

    def test_areas_subcommand_respects_days(self):
        dn.write_entry(date(2026, 7, 1), "Ancient", "\U0001f4ac T", "Body.")
        dn.write_entry(date(2026, 8, 9), "Claude Code", "\U0001f4ac T", "Body.")
        narrow = self._run("areas", "--date", "2026-08-09", "--days", "3")
        self.assertEqual(narrow.returncode, 0)
        self.assertIn("Claude Code", narrow.stdout)
        self.assertNotIn("Ancient", narrow.stdout)
        wide = self._run("areas", "--date", "2026-08-09", "--days", "60")
        self.assertEqual(wide.returncode, 0)
        self.assertIn("Ancient", wide.stdout)


if __name__ == "__main__":
    unittest.main()


class TestSkillValues(VaultCase):
    """The vault and the protected section come from the skill values
    (claude/skills/README.md); JOURNAL_VAULT stays the tests' seam."""

    def write_values(self, values):
        self.values.write_text(json.dumps(values), encoding="utf-8")

    def test_the_vault_is_the_skill_value(self):
        os.environ.pop("JOURNAL_VAULT", None)
        self.write_values({"vault": {"root": "/notes/vault"}})
        self.assertEqual(dn.vault_root(), Path("/notes/vault"))

    def test_the_seam_wins(self):
        self.write_values({"vault": {"root": "/notes/vault"}})
        self.assertEqual(dn.vault_root(), self.vault)

    def test_no_vault_names_the_key(self):
        os.environ.pop("JOURNAL_VAULT", None)
        self.write_values({})
        with self.assertRaises(LookupError) as caught:
            dn.vault_root()
        self.assertEqual(str(caught.exception), "set `vault.root` in your ravnix skill values")

    def test_the_cli_without_a_vault_exits_2_and_names_the_key(self):
        self.write_values({})
        env = {k: v for k, v in os.environ.items() if k != "JOURNAL_VAULT"}
        done = subprocess.run([sys.executable, "-B", str(SCRIPTS / "daily_note.py"), "path"],
                              capture_output=True, text=True, env=env)
        self.assertEqual(done.returncode, 2)
        self.assertIn("set `vault.root` in your ravnix skill values", done.stderr)

    def test_without_a_protected_section_capture_goes_at_the_end(self):
        self.write_values({})
        note = "## \u2705 Today\n\n" + PROTECTED + "\n\n- One.\n"
        out, _ = dn.splice(note, "Area", "Title", "Body.")
        self.assertGreater(out.index("## \U0001f4dd Capture"), out.index(PROTECTED))

    def test_another_protected_section_is_kept_below_capture(self):
        other = "## Private"
        self.write_values({"journal": {"protectedSection": other}})
        out, _ = dn.splice("## \u2705 Today\n\n" + other + "\n\n- Mine.\n",
                           "Area", "Title", "Body.")
        self.assertLess(out.index("## \U0001f4dd Capture"), out.index(other))
        self.assertTrue(out.endswith(other + "\n\n- Mine.\n"))

    def test_no_personal_value_is_built_in(self):
        source = (SCRIPTS / "daily_note.py").read_text(encoding="utf-8")
        self.assertNotIn("/home/", source)
        self.assertNotIn("VAULT_DEFAULT", source)
