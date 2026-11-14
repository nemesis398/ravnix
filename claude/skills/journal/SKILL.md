---
name: journal
description: >-
  Write the session's noteworthy work into its session note in the vault's
  `AI/sessions/`: a decision whose reasoning will matter later, a non-obvious
  finding, or a finished artifact, under five fixed sections and in the right
  language. Use this whenever a piece of work finishes and before a session
  ends, in every project and from every directory, when a Stop hook asks for
  it, or when {{user.name}} says journal it, write it up, put that in the daily note, or
  document this. Only an interactive main session writes one. Prefer this over
  leaving the work only in the transcript, because a transcript is not
  searchable a month later and the session note is.
---

# journal

A session note records what one session did that is worth finding again.
Months later {{user.name}} finds it by search or through the day: the note links its
daily note, and the daily note embeds the day's session notes through
`Sessions.base`. Agents never journal into the daily note itself. Your job is
to leave behind the entries that make a fact findable, and nothing else.

## The bar

Write an entry when one of these is true:

- **A decision was made and the reasoning matters.** Not the decision alone.
  Why the alternatives lost is the part that is expensive to reconstruct.
- **Something non-obvious was found**, above all a misdiagnosis you corrected.
  What the error message said and why acting on it would have been wrong is
  worth more than the fix.
- **An artifact was finished.** A script, a note, a config, a document.

Routine edits, chores and questions you answered stay out. So does work you
started and did not finish; that belongs in a handoff, not here.

If you cannot tell, ask {{user.name}} in the interactive question UI. When no
answer can come, because {{user.name}} said not to ask or left the session to run on its own,
write it and put `%%journal:unsure%%` on its own line after the entry, ahead
of any `→` line.

**Only an interactive main session writes a session note.** A subagent, a
workflow, a hook, a cron run and `--print` never do. The script refuses a
headless run, but a subagent inherits its parent's session id and would write
into the parent's note, so that half of the rule is yours to keep. A subagent
puts its candidate entry in its report to the parent.

## Never the protected section

The `{{journal.protectedSection}}` section of the daily note is
{{user.name}}'s alone. Do not write to it, do not reword it, do not mirror
your entry into it. The scripts never touch it either: a daily note they
create or extend gets its Capture section above it.

## Sections, domain and language

The body is Markdown under up to five `##` headings, in this order, each one
only when it has something in it:

- `## Done`: the artifacts finished, one bullet each.
- `## Decisions`: what was decided and why the alternatives lost.
- `## Findings`: what turned out to be true or false.
- `## Memory candidates`: facts that might earn a note in `AI/memory/`. They
  are searchable but never injected, and the planner's Sunday session proposes
  which to promote. The `ai-memory` skill holds the tests a memory must pass,
  and the form of the one other bullet here: `archive`, for a memory found
  wrong when {{user.name}} could not be asked.
- `## Next`: what follows, in a line or two. Where unfinished work stands
  belongs in a handoff.

The headings stay English whatever the language of the text under them.

**The domain names the subject.** Pass `--domain` once per domain. A domain
is a key of the skill value `memory.domains`, such as `claude-code`, and the
lint warns on any other.

**Language follows subject, not folder**, which is the rule in `Vault.md`.
{{journal.languageRule}}

**Write like the entries already there.** Read the two newest notes in
`AI/sessions/` before your first entry of a session. Entries are full
sentences, not bullet dumps: what was decided, what was measured, what turned
out to be false. The one sentence that matters most is set in bold, for
example a corrected misdiagnosis or the number that closes a question. An
error message that misled and was rejected is quoted in italics, with the
reasoning for rejecting it stated next to it. Counts and measurements are
exact, not rounded: "1.192 Zeichen", "36 berechnete Farben", "0 Verstöße von
4.590". A table earns its place when a section holds three or more parallel
rows of the same shape, one column per fact. When a permanent note carries the
detail, close your own text for that section with one link line, several notes
joined by ` · `: `→ [[Backup Plan]] · [[Vault]]`. It comes after any
`%%journal:unsure%%` marker. A later write appends below it, so a section can
hold several `→` lines, one per write, and that is fine. The scribe and
`/project update` read the line, so keep it bare.

## The prose gate

Every entry is read by a human on a phone. Compose the body in the session's
scratchpad, never in `/tmp` directly or in the vault, check it, fix what it
finds, then write:

```bash
{{ravnix.python}} {{ravnix.skillsDir}}/prose/scripts/check.py "$SCRATCH/session.md"
```

House rules, and the `prose` skill is where they live: no em dashes in either
language, the spaced en dash as the German Gedankenstrich and sparingly, emoji
only as heading labels, German dates as `09.08.2026` and English as
`2026-08-09`. A run that reports a backend failure is not a clean run; do it
again.

## Writing it

```bash
{{ravnix.python}} -B {{ravnix.skillDir}}/scripts/session_note.py write \
  --title "Questions go in the interactive UI" \
  --domain claude-code \
  --description "Why decisions are asked in the question dialog" \
  --body-file "$SCRATCH/session.md" \
  [--dry-run]
```

The title becomes the note's H1 and, after the date, its filename. Keep it a
plain phrase: no trailing punctuation, which markdownlint flags; no `#word`,
which Obsidian turns into an inline tag that nothing catches; and no wikilink
or Markdown link. The description is one line on what the session did, and it
is what the daily note's embed shows. On a later write, pass a description
that covers the whole session, because it replaces the old one.

The script finds the note on its own. A resumed session keeps its session id
and writes into the note it started, even on a later day, and so does a second
write with the same title on the same day. Each section's text goes under its
existing heading. Exit 2 means it refused the input, such as an empty body or
a heading outside the five; fix it and run again. Exit 2 with "set `vault.root`
in your ravnix skill values" means the skill is not set up: stop and tell
{{user.name}}. Exit 3 means a headless run, so write nothing and report the
entry instead.

`--dry-run` prints the resulting note without writing it. Use it when you are
unsure the entry will land where you think. A dry run writes nothing, yet the
Stop hook counts it as the entry, so run the command again without
`--dry-run`.

Then confirm the vault is still sound:

```bash
vault-check
```

If the session commits its notes, commit the note with `vault-commit`, never
with `git commit`, and name the file, never a folder:

```bash
vault-commit "docs(ai): add the session note on TITLE" "AI/sessions/FILE.md"
```

It commits where the vault's history is, by the skill value
`vault.commitVia`, and says what it did. On the laptop exit 0 may mean the
server queued the commit, and exit 1 means the server did not answer: say so,
and ask again later rather than retrying in a loop.

## What this skill does not do

It does not move or rename notes; that is the Obsidian CLI and the rules in
`AGENTS.md`. It does not file knowledge into permanent notes; that is
`/scribe` at harvest. It does not write memory notes; that is `ai-memory`. It
does not record where work stands for the next session; that is `handoff`. It
writes what happened, in the session it happened.
