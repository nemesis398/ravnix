"""agent-doctor: catch drift in the agent-instruction corpus.

The corpus is spread over two trees that no single tool owns: the vault's
conventions and roles, and the Claude Code skills. Nothing is generated from
anything else, so prevention is not available and detection is what is left.
Until 2026-10-03 the OpenCode fleet was a third tree; it went with OpenCode.

Four checks. The first three have each fired for real at least once; the fourth
has not, and says so below rather than implying coverage it has not earned.

  DUPLICATE  a canonical rule restated away from its home, without pointing at
             the home. This is the one P2 exists to prevent regrowing.
  DEADPATH   a file, script or note the instructions tell a model to read, that
             is not there. Cheap to introduce by renaming one file.
  LINECOUNT  a prose claim of the form "<path>, N lines" that no longer matches.
             `.claude/skills/vault/SKILL.md` claimed LIBRARIAN.md was 105 lines
             when it was 118, which is how the drift was first noticed at all.
  AGREEMENT  a fact deliberately stated in more than one file, whose copies have
             drifted apart. This is the INVERSE of DUPLICATE: there, a second
             copy IS the defect; here both copies are meant to exist and only
             disagreement is. Added 2026-08-23, when P8 put the memory type
             vocabulary in two files that must match and nothing watched them.
             It has not fired for real yet, and since 2026-10-03 it watches
             nothing: both of its agreements paired a Claude Code file with an
             OpenCode one and went with OpenCode. See AGREEMENTS.

Exit 0 is the gate, matching vault-check. Stdlib only, so it runs anywhere.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

HOME = Path.home()


def skill_value(*keys):
    """A string from the skill values file (claude/README.md), or "" when the
    file, the key or the type is not there."""
    path = os.environ.get("RAVNIX_SKILL_VALUES") or os.path.join(
        os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config"),
        "ravnix", "skill-values.json")
    try:
        with open(path, encoding="utf-8") as fh:
            value = json.load(fh)
        for key in keys:
            value = value[key]
    except (OSError, ValueError, KeyError, TypeError):
        return ""
    return value if isinstance(value, str) else ""


# Nothing about where the corpus lives is built in. The vault is VAULT_DIR,
# else the skill value vault.root; the skills are AGENT_DOCTOR_SKILLS, else
# ~/.claude/skills; the machine-wide norms document is AGENT_DOCTOR_NORMS,
# and without one the rules whose home it is, and its place in the corpus,
# are left out.
VAULT_GIVEN = os.environ.get("VAULT_DIR") or skill_value("vault", "root")
VAULT = Path(VAULT_GIVEN or "/nonexistent-vault")
CLAUDE_SKILLS = Path(os.environ.get("AGENT_DOCTOR_SKILLS") or HOME / ".claude/skills")
NORMS = Path(os.environ["AGENT_DOCTOR_NORMS"]) if os.environ.get("AGENT_DOCTOR_NORMS") else None
# ~/.claude/CLAUDE.md is a symlink, and the corpus collects it by this
# path, so an exemption has to spell it the same way or it silently never
# matches. It is always-loaded for Claude Code the way the vault's AGENTS.md
# is, but machine-wide rather than per-tree, which is why it is not in
# ALWAYS_LOADED: putting it there would exempt it from all seven replicated
# rules at once and blind six probes that currently cover it.
CLAUDE_MD = HOME / ".claude/CLAUDE.md"

# ---------------------------------------------------------------------------
# The canonical rules.
#
# `home` is the one file allowed to state the rule outright. `probe` matches a
# statement of it. `pointer` matches text that defers to the home instead of
# restating; a file that matches `probe` AND `pointer` is fine, because it is
# reminding the reader a rule exists and sending them to the source. A file
# that matches `probe` alone is a second authoritative copy, which is the
# defect. Keep probes narrow: a probe that matches a passing mention produces
# noise, and a noisy doctor gets ignored, which is worse than no doctor.
# ---------------------------------------------------------------------------
# A role file is routinely loaded ALONE, so a rule it does not state is a rule
# its reader never sees. The maintainer decided on 2026-08-19 that the two rules which
# have already caused real damage stay replicated in every role file
# deliberately: cheap insurance, and pointers only help when they are followed.
# Those carry `replicate_in_roles`, and a copy inside a role file is expected
# rather than a finding. Everywhere else they are still deduplicated.
ROLE_DIRS = (VAULT / ".agents", VAULT / ".claude/skills")


def is_role_file(f: Path) -> bool:
    return any(str(f).startswith(str(d)) for d in ROLE_DIRS)


# AGENTS.md is the only vault file loaded into every session; Vault.md is a
# note somebody has to open first. The maintainer decided on 2026-08-23 that the split
# there is not "safety rules versus the rest" but what fails silently versus
# what the gate catches loudly. never-mv and path= destroy notes without a
# sound. vault-check is the gate that catches the others, so dropping it from
# the always-loaded file would quietly disarm them. Nothing whatsoever checks
# the frontmatter property set: vault-check has no frontmatter test at all
# (verified 2026-08-23), so a fifth property just drifts in. Those four stay
# stated in full. bare-wikilinks does not, because vault-check raises an ERROR
# on all three broken forms and a copy here buys nothing a green gate does not.
# The vault's AGENTS.md reaches every Claude Code session in the vault. It
# carries the rules whose violation is silent, and it is exempt from the
# duplicate check for exactly those rules. Until 2026-10-03 the OpenCode
# AGENTS.md stood here too, as the one channel that reached all nine OpenCode
# agents; it went with OpenCode.
ALWAYS_LOADED = (VAULT / "AGENTS.md",)


RULES = [
    {
        "id": "never-mv-a-note",
        "home": VAULT / "Vault.md",
        "replicate_in_roles": True,
        "replicate_in_always_loaded": True,
        # The object matters. Without it this fired on "never rename it
        # unprompted" about the Linux account name in the OpenCode
        # AGENTS.md, which is the opposite advice about a different thing.
        # Found 2026-08-23, the first finding the widened corpus produced.
        "probe": (re.compile(r"(never|nie)\b", re.I),
                  re.compile(r"\b(mv|rm|rename)\b", re.I),
                  re.compile(r"\bnotes?\b", re.I)),
        "why": "moving a note outside Obsidian breaks every inbound wikilink",
    },
    {
        "id": "obsidian-cli-path-arg",
        "home": VAULT / "Vault.md",
        "replicate_in_roles": True,
        "replicate_in_always_loaded": True,
        "probe": re.compile(
            r"((always|never|must|bare)[^\n]{0,80}\bpath=|\bpath=[^\n]{0,80}(always|never|must|bare|positional))",
            re.I),
        "why": "a bare argument acts on whatever note is open; cost two MOCs",
    },
    {
        "id": "vault-check-is-the-gate",
        "home": VAULT / "Vault.md",
        "replicate_in_always_loaded": True,
        # Tightened 2026-08-23, same lesson as bare-wikilinks-only.
        # `run\W{0,4}`?vault-check` fired on every procedural "then run
        # `vault-check`" in a role's session loop, which is workflow rather
        # than a second authoritative statement of the rule: eleven of its
        # fourteen findings were that shape. The rule is "exit 0 is the gate";
        # a step that runs the command is not restating it. `is the gate` on
        # its own was tried and rejected, because it also matched "the house
        # checker is the gate" about the prose checker.
        "probe": re.compile(
            r"(vault-check[^\n]{0,45}(exit 0|is the gate|before you claim)|"
            r"exit 0[^\n]{0,20}is the gate|before you claim you are done)", re.I),
        "why": "the rule is exit 0, not the act of running it",
    },
    {
        "id": "bare-wikilinks-only",
        "home": VAULT / "Vault.md",
        # Tightened 2026-08-23. `bare\W{0,12}wikilink` fired on USAGE, not on
        # restatement: "a bare wikilink to the note the fact came from" is the
        # anki role being told what to put on a card, and three of its four
        # findings that day were that shape. A rule restatement names a
        # forbidden form or puts the link in subject position with a copula;
        # usage says "a bare wikilink" as the object of a verb. Match the
        # former only.
        "probe": re.compile(
            r"(folder path|path[- ]qualified|relative prefix|note name alone|"
            r"markdown link[^\n]{0,30}\.md|(every |all )?wikilinks? (is|are|must be) bare|"
            r"links? (are|must be) bare)", re.I),
        "why": "three forbidden forms, and vault-check greps raw text",
    },
    {
        "id": "closed-property-set",
        "home": VAULT / "Vault.md",
        "replicate_in_always_loaded": True,
        "probe": (re.compile(r"\btype\b", re.I), re.compile(r"\bstatus\b", re.I),
                  re.compile(r"\bdomain\b", re.I), re.compile(r"\bupdated\b", re.I)),
        "why": "the four queried properties are a closed set",
    },
    {
        "id": "no-em-dashes",
        "home": CLAUDE_SKILLS / "prose/SKILL.md",
        "probe": re.compile(r"(no|never|kein).{0,20}em[- ]dash", re.I),
        "why": "house style lives in the prose skill",
    },
    # --- P5, the machine-wide norms. Home is working-norms.md, which the
    # always-loaded files are supposed to cite rather than copy. Added 2026-08-23 so P5
    # has a before-number the way P2 did; without them its duplication was
    # measured by nothing at all.
    {
        "id": "selinux-stays-enforcing",
        "home": NORMS,
        "replicate_in_always_loaded": True,
        "probe": re.compile(r"(SELinux stays Enforcing|never disable SELinux|"
                            r"never\W{0,4}`?setenforce)", re.I),
        "why": "SELinux failures are silent, which is why the rule exists",
    },
    {
        "id": "fewest-package-sources",
        "home": NORMS,
        "probe": re.compile(r"fewest package sources", re.I),
        "why": "one ordered tier list, restated as a compressed arrow chain",
    },
    {
        "id": "no-runtime-state-in-synced-tree",
        "home": NORMS,
        "replicate_in_always_loaded": True,
        "probe": (re.compile(r"\b(mutable|runtime)\b", re.I),
                  re.compile(r"(synced tree|Nextcloud)", re.I),
                  re.compile(r"\b(never|not|keep .{0,12}out)\b", re.I)),
        "why": "writing state into the synced tree corrupts it quietly",
    },
    {
        "id": "snapshot-before-system-change",
        "home": NORMS,
        "replicate_in_always_loaded": True,
        "probe": re.compile(r"snapshot before (any |every )?(root|system|phase|a )", re.I),
        "why": "the rollback is missing exactly when it is needed",
    },
    {
        # Added 2026-08-23. The maintainer ruled that the duty is machine-wide, so it
        # stands in three files and all three are legitimate. NORMS is the
        # home. ~/.claude/CLAUDE.md, always loaded, restates it because
        # forgetting to write the note fails silently: nothing reports a
        # missing daily note, ever. The `journal` skill restates it because it
        # is the implementation, the same relationship `prose/SKILL.md` has to
        # the em dash ban. What this rule is actually for is the fourth copy: a
        # role file that inlines the duty and then drifts, which is exactly
        # what P2 removed elsewhere. (Until 2026-10-03 the OpenCode AGENTS.md
        # was a legitimate copy too; it went with OpenCode.)
        "id": "daily-note-duty",
        "home": NORMS,
        "replicate_in_always_loaded": True,
        "replicate_in": (CLAUDE_MD, CLAUDE_SKILLS / "journal/SKILL.md"),
        # Two parts, because "daily note" alone matches every role that merely
        # reads one, and the scribe reads them all day. The rule is the DUTY,
        # so the probe needs the obligation as well as the object.
        "probe": (re.compile(r"daily note", re.I),
                  re.compile(r"(noteworthy|before the session ends|"
                             r"the bar is|goes into)", re.I)),
        "why": "a missing daily note is never reported by anything",
    },
    # REMOVED 2026-08-19: "prose-checker-invocation". It only ever appeared
    # inside fenced code blocks, which are now excluded as usage rather than
    # restatement, so it could never fire again. It was a command, not a rule,
    # and commands recur legitimately with a per-role argument. A rule that
    # cannot fire is worse than no rule: it implies coverage that is not there.
]
# A rule whose home is the norms document has no home without one.
RULES = [r for r in RULES if r["home"] is not None]

# ---------------------------------------------------------------------------
# Facts that are deliberately stated in more than one file.
#
# RULES above is about a rule having ONE home. This list is the opposite case,
# and P2's dedup cannot reach it: sometimes two files must BOTH carry a fact
# because neither can read the other, and then the defect is not the second
# copy but the two copies disagreeing. Nothing in DUPLICATE can express that,
# which is why this is a check of its own rather than a twelfth rule.
#
# `files` are named directly instead of being drawn from corpus(), because an
# agreement is between specific documents. That also lets it reach files the
# corpus does not collect at all: OpenCode's `commands/write-memory.md` was not
# in the corpus, so before this check nothing in the tool had ever read it.
#
# `tokens` are compared as literal substrings, and they are backticked on
# purpose. Bare `user` or `project` are ordinary English and would match any
# prose; a backticked word is somebody naming an identifier. Verified
# 2026-08-23 that all five memory types appeared in that form in both files
# of the first agreement.
#
# Fences are NOT stripped here, unlike DUPLICATE. There a command inside a
# fence is usage rather than a restatement; here a vocabulary written into a
# template is still that file stating the vocabulary, and blanking it would
# hide the very line most likely to drift.
# ---------------------------------------------------------------------------
AGREEMENTS: list[dict] = [
    # Empty since 2026-10-03. Both agreements this list held paired a Claude
    # Code file with an OpenCode one, and went with OpenCode:
    #
    #   memory-type-vocabulary   ~/.claude/CLAUDE.md against OpenCode's
    #                            commands/write-memory.md. The five memory
    #                            types now live in ~/.claude/CLAUDE.md alone.
    #   handoff-reminder-parity  the handoff skill's stop.py against its
    #                            OpenCode plugin, handoff.ts.
    #
    # check_agreement() stays, so the next fact that has to be stated in two
    # files can be registered here. Until one is, this check watches nothing,
    # and --rules shows no agreement rather than implying coverage.
]

# A pointer defers rather than restates. Generous on purpose: the failure mode
# to avoid is flagging a legitimate cross-reference.
# The short words need word boundaries. Without them `per` matched inside
# "properties" and `read` inside "already", so any sentence using either word
# was silently treated as pointing and never reported. That is the dangerous
# direction for this tool: a false positive is visible and gets argued with, a
# false negative just lowers the number and looks like progress. Found and
# fixed 2026-08-23. It changed no finding on the corpus of that day, so the bug
# was latent rather than active: no sentence that matched a probe also happened
# to contain one of those words. Kept anyway, because the next rule added is
# the one that trips it.
#
# Bare `per` then turned out to be worse than either. It is a preposition here
# far more often than a citation: "capped at roughly one per 200 words",
# "average links per note, per folder", "one card pair per table row". Each of
# those silently exempted the bullet it sat in. It now has to be followed by
# the start of a reference, which is what "per `Vault.md`" looks like. Found
# 2026-08-23 while checking why two em-dash findings had vanished.
# Naming a rule's home file IS pointing at it, so those names are derived from
# RULES rather than listed by hand. Written out, the list goes stale the moment
# a rule gets a new home: `working-norms.md` was added as a home for P5 and
# every citation of it read as a restatement until this was fixed (2026-08-23).
_POINTER_BASE = (
    r"\b(?:see|read|siehe)\b|\bper\s+[`~\[]|defined in|lives in|owns? (that|this)|"
    r"canonical|\[\[Vault\]\]|prose.{0,10}skill|`prose`|\.claude/skills/[\w-]+"
)
# A generic basename is not an identifier. `prose/SKILL.md`'s name is just
# "SKILL.md", and admitting that would make every mention of any skill file
# read as a citation of the prose skill. Those get the parent folder attached.
_GENERIC = {"SKILL.md", "AGENTS.md", "CLAUDE.md", "README.md", "index.md"}


def _home_token(home) -> str:
    if home.name in _GENERIC:
        return re.escape(f"{home.parent.name}/{home.name}")
    return re.escape(home.name)


POINTER = re.compile(
    "(" + _POINTER_BASE + "|"
    + "|".join(sorted({_home_token(r["home"]) for r in RULES}))
    + ")", re.I
)

# "…/LIBRARIAN.md, 105 lines" or "`x.md` (118 lines)"
LINECOUNT = re.compile(r"`?([\w./\- ]+\.md)`?[^\n]{0,24}?\(?(\d{2,4})\s+lines\)?")

# Paths the corpus tells a model to open.
CITED_PATH = re.compile(r"`([~./][\w./\- ]+\.(?:md|py|sh|json|ts|base))`")

# Two things look like a path in backticks and are not one. Both produced
# false positives on the first run, and a doctor that cries wolf gets muted.
#   - a bare filename SUFFIX, e.g. `.excalidraw.md`, which names a file *kind*
#   - a placeholder in the adapter-pattern table: `.agents/ROLE.md`,
#     `.claude/skills/role/SKILL.md`, standing in for anki/scribe/tutor/...
PLACEHOLDER = re.compile(r"(^\.[\w-]+\.md$|\bROLE\.md$|/role/|/role\.md$)")


def corpus() -> list[Path]:
    """Every file that instructs a model. Missing trees are skipped, not fatal:
    this has to stay runnable on a machine that only has one of them."""
    out: list[Path] = []
    for p in (VAULT / "Vault.md", VAULT / "AGENTS.md", VAULT / "CLAUDE.md",
              HOME / ".claude/CLAUDE.md", NORMS):
        if p is not None and p.is_file():
            out.append(p)
    for d, pat in ((VAULT / ".agents", "*.md"),
                   (VAULT / ".claude/skills", "*/SKILL.md"),
                   (CLAUDE_SKILLS, "*/SKILL.md")):
        if d.is_dir():
            out.extend(sorted(d.glob(pat)))
    return out


_FENCE = re.compile(r"^\s*```", re.M)


def strip_code_fences(text: str) -> str:
    """Blank out fenced code blocks, preserving line count.

    A command inside a fence is USAGE, not a restatement of a rule. Five files
    show `check.py` with a role-appropriate argument (`"Some Machine.md"` in
    the documenter, `"$SCRATCH/entry.md"` in the journal) inside their own
    verification checklists. Counting those as duplicate authoritative copies
    is what made this tool report removable duplication it could not actually
    remove: deleting them would force every role to look the invocation up and
    guess its own argument. Rules live in prose; commands recur legitimately.
    """
    out, inside = [], False
    for ln in text.split("\n"):
        if _FENCE.match(ln):
            inside = not inside
            out.append("")
            continue
        out.append("" if inside else ln)
    return "\n".join(out)


def paragraphs(text: str):
    """Blank-line separated blocks, with the line number the block starts on."""
    line = 1
    for block in text.split("\n\n"):
        yield line, block
        line += block.count("\n") + 2


# Sentence-ish boundaries. Markdown bullets and headings end a thought as
# reliably as a full stop here, so they count.
_SENTENCE_END = re.compile(r"(?<=[.!?:])\s+|\n\s*[-*]\s+|\n#{1,6}\s+")


def sentences(block: str):
    """(offset, sentence) pairs for a block, so probe and pointer are judged on
    the same unit and a finding can be located at the sentence, not the block."""
    starts = [0] + [m.end() for m in _SENTENCE_END.finditer(block)]
    ends = [m.start() for m in _SENTENCE_END.finditer(block)] + [len(block)]
    for s, e in zip(starts, ends):
        if block[s:e].strip():
            yield s, block[s:e]


# A bullet is where a pointer belongs, and a sentence is too fine a unit for it.
# The PROBE stays per sentence, because that is what fixed a tuple probe
# matching four words scattered across four unrelated bullets. But a writer who
# says "see [[Vault]]" in the first sentence of a bullet has pointed for the
# whole bullet, and demanding the phrase again three sentences later produces
# text nobody would write. Measured on `.agents/LIBRARIAN.md`: its ERROR
# catalog needed the same four words in three of four bullets before this.
# Deliberately NOT paragraph-wide, which is the loosening that once hid two
# thirds of the findings: a paragraph spans unrelated bullets, a bullet does not.
_BULLET = re.compile(r"(?m)^\s*(?:[-*]\s+|\d+\.\s+)")


def pointer_scope(block: str, pos: int, window: str) -> str:
    """The list item containing `pos`, else the adjacent-sentence window.

    Falling back to the whole block would BE paragraph granularity, which is
    the loosening that once hid two thirds of the findings. A bullet is a
    bounded unit a writer treats as one thought, so a pointer anywhere in it
    counts. Outside a list the unit is the sentence plus its two neighbours,
    because both of these defer and a reader would say so:

        "No em dashes. That is the house rule in the `prose` skill."
        "The `prose` skill holds the house style: no em dashes, ..."

    Demanding the citation inside the same sentence as the rule produces text
    nobody writes. Three sentences is still bounded; a paragraph is not.
    """
    starts = [m.start() for m in _BULLET.finditer(block)]
    begin = max([s for s in starts if s <= pos], default=None)
    if begin is None:
        return window
    after = [s for s in starts if s > pos]
    return block[begin:after[0]] if after else block[begin:]


def sentence_around(block: str, pos: int) -> str:
    """The sentence containing offset `pos`.

    Paragraph granularity was the first cut and it under-reported badly: any
    paragraph that restated a rule but mentioned `Vault.md` anywhere in its
    several lines was scored a pointer and passed silently. Only 2 of 7 rules
    produced findings while a plain grep showed 10 to 13 files touching the
    others. Judging the sentence the rule is actually stated in is the honest
    unit: a real pointer says "see Vault.md" in the same breath as the rule,
    not four lines later about something else.
    """
    starts = [0] + [m.end() for m in _SENTENCE_END.finditer(block)]
    ends = [m.start() for m in _SENTENCE_END.finditer(block)] + [len(block)]
    for s, e in zip(starts, ends):
        if s <= pos < e:
            return block[s:e]
    return block


def probe_match(probe, text):
    """A probe is one regex, or several that must ALL match the same text.

    The multi-regex form exists because some rules have no single canonical
    spelling: the four view properties appear in at least three orders, joined
    by "and" or "or". Matching one exact comma-list found 3 of 8 copies and
    looked like a clean result. Returns the earliest match position, or None.
    """
    if isinstance(probe, tuple):
        ms = [r.search(text) for r in probe]
        return min((m.start() for m in ms), default=None) if all(ms) else None
    m = probe.search(text)
    return m.start() if m else None


def check_duplicates(files: list[Path]) -> list[str]:
    out = []
    for rule in RULES:
        home = rule["home"]
        for f in files:
            if f == home:
                continue
            if rule.get("replicate_in_roles") and is_role_file(f):
                continue  # deliberate safety replication, not drift
            if rule.get("replicate_in_always_loaded") and f in ALWAYS_LOADED:
                continue  # see ALWAYS_LOADED: silent failure, or the gate itself
            if f in rule.get("replicate_in", ()):
                continue  # this rule only: a named file that may restate it
            try:
                text = strip_code_fences(f.read_text(encoding="utf-8"))
            except (OSError, UnicodeDecodeError):
                continue
            hit = None
            for para_line, para in paragraphs(text):
                sents = list(sentences(para))
                # Sentence granularity for the PROBE too, not just for POINTER.
                # Judging the probe per paragraph was wrong twice over: a
                # markdown bullet list is one blank-line-separated block, so a
                # multi-regex probe matched four words scattered across four
                # unrelated bullets, and the finding was then reported at the
                # line the block started on rather than where the rule is.
                for i, (s_start, sent) in enumerate(sents):
                    if probe_match(rule["probe"], sent) is None:
                        continue
                    window = " ".join(s for _, s in sents[max(0, i - 1):i + 2])
                    if POINTER.search(pointer_scope(para, s_start, window)):
                        continue
                    hit = para_line + para[:s_start].count("\n")
                    break
                if hit is not None:
                    break
            if hit is not None:
                rel = str(f).replace(str(HOME), "~")
                out.append(
                    f"DUPLICATE {rel}:{hit}\n"
                    f"          restates '{rule['id']}' without pointing at "
                    f"{str(home).replace(str(HOME), '~')}\n"
                    f"          ({rule['why']})"
                )
    return out


def check_deadpaths(files: list[Path]) -> list[str]:
    out = []
    for f in files:
        try:
            text = f.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for m in CITED_PATH.finditer(text):
            raw = m.group(1)
            if PLACEHOLDER.search(raw):
                continue
            cand = Path(os.path.expanduser(raw))
            if not cand.is_absolute():
                cand = f.parent / raw
            if cand.exists():
                continue
            # A relative path is usually vault-root-relative rather than
            # sibling-relative. Resolve it as written: `.lstrip("./")` looks
            # right and is wrong, because it eats the leading dot of
            # `.agents/SCRIBE.md` and turns a live path into a false positive.
            rel_raw = raw[2:] if raw.startswith("./") else raw
            if (VAULT / rel_raw).exists():
                continue
            lineno = text[: m.start()].count("\n") + 1
            rel = str(f).replace(str(HOME), "~")
            out.append(f"DEADPATH  {rel}:{lineno}\n          cites `{raw}`, which is not there")
    return out


def check_linecounts(files: list[Path]) -> list[str]:
    out = []
    for f in files:
        try:
            text = f.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        for m in LINECOUNT.finditer(text):
            named, claimed = m.group(1).strip(), int(m.group(2))
            for base in (f.parent, VAULT, VAULT / ".agents", VAULT / ".claude/skills"):
                cand = base / named
                if cand.is_file():
                    actual = len(cand.read_text(encoding="utf-8").splitlines())
                    if actual != claimed:
                        lineno = text[: m.start()].count("\n") + 1
                        rel = str(f).replace(str(HOME), "~")
                        out.append(
                            f"LINECOUNT {rel}:{lineno}\n"
                            f"          claims {named} is {claimed} lines; it is {actual}"
                        )
                    break
    return out


def check_agreement() -> list[str]:
    """Named files that must all state the same fact, reported when they stop.

    The unit is the token, not the file, so a vocabulary that gained a sixth
    type in one place names exactly the missing word rather than saying the
    two files differ somehow.

    Three outcomes per token, and the third is the one worth explaining. If
    every file has it, there is nothing to say. If some do and some do not,
    the ones missing it are the finding. If NO file has it, the files still
    agree, and the defect has moved into this list: the token was renamed or
    dropped everywhere and the entry was never updated. That is reported as
    STALE rather than passed over, because a check watching for a string that
    no longer exists anywhere is the "rule that cannot fire" the removed
    prose-checker rule was deleted for.

    A file that is simply absent is skipped, and an agreement with fewer than
    two files present is skipped whole. This tool has to keep running on a
    machine that only has one of the trees, which is the same reason
    corpus() tolerates missing directories.
    """
    out = []
    for ag in AGREEMENTS:
        texts = {}
        for f in ag["files"]:
            if not f.is_file():
                continue
            try:
                texts[f] = f.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError):
                continue
        if len(texts) < 2:
            continue
        for tok in ag["tokens"]:
            have = [f for f in texts if tok in texts[f]]
            if not have:
                out.append(
                    f"AGREEMENT {ag['id']}: STALE\n"
                    f"          declares {tok}, which no longer appears in any of "
                    f"the {len(texts)} files;\n"
                    f"          update AGREEMENTS in this script, or the check is "
                    f"watching nothing"
                )
                continue
            for f in texts:
                if f in have:
                    continue
                rel = str(f).replace(str(HOME), "~")
                others = ", ".join(
                    str(o).replace(str(HOME), "~") for o in have
                )
                out.append(
                    f"AGREEMENT {rel}\n"
                    f"          does not state {tok} for '{ag['id']}', but "
                    f"{others} does\n"
                    f"          ({ag['why']})"
                )
    return out


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="agent-doctor", description=__doc__.split("\n")[0])
    ap.add_argument("--quiet", action="store_true", help="findings only, no summary")
    ap.add_argument("--rules", action="store_true", help="list the canonical rules and exit")
    args = ap.parse_args(argv)

    if not VAULT_GIVEN and not args.rules:
        print("agent-doctor: no vault: set VAULT_DIR, or vault.root in ravnix.claude.skillValues",
              file=sys.stderr)
        return 2

    if args.rules:
        for r in RULES:
            print(f"{r['id']:<26} home: {str(r['home']).replace(str(HOME), '~')}")
        # Listed here too, because "what does this tool watch" is one question
        # and answering it with only the one-home rules would understate it.
        for a in AGREEMENTS:
            shared = ", ".join(str(f).replace(str(HOME), "~") for f in a["files"])
            print(f"{a['id']:<26} agreed across: {shared}")
        return 0

    files = corpus()
    findings = (check_duplicates(files) + check_deadpaths(files)
                + check_linecounts(files) + check_agreement())

    for f in findings:
        print(f)
        print()

    if not args.quiet:
        print(f"SUMMARY {len(findings)} finding(s) across {len(files)} instruction file(s)")
    return 1 if findings else 0


if __name__ == "__main__":
    raise SystemExit(main())
