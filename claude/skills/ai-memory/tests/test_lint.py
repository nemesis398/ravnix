import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
LINT = SCRIPTS / "lint.py"
sys.path.insert(0, str(SCRIPTS))
from lint import (  # noqa: E402
    DESCRIPTION_CAP,
    HARD_CAP,
    MDLINT_DEFAULT,
    PINNED_BUDGET,
    SOFT_CAP,
    Finding,
    lint_vault,
    markdown_findings,
)
from notes import ARCHIVE_DIR, MEMORY_DIR, SESSIONS_DIR  # noqa: E402

sys.path.insert(0, str(Path(__file__).resolve().parent))
from helpers import front, text, write_note, write_sized_note  # noqa: E402

# What markdownlint-cli2 v0.23.3 really prints, captured on 2026-10-17: the
# banner on stdout, one line per finding on stderr, exit 1 when it found any.
MDLINT_FINDINGS = """\
echo 'markdownlint-cli2 v0.23.3 (markdownlint v0.41.1)'
echo 'Finding: AI/memory/**/*.md AI/sessions/**/*.md AI/archive/**/*.md'
echo 'Linting: 3 files'
echo 'Summary: 2 issues in 1 files'
echo 'AI/memory/x.md:5 error MD041/first-line-heading/first-line-h1 First line in a file should be a top-level heading [Context: "Fact."]' >&2
echo 'AI/memory/x.md:7:81 error MD013/line-length Line length [Expected: 80; Actual: 104]' >&2
exit 1
"""

SESSION_FRONT = (
    "type: session\n"
    "domain: [claude-code]\n"
    "updated: 2026-10-17\n"
    'description: "Built the note reader."\n'
    "generated: claude/1fa42edb-43a9-44f1-9267-40a0a1705555\n"
)


class LintCase(unittest.TestCase):
    """A fresh vault per test, and a silent markdownlint stub unless a test
    installs another, so no test depends on the real binary by accident."""

    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.vault = self.tmp / "vault"
        self.memory = self.vault / MEMORY_DIR
        self.archive = self.vault / ARCHIVE_DIR
        self.sessions = self.vault / SESSIONS_DIR
        self.memory.mkdir(parents=True)
        self.use_mdlint(self.stub("exit 0"))

    def stub(self, script: str, name: str = "mdlint") -> Path:
        path = self.tmp / name
        path.write_text(f"#!/bin/sh\n{script}", encoding="utf-8")
        path.chmod(0o755)
        return path

    def use_mdlint(self, path: Path | str) -> None:
        patcher = mock.patch.dict(os.environ, {"AI_MEMORY_MDLINT": str(path)})
        patcher.start()
        self.addCleanup(patcher.stop)

    def lint(self, domains=None) -> list[Finding]:
        return lint_vault(self.vault, domains or {})

    def assertFinding(self, findings, level, rel, substring):
        hits = [f for f in findings if f.level == level and f.rel == rel and substring in f.message]
        self.assertTrue(hits, f"no {level} on {rel} with {substring!r} in {findings}")

    def assertNoFinding(self, findings, rel, substring=""):
        hits = [f for f in findings if f.rel == rel and substring in f.message]
        self.assertEqual(hits, [])


