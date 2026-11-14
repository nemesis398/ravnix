---
name: simplify-changes
description: >-
  The strict, provably behaviour-preserving simplification pass, for code whose
  cleanup diff has to be safe to accept without re-reviewing the whole feature.
  Holds the rule that error handling is behaviour and must never be deleted
  inside a cleanup, and the "flagged, not fixed" contract that keeps a real bug
  from being smuggled into a no-behaviour-change diff. Reach for it when the
  simplification touches error paths, fallbacks, null checks or retry logic;
  when a cleanup is about to land on code someone else depends on; or when {{user.name}}
  asks for the strict pass, the careful pass, or a cleanup that provably changes
  nothing. For an ordinary tidy-up with no such stakes, the built-in `/simplify`
  is the lighter default and owns the plain "clean this up" phrasings. Quality
  only: it does not hunt for bugs or security holes, so use `/code-review` when
  correctness is the question.
---

# Simplify changes

Make code that already works easier to read, without changing what it does.

The value here is subtraction. Anyone can add a layer; the hard, useful move is
removing the layer that was never needed. Work on the diff — the code that was
just written or changed — because that is where accidental complexity is freshest
and cheapest to remove, and because a cleanup that quietly grows into a rewrite of
untouched code is not a cleanup anyone asked for.

## The hard constraint

**Behaviour must not change.** That is what separates a simplification from a
redesign, and it is what makes this pass safe to accept without re-reviewing the
whole feature.

So if you spot something that looks wrong — a real bug, an unhandled case, a
security problem — do not quietly fix it inside a simplification pass. The reader
is trusting that this diff is behaviour-preserving; smuggling a behaviour change
into it destroys exactly the property that makes it cheap to review. Say what you
found, plainly, and leave it for a separate change.

**Error handling is behaviour, and it is the easiest thing to delete by
accident.** Removing a `try`/`except`, narrowing a catch, dropping a null check,
or deleting a fallback branch all change what the program does when something
goes wrong — and a green test suite does not contradict that, because tests only
cover the failure paths somebody thought to write.

The tempting move here is the argument "I traced every caller and nothing can
actually throw, so removing it is behaviour-preserving." Treat reaching that
thought as a signal to stop rather than a licence to proceed. It is a claim about
today's callers, not about the function's contract; the next caller will not know
the audit happened, and if the handler really is unreachable it costs nothing to
leave it one more day. A handler that looks dead, too broad, or that silently
swallows errors is a genuine finding — report it under *Flagged, not fixed* so
someone removes it as a deliberate, reviewable decision. Deleting it inside a
cleanup is how a "no behaviour change" diff quietly stops being one.

## Establish the scope first

Get the actual diff before reading anything else, so you are working from what
changed rather than what you imagine changed:

```bash
git diff HEAD          # uncommitted work
git diff main...HEAD   # everything on this branch
```

If there is no version control, or the user pointed at specific files, use what
they named. When the diff is large, say which parts you are covering rather than
skimming everything at low resolution — a thorough pass over three files beats a
shallow one over thirty.

Then read enough of the surrounding code to know what is already there. Most
missed simplifications are missed because the helper that already does the job
was never found.

## Four lenses

Run each lens over the changed code. They catch different things, and the second
and fourth are the ones people skip.

**Reuse — does this already exist?**
Newly written code often reimplements a helper, a constant, a validation, or a
type that the codebase already has, because the author did not know about it.
This is the highest-value lens: it removes code *and* removes a second definition
that will drift from the first. Search before you conclude it is new.

**Simplification — fewer moving parts for the same behaviour.**
Look for: a variable used once, an indirection with a single caller, a flag
parameter that splits a function into two unrelated halves, nested conditionals
that flatten into a guard clause, a try/except spanning far more than the line
that can actually throw, a comment explaining something the code could just say
by naming it well. Ask what the code would look like if written knowing what is
known now — the first draft had to discover the shape, the second does not.

**Efficiency — only where it is obvious and free.**
Work repeated inside a loop that could be hoisted, a query per iteration instead
of one query, a list built to be thrown away, a whole file read to count lines.
Take these when they also make the code clearer. Leave anything needing a
benchmark to justify it — speculative optimisation is a way of adding complexity
while feeling productive.

Do not let that caveat swallow the easy cases. A computation inside a loop that
depends on nothing the loop changes is a plain take, not a performance question:
lifting it out states once that the value is fixed, which is a readability win
that happens to also stop repeating the work. "Needs a benchmark" applies to
changes that trade clarity for speed — restructuring data, caching, hand-unrolling
— not to deleting repetition that was never meant to be there.

**Altitude — is everything here at the same level of detail?**
A function should read at one level of abstraction. When a routine that decides
*policy* also fiddles with byte offsets or string escaping, the reader has to
change gears mid-sentence, and the policy becomes hard to see. The fix is
usually to name the low-level part and lift the detail out of view — not to
introduce a new abstraction layer, just to move detail behind a good name.
This is the subtlest lens; if nothing here is genuinely mixed, say so and move on.

## What to leave alone

Restraint is most of the skill. A diff full of churn buries the two changes that
mattered and burns the reviewer's attention.

- **Code you do not understand.** Not-understood is not the same as complex. Ask.
- **Behaviour you cannot verify.** No tests and no way to check means no edit.
- **Pure formatting and style.** That is the formatter's job, not a reviewer's.
- **Renames without a reason.** A better name earns its diff; a differently-opinionated one does not.
- **Untouched code.** Note it if it is genuinely bad; do not fold it into this pass.
- **Anything where the simpler version is merely shorter.** Terseness is not simplicity — a dense one-liner that takes a minute to decode is a step backwards.

If a proposed simplification would introduce a new abstraction, interface, or
option, stop and make the case for it explicitly — that is the moment where a
cleanup turns into speculative design. The `conscience` skill exists for
exactly that argument; hand off to it rather than waving the abstraction through
because it appeared inside a cleanup.

## Apply, then prove it

Make the edits. Then verify, and do it before you describe the result, not after:

1. Run the test suite. If one exists and you did not run it, you do not yet know
   whether behaviour was preserved — so do not say that it was.
2. If there are no tests, say so explicitly and describe how you convinced
   yourself instead (traced the callers, the change is syntactic, etc.). An
   honest "unverified, here is why I think it holds" is far more useful than a
   confident claim resting on nothing.
3. If a test fails, the simplification was wrong, or the code was doing something
   you did not see. Revert it and report what you learned — a failing test is
   information, not an obstacle.

## Report

Keep it short. The diff carries the detail; the report explains the thinking.

```
## Simplified
- <file:line> — <what changed, and the reason it is simpler>

## Left alone
- <thing considered and deliberately not changed, and why>

## Flagged, not fixed
- <suspected bug / behaviour question, for a separate change>

## Verification
<command run, and its result — or an explicit statement that nothing was run>
```

If a lens found nothing, say nothing about it. And if the code was already clean,
say that and change nothing — a pass that reports "no changes needed" is a real
result, and far more valuable than manufactured edits that let you look busy.
