---
name: handoff
description: >-
  Write or resume a session handoff on {{user.name}}'s Plane board: the goal as
  a parent work item, the next steps as sub-items, and the state, files,
  changes, dead ends and resume checks as one comment on the parent. Use this
  when {{user.name}} says handoff, hand off, wrap up, save state, park this, or
  asks what we were doing. Do not use it because a token threshold fired: that
  reminder is addressed to {{user.name}}, who decides. Prefer this over letting a session be summarized,
  because a summary records what was said and a handoff records where the work
  stands.
---

# handoff

A handoff is not a summary of the conversation. It is a description of where
the work stands, written so that a session with no memory of this one can pick
it up and be useful in its first minute.

It lives on a Plane board now, not in a file. The goal is a parent work item,
the next steps are its sub-items, and everything else is one comment on the
parent. Nothing is archived and nothing is superseded, because the comment
history is the chain.

Everything mechanical lives in one script. Call it rather than reimplementing
its logic, with the absolute paths below and the `-B` flag:

    {{ravnix.python}} -B {{ravnix.skillDir}}/scripts/handoff_state.py projects --cwd "$PWD"

It prints the board layout, the workspaces and projects of the skill value
`handoff.workspaces`, and the directory's default project. If it exits 2
with "set `handoff.workspaces` in your ravnix skill values", stop and tell
{{user.name}} that; there is no board to write to.

## Choosing where it goes

The project follows the **task**, never the directory. The directory only
suggests, and it has been wrong: the vault's own handoff chain was agent-setup
work carried out inside the vault repository, and one work stream spanned two
directories at once.

The rule is objective, because "ask when unsure" is what a model rationalizes
past:

- **A stream already claimed in this session needs no question.** Write to it.
- **Creating a new parent item always asks which project it belongs to**, in
  the interactive question interface, with the directory's default offered
  first and marked as the recommendation.
- **A directory with no default always asks**, with no recommendation offered.

**Claim the stream once you have one.** Nothing else knows which of several open
parent items this session is on, and without a claim the handoff has nowhere to
go:

    {{ravnix.python}} -B {{ravnix.skillDir}}/scripts/handoff_state.py claim \
      --session "$SESSION" --workspace <workspace slug> \
      --project <project id> --parent <item id> --identifier PROJ-12

`--workspace` defaults to the layout's default workspace.

Release it when the parent closes, with the same command and `release`.

**`claim` and `release` take no `--cwd`**, and that is the fix for two real
failures rather than a tidy-up. A claim used to be filed under the directory it
was made in, so a claim in one of a project's declared directories was invisible
from the other, and a `--cwd "$PWD"` from a shell that had wandered filed the
claim somewhere no session would ever read it. The session id is the identity.

A **cleared** session gets a new session id, so its claim does not carry over.
That is deliberate: `/clear` is a clean slate, not a continuation, and the board
tells the new session which stream was most recently claimed rather than
pretending none was. Claim it again to carry on. Compaction keeps its session
id, so nothing is lost there.

Several streams can be open in one project at once. **Nothing is ever archived
or superseded**, so there is no incumbent to check against and nothing to
displace.

## Writing one

**Ground every claim in output, not recollection.** The failure mode of a
self-written summary is confidently recording a change that was never made, and
the next session has no way to catch it. Before writing, run and read:

    git status --short && git diff --stat && git log --oneline -5

Then whatever proves the current state: the test command, `vault-check`, the
build. Quote what it actually printed.

Then write three things.

**The parent item's description** is the Goal: why this work exists and what
done looks like, one paragraph, surviving verbatim unless the goal genuinely
changed.

**Sub-items** are the Next steps, one per step, numbered in order, each standing
alone for someone who has read nothing else. Match existing sub-items **by exact
title** and update them. A step whose title changed is a different step: create
the new one and move the old to `Cancelled` with a comment naming what replaced
it. Matching on similarity would silently merge two steps that only look alike.
A step that is finished moves to `Done` with a comment naming its evidence.

