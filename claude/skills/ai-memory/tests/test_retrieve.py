import math
import os
import re
import sys
import unicodedata
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import lint  # noqa: E402
import notes  # noqa: E402
import retrieve  # noqa: E402
from retrieve import (  # noqa: E402
    DIGEST_BUDGET,
    MATCH_BUDGET,
    MAX_FAILURE_HITS,
    MAX_MATCHES,
    PINNED_BUDGET,
    digest,
    header,
    line,
    match_failure,
    match_prompt,
    pinned,
    symptoms,
    tokens,
    touched_domains,
)

sys.path.insert(0, str(Path(__file__).resolve().parent))
from helpers import filler, front, memory, text  # noqa: E402

# The scores below use N, the number of active notes, and df, the number of
# them that hold the word: a word scores ln(N / df).
EPS = 1e-9


def note(name: str, description: str = "A fact worth keeping.", **fields: str):
    """An active note in AI/memory. `fields` replace keys of the clean
    frontmatter, each as its raw YAML text."""
    return memory(f"{name}.md", front(description=f'"{description}"', **fields))


def sized(name: str, length: int, **fields: str):
    """A note whose line is exactly `length` characters, before its newline."""
    made = note(name, text(length - len(f"- {name}: ")), **fields)
    assert len(line(made)) == length, len(line(made))
    return made


def rels(found) -> list[str]:
    return [n.rel for n in found]


class Tokens(unittest.TestCase):
    def test_tokens_casefold_umlauts_and_sharp_s(self):
        self.assertEqual(tokens("Straße PRÜFUNG"), {"strasse", "prüfung"})

    def test_a_decomposed_umlaut_reads_like_a_composed_one(self):
        # A filename written on macOS or iOS can spell ü as u plus U+0308.
        self.assertEqual(tokens(unicodedata.normalize("NFD", "Prüfung")), {"prüfung"})

    def test_stopwords_and_short_words_drop_out(self):
        self.assertEqual(tokens("the and der die ok"), set())

    def test_line_and_symptoms_have_one_definition(self):
        self.assertIs(retrieve.line, notes.line)
        self.assertIs(lint.symptoms, retrieve.symptoms)
        self.assertIs(lint.PINNED_BUDGET, retrieve.PINNED_BUDGET)


class Pinned(unittest.TestCase):
    def test_pinned_keeps_newest_within_budget(self):
        # Two lines of 1800 and their newlines take 3602 of 4000, a third would not fit.
        found = pinned([
            sized("p-old", 1800, tags="[reference, pinned]", updated="2026-08-01"),
            sized("p-new", 1800, tags="[reference, pinned]", updated="2026-10-01"),
            sized("p-mid", 1800, tags="[reference, pinned]", updated="2026-09-01"),
            note("not-pinned", updated="2026-10-17"),
        ])
        self.assertEqual(rels(found), ["AI/memory/p-new.md", "AI/memory/p-mid.md"])

    def test_a_budget_counts_each_line_and_its_newline(self):
        # Two lines of 1999 plus their newlines are exactly PINNED_BUDGET.
        a = sized("a", 1999, tags="[reference, pinned]", updated="2026-10-02")
        fits = sized("b", 1999, tags="[reference, pinned]", updated="2026-10-01")
        over = sized("b", 2000, tags="[reference, pinned]", updated="2026-10-01")
        self.assertEqual(sum(len(line(n)) + 1 for n in (a, fits)), PINNED_BUDGET)
        self.assertEqual(rels(pinned([a, fits])), [a.rel, fits.rel])
        self.assertEqual(rels(pinned([a, over])), [a.rel])


