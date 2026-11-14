---
name: conscience
description: >-
  A sparring conscience for writing, reviewing, and designing code in any
  language. Flags three temptations — folklore lines, speculative abstraction,
  and unexamined convenience — and forces an honest argument before they enter
  the code. Reach for it when designing an abstraction/module/helper/interface/
  option, adding a dependency or adopting a framework, choosing dynamic dispatch
  or polymorphism, making a memory/data-layout/batching/API-shape decision, or
  reviewing code that smells of premature abstraction or copied config; also
  when the user asks to flag-and-discuss, spar, or apply "the conscience." Not a
  rulebook, not a performance regime, not a law.
---

# Conscience

A sparring conscience for writing, reviewing, and designing code in any language. It flags three recurring temptations — folklore, speculative abstraction, and unexamined convenience — and forces an honest argument before they enter the code. It is a lens to reason with, **not** a rulebook, **not** a performance regime, and **not** a law: every rule here can lose the argument on its merits and be set aside for the case at hand.

Most of this file is cheap, universal habit — no cargo cult, no speculative abstraction, no gratuitous waste — and applies in every language. The perf tactics (cache/cycle framing, SIMD, arenas, the leverage ladder) are native/compiled-CPU-oriented and go quiet in IO-bound and managed/JIT contexts; the **Boundaries** section says exactly where.

## What this changes about how you act

When this skill is active, you stop treating abstraction, dispatch, options, and dependencies as free. You name the cost, ask the standing question, and only then decide. Abstractions, frameworks, and libraries are welcome — but *after* they are earned, *with* their tradeoffs named, and *understanding* the layer rather than worshipping it.

## The three allergies

1. **Folklore lines** — code or config copied in without understanding what each part does or why it is there. *(Policed by R3, R7.)*
2. **Speculative abstraction** — a helper, factory, framework, interface, or option built for a customer who has not arrived. *(Policed by R1, R2, R4, R8.)*
3. **Unexamined convenience** — a line kept only because removing it would mean having to explain it. *(Policed by R3.)*

The rules below are one system, not a second list: each exists to make one of these three allergies operational.

## When to apply

Reach for this conscience when:

- You are about to **design an abstraction, module, helper, interface, base class, or option** — anything that generalizes.
- You are **adding a dependency or adopting a framework**, or wiring code to be called *by* one.
- You are **reviewing code** and smell premature abstraction, unexplained lines, or copied config.
- You are making a **memory, data-layout, batching, or API-shape decision**.
- You are choosing **dynamic dispatch / polymorphism** where a simpler form might do.
- The user explicitly asks to **flag-and-discuss**, spar, or apply "the conscience."

Do **not** perform this ritual on every line. It is for decisions with a design surface, not for obvious glue.

## The core rules (R1–R8)

Each rule is one idea plus a standing question you actually ask, out loud, at the decision point.

- **R1 — Compress on the second occurrence, not before.** No shared abstraction until the same *semantic* pattern appears twice in real, working code; then extract the smallest shareable unit. (One occurrence earlier than the Rule of Three, on purpose: we compress on genuine semantic recurrence, and the first copy is the input data the later compression is designed from — not incidental repetition.) → *What is the second occurrence?*
- **R2 — Usable before reusable.** Write the call site you wish you could write first, then implement toward it. → *Have I written the caller's line before generalizing it?*
- **R3 — No cargo-cult lines (explainability).** Every line must be explainable: what it does, why it is here, what breaks if removed. → *Where is this documented, and what does each part do?*
- **R4 — Do not pessimize.** Roughly know the work a change asks of the machine; do not add indirection, inputs, or flexibility for needs that do not exist. → *What work does this ask of the machine?*
- **R5 — Protect the iteration loop.** Keep think→type→run→inspect fast; treat rising latency in that loop as a bug to diagnose, not a fact of life. One concrete way to keep it fast: split a pure core `(state, input) → new state` from an IO shell, record the input stream, and replay it deterministically so you can reload the core without losing state (functional core / imperative shell; Handmade Hero Day 23, "Looped Live Code Editing"). → *Is this making the feedback loop slower?*
- **R6 — Inspect the actual data.** Do not reason from imagined values — print, log, evaluate, measure the real thing. → *Have I looked at the actual values, or am I guessing?*
- **R7 — Measurements and primary sources over folklore.** The number and the manual get the final vote, not received wisdom. → *What does the measurement or the source actually say?*
- **R8 — Evaluate every fork on shared dials.** Name which dials a decision turns (see below) instead of arguing "good design." → *Which dials does this move, and in which direction?*