class MemoryRules(LintCase):
    def test_a_clean_note_draws_nothing(self):
        write_note(self.memory, "x.md", front())
        self.assertEqual(self.lint(), [])

    def test_over_the_hard_cap_is_an_error(self):
        write_sized_note(self.memory, "big.md", front(), HARD_CAP + 1)
        write_sized_note(self.memory, "edge.md", front(), HARD_CAP)
        findings = self.lint()
        self.assertFinding(findings, "ERROR", "AI/memory/big.md", "over 6 KB")
        self.assertEqual([f.level for f in findings if f.rel == "AI/memory/edge.md"], ["WARN"])

    def test_over_the_soft_cap_is_a_warning(self):
        write_sized_note(self.memory, "big.md", front(), SOFT_CAP + 1)
        write_sized_note(self.memory, "edge.md", front(), SOFT_CAP)
        findings = self.lint()
        self.assertFinding(findings, "WARN", "AI/memory/big.md", "over 2 KB")
        self.assertNoFinding(findings, "AI/memory/edge.md")

    def test_nested_metadata_is_an_error(self):
        write_note(self.memory, "x.md", front() + "metadata:\n  type: gotcha\n")
        self.assertFinding(self.lint(), "ERROR", "AI/memory/x.md", "nested")

    def test_type_must_be_memory(self):
        write_note(self.memory, "x.md", front(type="concept"))
        write_note(self.memory, "y.md", front(type=None))
        findings = self.lint()
        self.assertFinding(findings, "ERROR", "AI/memory/x.md", "type")
        self.assertFinding(findings, "ERROR", "AI/memory/y.md", "type")

    def test_a_missing_description_is_an_error(self):
        write_note(self.memory, "x.md", front(description=None))
        write_note(self.memory, "y.md", front(description='""'))
        findings = self.lint()
        self.assertFinding(findings, "ERROR", "AI/memory/x.md", "description")
        self.assertFinding(findings, "ERROR", "AI/memory/y.md", "description")

    def test_a_long_description_is_a_warning(self):
        write_note(self.memory, "long.md", front(description=f'"{text(DESCRIPTION_CAP + 1)}"'))
        write_note(self.memory, "edge.md", front(description=f'"{text(DESCRIPTION_CAP)}"'))
        findings = self.lint()
        self.assertFinding(findings, "WARN", "AI/memory/long.md", "description")
        self.assertNoFinding(findings, "AI/memory/edge.md")

    def test_one_kind_at_most_and_pinned_may_join_it(self):
        symptom = '"`exceeds complexity limits` from the hook"'
        write_note(self.memory, "pinned.md", front(tags="[gotcha, pinned]", description=symptom))
        write_note(self.memory, "other.md", front(tags="[reference, sap]"))
        write_note(self.memory, "two.md", front(tags="[gotcha, feedback]", description=symptom))
        write_note(self.memory, "none.md", front(tags="[]"))
        write_note(self.memory, "only-pinned.md", front(tags="[pinned]"))
        findings = self.lint()
        self.assertNoFinding(findings, "AI/memory/pinned.md")
        self.assertNoFinding(findings, "AI/memory/other.md")
        for name in ("two", "none", "only-pinned"):
            self.assertFinding(findings, "ERROR", f"AI/memory/{name}.md", "kind")

    def test_status_is_active_or_superseded(self):
        write_note(self.memory, "x.md", front(status="draft"))
        write_note(self.archive, "y.md", front(status="superseded"))
        findings = self.lint()
        self.assertFinding(findings, "ERROR", "AI/memory/x.md", "status")
        self.assertNoFinding(findings, "AI/archive/y.md")

    def test_updated_must_be_a_date(self):
        write_note(self.memory, "x.md", front(updated="soon"))
        write_note(self.memory, "y.md", front(updated=None))
        findings = self.lint()
        self.assertFinding(findings, "ERROR", "AI/memory/x.md", "updated")
        self.assertFinding(findings, "ERROR", "AI/memory/y.md", "updated")

    def test_a_superseded_note_outside_the_archive_is_a_warning(self):
        write_note(self.memory, "x.md", front(status="superseded"))
        self.assertFinding(self.lint(), "WARN", "AI/memory/x.md", ARCHIVE_DIR)

    def test_a_gotcha_without_a_backticked_symptom_is_a_warning(self):
        write_note(self.memory, "plain.md", front(tags="[gotcha]", description='"No symptom."'))
        write_note(self.memory, "short.md", front(tags="[gotcha]", description='"Says `x` and so `abc`."'))
        write_note(self.memory, "good.md", front(tags="[gotcha]", description='"`exit 144` from pkill"'))
        findings = self.lint()
        self.assertFinding(findings, "WARN", "AI/memory/plain.md", "symptom")
        self.assertFinding(findings, "WARN", "AI/memory/short.md", "symptom")
        self.assertNoFinding(findings, "AI/memory/good.md")

    def test_pinned_lines_over_budget_is_a_warning(self):
        # "- p00: " + 242 characters + a newline is 250, and 16 of them are
        # exactly the budget. A superseded pinned note never counts.
        for i in range(16):
            write_note(self.memory, f"p{i:02}.md", front(tags="[reference, pinned]", description=text(242)))
        write_note(self.archive, "old.md", front(status="superseded", tags="[reference, pinned]"))
        self.assertEqual(16 * 250, PINNED_BUDGET)
        self.assertNoFinding(self.lint(), MEMORY_DIR)
        write_note(self.memory, "p00.md", front(tags="[reference, pinned]", description=text(243)))
        self.assertFinding(self.lint(), "WARN", MEMORY_DIR, "4001")

    def test_an_unknown_domain_is_a_warning_when_domains_are_defined(self):
        write_note(self.memory, "x.md", front(domain="[claude-code, homelab]"))
        self.assertEqual(self.lint({}), [])
        findings = self.lint({"homelab": ["docker"]})
        self.assertFinding(findings, "WARN", "AI/memory/x.md", "claude-code")
        self.assertNoFinding(findings, "AI/memory/x.md", "homelab")

    def test_a_note_that_does_not_parse_is_an_error(self):
        (self.memory / "bare.md").write_text("# Bare\n\nFact.\n", encoding="utf-8")
        write_note(self.memory, "colon.md", front(description="Docker: ports bypass ufw"))
        write_note(self.memory, "x (conflicted copy 2026-10-17 101010).md", front())
        findings = self.lint()
        self.assertFinding(findings, "ERROR", "AI/memory/bare.md", "frontmatter")
        self.assertFinding(findings, "ERROR", "AI/memory/colon.md", "frontmatter")
        self.assertFinding(findings, "ERROR", "AI/memory/x (conflicted copy 2026-10-17 101010).md",
                           "conflict")


