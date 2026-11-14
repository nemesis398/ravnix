---
name: prose
description: >-
  Write and repair prose in German and English so it is free of errors and does
  not read as machine-written. Holds {{user.name}}'s house style: no em dashes anywhere,
  the spaced en dash kept as the German Gedankenstrich but capped, emoji as
  literal section labels in headings only and never in body text, DIN 5008
  typography in German, American spelling in English. Bundles a checker that
  masks the markdown and runs LanguageTool, so correctness is verified rather
  than claimed. Use this whenever text is being produced or edited for a human
  reader: vault notes, daily notes, documentation, READMEs, mails, report
  entries, the body of a commit message, comments in source files, or when
  {{user.name}} pastes text and asks to clean it up, proofread it, fix the German, kill the em
  dashes, or make it sound less like AI. Use it even when the request says
  nothing about style, because output otherwise drifts straight back to em
  dashes and machine rhythm.
license: AGPL-3.0-or-later
metadata:
  languages: de, en
---

# Prose

Two jobs, same rules.

- **Compose.** Write the text, then verify it, then hand it over.
- **Repair.** Verify first, read what came back, fix, verify again.

The order matters in both directions. Composing without verifying means
shipping em dashes you did not notice writing. Repairing without verifying
first means guessing at what is wrong.

## The loop

Nothing is finished until the checker has run on the actual saved text and you
have read its output.

```bash
{{ravnix.python}} {{ravnix.skillDir}}/scripts/check.py path/to/file.md
```

Useful flags: `--no-lt` skips the network and runs the deterministic pass only,
`--picky` turns on LanguageTool's formal-text rules for something that has to
be correct in front of other people, `--json` for parsing, `--stdin` for text
that is not in a file yet, `--selftest` to see which backend answers.

`--json` prints one object per file, with that file's findings nested under
`findings`. Flatten it with
`[x for f in json.load(sys.stdin) for x in f['findings']]` and index
`x['line']`, not `.get`: a filter over the top level matches nothing and
reports a clean zero for a file with 16 errors.

Fix every `error`. Read every `warning` and decide, because some of them are
judgment calls the script deliberately leaves open. Then run it again. Report
what the final run said rather than asserting the text is clean.

One error is not about the text at all. `LT-CHUNK-FAILED` means part of the
document was never checked, usually a rate limit or a network problem. Re-run
it, and never report a clean result from a run containing it: the unchecked
stretch is precisely where an error would go unnoticed.

A huge count is a reason to read before fixing. When one rule fires hundreds
of times in one or two files, check whether the findings cluster inside
markup (links, HTML, inline CSS). That is a masking bug in the checker, not a
discovery about the prose: five such bugs once invented 654 of 890 errors, and
obeying them would have rewritten CSS to `17 px` and broken two diagrams.

The checker covers the mechanical layer only. It cannot tell you that a
paragraph restates itself or that every bullet has the same shape. A clean run
is necessary, not sufficient.

## Dashes

**The em dash `—` is never correct here**, in either language, in headings, in
tables, in commit messages, in comments. It is the single clearest fingerprint
of generated text.

**German keeps the spaced en dash ` – `.** It is the correct Gedankenstrich and
it is how {{user.name}} already writes. It is capped at roughly one per 200 words, and
the checker reports the density for the document as a whole. The cap exists
because the problem was never the character. The problem is reaching for the
same move every third sentence, so the dash stops being a device and becomes
the default rhythm.

**English restructures.** A comma, a colon, a parenthesis, or two sentences.

```
bad     Umami runs locally — no data protection agreement needed.
good    Umami runs locally, so no data protection agreement is needed.
good    Umami runs locally. No data protection agreement needed.

bad     Umami läuft lokal — kein AVV nötig.
good    Umami läuft lokal – kein AVV nötig.
```

Ranges keep the unspaced en dash in both languages: `2020–2024`, `10–40 %`,
`Mittel–hoch`, `S. 341–356`.

## Emoji

Emoji are **labels, not decoration**. That is the whole distinction, and it is
what separates {{user.name}}'s convention from the way generated text uses them.

- One per heading, as the first character, single space after.
- Literal, matched to the content. `🍪` for the cookie banner, `🐞` for error
  tracking, `📊` for analytics, `🏫` for school. Never `🚀` for getting
  started, never `✨` for features, never `🎯` for goals.
- Only on headings a reader scans for. Sub-headings that exist as internal
  scaffolding get none.
- Never the same emoji twice in one document. A landmark that repeats is not a
  landmark.
- None in body text, tables or bullets.