## The dials — shared vocabulary for comparing options

From *Designing and Evaluating Reusable Components*. Use these to compare two designs concretely instead of trading adjectives:

- **Granularity** — Can a coarse call be replaced by a few finer calls? Prefer gradual tiers; never offer a high-level entry point that cannot be trivially rebuilt from lower-level ones. A cliff between "easy demo" and "shippable" is an *integration discontinuity*.
- **Redundancy** — How many paths reach the same effect? Convenience paths cost maintenance and drift.
- **Coupling** — Does using one thing secretly obligate another? Almost always bad, usually somewhat unavoidable — so name it.
- **Retention** — Does the interface keep its own copy of your data that you must keep in sync? Prefer the least retention at the most granular tier, so your data stays the single source of truth (the root of immediate-mode thinking below).
- **Flow control** — Who calls whom? Prefer *a library you call* over *a framework that calls you back*, wherever the requirement allows. Operational move: anywhere there is a callback or inheritance hook, there should also be an equivalent plain API call — an escape hatch that lets you adopt the framework without surrendering the flow of control.

Ideal profile: gradually tiered, highly decoupled, no retention at the most granular tier, caller keeps the flow of control.

## Flag-and-discuss — the one procedure

This is sparring between equals, not enforcement. When a trigger fires, run this — and be willing to lose:

1. **Spot the trigger and name the rule** the change appears to violate (e.g., "R1 — I don't see a second occurrence yet"). For a proposed abstraction, this *is* R1: if there is no real second occurrence, inline it and stop here.
2. **Write the call site first (R2).** If you cannot name the line you wish you could write, you are not ready to generalize.
3. **Ask the standing question** plainly and wait for a real answer. For each nontrivial line also run R3 silently (what it does, why, what breaks if removed).
4. **State the work on the machine (R4) and the dial(s) at stake (R8)** so the tradeoff is concrete. **Name the currency the cost is actually paid in** — cycles, comprehension, or lock-in. They are not interchangeable, and picking the wrong one loses the argument on the merits: objecting to an interface in an IO-bound path *because of dispatch overhead* is refutable in one line, since an SMTP round-trip is five-plus orders of magnitude above a vtable lookup. The honest version of that same objection is comprehension and lock-in, and it survives. Say which one you mean.
5. **When facts are in doubt, look (R6) and measure or read the source (R7)** instead of arguing.
6. **Argue as an equal.** Present the cheaper alternative (often: inline it, defer it, delete it) and invite the counter-argument.
7. **Let the rule lose if it should.** A named, understood, deliberately-accepted cost satisfies the conscience: "We keep this because X, at the cost of Y on dial Z" is a *win*, not a bypass. Record the reasoning where the code lives — and when you *do* extract, record the two occurrences that justified it (R1 evidence).

The goal is the **total lifecycle cost and only the total cost** — not elegance, not maximal reuse, not minimal lines. Sometimes the right move is to stop compressing.

## Mental models to reach for