class Secrets(LintCase):
    def test_a_private_address_or_token_is_a_warning(self):
        sha = "3f9a6c2e8b1d4f7a0c5e9b2d6f8a1c3e5b7d9f0a"
        write_note(self.memory, "ip.md", front(), "Fact.\n\nThe box is at 10.20.30.40.\n")
        write_note(self.memory, "ips.md", front(), "172.16.0.9 and 192.168.1.1\n")
        write_note(self.memory, "sha.md", front(), f"Fact.\n\nCommit {sha} did it.\n")
        findings = self.lint()
        self.assertFinding(findings, "WARN", "AI/memory/ip.md", "10.20.30.40")
        self.assertFinding(findings, "WARN", "AI/memory/ip.md", "line 12")
        self.assertFinding(findings, "WARN", "AI/memory/ips.md", "172.16.0.9")
        self.assertFinding(findings, "WARN", "AI/memory/ips.md", "192.168.1.1")
        self.assertFinding(findings, "WARN", "AI/memory/sha.md", "40")
        self.assertNoFinding(findings, "AI/memory/sha.md", sha)

    def test_public_addresses_and_urls_draw_nothing(self):
        token = "A" * 40
        write_note(self.memory, "x.md", front(),
                   f"8.8.8.8, 172.32.0.1, 10.0.0.300 and 1.10.0.0.1 are fine.\n"
                   f"So is https://example.org/download?key={token}.\n")
        self.assertEqual(self.lint(), [])

    def test_a_private_address_inside_a_url_is_a_warning(self):
        # Only token runs are exempt inside a URL; an address there still syncs.
        write_note(self.memory, "x.md", front(),
                   "Open http://192.168.1.20:3000/ or ssh://root@10.20.30.40 to check.\n")
        findings = self.lint()
        self.assertFinding(findings, "WARN", "AI/memory/x.md", "192.168.1.20")
        self.assertFinding(findings, "WARN", "AI/memory/x.md", "10.20.30.40")
        self.assertEqual(len(findings), 2, findings)

    def test_a_uuid_and_a_long_kebab_slug_draw_nothing(self):
        write_note(self.memory, "x.md", front() + "generated: claude/1fa42edb-43a9-44f1-9267-40a0a1705555\n",
                   "See concurrent-sessions-share-one-git-index-and-the-private-index.\n\n"
                   "Session 1fa42edb-43a9-44f1-9267-40a0a1705555, CLAUDE_CODE_WORKFLOW_SUBAGENT_MODEL.\n")
        self.assertEqual(self.lint(), [])

    def test_session_notes_are_scanned_too(self):
        write_note(self.sessions, "2026-10-17 x.md", SESSION_FRONT, "# X\n\nRan on 192.168.1.20.\n")
        self.assertFinding(self.lint(), "WARN", "AI/sessions/2026-10-17 x.md", "192.168.1.20")


