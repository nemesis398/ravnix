import json
import os
import sys
import tempfile
import unittest
from datetime import date
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from notes import (  # noqa: E402
    ARCHIVE_DIR,
    MEMORY_DIR,
    SESSIONS_DIR,
    FrontmatterError,
    load_domains,
    load_notes,
    line,
    parse_frontmatter,
    vault_root,
)

sys.path.insert(0, str(Path(__file__).resolve().parent))
from helpers import front, write_note  # noqa: E402


class ParseFrontmatter(unittest.TestCase):
    def test_flow_and_block_lists_read_the_same(self):
        a, _ = parse_frontmatter("---\ndomain: [homelab, docker]\n---\n")
        b, _ = parse_frontmatter("---\ndomain:\n  - homelab\n  - docker\n---\n")
        self.assertEqual(a["domain"], ["homelab", "docker"])
        self.assertEqual(a, b)

    def test_an_unindented_block_list_reads_too(self):
        m, _ = parse_frontmatter("---\ndomain:\n- homelab\n- docker\ntype: memory\n---\n")
        self.assertEqual(m, {"domain": ["homelab", "docker"], "type": "memory"})

    def test_a_quoted_description_keeps_its_colon(self):
        m, _ = parse_frontmatter('---\ndescription: "Docker: ports bypass ufw"\n---\n')
        self.assertEqual(m["description"], "Docker: ports bypass ufw")

    def test_quotes_escapes_and_comments(self):
        m, _ = parse_frontmatter(
            "---\n"
            "a: 'it''s'\n"
            'b: "say \\"hi\\""\n'
            "c: active # a comment\n"
            'd: ["x, y", \'z\', w]\n'
            "e: []\n"
            "f:\n"
            "---\n"
        )
        self.assertEqual(m, {"a": "it's", "b": 'say "hi"', "c": "active",
                             "d": ["x, y", "z", "w"], "e": [], "f": ""})

    def test_a_nested_key_comes_back_as_a_mapping(self):
        m, _ = parse_frontmatter("---\nmetadata:\n  type: gotcha\n---\n")
        self.assertEqual(m["metadata"], {"type": "gotcha"})

    def test_the_body_is_everything_after_the_closing_line(self):
        _, body = parse_frontmatter("---\ntype: memory\n---\n\n# T\n\nFact.\n")
        self.assertEqual(body, "\n# T\n\nFact.\n")

    def test_missing_or_unclosed_frontmatter_raises(self):
        for text in ("# T\n\nFact.\n", "", "---\ntype: memory\n"):
            with self.subTest(text=text), self.assertRaises(FrontmatterError):
                parse_frontmatter(text)

    def test_what_obsidian_cannot_read_raises(self):
        # YAML reserves the backtick, so a description that opens with a
        # symptom has to be quoted, and ": " in a plain value starts a mapping.
        for bad in ("description: `exit 2` on push\n",
                    "description: Docker: ports bypass ufw\n",
                    "type: memory\ntype: session\n",
                    "domain: [a, [b]]\n",
                    "description: \"unclosed\n",
                    "  type: memory\n",
                    "domain:\n  - a\n    - b\n"):
            with self.subTest(bad=bad), self.assertRaises(FrontmatterError):
                parse_frontmatter(f"---\n{bad}---\n")