- **Immediate-mode vs retained-mode** — Prefer redeclaring the desired state each pass from your own authoritative data over mutating a standing mirror you must keep in sync. Immediate mode is not *stateless* (a library may keep ephemeral, ID-keyed interaction state) — the point is that *your* data stays the single source of truth. Retained caches are earned by measurement, not assumed.
- **Prefer the least-dynamic dispatch the requirement demands** — A closed set of variants is often a tagged union + exhaustive match, not a class hierarchy with per-object dispatch: Rust `enum` + `match`, OCaml variants, TypeScript discriminated unions, Java 17+ sealed interfaces + records with pattern `switch`, C# records + pattern matching. Reserve interface/method-table dispatch for genuinely open-ended dynamism. (Managed runtimes may already devirtualize monomorphic call sites — measure; don't hand-port native tactics blindly.)
- **Existence-based processing** — Represent optional/boolean state by membership in a set or table rather than per-item flags or null checks: a row's presence *is* the state; membership in a set, a sparse map. Removes branches and enables batch processing; language-independent (SQL, a Python `set`).
- **Crash on the impossible** — Assert invariants and panic on the unhandled variant (invalid-default-case) so illegal states fail loudly instead of drifting silently. The practical partner to R3/R6 and Carmack's "understand every state your code can reach."
- **Grouped lifetimes (the arena idea)** — Bucket allocations that share a lifetime to a boundary the system already has (whole run, per-frame, per-request, per-parse) and release them in one motion. Degrades to pooling/buffer-reuse under a garbage collector — and only when profiling shows allocation is the bottleneck.
- **ZII (zero is initialization)** — Design types whose all-zero state is a valid, no-op default where the language makes that natural (e.g., Go zero values). Skip it where a type's valid state is not all-zero.
- **Abstraction is an output, not an input** — It emerges from concrete working code; it is not designed up front. Likewise, house style is a per-language output — decide idiom after real code exists.
- **Demystify frameworks you cannot avoid** — Understand the layer's cost and control flow; do not worship it.

## Optimization, kept in three buckets

Keep these distinct so you apply the right one (Muratori, "Philosophies of Optimization"):

- **Non-pessimization** — the everyday default: don't ask the machine for work the task doesn't require (kill N+1 queries, redundant serialization, per-item allocations, recomputed invariants, speculative indirection). Usually *shorter*, not more complex, and free to fix.
- **Actual optimization** — rare, measured, machine-specific, reserved for hot paths proven by profiling.
- **Fake optimization** — folklore tips ("never use X") applied without measuring. A vice; refuse it (R7).

When performance genuinely matters, reason in order of leverage: **waste** (usually largest and cheapest) → instructions-per-clock → SIMD → cache → multithreading. That ladder is native/compiled-CPU framing; in IO-bound or managed contexts it is not meaningful — cut round-trips and payloads instead (Amdahl governs). A speed-of-light back-of-envelope estimate is just arithmetic; do it before optimizing.

## Boundaries — when NOT to wield this

This is a lens to discuss with, never a verdict to stamp:

- **IO-, network-, or database-bound code.** The cache-line/cycle framing does not generalize here; the win is round-trips and payloads, and micro-layout is noise. Amdahl's law governs.
- **Throwaway prototypes and spikes.** If the code's lifespan is measured in hours, minimize *your* cycles, not the machine's.
- **Established team idiom or domain convention.** Consistency and comprehensibility often outrank a marginal compression or layout win, especially where change-rate and team size dominate. Conserving programmer cycles usually beats conserving machine cycles.
- **Managed/JIT runtimes** where hand-ported low-level tactics may be neutral or negative — measure before porting.
- **Hot, homogeneous, high-volume transforms** are where the data-oriented tactics *do* earn their keep — apply them there, deliberately.

The conscience keeps its cheap universal habits everywhere and reserves its expensive, opinionated moves for the places measurement justifies them. (And hold the counter-claim too: well-compressed code is often *easier* to maintain, because everything doing the identical thing goes through one path — compression is not automatically a maintainability cost.)

## Reference material

- `reference/principles.md` — the full conscience: each rule expanded with its standing question, the dials, the mental models, house-style-per-language, and the session protocol (flag-and-discuss + audit trail).
- `reference/patterns.md` — the cross-language pattern catalog: tagged-union dispatch, data-first/batch processing, grouped lifetimes/arenas, immediate-vs-retained, write-the-usage-first, compress-on-second-occurrence, the non-pessimization checklist, explicit dispatch, and functional-core/replay — each with idiomatic examples in several languages and an explicit "when NOT to."
- `reference/lineage-and-sources.md` — the school (Muratori, Acton, Fabian, Fleury, Blow, Carmack, Gross) and its own critiques and boundary negotiations (the Martin exchange, Teran, Metz, Fowler, Hickey, Ousterhout, Pakkanen), plus an annotated reading list of primary sources.
