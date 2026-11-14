"""skill_values.py, the one reader of the ravnix skill values.

Every skill of ravnix that has scripts carries a byte-identical copy of the
module (the check claude-skills compares them), so this suite stands for all
of them. What it pins: where the file is looked for, that anything other than
a JSON object reads as no values, that a key of the wrong type or an empty
string counts as not set, and the one sentence a missing key produces.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import skill_values as sv  # noqa: E402


class Where(unittest.TestCase):
    def test_the_variable_names_the_file(self):
        with mock.patch.dict(os.environ, {"RAVNIX_SKILL_VALUES": "/x/values.json"}):
            self.assertEqual(sv.path(), Path("/x/values.json"))

    def test_without_it_the_xdg_config_home(self):
        env = {"XDG_CONFIG_HOME": "/cfg", "HOME": "/home/tester"}
        with mock.patch.dict(os.environ, env, clear=True):
            self.assertEqual(sv.path(), Path("/cfg/ravnix/skill-values.json"))

    def test_without_both_the_home_config(self):
        with mock.patch.dict(os.environ, {"HOME": "/home/tester"}, clear=True):
            self.assertEqual(sv.path(), Path("/home/tester/.config/ravnix/skill-values.json"))

    def test_an_empty_variable_counts_as_unset(self):
        env = {"RAVNIX_SKILL_VALUES": "", "XDG_CONFIG_HOME": "", "HOME": "/h"}
        with mock.patch.dict(os.environ, env, clear=True):
            self.assertEqual(sv.path(), Path("/h/.config/ravnix/skill-values.json"))


class Reading(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.file = Path(self.tmp.name) / "values.json"
        patcher = mock.patch.dict(os.environ, {"RAVNIX_SKILL_VALUES": str(self.file)})
        patcher.start()
        self.addCleanup(patcher.stop)

    def write(self, text: str) -> None:
        self.file.write_text(text, encoding="utf-8")

    def test_a_missing_file_is_no_values(self):
        self.assertEqual(sv.load(), {})

    def test_malformed_json_is_no_values(self):
        self.write("{not json")
        self.assertEqual(sv.load(), {})

    def test_a_list_is_no_values(self):
        self.write("[1, 2]")
        self.assertEqual(sv.load(), {})

    def test_bytes_that_are_not_utf8_are_no_values(self):
        self.file.write_bytes(b"\xff\xfe{}")
        self.assertEqual(sv.load(), {})

    def test_a_directory_is_no_values(self):
        self.file.mkdir()
        self.assertEqual(sv.load(), {})

    def test_a_dotted_key_walks_the_objects(self):
        self.write(json.dumps({"user": {"name": "Alice"}}))
        self.assertEqual(sv.get("user.name"), "Alice")

    def test_a_missing_key_is_none(self):
        self.write(json.dumps({"user": {}}))
        self.assertIsNone(sv.get("user.name"))
        self.assertIsNone(sv.get("nothing.at.all"))

    def test_a_key_under_a_string_is_none(self):
        self.write(json.dumps({"user": "Alice"}))
        self.assertIsNone(sv.get("user.name"))

    def test_the_wrong_type_is_none(self):
        self.write(json.dumps({"user": {"name": ["Alice"]}, "n": 3, "flag": True}))
        self.assertIsNone(sv.get("user.name"))
        self.assertIsNone(sv.get("n"))
        self.assertIsNone(sv.get("flag", dict))

    def test_an_empty_or_blank_string_is_not_set(self):
        self.write(json.dumps({"a": "", "b": "  \n"}))
        self.assertIsNone(sv.get("a"))
        self.assertIsNone(sv.get("b"))

    def test_objects_and_lists_by_kind(self):
        self.write(json.dumps({"m": {"x": [1]}, "l": ["a"]}))
        self.assertEqual(sv.get("m", dict), {"x": [1]})
        self.assertEqual(sv.get("l", list), ["a"])

    def test_values_can_be_handed_in(self):
        self.assertEqual(sv.get("a.b", values={"a": {"b": "c"}}), "c")

    def test_require_names_the_key(self):
        self.write("{}")
        with self.assertRaises(sv.Missing) as caught:
            sv.require("vault.root")
        self.assertEqual(str(caught.exception),
                         "set `vault.root` in your ravnix skill values")
        self.assertEqual(caught.exception.key, "vault.root")

    def test_require_returns_a_value_that_is_set(self):
        self.write(json.dumps({"vault": {"root": "/v"}}))
        self.assertEqual(sv.require("vault.root"), "/v")

    def test_a_huge_file_reads(self):
        self.write(json.dumps({"k": "x" * 2_000_000}))
        self.assertEqual(len(sv.get("k")), 2_000_000)


if __name__ == "__main__":
    unittest.main()