class LoadNotes(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.vault = Path(tmp.name)
        self.memory = self.vault / MEMORY_DIR

    def test_a_note_carries_its_properties(self):
        write_note(self.memory, "ugrep-dies-on-long-patterns.md",
                   front(domain="\n  - tooling\n  - linux", tags="[gotcha, pinned]",
                         description='"`pattern too long` from ugrep"'))
        notes, problems = load_notes(self.memory, self.vault)
        self.assertEqual(problems, [])
        (n,) = notes
        self.assertEqual(n.rel, "AI/memory/ugrep-dies-on-long-patterns.md")
        self.assertEqual(n.title, "ugrep-dies-on-long-patterns")
        self.assertEqual(n.status, "active")
        self.assertEqual(n.description, "`pattern too long` from ugrep")
        self.assertEqual(n.domains, ["tooling", "linux"])
        self.assertEqual(n.tags, ["gotcha", "pinned"])
        self.assertEqual(n.updated, date(2026, 10, 17))
        self.assertEqual(n.size, n.path.stat().st_size)
        self.assertEqual(n.body, "\nFact.\n")

    def test_missing_or_malformed_properties_read_as_empty(self):
        write_note(self.memory, "x.md", "domain: homelab\nupdated: soon\n")
        (n,), _ = load_notes(self.memory, self.vault)
        self.assertEqual((n.status, n.description, n.tags), ("", "", []))
        self.assertEqual(n.domains, ["homelab"])
        self.assertIsNone(n.updated)

    def test_a_note_without_frontmatter_is_a_problem_not_a_crash(self):
        (self.memory).mkdir(parents=True)
        (self.memory / "bare.md").write_text("# Bare\n\nFact.\n", encoding="utf-8")
        notes, problems = load_notes(self.memory, self.vault)
        self.assertEqual(notes, [])
        self.assertEqual([rel for rel, _ in problems], ["AI/memory/bare.md"])

    def test_a_nextcloud_conflict_copy_is_skipped_and_reported(self):
        write_note(self.memory, "x.md", front())
        write_note(self.memory, "x (conflicted copy 2026-10-17 101010).md", front())
        notes, problems = load_notes(self.memory, self.vault)
        self.assertEqual([n.rel for n in notes], ["AI/memory/x.md"])
        self.assertEqual([rel for rel, _ in problems],
                         ["AI/memory/x (conflicted copy 2026-10-17 101010).md"])
        self.assertIn("conflict", problems[0][1])

    def test_umlauts_and_en_dashes_survive(self):
        write_note(self.memory, "prüfung.md", front(description='"Prüfung – Übersicht"'))
        (n,), _ = load_notes(self.memory, self.vault)
        self.assertEqual(n.description, "Prüfung – Übersicht")
        self.assertEqual(n.title, "prüfung")
        self.assertEqual(n.size, len(n.path.read_bytes()))
        self.assertGreater(n.size, len(n.path.read_text(encoding="utf-8")))

    def test_subfolders_are_read_and_a_missing_folder_is_empty(self):
        write_note(self.vault / ARCHIVE_DIR / "2026", "old.md", front(status="superseded"))
        notes, problems = load_notes(self.vault / ARCHIVE_DIR, self.vault)
        self.assertEqual([n.rel for n in notes], ["AI/archive/2026/old.md"])
        self.assertEqual(load_notes(self.vault / SESSIONS_DIR, self.vault), ([], []))

    def test_line_is_title_and_description(self):
        write_note(self.memory, "a-b.md", front(description='"Says c."'))
        (n,), _ = load_notes(self.memory, self.vault)
        self.assertEqual(line(n), "- a-b: Says c.")


class Environment(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)

    def test_vault_root_reads_the_environment(self):
        with mock.patch.dict(os.environ, {"AI_MEMORY_VAULT": str(self.dir)}):
            self.assertEqual(vault_root(), self.dir)

    def values(self, data) -> dict:
        path = self.dir / "skill-values.json"
        path.write_text(json.dumps(data), encoding="utf-8")
        return {"RAVNIX_SKILL_VALUES": str(path), "AI_MEMORY_VAULT": "",
                "AI_MEMORY_DOMAINS": ""}

    def test_without_the_variable_the_vault_is_the_skill_value(self):
        with mock.patch.dict(os.environ, self.values({"vault": {"root": "~/notes"}})):
            self.assertEqual(vault_root(), Path.home() / "notes")

    def test_without_both_the_vault_names_the_key(self):
        with mock.patch.dict(os.environ, self.values({})):
            with self.assertRaises(LookupError) as caught:
                vault_root()
            self.assertEqual(str(caught.exception), "set `vault.root` in your ravnix skill values")

    def test_without_the_variable_the_domains_are_the_skill_value(self):
        env = self.values({"memory": {"domains": {"homelab": ["docker"]}}})
        with mock.patch.dict(os.environ, env):
            self.assertEqual(load_domains(), {"homelab": ["docker"]})

    def test_no_domains_value_is_no_domains(self):
        with mock.patch.dict(os.environ, self.values({})):
            self.assertEqual(load_domains(), {})

    def test_a_malformed_domains_value_raises(self):
        for bad in ({"homelab": "docker"}, {"homelab": [1]}):
            with self.subTest(bad=bad), mock.patch.dict(
                    os.environ, self.values({"memory": {"domains": bad}})):
                with self.assertRaises(ValueError) as caught:
                    load_domains()
                self.assertIn("memory.domains", str(caught.exception))

    def test_domains_come_from_the_file_and_a_missing_file_is_empty(self):
        path = self.dir / "domains.json"
        with mock.patch.dict(os.environ, {"AI_MEMORY_DOMAINS": str(path)}):
            self.assertEqual(load_domains(), {})
            path.write_text(json.dumps({"homelab": ["docker", "caddy"]}), encoding="utf-8")
            self.assertEqual(load_domains(), {"homelab": ["docker", "caddy"]})

    def test_a_malformed_domains_file_raises(self):
        path = self.dir / "domains.json"
        with mock.patch.dict(os.environ, {"AI_MEMORY_DOMAINS": str(path)}):
            for text in ("{not json", '["homelab"]', '{"homelab": "docker"}'):
                path.write_text(text, encoding="utf-8")
                with self.subTest(text=text), self.assertRaises(ValueError):
                    load_domains()


if __name__ == "__main__":
    unittest.main()