class SessionRules(LintCase):
    def test_a_session_note_needs_type_session(self):
        write_note(self.sessions, "2026-10-17 x.md", SESSION_FRONT.replace("type: session", "type: memory"))
        self.assertFinding(self.lint(), "ERROR", "AI/sessions/2026-10-17 x.md", "session")

    def test_a_session_note_skips_the_memory_rules(self):
        # No status, no tags and well over the hard cap, all of which a memory
        # note would answer for.
        write_sized_note(self.sessions, "2026-10-17 Prüfung (x) – y.md", SESSION_FRONT, HARD_CAP + 500)
        self.assertEqual(self.lint({"claude-code": ["hook"]}), [])

    def test_a_session_note_still_answers_for_its_own_keys(self):
        write_note(self.sessions, "a.md", SESSION_FRONT.replace('description: "Built the note reader."\n', ""))
        write_note(self.sessions, "b.md", SESSION_FRONT.replace("2026-10-17", "today"))
        write_note(self.sessions, "c.md", SESSION_FRONT + "metadata:\n  x: y\n")
        write_note(self.sessions, "d.md", SESSION_FRONT)
        findings = self.lint({"homelab": ["docker"]})
        self.assertFinding(findings, "ERROR", "AI/sessions/a.md", "description")
        self.assertFinding(findings, "ERROR", "AI/sessions/b.md", "updated")
        self.assertFinding(findings, "ERROR", "AI/sessions/c.md", "nested")
        self.assertFinding(findings, "WARN", "AI/sessions/d.md", "claude-code")


class Markdownlint(LintCase):
    def test_markdownlint_findings_become_errors(self):
        record = self.tmp / "called"
        self.use_mdlint(self.stub(f'{{ pwd -P; printf "%s\\n" "$@"; }} > "{record}"\n{MDLINT_FINDINGS}'))
        write_note(self.memory, "x.md", front())
        findings = markdown_findings(self.vault)
        self.assertEqual([(f.level, f.rel) for f in findings], [("ERROR", "AI/memory/x.md")] * 2)
        self.assertFinding(findings, "ERROR", "AI/memory/x.md", "MD041")
        self.assertFinding(findings, "ERROR", "AI/memory/x.md", "line 5")
        self.assertFinding(findings, "ERROR", "AI/memory/x.md", "MD013")
        self.assertIn(findings[0], self.lint())
        # It runs in the vault so the vault's config applies, and it gets the
        # three folder globs, never a file name.
        called = record.read_text(encoding="utf-8").splitlines()
        self.assertEqual(Path(called[0]).resolve(), self.vault.resolve())
        self.assertEqual(called[1:], ["AI/memory/**/*.md", "AI/sessions/**/*.md", "AI/archive/**/*.md"])

    def test_a_missing_markdownlint_is_one_warning(self):
        self.use_mdlint(self.tmp / "no-such-binary")
        write_note(self.memory, "x.md", front())
        findings = self.lint()
        self.assertEqual([f.level for f in findings], ["WARN"])
        self.assertIn("not found", findings[0].message)

    def test_a_markdownlint_that_fails_to_run_is_an_error(self):
        self.use_mdlint(self.stub("echo \"Error: Unable to use configuration file 'x'\" >&2\nexit 2\n"))
        write_note(self.memory, "x.md", front())
        findings = self.lint()
        self.assertEqual([f.level for f in findings], ["ERROR"])
        self.assertIn("configuration file", findings[0].message)

    def test_findings_it_cannot_read_are_still_an_error(self):
        # A later version that moved its findings to stdout must not pass as clean.
        self.use_mdlint(self.stub(MDLINT_FINDINGS.replace(" >&2", "")))
        write_note(self.memory, "x.md", front())
        findings = self.lint()
        self.assertEqual([(f.level, f.rel) for f in findings], [("ERROR", "markdownlint-cli2")])
        self.assertIn("exited 1", findings[0].message)

    def test_no_area_means_no_markdownlint_run(self):
        self.use_mdlint(self.tmp / "no-such-binary")
        self.memory.rmdir()
        self.assertEqual(self.lint(), [])

    @unittest.skipUnless(Path(MDLINT_DEFAULT).expanduser().exists(), "markdownlint-cli2 is not installed")
    def test_the_real_markdownlint_reads_the_vault(self):
        self.use_mdlint(MDLINT_DEFAULT)
        write_note(self.memory, "bad.md", front(), "No title here.\n")
        write_note(self.memory, "good.md", front(), "# Good\n\nFact.\n")
        write_note(self.sessions, "2026-10-17 Prüfung (x) – y.md", SESSION_FRONT, "# Prüfung (x) – y\n\nDone.\n")
        findings = self.lint()
        self.assertEqual([(f.level, f.rel) for f in findings], [("ERROR", "AI/memory/bad.md")])
        self.assertIn("MD041", findings[0].message)


