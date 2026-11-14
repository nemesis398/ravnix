"""Where the checker's personal parts come from on a ravnix host.

- The accepted words are the user's own list, `~/.config/prose/dictionary.txt`
  (ravnix-dict keeps it, `ravnix.dictionary.paths.prose`). The list that
  ships with the skill is read only when that file is absent, and it holds
  no one's words.
- More accepted words can be a skill value, `prose.ignoreWords`, merged
  into the checker's own short list of tool names at run time.
- The LanguageTool key is the Bitwarden item that the skill value
  `prose.languagetool.item` names, read with rbw, and the account is the
  skill value `prose.languagetool.username`. No file in either repository
  and no file on the disk holds them; the environment still wins. Without
  them the checker names the value to set and stops, instead of falling
  back to the free tier without a word.

    python3 -m unittest test_values
"""
from __future__ import annotations

import json
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SKILL = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SKILL / "scripts"))
import check  # noqa: E402

BUNDLED = SKILL / "dictionary.txt"
CHECK = SKILL / "scripts" / "check.py"
PREMIUM = {"prose": {"languagetool": {"item": "LT item", "username": "alice@example.org"}}}


def words(path: Path) -> list[str]:
    return [w.strip() for w in path.read_text(encoding="utf-8").splitlines()
            if w.strip() and not w.strip().startswith("#")]