class Active(unittest.TestCase):
    def test_superseded_notes_are_never_returned(self):
        # N = 301 while the note is active and 300 once it is superseded. The
        # active run proves each call would return it.
        for status, wanted in (("active", ["AI/memory/ugrep-dies.md"]), ("superseded", [])):
            with self.subTest(status=status):
                old = note("ugrep-dies", "`pattern too long` from ugrep", status=status,
                           tags="[gotcha, pinned]", domain="[desktop]")
                corpus = filler(300) + [old]
                self.assertEqual(rels(pinned(corpus)), wanted)
                self.assertEqual(rels(match_prompt("ugrep again", corpus, {}, set())), wanted)
                self.assertEqual(rels(digest("desktop", corpus, set())), wanted)
                self.assertEqual(rels(match_failure("ugrep: pattern too long", corpus, set())),
                                 wanted)

    def test_superseded_notes_do_not_count_toward_n_or_df(self):
        # N = 301 and df = 1 give ln(301) = 5.71. Counting the four superseded
        # notes would give ln(305 / 5) = 4.11, under a bar of 5.
        target = note("ugrep-dies", "ugrep dies on long patterns.")
        gone = [note(f"ugrep-old-{i}", "ugrep fact.", status="superseded") for i in range(4)]
        found = match_prompt("ugrep", filler(300) + [target] + gone, {}, set(), min_score=5.0)
        self.assertEqual(rels(found), [target.rel])