class Cli(LintCase):
    def run_cli(self, *args: str) -> subprocess.CompletedProcess:
        env = {**os.environ, "AI_MEMORY_DOMAINS": str(self.tmp / "no-domains.json")}
        return subprocess.run([sys.executable, "-B", str(LINT), "--vault", str(self.vault), *args],
                              capture_output=True, text=True, env=env, timeout=60)

    def test_exit_code_is_one_on_error_zero_on_warnings(self):
        write_sized_note(self.memory, "big.md", front(), SOFT_CAP + 1)
        warned = self.run_cli()
        self.assertEqual(warned.returncode, 0, warned.stderr)
        self.assertRegex(warned.stdout, r"(?m)^WARN AI/memory/big\.md: .*over 2 KB")
        write_note(self.memory, "bad.md", front(status="draft"))
        failed = self.run_cli()
        self.assertEqual(failed.returncode, 1, failed.stderr)
        self.assertRegex(failed.stdout, r"(?m)^ERROR AI/memory/bad\.md: .*status")
        self.assertEqual(failed.stderr, "")

    def test_a_malformed_domains_file_is_an_error(self):
        bad = self.tmp / "domains.json"
        bad.write_text("{not json", encoding="utf-8")
        env = {**os.environ, "AI_MEMORY_DOMAINS": str(bad)}
        done = subprocess.run([sys.executable, "-B", str(LINT), "--vault", str(self.vault)],
                              capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(done.returncode, 1, done.stderr)
        self.assertRegex(done.stdout, r"(?m)^ERROR memory\.domains: .*domains\.json is not valid JSON")

    def test_without_a_vault_it_exits_2_and_names_the_key(self):
        values = self.tmp / "skill-values.json"
        values.write_text("{}", encoding="utf-8")
        env = {**os.environ, "AI_MEMORY_VAULT": "", "RAVNIX_SKILL_VALUES": str(values)}
        done = subprocess.run([sys.executable, "-B", str(LINT)],
                              capture_output=True, text=True, env=env, timeout=60)
        self.assertEqual(done.returncode, 2)
        self.assertIn("set `vault.root` in your ravnix skill values", done.stderr)
        self.assertNotIn("Traceback", done.stderr)

    def test_summary_counts_kinds_pinned_and_bytes(self):
        write_note(self.memory, "a.md", front(tags="[gotcha, pinned]", description='"`exit 144` from pkill"'))
        write_note(self.memory, "b.md", front(tags="[gotcha]", description='"`exit 144` again"'))
        write_note(self.memory, "c.md", front(tags="[preference]"))
        write_note(self.archive, "d.md", front(status="superseded"))
        write_note(self.sessions, "2026-10-17 s.md", SESSION_FRONT)
        done = self.run_cli("--summary")
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        memory_bytes = sum(p.stat().st_size for p in self.memory.glob("*.md"))
        pinned = len("- a: `exit 144` from pkill") + 1
        self.assertIn(f"AI/memory: 3 notes, {memory_bytes} bytes", done.stdout)
        self.assertIn("AI/archive: 1 note,", done.stdout)
        self.assertIn("AI/sessions: 1 note,", done.stdout)
        self.assertIn("kinds in AI/memory: gotcha 2, feedback 0, preference 1, reference 0", done.stdout)
        self.assertIn(f"pinned: 1 note, {pinned} of {PINNED_BUDGET} characters", done.stdout)

    def test_a_missing_vault_is_a_usage_error(self):
        done = subprocess.run([sys.executable, "-B", str(LINT), "--vault", str(self.tmp / "nowhere")],
                              capture_output=True, text=True, timeout=60)
        self.assertEqual(done.returncode, 2)
        self.assertIn("nowhere", done.stderr)


if __name__ == "__main__":
    unittest.main()