class Case(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.config = self.tmp / "config"
        self.values = self.tmp / "skill-values.json"
        self.values.write_text("{}", encoding="utf-8")
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        env = {"XDG_CONFIG_HOME": str(self.config), "HOME": str(self.tmp / "home"),
               "RAVNIX_SKILL_VALUES": str(self.values), "PATH": str(self.bin)}
        patcher = mock.patch.dict(os.environ, env, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)

    def user_list(self, *lines: str) -> Path:
        path = self.config / "prose" / "dictionary.txt"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return path

    def fake_rbw(self, script: str) -> Path:
        rbw = self.bin / "rbw"
        rbw.write_text("#!/bin/sh\n" + script, encoding="utf-8")
        rbw.chmod(rbw.stat().st_mode | stat.S_IEXEC)
        return rbw

    def set_values(self, values: dict) -> None:
        self.values.write_text(json.dumps(values), encoding="utf-8")

    def run_check(self, *args: str) -> subprocess.CompletedProcess:
        doc = self.tmp / "doc.md"
        doc.write_text("A plain sentence.\n", encoding="utf-8")
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        return subprocess.run([sys.executable, "-B", str(CHECK), *args, str(doc)],
                              env=env, capture_output=True, text=True, timeout=60)


class Dictionary(Case):
    def test_the_shipped_list_holds_no_words(self):
        self.assertEqual(words(BUNDLED), [])

    def test_the_user_list_is_read(self):
        self.user_list("# mine", "Zettelkasten", "", "  Rechenkiste  ")
        got = check.load_dictionary()
        self.assertIn("Zettelkasten", got)
        self.assertIn("Rechenkiste", got)
        self.assertNotIn("# mine", got)

    def test_the_user_list_is_the_one_that_counts(self):
        self.user_list("Zettelkasten")
        self.assertEqual(check.dictionary_files(), [self.config / "prose" / "dictionary.txt"])

    def test_without_the_user_list_the_shipped_one_is_read(self):
        self.assertEqual(check.dictionary_files(), [BUNDLED])
        self.assertTrue(check.IGNORE_WORDS <= check.load_dictionary())

    def test_without_xdg_config_home_the_home_config(self):
        os.environ.pop("XDG_CONFIG_HOME")
        self.assertEqual(check.user_dictionary(),
                         self.tmp / "home" / ".config" / "prose" / "dictionary.txt")

    def test_an_unreadable_user_list_is_no_crash(self):
        path = self.user_list("x")
        path.write_bytes(b"\xff\xfe\x00broken")
        self.assertTrue(check.IGNORE_WORDS <= check.load_dictionary())

    def test_a_huge_user_list_reads(self):
        self.user_list(*(f"word{i}" for i in range(100_000)))
        self.assertIn("word99999", check.load_dictionary())


class IgnoreWordsValue(Case):
    def test_the_value_is_merged(self):
        self.set_values({"prose": {"ignoreWords": ["Zettelkasten", "Rechenkiste"]}})
        got = check.load_dictionary()
        self.assertIn("Zettelkasten", got)
        self.assertIn("Rechenkiste", got)
        self.assertTrue(check.IGNORE_WORDS <= got)

    def test_with_the_user_list_too(self):
        self.user_list("Wortliste")
        self.set_values({"prose": {"ignoreWords": ["Zettelkasten"]}})
        got = check.load_dictionary()
        self.assertIn("Wortliste", got)
        self.assertIn("Zettelkasten", got)

    def test_a_malformed_value_adds_nothing_and_breaks_nothing(self):
        for bad in ("Zettelkasten", {"a": 1}, 7, None, [1, None, "", "  ", ["x"]]):
            with self.subTest(bad=bad):
                self.set_values({"prose": {"ignoreWords": bad}})
                got = check.load_dictionary()
                self.assertEqual(got, set(check.IGNORE_WORDS))

    def test_entries_are_trimmed(self):
        self.set_values({"prose": {"ignoreWords": ["  Zettelkasten  ", 3]}})
        got = check.load_dictionary()
        self.assertIn("Zettelkasten", got)
        self.assertNotIn(3, got)


class Credentials(Case):
    def test_the_item_and_the_account_come_from_the_skill_values(self):
        self.set_values(PREMIUM)
        log = self.tmp / "rbw.log"
        self.fake_rbw(f'echo "$@" >> "{log}"\n'
                      'case "$1" in unlocked) exit 0;; get) printf "k3y\\nUsername: someone-else\\n";; esac\n')
        creds, trail = check.load_credentials()
        self.assertEqual(creds, {"LANGUAGETOOL_API_KEY": "k3y",
                                 "LANGUAGETOOL_USERNAME": "alice@example.org"})
        self.assertIn("get --full LT item", log.read_text(encoding="utf-8"))
        self.assertFalse(any("k3y" in line for line in trail))

    def test_without_the_value_rbw_is_not_asked_and_the_key_is_named(self):
        log = self.tmp / "rbw.log"
        self.fake_rbw(f'echo "$@" >> "{log}"\nexit 0\n')
        creds, trail = check.load_credentials()
        self.assertEqual(creds, {})
        self.assertFalse(log.exists())
        self.assertTrue(any("set `prose.languagetool.item` in your ravnix skill values" in line
                            for line in trail), trail)

    def test_a_locked_vault_is_said_and_never_unlocked(self):
        self.set_values({"prose": {"languagetool": {"item": "x"}}})
        log = self.tmp / "rbw.log"
        self.fake_rbw(f'echo "$@" >> "{log}"\ncase "$1" in unlocked) exit 1;; esac\nexit 0\n')
        creds, trail = check.load_credentials()
        self.assertEqual(creds, {})
        self.assertEqual(log.read_text(encoding="utf-8").split(), ["unlocked"])
        self.assertTrue(any("locked" in line for line in trail))

    def test_no_rbw_is_said(self):
        self.set_values({"prose": {"languagetool": {"item": "x"}}})
        creds, trail = check.load_credentials()
        self.assertEqual(creds, {})
        self.assertTrue(any("rbw not installed" in line for line in trail))

    def test_a_plaintext_credentials_file_is_never_read(self):
        old = self.tmp / "home" / ".config" / "languagetool" / "credentials"
        old.parent.mkdir(parents=True)
        old.write_text("LANGUAGETOOL_API_KEY=from-file\nLANGUAGETOOL_USERNAME=f\n", encoding="utf-8")
        mine = self.config / "languagetool" / "credentials"
        mine.parent.mkdir(parents=True)
        mine.write_text("LANGUAGETOOL_API_KEY=from-file\n", encoding="utf-8")
        creds, _ = check.load_credentials()
        self.assertNotIn("from-file", creds.values())

    def test_the_environment_wins(self):
        self.set_values({"prose": {"languagetool": {"item": "x"}}})
        self.fake_rbw('case "$1" in unlocked) exit 0;; get) printf "k3y\\n";; esac\n')
        os.environ["LANGUAGETOOL_API_KEY"] = "env-key"
        os.environ["LANGUAGETOOL_USERNAME"] = "env-user"
        creds, _ = check.load_credentials()
        self.assertEqual(creds["LANGUAGETOOL_API_KEY"], "env-key")
        self.assertEqual(creds["LANGUAGETOOL_USERNAME"], "env-user")

    def test_the_account_without_the_item(self):
        self.set_values({"prose": {"languagetool": {"username": "alice@example.org"}}})
        creds, _ = check.load_credentials()
        self.assertEqual(creds, {"LANGUAGETOOL_USERNAME": "alice@example.org"})

    def test_no_item_id_is_built_in(self):
        source = (SKILL / "scripts" / "check.py").read_text(encoding="utf-8")
        self.assertNotRegex(source, r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")


class PremiumOrSay(Case):
    """No silent free tier: a missing value or key stops the check, named."""

    def premium_rbw(self):
        self.fake_rbw('case "$1" in unlocked) exit 0;; get) printf "k3y\\n";; esac\n')

    def test_without_values_both_are_named(self):
        self.assertEqual(check.premium_problems({}), [
            "set `prose.languagetool.item` in your ravnix skill values",
            "set `prose.languagetool.username` in your ravnix skill values"])

    def test_without_the_account_it_is_named(self):
        self.set_values({"prose": {"languagetool": {"item": "LT item"}}})
        self.premium_rbw()
        creds, _ = check.load_credentials()
        self.assertEqual(check.premium_problems(creds),
                         ["set `prose.languagetool.username` in your ravnix skill values"])

    def test_without_the_item_it_is_named(self):
        self.set_values({"prose": {"languagetool": {"username": "alice@example.org"}}})
        creds, _ = check.load_credentials()
        self.assertEqual(check.premium_problems(creds),
                         ["set `prose.languagetool.item` in your ravnix skill values"])

    def test_with_both_and_the_key_there_is_nothing_to_say(self):
        self.set_values(PREMIUM)
        self.premium_rbw()
        creds, _ = check.load_credentials()
        self.assertEqual(check.premium_problems(creds), [])

    def test_a_locked_vault_is_a_problem_not_a_free_tier(self):
        self.set_values(PREMIUM)
        self.fake_rbw('case "$1" in unlocked) exit 1;; esac\nexit 0\n')
        creds, trail = check.load_credentials()
        problems = check.premium_problems(creds, trail)
        self.assertEqual(len(problems), 1)
        self.assertIn("locked", problems[0])

    def test_the_environment_needs_no_values(self):
        os.environ["LANGUAGETOOL_API_KEY"] = "env-key"
        os.environ["LANGUAGETOOL_USERNAME"] = "env-user"
        creds, _ = check.load_credentials()
        self.assertEqual(check.premium_problems(creds), [])

    def test_a_self_hosted_server_needs_no_values(self):
        os.environ["LANGUAGETOOL_SERVER"] = "http://127.0.0.1:9"
        creds, _ = check.load_credentials()
        self.assertEqual(check.premium_problems(creds), [])

    def test_the_check_stops_with_exit_2_and_names_the_values(self):
        got = self.run_check()
        self.assertEqual(got.returncode, 2, got.stdout + got.stderr)
        self.assertIn("set `prose.languagetool.item` in your ravnix skill values", got.stderr)
        self.assertIn("set `prose.languagetool.username` in your ravnix skill values", got.stderr)
        self.assertNotIn("free cloud", got.stdout + got.stderr)

    def test_no_lt_needs_no_values(self):
        got = self.run_check("--no-lt")
        self.assertEqual(got.returncode, 0, got.stdout + got.stderr)

    def test_selftest_names_what_is_missing(self):
        env = dict(os.environ, PYTHONDONTWRITEBYTECODE="1")
        got = subprocess.run([sys.executable, "-B", str(CHECK), "--selftest"], env=env,
                             capture_output=True, text=True, timeout=60,
                             input="")
        self.assertIn("set `prose.languagetool.username` in your ravnix skill values", got.stdout)


if __name__ == "__main__":
    unittest.main()