class MatchPrompt(unittest.TestCase):
    def test_a_rare_word_matches_on_its_own(self):
        # N = 301: "ugrep" is in 1 note, so it scores ln(301 / 1) = 5.71.
        target = note("ugrep-dies-on-long-patterns", "The Bash tool's grep is ugrep.")
        corpus = filler(300) + [target]
        prompt = "ugrep crashed again"
        self.assertEqual(rels(match_prompt(prompt, corpus, {}, set())), [target.rel])
        score = math.log(301 / 1)
        self.assertEqual(rels(match_prompt(prompt, corpus, {}, set(), min_score=score - EPS)),
                         [target.rel])
        self.assertEqual(match_prompt(prompt, corpus, {}, set(), min_score=score + EPS), [])
        self.assertEqual(match_prompt("", corpus, {}, set()), [])

    def test_a_common_word_does_not_match_on_its_own(self):
        # N = 300: "docker" is in 20 notes, so it scores ln(300 / 20) = 2.71.
        common = [note(f"docker-{i:02}", "Docker fact.") for i in range(20)]
        corpus = filler(280) + common
        prompt = "Is docker running?"
        self.assertEqual(match_prompt(prompt, corpus, {}, set()), [])
        score = math.log(300 / 20)
        self.assertEqual(len(match_prompt(prompt, corpus, {}, set(), min_score=score - EPS)),
                         MAX_MATCHES)
        self.assertEqual(match_prompt(prompt, corpus, {}, set(), min_score=score + EPS), [])

    def test_two_mid_frequency_words_match_together(self):
        # N = 300: "docker" and "firewall" are each in 20 notes. Either alone
        # scores ln(15) = 2.71, and the one note with both scores 5.42.
        both = note("docker-ports-skip-the-firewall", "Published Docker ports skip the firewall.")
        corpus = (filler(261) + [both]
                  + [note(f"docker-{i:02}", "Docker fact.") for i in range(19)]
                  + [note(f"firewall-{i:02}", "Firewall fact.") for i in range(19)])
        prompt = "Why can docker get past the firewall?"
        self.assertEqual(rels(match_prompt(prompt, corpus, {}, set())), [both.rel])
        score = 2 * math.log(300 / 20)
        self.assertEqual(match_prompt(prompt, corpus, {}, set(), min_score=score + EPS), [])

    def test_a_german_prompt_finds_the_german_term(self):
        # N = 300: "abdocken" is in 1 note and scores ln(300) = 5.70. "login"
        # is in 20 notes and scores ln(15) = 2.71, so it drags none of them in.
        target = note("sway-loses-the-monitor-after-undocking",
                      "Nach dem Abdocken verliert sway den externen Monitor.")
        logins = [note(f"login-{i:02}", "Login fact.") for i in range(20)]
        corpus = filler(279) + logins + [target]
        prompt = "Warum schlägt der Login nach dem Abdocken fehl"
        self.assertEqual(rels(match_prompt(prompt, corpus, {}, set())), [target.rel])
        score = math.log(300 / 1)
        self.assertEqual(match_prompt(prompt, corpus, {}, set(), min_score=score + EPS), [])

    def test_a_prompt_of_filler_words_matches_nothing(self):
        # N = 320. The twenty notes hold the stopwords of the prompts below
        # the way the old store's descriptions do, each in 1 to 5 of them, so
        # each would score ln(320 / 5) = 4.16 or more and fire alone if it
        # were not a stopword. The inner loop proves it for every one: take
        # a single word out of STOPWORDS and its prompt matches a note.
        stems = [note(name, description) for name, description in (
            ("a-container-keeps-its-resolvers",
             "A later change to resolv.conf never reaches a container that is running."),
            ("text-before-a-question-dialog-may-not-be-seen",
             "Prose beside a question dialog may not be seen."),
            ("rcpt-probing-is-blocked",
             "The laptop's address blocks RCPT probing of our own mailboxes."),
            ("plane-refuses-per-page-above-100",
             "Plane refuses per_page above 100 and filters between pages, below the cap, "
             "unless told otherwise."),
            ("mkstemp-ignores-the-umask",
             "mkstemp lands at 0600 whatever the umask says, so those files must be shared "
             "by hand."),
            ("flow-complaint-is-a-term-used-early",
             "When Alice says an order doesn't make sense, a term is used before its "
             "definition."),
            ("rbw-does-not-list-ssh-keys",
             "rbw doesn't list SSH key entries and doesn't know Archive."),
            ("swaymsg-needs-swaysock",
             "swaymsg needs SWAYSOCK over SSH, and for_window rules need a reload."),
            ("snapper-skips-dnf5",
             "The snapper plugin won't snapshot on dnf5, didn't work and isn't loaded."),
            ("git-signing-needs-the-agent",
             "Git says Couldn't find key in agent when it wasn't loaded, and I don't want to "
             "try again."),
            ("read-a-unit-journal-before-its-config",
             "Take a look at a unit's journal first: it can tell you why it isn't working "
             "before you think of its config."),
            ("a-stale-agent-socket-looks-like-a-dead-key",
             "A stale agent socket works for one shell, then fails in every other one; let a "
             "new login restart it to see."),
            ("an-apology-is-not-a-fix",
             "Sorry is not a next step: say what was meant, make sure this is fixed, keep "
             "your tone cool."),
            ("a-shared-checkout-is-ours",
             "A shared checkout is ours: put a reset to them first, never run it yourself, "
             "since others would rather keep theirs."),
            ("a-commit-body-says-why",
             "A commit body shall say why a change was made, not what, which a diff already "
             "shows."),
            ("three-fixes-went-nowhere",
             "Three fixes were made but none worked; what went wrong was a stale cache."),
            ("plane-today-label-is-per-board",
             "Plane's Today label is per board, so My day lists fewer items than half your "
             "boards hold."),
            ("ci-job-cost-grows-per-step",
             "A CI job with five or six more steps plus a cache takes a bit longer per run."),
            ("an-empty-firewall-means-two-things",
             "An empty firewall at one host means deny-all, at another its opposite, "
             "so ask which kind you have now."),
            ("a-preview-lies-about-sharpness",
             "A slide that looks perfect in a preview can still be pretty blurry on a "
             "projector."),
        )]
        corpus = filler(300) + stems
        for prompt in (
                "why doesn't it work, what do I need to know",
                "I don't know why it isn't working, it didn't do that and it wasn't like this",
                "can you take a look and tell me what you think, let's try that again",
                "make sure it works and then let me know, I want to see it",
                "sorry, I meant the other one, may we do it later?",
                "ok cool, our next step then",
                "shall we put it above those, below them or between ours, "
                "unless he says we must not, or would you rather do it yourself?",
                "you made that up and none of it worked, so what went wrong?",
                "plus five or six more steps today, a bit fewer than half",
                "is that perfect now, or kind of the opposite? pretty sure it means we ask again"):
            with self.subTest(prompt=prompt):
                self.assertEqual(match_prompt(prompt, corpus, {}, set()), [])
                used = set(re.findall(r"\w+", prompt.casefold())) & retrieve.STOPWORDS
                for word in sorted(used):
                    with mock.patch.object(retrieve, "STOPWORDS", retrieve.STOPWORDS - {word}):
                        self.assertNotEqual(match_prompt(prompt, corpus, {}, set()), [],
                                            f"{word!r} would not fire without its stopword")
        # The controls: a topic word in the same kind of prompt still finds its note.
        for prompt in ("why doesn't swaymsg work",
                       "may we look at swaymsg later, once it says why?"):
            with self.subTest(prompt=prompt):
                self.assertEqual(rels(match_prompt(prompt, corpus, {}, set())),
                                 ["AI/memory/swaymsg-needs-swaysock.md"])

    def test_at_most_four_matches_within_budget(self):
        # N = 306: six notes, each the only one with its word, all at ln(306) = 5.72.
        words = ["kanshi", "fuzzel", "swaylock", "waybar", "dunst", "ghostty"]
        prompt = " ".join(words)
        short = [note(w, f"{w} fact.", updated=f"2026-10-{10 + i}") for i, w in enumerate(words)]
        found = match_prompt(prompt, filler(300) + short, {}, set())
        self.assertEqual(rels(found), [n.rel for n in reversed(short[2:])])
        self.assertEqual(len(found), MAX_MATCHES)
        # Lines of 300 take 301 each: three take 903 of 1000, and a fourth would not fit.
        long = [note(w, f"{w} " + text(300 - len(f"- {w}: ") - len(w) - 1)) for w in words]
        self.assertEqual({len(line(n)) for n in long}, {300})
        found = match_prompt(prompt, filler(300) + long, {}, set())
        self.assertEqual(len(found), 3)
        self.assertLessEqual(sum(len(line(n)) + 1 for n in found), MATCH_BUDGET)

    def test_matches_rank_by_score_then_touched_domain_then_updated(self):
        # N = 304. "high" holds two prompt words and scores 2 ln(304) = 11.4.
        # The other three hold one each at ln(304) = 5.72, so the touched
        # domain decides, then the newer date.
        high = note("high", "kanshi and fuzzel fact.", domain="[homelab]", updated="2026-01-01")
        touched = note("touched-old", "swaylock fact.", domain="[desktop]", updated="2026-02-01")
        newer = note("untouched-new", "waybar fact.", domain="[homelab]", updated="2026-10-01")
        older = note("untouched-old", "dunst fact.", domain="[homelab]", updated="2026-03-01")
        corpus = filler(300) + [older, newer, touched, high]
        domains = {"desktop": ["sway"], "homelab": ["docker"]}
        found = match_prompt("sway: kanshi fuzzel swaylock waybar dunst", corpus, domains, set())
        self.assertEqual(rels(found), [high.rel, touched.rel, newer.rel, older.rel])

    def test_excluded_notes_are_not_matched_again(self):
        # N = 301: "ugrep" is in 1 note, as in the rare-word case.
        target = note("ugrep-dies", "`pattern too long` from ugrep")
        corpus = filler(300) + [target]
        self.assertEqual(rels(match_prompt("ugrep", corpus, {}, set())), [target.rel])
        self.assertEqual(match_prompt("ugrep", corpus, {}, {target.rel}), [])
        error = "ugrep: pattern too long"
        self.assertEqual(rels(match_failure(error, corpus, set())), [target.rel])
        self.assertEqual(match_failure(error, corpus, {target.rel}), [])