**One comment on the parent** carries the rest, under these five headings:

- **State.** Branch, HEAD, whether the tree is dirty, what passes and what fails
  with the real output. Say which unfinished things are deliberate, because
  otherwise the next session tries to fix them.
- **Files.** One line per file on what it is for. Point at commits, never paste
  diffs.
- **Changes made.** Committed work as `<sha> <subject>`, uncommitted as path
  plus what differs.
- **Tried and failed.** The most valuable section. Each entry: what was tried,
  the actual error quoted, and why it failed, or an honest "reason unknown".
  Carry entries forward while they still apply. This stays whole rather than
  being split across the sub-items it belongs to, because a finding spanning
  three steps would otherwise have no home.
- **Resume checks.** The commands that prove this comment is still true. Three
  or four is plenty.

Send the comment as **raw HTML**. Plane escapes it again and wraps escaped input
in a `span`, so an escaped body renders as visible markup.

**Open it with the handoff marker**, `<!-- plane-handoff -->`, as the very first
characters. Nothing else tells a handoff from the other comments on the parent,
such as a correction or a note typed into the UI. Resuming reads the newest
marked comment, and the `Stop` hook counts only a marked comment as a handoff
posted. Leave it off and the next session resumes from the previous handoff.

**Then propose memory promotions.** Look at what was learned, especially in
Tried and failed, and judge each candidate by the four tests in the `ai-memory`
skill. Name each with the one-line description you would give it, marked
Recommended or Not recommended with a one-line reason, and let {{user.name}} approve or
reject each. Write an approved one through the `ai-memory` skill, and put the
rest under the session note's *Memory candidates*. Anything promoted comes out
of the handoff, which keeps the handoff about the work rather than about the
world.

Say which item the handoff went to. Do not summarize it back; it was just
written and reading it twice is waste.

## If Plane cannot be reached

Write the same sections to the local store and **say that you did**:

    {{ravnix.python}} -B {{ravnix.skillDir}}/scripts/handoff_state.py paths --cwd "$PWD"

That file is the failure sink, not the normal home. A handoff is never lost, and
a handoff that landed there needs moving onto the board when the network is back.

## Resuming one

`SessionStart` has already put the board in front of you. Read its Resume checks
and run them before doing anything else. A handoff describing a dirty tree, read
after a stash and a rebase, is a confident lie: if a check disagrees, stop and
say so rather than acting on it.

Start at the first sub-item that is not `Done`. Read Tried and failed before
proposing anything, so the session does not spend its first hour rediscovering a
dead end that is written down two paragraphs above.

After a compaction the newest handoff comment is already in front of you. After
a `/clear` it is not, because a cleared session has a new id and no claim: when
{{user.name}} says to resume a stream, claim it again and read the newest marked comment
on its parent yourself, then any comment posted after it, which may correct it.

## When a threshold fires

From 200k tokens the `Stop` hook advises {{user.name}} at the first natural break in the
work: a commit, a Plane item closed or moved, a todo step done, a journal entry,
a stream claimed or released, or a handoff posted. From 400k it advises
regardless, because auto-compaction comes at about 487k. The advice is
`/compact`, a handoff then `/compact`, a handoff then `/clear`, or `/clear`, and
each band speaks once until a compaction re-arms it.

**That advice is addressed to {{user.name}}, not to you.** It is not an instruction, it
does not mean write a handoff or compact, and it does not end the turn. Carry on
with the work. If {{user.name}} answers it by saying "handoff", write one as above.

The hook stays silent while a `/goal` run is active, while another stop hook is
keeping the turn going, when `HANDOFF_DISABLED=1` is set, and in any repository
that declares it manages its own handoff, with a `handoff.json` marker in its
`.claude` directory naming `project` as the owner.

That last one is written as a shape rather than as a path on purpose:
`agent-doctor` greps raw text and cannot tell a pattern that describes a file
per repository from a citation of one that should exist here, so spelling the
two out joined would raise a DEADPATH on every run.