```
## 📊 Analytics          section anchor, gets one
### Vergleich            internal scaffolding, none
#### 🍪 Cookie-Banner    scan target, gets one
##### Empfehlung         internal, none
```

The exception is a document that already runs a legend, the way a reference
note may mark its rows with the same few emoji throughout. Follow the convention already in
the file instead of stripping it. The checker recognises this: an emoji that
repeats, or that also labels a heading, is reported as a legend and left alone.

## Heading case

In English, **Title Case for the note's name and its `#` heading, sentence
case for every heading inside it.** Proper nouns keep their capitals either
way, which is why `## ☁️ Tier 2: restic to B2 Cloud Storage` is already
correct: `restic` is lowercase because that is the tool's name, and Backblaze
sells a product actually called B2 Cloud Storage.

```
Backup Plan.md                          filename, Title Case
# Backup Plan                           H1, Title Case
## 🔢 3-2-1 in one paragraph            H2, sentence case
## 🧪 Open: none of this is restore-tested
```

German needs no rule here, because German capitalises nouns regardless.

This one is deliberately not in the checker. Telling a wrongly capitalised
heading from a run of proper nouns needs judgment the script does not have,
and a rule that fires on `Proxmox Backup Server` would be worse than no rule.

## Voice

The mechanical rules above are enforced by a script. This part is not, and it
is where the actual work is. A banned-word list produces text that dodges the
words and keeps the tic, because the tell is structural.

**Vary sentence length on purpose.** Uniform length is the strongest single
signal of generated prose, because every sentence gets written to the same
target. A four-word sentence after a thirty-word one is what a person sounds
like.

**Commit to a sentence before writing it.** The dash habit is a symptom: the
sentence finished, something else occurred to the writer, and a dash glued it
on. Decide what the sentence is about first, then the punctuation follows.

**Delete the sentence that restates the paragraph.** Sections that end by
summarising themselves add length and no information. If the point was made,
it was made.

**Let bullets be ragged.** If every bullet has the same length and the same
grammatical shape, it was generated rather than observed. Real notes have a
two-word bullet next to a three-line one, because reality is uneven.

**Bold is a landmark, not emphasis.** More than roughly one bold phrase per
paragraph and nothing stands out any more.

**Two or four, not always three.** The rule of three is real, and reaching for
it every single time is a tell.

**Say the thing instead of announcing it.** Cut `let's look at the options`
and give the options. Cut `it's worth noting` and note it.

**Prefer the verb to the noun**, especially in German. `Wir migrieren am
Freitag` beats `Die Durchführung der Migration erfolgt am Freitag`.

**Name who does it.** Passive hides the actor, and in a work note the actor is
usually the useful part.

**Be concrete.** {{user.name}}'s own notes already do this well and are the register to
match: `2–4 h`, `5.000 Fehler/Monat`, `ab 35 €/Monat`, `14 Monate
Aufbewahrung`. Numbers, names and dates instead of "significant" and
"umfangreich".

The house register, from the daily notes: terse, decision-first, tables for
comparisons, bold on the decision itself, `→` for something superseded. Match
that. Do not inflate a note into an essay.

## Language

Pick the language from the text and the reader, not from the conversation.

{{prose.languageRule}}

Mixed files are normal and correct. English headings over German prose in one
note is a real pattern, not a mistake to clean up. The checker detects
language per paragraph and sends each stretch to LanguageTool under its own
language, so leave the mixture alone.

German address form is lowercase `du`, held consistently through a document,
unless the rule above says otherwise for the reader at hand.

English is **American** spelling: `organize`, `behavior`, `color`, `center`.

## References

Load these when the work is actually in that language. They carry the detail
that does not belong in this file.

- `references/german.md` for German. Komma rules that matter, `das`/`dass`,
  `ss`/`ß`, Groß- und Kleinschreibung, Komposita and the Deppenleerzeichen,
  numbers and units per DIN 5008, quotation marks, and the German phrasings
  that read as machine-written.
- `references/english.md` for English. The dash policy in detail, the
  structural AI tells, and a section on German interference errors that
  survive proofreading because they are real English words. Read this one even
  when the English looks fine, because that is exactly when those slip through.
- `references/languagetool.md` for the checker's backends, credentials,
  self-hosting, and what to do when it will not connect.

## Scope

This governs prose written for a human reader. It applies to files, to the body
of a commit message, and to comments and identifiers in source.

In source files, apply the spelling and dash rules and nothing else. The emoji
convention and the register guidance are for documents, not for code. For the
shape of a commit message, `conventional-commits` decides; this skill only
makes the prose inside it correct.

It does not govern chat replies.