class Domains(unittest.TestCase):
    def test_touched_domains_from_keywords(self):
        self.assertEqual(touched_domains({"docker"}, {"homelab": ["docker"]}), {"homelab"})

    def test_a_domain_name_alone_touches_nothing(self):
        self.assertEqual(touched_domains({"homelab"}, {"homelab": ["docker"]}), set())

    def test_keywords_read_the_way_prompt_words_do(self):
        # A keyword goes through tokens() too, and every word of it must be there.
        self.assertEqual(touched_domains(tokens("Docker Compose"), {"homelab": ["Docker"]}),
                         {"homelab"})
        keyed = {"claude-code": ["claude-code"]}
        self.assertEqual(touched_domains(tokens("a Claude Code hook"), keyed), {"claude-code"})
        self.assertEqual(touched_domains(tokens("dead code"), keyed), set())
        self.assertEqual(touched_domains({"the"}, {"x": ["the", "ok"]}), set())

    def test_digest_is_the_domain_newest_first_within_budget(self):
        # Lines of 999 take 1000 each with the newline, so four fill DIGEST_BUDGET.
        both = sized("both", 999, domain="[desktop, homelab]", updated="2026-10-07")
        h2 = sized("h2", 999, domain="[homelab]", updated="2026-10-05")
        h4 = sized("h4", 999, domain="[homelab]", updated="2026-10-03")
        h1 = sized("h1", 999, domain="[homelab]", updated="2026-10-01")
        h3 = sized("h3", 999, domain="[homelab]", updated="2026-09-01")
        seen = sized("seen", 999, domain="[homelab]", updated="2026-10-10")
        other = sized("other", 999, domain="[desktop]", updated="2026-10-09")
        corpus = [h1, h2, h3, h4, seen, other, both]
        self.assertEqual(4 * 1000, DIGEST_BUDGET)
        self.assertEqual(rels(digest("homelab", corpus, {seen.rel})),
                         [both.rel, h2.rel, h4.rel, h1.rel])
        # The budget is the only cap: short lines all go in.
        short = [note(f"s{i}", domain="[homelab]", updated=f"2026-10-{10 + i}") for i in range(6)]
        self.assertEqual(rels(digest("homelab", short, set())), [n.rel for n in reversed(short)])


