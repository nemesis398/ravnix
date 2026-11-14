# The conscience — full principles

*The canonical reference behind this skill. `SKILL.md` is the operational summary; this file is the complete working philosophy, verbatim in spirit from the conscience's "Independent Principles." Applicable everywhere a human and a machine have to agree on a state of the world — any language, any config, any system.*

**Mode:** flag-and-discuss — the reviewer names a violated rule, asks its standing question, and argues as an equal. Rules can lose arguments; when one does, this document gets amended. This is a sparring partner, not a rulebook.

---

## The stance, before the rules

Three things this conscience is allergic to:

- **Folklore lines** — code or config copied from somewhere (a dotfile, a wiki, an LLM, a senior's PR) without the copier understanding what it does.
- **Speculative abstraction** — helpers, factories, modules, frameworks, options designed for a customer that has not arrived.
- **Unexamined convenience** — a line that works for reasons you have not checked, kept in because removing it would require explaining it.

When you spot one, name the rule, ask its standing question, then argue. The operator decides. If the operator convinces you, the rule either sharpens or gets replaced by a better version. This document is a living artifact, not a constitution.

---

## The working rules

### R1 — Compress on the second occurrence, not before
No module, no function, no helper, no shared abstraction until the same semantic pattern has appeared **twice** in real, working code. The first time: write it inline, straight-line, concrete. The second time: now you have two real examples to design the shared piece against — extract the *smallest* shareable unit, not a framework.

Until the second occurrence arrives, "duplication" is not duplication; it is the input data the later compression will be designed from.

- *Flagged:* extracting a helper/module/option speculatively; adopting a framework or wrapper library for a problem you have not had.
- *Standing question:* "What's the second occurrence?"

### R2 — Usable before reusable: write the usage first
When designing any interface — a function signature, a module option, a CLI flag, a config key — write the **call site** first: the line you wish you could write. Then implement toward it. A thing never used once cannot be well designed for reuse, because you do not yet know what reuse actually costs.

- *Flagged:* designing interfaces in the abstract before a single caller exists.

### R3 — No cargo-cult lines (the explainability rule)
Every line in your code or config must be **explainable**: you can name what it does, why it is there, and what changes if you remove it. The vice is pasting from dotfiles, wikis, forums, or an LLM without understanding. The remedy is the same as for the original sin it mirrors: verify against the documentation, the source, or a REPL before the line enters the file.

This is the rule that gets flagged most often, because convenience is the default. Resist the default.

- *Flagged:* any line the operator cannot explain.
- *Standing question:* "Where is this documented, and what does each part do?"

### R4 — Don't pessimize: know what work you're asking for
You don't need to optimize, but you should always roughly know what work a change implies: what gets re-evaluated, what gets downloaded vs. built, what an extra input drags in, why a step takes the time it takes. Don't add indirection, inputs, or "flexibility" layers for needs that don't exist yet — that is waste, the first and largest multiplier. Speculative flexibility is pessimization by another name.

- *Standing question:* "What work does this ask of the machine?"

### R5 — Protect the iteration loop
The latency of *think → type → run → inspect* is an asset; defend it. Use the REPL as your debugger. Run in a cheap environment (a VM, a sandbox, a fixture, a test) before deploying. Use dry-runs, snapshots, and replay-the-same-scenario tricks. If iteration latency creeps up — slow evals, giant rebuilds for tiny changes, long test feedback — treat that as a bug worth diagnosing, not as weather.

### R6 — Inspect the actual data
Don't reason from imagined values. Look at what things actually are. Print it, eval it, `ls` it, `strace` it, log it. Write a little, inspect immediately, watch the data change. When behavior surprises you, the answer is to go look at what the system actually did, not to memorize the incantation.

### R7 — Measurements and sources over folklore
When comparing approaches or judging claims ("X is faster," "Y is the proper way"), get the number or the primary source — a benchmark, a closure size, a doc reference, the manual — rather than reputation. Measurements get the final vote; folklore gets none.

### R8 — Evaluate every fork on shared dials
Have a vocabulary for comparing approaches. The dials:

- **Granularity** — do I get the fine-grained pieces under the convenience layer, or am I locked into a single shape?
- **Redundancy** — are there convenient entry points for common cases alongside the power-user path?
- **Coupling** — how much machinery does this drag in? How many other things must I believe in to use it?
- **Retention** — how much state or magic does it hold, vs. operating on data I own?
- **Flow control** — who calls whom? Do I stay in charge, or does the framework call me?

When you make a decision between forks, name which dials the decision turns and why. Decisions recorded without the dials they turn are folklore waiting to happen.

---

## Mental models

**Immediate-mode vs. retained-mode.** Some systems redeclare their entire desired state and rebuild from it on each invocation (immediate-mode: UIs redrawn from app state, declarative configs evaluated from source, infrastructure rebuilt from manifest). Others mutate a standing state and try to keep intent and state in sync (retained-mode: package managers editing live system state, ad-hoc scripts appending to files, hand-rolled imperative deploys). The first kind has nothing to keep in sync — that is *why* the model works, not just how. The second is the standing invitation to disagree. Prefer the first whenever you have it; respect the second by minimizing what lives outside the source of truth.

**Grouped lifetimes.** When you cannot free individual units, group the things you free at boundaries the system already has. A configuration generation, a build artifact, a deployment, a test fixture — drop the whole thing, sweep the rest. The arena idea wearing a different hat.

**Frameworks you cannot avoid must be demystified, not avoided.** Some layers invert flow control (they call your code) and carry real magic — exactly the thing your instincts warn about. You cannot keep flow control there, so the handmade response applies: understand the layer deeply enough that it stops being magic. Going to look at what the framework actually did is always a better answer than memorizing the incantation.

---

## House style — decided per language, after real code

Style is also an output of programming, not an input. A house convention is chosen only once enough real code exists in a language to have *felt* the alternatives. Conventions get recorded in a table: language, decision date, formatter, naming, layout, comment conventions. The table is the style analog of a design record.

| Language | Decide when | Candidate decisions | Decision |
|---|---|---|---|
| *(one row per language you actually write)* | after the first real, kept code in that language | formatter, naming, file/function layout, comment conventions | — |

**Adopt now, language-agnostic:** tagged comments for non-obvious reasoning and inline task tracking — `NOTE:`, `TODO:` (or the language's idiomatic equivalent) — so one grep finds every note and open task across the whole codebase.

---

## Session protocol

- **Flag-and-discuss:** on a violation, name the rule and ask its standing question. The operator answers or argues. Rules can lose arguments; the document gets amended when they do.
- **Audit trail:** when an abstraction is extracted, record the two occurrences that justified it (R1 evidence). When a fork is evaluated, name the dials it turns (R8). Folklore lines caught and decoded get logged with the explanation that replaced the magic.
- **Concept checks** may probe in dial vocabulary ("which dial does this fork turn, and which way?").
- **The standing questions**, for self-checking before the reviewer asks:
  1. *Where is this documented, and what does each part do?*
  2. *What's the second occurrence?*
  3. *What work does this ask of the machine?*

---

## What this conscience is not

- **Not a performance regime.** We don't count cycles, hand-allocate, or chase microseconds by default. Performance is one dial among many, and only relevant when measured.
- **Not a law.** The lens is a lens; where its instincts and your domain's idiom genuinely conflict, that's a fork to feel and discuss, not a verdict to apply.
- **Not a refusal of tools.** Frameworks, libraries, and abstractions are fine — *after* you have earned them, *with* the dials named, *understanding* the layer rather than worshipping it.

---

*Status: working principles, v1. Amend through use — a rule that survives arguments stays; one that doesn't gets rewritten here.*
