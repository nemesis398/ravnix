# prose skill, design record

Written 2026-07-27. The vault is not a git repository, so this lives beside the
skill rather than in `docs/superpowers/specs/`.

## Problem

The vault held 1179 em dashes against 268 en dashes. The em dashes are almost
entirely in AI-written files. {{user.name}}'s own hand-written German uses the spaced en
dash correctly as Gedankenstrich. So the complaint is not about dashes in
general, it is about generated text having a recognisable fingerprint, and
about German and English both needing to come out correct.

## Decisions

**One bilingual skill, not two.** The vault mixes languages inside single
files: today's daily note has English headings over German prose. Two
language-scoped skills would duplicate most of their content and compete to
trigger on exactly the files that matter most.

**Two layers, kept apart.** Mechanical rules are script-enforced and provable.
Voice is taught with reasons. Collapsing them into one banned-word list is why
that genre of skill fails: the output dodges the listed words and keeps the
underlying tic, which is structural.

**Dash policy, per language.** German keeps ` – ` capped at roughly one per 200
words, because it is correct German and it is how {{user.name}} writes; the cap targets
the habit, not the character. English restructures. `—` is zero everywhere.
Ranges keep the unspaced en dash in both.

**Emoji are labels, not decoration.** Derived from the vault rather than
assumed: leading the heading, one per heading, semantically literal, only on
headings a reader scans for, none in body text. A repeated emoji, or one that
also labels a heading, is recognised as a deliberate legend and left alone.

**Verification is part of the skill, not a suggestion.** The skill is not
finished until `check.py` has run on the saved text and its output has been
read. Without that it is advice, and advice does not deliver "free of errors".

## Settled from evidence, not preference

- American spelling. `organize` 7/0, `behavior` 11/1, `color` 30/3, `center`
  8/0 across the vault. The `analyse` hits are the German noun.
- Lowercase `du`, confirmed by {{user.name}}. The vault had no real convention, six `Du`
  against three `du`, all in generated files.
- Emoji concentrate at H1 and H2 and appear on a minority of headings, so the
  rule is "headings a reader scans for", not "every heading".

## Scope

Files, commit message bodies, comments and identifiers. Not chat replies, so
the global `CLAUDE.md` was left untouched. In source files only the spelling
and dash rules apply.

## Empirical findings that shaped the implementation

Three things were established against the live LanguageTool API because
assuming them the other way produces confidently wrong output.

1. **Offsets are UTF-16 code units.** LanguageTool is a JVM program. Each emoji
   before a finding shifts its reported position by one and the error
   accumulates. In this vault every file is affected.
2. **`interpretAs` does not shift offsets.** Markup counts at full original
   length and the replacement contributes nothing, so offsets are positions in
   the original document once converted from UTF-16. The plaintext mapping
   layer originally built for this was wrong and was deleted.
3. **`software.premium` is not the tier signal.** It is `true` even on the free
   endpoint because it describes the build. `premiumHint` is present exactly
   when premium rules were not applied.

## Rejected

- Sending a mixed document under one language code. It looks like a clean
  result and is not one: the English paragraphs get German grammar rules and no
  English spellcheck at all.
- Flagging each dash past the budget. The budget is a document property, so the
  cutoff position is arbitrary and the report is noise. It is one finding that
  names the densest paragraphs.
- Repeating an identical emoji warning per occurrence. On a note with an emoji
  legend that produced 22 warnings for the legend and buried everything else.

## Closed 2026-07-27

**The premium key works.** The consumer Premium key authenticates against
`api.languagetoolplus.com` with no support request, despite LanguageTool's own
docs implying otherwise. It lives in a password manager and reaches the checker
through the environment or rbw.

**Premium needed three filters before it was usable.** More findings turned out
not to mean better findings:

- `LT_RECOMMENDATION_*` are adverts, not errors, and are dropped.
- `QB_NEW_*` declare `issueType=grammar` but are rephrasing suggestions. On one
  real note they arrived as 23 errors, including capitalising `restic` and
  lowercasing a vendor's product name "Cloud Storage". Demoted to warnings, which
  took that note to 0 errors and 15 warnings.
- Suggestion-class rules read a markdown table row as prose and would corrupt
  it, so they are dropped on table rows.

German came back at 0 errors and 1 arguable warning per document even in picky
mode, so the German side needed no tuning.

## Heading case, a finding that turned out to be a misreading

Flagged during the eval review as an inconsistency between runs. It was not.
Measured across the vault, excluding German headings and single proper nouns:

| | Title Case | sentence case |
|---|---|---|
| note filenames | 26 | 1 |
| `#` | 29 | 11 |
| `##` | 25 | 61 |
| `###` | 19 | 31 |

The convention is Title Case for the note name and its H1, sentence case for
headings inside, which is ordinary editorial practice. Both English runs
followed it correctly. The apparent disagreement was an H1 compared against an
H2, which is the convention working rather than failing.

The initial claim was drawn from *note titles* rather than from headings
inside documents, which is why it pointed the wrong way.

It is now stated in SKILL.md so the behaviour is instructed rather than
incidental, and deliberately left out of the checker: separating a wrongly
capitalised heading from a run of proper nouns needs judgment the script does
not have, and a rule that fired on `Proxmox Backup Server` would do more harm
than the rule prevents.

## Open

Nothing blocking.