class Failure(unittest.TestCase):
    def test_symptoms_are_backticked_spans_of_six_or_more(self):
        self.assertEqual(symptoms("`exceeds complexity limits` and `x`"),
                         ["exceeds complexity limits"])
        self.assertEqual(symptoms("`exit 1` is six, `exit2` is five"), ["exit 1"])
        # Backticks pair in order, so the gap between two short spans is no span.
        self.assertEqual(symptoms("`ab` then `cd`"), [])

    def test_a_failure_matches_its_symptom_case_insensitively(self):
        hit = note("pkill-f-kills-the-shell", "`Exit code 144` with no output from pkill -f.",
                   tags="[gotcha]")
        other = note("ugrep-dies", "`pattern too long` from ugrep", tags="[gotcha]")
        prose = note("prose-symptom", "Exit code 144 in prose is never matched.", tags="[gotcha]")
        found = match_failure("EXIT CODE 144\n(no output)", [hit, other, prose], set())
        self.assertEqual(rels(found), [hit.rel])

    def test_at_most_two_failure_hits(self):
        # All three match. The longest matched symptom is the most specific, so it leads.
        short = note("short", "`code 144` again", updated="2026-10-17")
        middle = note("middle", "`Exit code 144` from pkill", updated="2026-01-01")
        longest = note("longest", "`code 144 with no output`", updated="2026-01-01")
        found = match_failure("Exit code 144 with no output", [short, middle, longest], set())
        self.assertEqual(len(found), MAX_FAILURE_HITS)
        self.assertEqual(rels(found), [longest.rel, middle.rel])


class Header(unittest.TestCase):
    def test_header_copy_is_exact(self):
        with mock.patch.dict(os.environ, {"HOME": "/home/tester"}):
            vault = Path("/home/tester/Vault")
            where = "~/Vault/AI/memory"
            self.assertEqual(header("pinned", vault),
                             f"Pinned memory (notes in {where}; "
                             f"open one only when its line is not enough):")
            self.assertEqual(header("match", vault),
                             f"Memory that may apply to this prompt (notes in {where}):")
            self.assertEqual(header("digest", vault, "homelab"),
                             f"Memory digest for homelab, most recently verified first "
                             f"(notes in {where}):")
            self.assertEqual(header("failure", vault),
                             f"Memory that may explain this failure (notes in {where}):")

    def test_only_a_path_inside_home_gets_the_tilde(self):
        with mock.patch.dict(os.environ, {"HOME": "/home/tester"}):
            for vault, where in ((Path("~/Vault"), "~/Vault/AI/memory"),
                                 (Path("/srv/vault"), "/srv/vault/AI/memory"),
                                 (Path("/home/tester2/v"), "/home/tester2/v/AI/memory")):
                with self.subTest(vault=vault):
                    self.assertEqual(header("match", vault),
                                     f"Memory that may apply to this prompt (notes in {where}):")


if __name__ == "__main__":
    unittest.main()
