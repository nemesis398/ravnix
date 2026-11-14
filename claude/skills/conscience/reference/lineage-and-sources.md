# Lineage and sources — where the conscience comes from

*Companion to `principles.md`. That file is the working philosophy; this one traces the intellectual lineage behind it, states where it agrees with mainstream software engineering, records the honest critiques and boundaries, and gives an annotated reading list. The point is to hold the stance the way it asks you to hold code: understood, sourced, and demystified — not worshipped.*

*Sourcing discipline: every URL below was verified at time of writing; the web rots, so uncertain or unconfirmable items are flagged inline. Nothing here is invented — where a source is real but a URL, quote, or figure could not be confirmed, it is marked or omitted rather than guessed. Quoted strings are verbatim; paraphrases carry the tag "(paraphrase)". If you are about to repeat a name or a number from this school, check it here first.*

---

## 0. Quick lookup — which source backs which rule

The fast path. If you invoke a rule in review, this is the one line and the one link to check before repeating it. Fuller treatment is in the sections below.

| Rule | Primary source | The load-bearing claim | Where |
|---|---|---|---|
| **R1** Compress on the second occurrence | Muratori, "Semantic Compression" (2014); Fowler's Rule of Three | "I don't reuse anything until I have at least two instances of it occurring" (verbatim) | caseymuratori.com/blog_0015 |
| **R2** Usable before reusable | Muratori, "Semantic Compression" (2014) | "make your code usable before you try to make it reusable" (verbatim) | caseymuratori.com/blog_0015 |
| **R3** No cargo-cult lines / explainability | Carmack, "On Inlined Code" (2007); Blow, "Collapse of Civilization" | understand every state your code can reach; demystify what you cannot avoid | number-none.com/blow/john_carmack_on_inlined_code.html |
| **R4** Don't pessimize / know the work | Acton, "Data-Oriented Design and C++" (2014); Muratori, "Philosophies of Optimization" | non-pessimization: don't ask the machine for work the task doesn't need | youtu.be/pgoetgxecw8 |
| **R5** Protect the iteration loop | Handmade Hero Day 21–23 (hot reload + "Looped Live Code Editing"); Bernhardt, "functional core, imperative shell" | pure core (state, input → new state) + IO shell; record inputs, replay deterministically, hot-swap the core | guide.handmadehero.org |
| **R6** Inspect the actual data | Acton, "Data-Oriented Design and C++" (2014) | "if you don't understand the data, you don't understand the problem" | youtu.be/rX0ItVEVjHc |
| **R7** Measurements over folklore | Muratori, "Philosophies of Optimization" (2021); Teran critique (2023) | measure the number; don't assume a result transfers across machine or language | youtu.be/pgoetgxecw8 |
| **R8** Evaluate every fork on shared dials | Muratori, "Designing and Evaluating Reusable Components" (2004) | the five dials: granularity, redundancy, coupling, retention, flow control | caseymuratori.com/blog_0024 |

---

## 1. The school and its people

**Casey Muratori — compression-oriented programming.** The spine of this conscience. Muratori's twin essays "Semantic Compression" (2014) and "Complexity and Granularity" (2014) argue that you improve code by acting like a continuous PKZip pass over it — reducing duplicated *meaning*, not character count. He prefers "compress" to "abstract" because, in his framing, abstraction does not by itself imply anything useful (paraphrase); abstractions emerge from concrete working code rather than being designed up front. Two verbatim lines anchor R1 and R2: "make your code usable before you try to make it reusable," and "I don't reuse anything until I have at least two instances of it occurring." The granularity essay adds the tiering rule — you should never supply a higher-level entity that cannot be trivially recreated from a few lower-level ones (paraphrase) — and the cost stance ("the total cost and only the total cost"). A verified counterweight to the common "compression sacrifices maintainability" read: Muratori's own claim is that well-compressed code is *also* easier to maintain, because every place doing an identical thing goes through the same path, so a fix lands once (paraphrase; carry this next to the maintainability concessions in Section 3). His teaching vehicles are Handmade Hero (a from-scratch game and engine; handmadehero.org now 301-redirects to mollyrocket.com/handmade, and his current work is Computer Enhance) and refterm (a deliberately "largely unoptimized" reference terminal renderer). Note on the refterm number before you repeat it: the headline "~1000x faster than Windows Terminal" is Muratori's own claim, the widely reshared "100x" is a community simplification, and the README frames refterm as a floor — "not a maximum to aspire to" — not a triumph. See Pakkanen's counterweight in Section 3.

**Mike Acton — data-oriented design.** The performance-realist wing. Acton's CppCon 2014 keynote "Data-Oriented Design and C++" states that the purpose of all programs is to transform data from one form to another (paraphrase — the often-quoted "the transformation of data is the only purpose of any program" is a tightened restatement, not his verbatim wording), and "if you don't understand the data, you don't understand the problem." His "three big lies" (software is a platform; code should model the world; code matters more than data; originally 2008, restated 2014) invert the OO default. Practical residue in this conscience: design for the collection not the instance ("where there is one, there are many"), pick Structure-of-Arrays vs Array-of-Structures by which fields a pass actually touches, and design to the real cost model (memory access dominates). Two techniques from this wing generalize past C:

- **Existential (existence-based) processing** — Richard Fabian's signature DOD move: represent an optional or boolean state by *membership in a set or table* rather than a per-item flag or null check, which deletes the branch and lets you process the whole set uniformly. This ports directly: a row's presence in a SQL table *is* the "active" state; presence in a Python `set` or a sparse dict *is* the flag; no per-item `is_active` column needed.
- **The relational / ECS generalization** — model entities as rows, components as columns, systems as queries over them. This is how most non-C developers actually meet DOD: Unity DOTS, Bevy, and EnTT are entity-component-system frameworks, and the SoA/columnar-store idea is the same shape a columnar database or a dataframe already uses.

Richard Fabian's book *Data-Oriented Design* (2018, free online) systematizes all of this. Feeds R4 (know the work) and R8 (the dials).

**Jonathan Blow — transmission of low-level craft.** The cultural argument. Blow's "Preventing the Collapse of Civilization" (DevGAMM Moscow 2019) claims software is quietly declining because low-level understanding is not being transmitted between generations of programmers; his Jai language work is the constructive counterpart. This is the "demystify, don't worship" mental model's origin: abstractions are fine once earned, but a generation that can only call frameworks it cannot open has lost something. Counterweight (carry it the way refterm carries Pakkanen): the decline thesis is vulnerable to survivorship and nostalgia bias — the old software we remember is the software that survived, and "things were more rigorous then" is a hard claim to measure. Hold it as a provocation about *transmission*, not as an established historical fact. Blow also hosts Carmack's inlining email, tying the two together.

**The arena / region tradition — grouped lifetimes.** The memory face of R1's discipline and the "grouped lifetimes" mental model. Casey's Handmade Hero Day 14 introduced the permanent-vs-transient storage split (transient memory holds no authoritative state and can be zeroed and regenerated). Ginger Bill's "Memory Allocation Strategies" (Part 2) is the canonical arena writeup (allocate by bumping an offset, free is a no-op, reclaim by resetting). Ryan Fleury's "Untangling Lifetimes: The Arena Allocator" makes the central move explicit: bucket allocations that share a lifetime into one arena tied to a boundary the program already has (per-frame, per-request, per-parse) and free the group in one motion. This has a rigorous academic ancestor — Tofte and Talpin's region-based memory management (*Information and Computation*, 1997), a type-and-effect system inferring region alloc/dealloc with no GC, later brought to a safe C dialect by Cyclone (PLDI 2002), itself a precursor to Rust's lifetimes. Paired with ZII ("zero is initialization," popularized by Muratori): all-zero bytes as a valid default state.

**The live-editing lineage — how R5 is actually built.** R5 ("protect the iteration loop") is the conscience's own synthesis, and this is the verified material it rests on. Handmade Hero Day 21–22 demonstrate hot code reloading (the game logic is a DLL the platform layer reloads without restarting), and Day 23, "Looped Live Code Editing," records the input stream and replays it deterministically so a change to the core is felt instantly against a fixed scenario. The structural precondition is exactly Gary Bernhardt's "functional core, imperative shell": a pure core of the form `(state, input) → new state` with all IO pushed to a thin shell. Once the core is pure and inputs are recorded, you can replay the same scenario, hot-swap the core, and never lose the state you were debugging. That is the concrete, language-independent machinery behind "defend think → type → run → inspect."

**The immediate-mode lineage — Muratori to Dear ImGui.** The clearest instance of the immediate-mode-vs-retained-mode model. Muratori coined "Single-path Immediate Mode GUI" (essay, 2005; technique developed ~2002 on a Granny 3D viewer at RAD): redeclare desired state each frame from your own data rather than mutating a persistent object model you must keep in sync. Sean Barrett gave a parallel print treatment (Game Developer Magazine, Sept 2005). Omar Cornut built Dear ImGui and its wiki page "About the IMGUI paradigm" carries the load-bearing correction: immediate mode is *not* stateless — the library keeps ephemeral, ID-keyed interaction state — but your application data stays the single source of truth. The kernel that ports everywhere: make your own data authoritative, derive views from it, and watch for the identity/key-mismatch trap.

**Kindred voices — Carmack, suckless, grug, Locality of Behaviour.** The wider ring that keeps the school from being a games-only cult. John Carmack's 2007 "inlined code" email (hosted by Blow) grounds R3 and R6: "a large fraction of the flaws in software development are due to programmers not fully understanding all the possible states their code may execute in" — shrink the state-space you must reason about. On the file's own read (synthesis, not a sourced ranking), Carmack is the least absolutist of these voices: he frames inlining as a convenience-driven judgement call, not a mandate. The practical partner to Carmack's point is the **Assert / InvalidCodePath / InvalidDefaultCase discipline** from Handmade Hero (verbatim macros in the cj1128 mirror below): make invalid states crash loudly at the point they become reachable, and make the `default:` case of an enum switch an explicit "this should never happen" so an unhandled variant fails fast instead of silently. It ports to every language — assert your invariants, and panic/throw on an unhandled case rather than falling through. Carson Gross contributes two: "The Grug Brained Developer" (defer factoring until cut-points emerge; say "no" to speculative complexity — pure R1) and "Locality of Behaviour" (co-locate behavior with the unit it acts on, explicitly a subjective tradeoff against DRY and Separation of Concerns, not a rule). suckless.org supplies the "every line and dependency is a liability" minimalism (removed code is progress). These are heuristics from adjacent traditions, not scripture — which is exactly how the conscience wants them held.

---

## 2. Where it agrees with the mainstream

This school is often heard as a fringe war on abstraction. On the abstraction question specifically it is not fringe at all — it converges with some of the most cited names in mainstream software engineering. The disagreements are narrower than the rhetoric suggests.

- **Rule of Three (Martin Fowler, crediting Don Roberts).** "The third time you do something similar, you refactor." Two copies are acceptable; extract on the third. Muratori's "I don't reuse anything until I have at least two instances" is the same deferred-DRY instinct — compress *at* recurrence, not before and not never. R1 is essentially the Rule of Three with a standing question attached.

- **YAGNI (Fowler, 2015).** "You Aren't Gonna Need It" names the cost of building for a customer who has not arrived — Fowler's four cost categories (build, delay, carry, repair) are a mainstream articulation of the conscience's second allergy (speculative abstraction) and of R4's "don't add flexibility for needs that don't exist."

- **KISS.** The generic "keep it simple" folk-rule is the low-resolution version of the same posture; the conscience's contribution is to make it operational (name the dials, ask the standing question) rather than a slogan.

- **The Wrong Abstraction (Sandi Metz, 2016).** Verbatim: "duplication is far cheaper than the wrong abstraction." Her repair prescription — when a shared abstraction has accreted conditionals, re-inline it back into its callers and re-derive ("the fastest way forward is back") — is the exact failure mode R1 exists to prevent. On this file's read, this is among the strongest mainstream endorsements of the whole compression discipline.

- **Simple Made Easy (Rich Hickey, Strange Loop 2011).** Simple (un-complected, an objective property) vs easy (at-hand, familiar, subjective). "Complect" = to braid together; state complects value and time; objects complect identity, value, and behavior. Hickey targets *incidental* complexity, which is the same enemy as the conscience's "unexamined convenience." Divergence: Hickey reaches for immutability and data-as-data; the DOD wing reaches for cache-friendly layout — different tools, same anti-incidental-complexity aim.

- **A Philosophy of Software Design (John Ousterhout).** "Deep modules" — a simple interface hiding substantial implementation — and the definition of complexity as anything making a system hard to understand and modify. This is where the schools genuinely *diverge*: Ousterhout wants interfaces to conceal representation and machine cost; Acton/Muratori want the cost model visible and the fine-grained tier reachable (R8's granularity dial). The disagreement is real but narrow — both are hunting incidental complexity; they split only on whether concealment or exposure serves comprehension better in a given domain.

The honest synthesis: keep the cheap habits universally (no cargo cult, no speculative abstraction, no gratuitous waste), reserve data-oriented micro-optimization for measured hot paths, and let comprehensibility lead wherever change-rate and team-size dominate.

---

## 3. Honest critiques and boundaries

The conscience is a lens, not a law (its own words). Here is where it is genuinely contested, stated fairly to both sides.

**The microbenchmark objection.** The most rigorous critique is Evan Teran's "Casey Muratori is wrong about clean code (but he's also right)" (2023). Teran's verified core point: nearly all the slowness in Muratori's "Clean Code, Horrible Performance" benchmark comes from *virtual function dispatch specifically*, not from the other "clean code" rules Casey bundles with it — and `std::variant`/`std::visit` can match a per-object method-table dispatch, showing you can drop dispatch cost without abandoning encapsulation. Combined with Amdahl's law, this grounds the real boundary: a benchmark on a hot, homogeneous loop does not generalize to a whole program. The Muratori numbers themselves are genuine but must be quoted with care, and every figure here is an **x86/C++ microbenchmark that will not reproduce verbatim in another language or on another machine** — roughly ~35 cycles/shape for virtual dispatch down to ~24 for a switch (about 1.5x, *not* 2x), roughly 10x from a coefficient-table layout versus the virtual baseline, ~15x when a second property is added, and 20–25x with a light AVX path. The often-repeated "25x from a switch" is an overstatement; treat any precise per-shape cycle count as approximate and re-measure in your own environment.

**IO-, network-, and business-bound software, and the portable half.** The 10x/cache-line framing is domain-bound to hot, high-volume, homogeneous data paths. Transplanted onto IO-bound CRUD, request-handling glue, or business logic that spends its life waiting on a database or the network, the same tactics are unmeasured micro-optimization — you are shaving nanoseconds off code whose cost is milliseconds elsewhere. DOD itself says little about IO- or network-bound systems. But the *portable half* — non-pessimization, defined against the **task**, not the machine — applies everywhere, and it is concrete, not a slogan:

- **N+1 queries → batch or join.** One query per row in a loop is the canonical waste. Django `select_related`/`prefetch_related`, Rails `includes`, an explicit `JOIN`, or a single `WHERE id IN (...)` — same fix in every stack.
- **Redundant serialization / parsing → parse once, pass the value.** Re-`JSON.parse`ing the same payload per call, re-deserializing a config each request, re-`json.loads` in a loop. Parse at the boundary, pass the parsed object inward.
- **Per-item allocation in a hot loop → reuse the buffer.** Churning a new array/list/object per element. Preallocate and reuse (Go `sync.Pool`; a hoisted slice; a reused list); in Python prefer a comprehension over repeated `append` growth where it is genuinely hot.
- **Recomputed invariants → hoist out of the loop.** Compiling the same regex every iteration (Python `re.compile` once; a hoisted JS regex literal), recomputing a constant, re-reading an unchanged file.
- **Speculative indirection → inline until the second occurrence (R1).** The plugin system, the config-driven strategy map, the extra interface layer for the one caller that exists.

None of these need a profiler to justify removing; they are waste against the task by definition. The machine-specific half (cache layout, SoA, SIMD) is what waits for a measurement.

**Large-team maintainability.** The benchmark-driven style optimizes a hot kernel written and owned by an expert. Off that path, where change-rate and headcount dominate, the concealment that Ousterhout and the "clean code" tradition prize can be worth more than exposed layout. Muratori concedes this on SE Radio 577: the shapes example is a tight numeric kernel and maintainability trade-offs off the hot path are real. (Balance it against his counter-claim in Section 1 — that identical paths going through one code path is itself a maintainability win. Both are true; they apply in different regions.)

**Prototyping and exploration.** R2 (write the call site first) and R6 (inspect the actual data) serve exploration well, but the whole non-pessimization posture presumes you know the task. In genuinely exploratory work — where the data shape and the problem are both unknown — reaching for the "correct" data-oriented layout early is itself a form of speculative commitment. The conscience's own R1 protects against this: stay concrete until the second occurrence teaches you the shape.

**Managed/JIT runtimes.** A cross-language trap worth stating: in JIT/managed runtimes the compiler may already devirtualize and vectorize, so hand-porting C tactics (manual tagged unions to dodge dispatch) can be neutral or negative. R7 settles it — measure, don't assume the C result transfers.

**The Muratori vs. Robert C. Martin exchange — contested vs. conceded.** Documented in the `unclebob/cmuratori-discussion` repo (`cleancodeqa.md`). It reads as a boundary negotiation, not a knockout, and both men gave ground.

- *Martin conceded:* Clean Code examples are inefficient at the nanosecond level; "the vast majority of software systems require less than 1% of a modern processor's power"; "it is economically better for most organizations to conserve programmer cycles than computer cycles"; and that he had under-weighted performance, promising "more than barely a nod" going forward. (Accuracy caveat: the popular "two or three nods" phrasing is an embellishment — the source says "more than barely a nod.")
- *Muratori conceded:* domains differ; the choice is context-driven.
- *Still contested:* inheritance vs. discriminated unions (Casey's position: inheritance leaves you "stuck," unions let you change your mind), and whether performance should be the *default* posture.
- *Agreed:* "all these issues are human issues. The computer does not care." The decision is context-driven.

The fair reading: not a case of one side winning. It maps the boundary the conscience already respects — keep the cheap universal habits, reserve the expensive machine-specific ones for where they measurably pay.

**A standing counterweight for refterm itself.** Jussi Pakkanen's "Looking at the performance of Refterm" (Nibble Stew) is an honest critique from the author of the Meson build system: refterm shows high idle memory (~351 MB), no idle rate-limiting, and freezes on some binary input. Cite it whenever refterm is invoked as an unqualified triumph — the README's own "modern minimum, not a maximum to aspire to" framing agrees.

---

## 4. Annotated further reading

*Grouped by medium. Each entry: author — title (year) — one line on why it matters — URL only where verified at time of writing. Uncertain items are marked.*

### Essays

- Casey Muratori — "Semantic Compression" (2014) — the founding text; PKZip metaphor, usable-before-reusable, the two-instances rule. https://caseymuratori.com/blog_0015
- Casey Muratori — "Complexity and Granularity" (2014) — the tiering rule and "the total cost and only the total cost"; the bool_button/push_button example. https://caseymuratori.com/blog_0016
- Casey Muratori — "Immediate-Mode Graphical User Interfaces" (2005) — coins IMGUI; origin of the immediate-vs-retained model. https://caseymuratori.com/blog_0001
- Casey Muratori — "'Clean' Code, Horrible Performance" (2023) — the benchmark essay; read *with* the Teran critique below. https://www.computerenhance.com/p/clean-code-horrible-performance
- Ryan Fleury — "Untangling Lifetimes: The Arena Allocator" — the canonical grouped-lifetimes argument. (rfleury.com now redirects to dgtlgrove.com; current canonical host below.) https://www.dgtlgrove.com/p/untangling-lifetimes-the-arena-allocator
- Ginger Bill (Bill Hall) — "Memory Allocation Strategies," Part 2 (2019) — canonical arena/linear-allocator implementation writeup. https://www.gingerbill.org/series/memory-allocation-strategies/
- Sandi Metz — "The Wrong Abstraction" (2016) — "duplication is far cheaper than the wrong abstraction"; the re-inline repair. https://sandimetz.com/blog/2016/1/20/the-wrong-abstraction
- Martin Fowler — "Yagni" (2015) — the four cost categories behind speculative-abstraction restraint. https://martinfowler.com/bliki/Yagni.html
- Carson Gross — "The Grug Brained Developer" — defer factoring until cut-points emerge; the verbatim line is "the best weapon against complexity spirit demon is magic word: no." https://grugbrain.dev/
- Carson Gross — "Locality of Behaviour" (2020) — co-locate behavior with its unit; an explicit tradeoff against DRY/SoC. https://htmx.org/essays/locality-of-behaviour/
- John Carmack — "On Inlined Code" (2007 email, reposted 2014 by Jonathan Blow) — understand every state your code can reach. http://number-none.com/blow/john_carmack_on_inlined_code.html
- Evan Teran — "Casey Muratori is wrong about clean code (but he's also right)" (2023) — the sharpest critique: the cost is virtual dispatch specifically, not the other rules. https://blog.codef00.com/2023/04/13/casey-muratori-is-wrong-about-clean-code
- Lucian Radu Teodorescu — "Revisiting Data-Oriented Design" (Overload 167, 2022) — the one careful secondary analysis of DOD's actual tradeoffs; use it when crediting the SoA cost/benefit claim rather than asserting it. https://accu.org/journals/overload/30/167/teodorescu/
- Jussi Pakkanen — "Looking at the performance of Refterm" — honest counterweight (idle memory, no rate-limiting). https://nibblestew.blogspot.com/2021/07/looking-at-performance-of-refterm.html
- suckless community — "suckless philosophy" — every line and dependency is a liability; removed code is progress. https://suckless.org/philosophy/
- Omar Cornut — "About the IMGUI paradigm" (Dear ImGui wiki) — immediate mode is not stateless; your data stays the source of truth. https://github.com/ocornut/imgui/wiki/About-the-IMGUI-paradigm
- Haskell Foundation — "1.5 Philosophies of Optimization" (Haskell Optimization Handbook) — independent, non-C codification of optimization / non-pessimization / fake optimization. https://haskell.foundation/hs-opt-handbook.github.io/src/Preliminaries/philosophies_of_optimization.html
- Luna — "Systems Languages Should Support Zero Is Initialization (ZII)" (blog.xoria.org) — secondary explainer of ZII; attributes popularization to Muratori. https://blog.xoria.org/zii/
- *(secondary, lower weight)* Soren Saket — "Zero Is Initialization (ZII)" (Medium) — another secondary ZII explainer. https://medium.com/low-level/zero-is-initialization-zii-be3a7f1eec41
- *(uncertain)* PVS-Studio — "Clean code: blessing or curse? Act I" — plausible but not re-verified; treat as low-weight corroboration only. https://pvs-studio.com/en/blog/posts/1157/

### Talks (video)

- Casey Muratori — "Designing and Evaluating Reusable Components" (2004) — origin of the five dials (granularity, redundancy, coupling, retention, flow control), the three reuse models (layer / engine-framework / component), and "integration discontinuity." Also the source of the operational flow-control rule: anywhere there is a callback or inheritance, provide an equivalent plain API call so an adopter keeps an escape hatch. (Historical note carried in the video: there were originally *four* characteristics; flow control was the fifth, added on Chris Hecker's suggestion.) https://caseymuratori.com/blog_0024 (video: https://www.youtube.com/watch?v=ZQ5_u8Lgvyk)
- Casey Muratori — "Refterm Lecture Part 1: Philosophies of Optimization" (2021) — the three activities: optimization / non-pessimization / fake optimization. https://youtu.be/pgoetgxecw8
- Mike Acton — "Data-Oriented Design and C++" (CppCon 2014) — the purpose of all programs is to transform data; "if you don't understand the data, you don't understand the problem." https://www.youtube.com/watch?v=rX0ItVEVjHc
- Jonathan Blow — "Preventing the Collapse of Civilization" (DevGAMM Moscow 2019) — low-level craft must be deliberately transmitted (hold with the survivorship-bias caveat in Section 1). https://www.youtube.com/watch?v=pW-SOdj4Kkk (official English-audio upload: https://www.youtube.com/watch?v=q3OCFfDStgM)
- Jonathan Blow — "Ideas about a new programming language for games" (2014) — the first Jai design talk. https://www.youtube.com/watch?v=TH9VCN6UkyQ
- Rich Hickey — "Simple Made Easy" (Strange Loop 2011) — simple (un-complected) vs easy (at-hand); decomplect state and time. https://www.infoq.com/presentations/Simple-Made-Easy/
- Tony Albrecht — "Pitfalls of Object Oriented Programming" (Game Connect: Asia Pacific 2009) — the classic AoS-to-SoA cache-miss demonstration on real game code. https://harmful.cat-v.org/software/OO_programming/_pdf/Pitfalls_of_Object_Oriented_Programming_GCAP_09.pdf
- SE Radio 577 (host Giovanni Asproni, guest Casey Muratori) — "Casey Muratori on Clean Code, Horrible Performance?" (2023) — where Muratori concedes maintainability trade-offs off the hot path. https://se-radio.net/2023/08/se-radio-577-casey-muratori-on-clean-code-horrible-performance/
- Julian Ceipek — visual transcript of "Designing and Evaluating Reusable Components" — the five dials enumerated verbatim; useful if you prefer text. https://github.com/jceipek/designing-reusable-components
- *(uncertain wording)* Casey Muratori — "Smart-Pointers, RAII, ZII? Becoming an N+2 programmer" — supports ZII-vs-RAII attribution; exact in-video wording unverified. https://www.youtube.com/watch?v=xt1KNDmOYqA

### Books

- Richard Fabian — *Data-Oriented Design: Software Engineering for Limited Resources and Short Schedules* (2018, ISBN 9781916478701) — the systematic DOD text; existential processing, the relational/ECS framing. Free online: https://www.dataorienteddesign.com/dodbook/
- John Ousterhout — *A Philosophy of Software Design* — deep modules; the mainstream case for concealment that the DOD wing partly disputes. (Book; no canonical free URL.)
- Martin Fowler — *Refactoring* — home of the Rule of Three (attributed to Don Roberts): "the third time you do something similar, you refactor." (Book; no free URL cited.)

### Repositories

- Casey Muratori — refterm (reference monospace terminal renderer) — the "modern minimum, not a maximum" case study. https://github.com/cmuratori/refterm
- Robert C. Martin & Casey Muratori — `cmuratori-discussion` (`cleancodeqa.md`) — the full written exchange; read for what was conceded vs. contested. https://github.com/unclebob/cmuratori-discussion
- Epic Games / Allen Webster, Ryan Fleury et al. — RAD Debugger — a large real C codebase built on arenas, ZII, and explicit allocator passing. https://github.com/EpicGamesExt/raddebugger
- CppCon 2014 — Acton "Data-Oriented Design and C++" slide deck (image-based; text not machine-extractable). https://github.com/CppCon/CppCon2014
- Omar Cornut — Dear ImGui — the immediate-mode GUI library that carried the paradigm to the mainstream. https://github.com/ocornut/imgui
- Community mirror (cj1128) — Handmade Hero `handmade_platform.h` — verbatim `Assert` / `InvalidCodePath` / `InvalidDefaultCase` macros (the crash-loudly discipline). https://github.com/cj1128/handmade-hero/blob/master/code/handmade_platform.h

### Courses and series

- Casey Muratori — "Computer, Enhance!" Performance-Aware Programming — teaches speed through Waste, Instructions Per Clock, SIMD, Caching, Multithreading, in order of accessibility (Waste first, largest, cheapest). Note this ladder is native/compiled-oriented x86 framing; in IO-bound or managed contexts the ordering is not the right lens. Table of contents: https://www.computerenhance.com/p/table-of-contents ; series intro: https://www.computerenhance.com/p/performance-aware-programming-series
  - *(paywalled / not independently verified)* "Waste" prologue post — the "biggest, cheapest multiplier" claim lives here but is behind the paywall. https://www.computerenhance.com/p/waste
- Casey Muratori — Handmade Hero (episode series and code) — Day 14 "Platform-independent Game Memory" (permanent/transient split); Day 21–22 hot reload; Day 23 "Looped Live Code Editing" (input recording + looped playback) — the verified backing for R5. https://guide.handmadehero.org/
- Gary Bernhardt — "Boundaries" / "functional core, imperative shell" — the pattern name for the pure-core + IO-shell split that makes hot reload and deterministic replay possible. (Talk; cite by name — no single canonical free URL verified here.)

### Academic sources (region-based memory — the arena's formal ancestor)

- Mads Tofte & Jean-Pierre Talpin — "Region-Based Memory Management" (*Information and Computation* 132(2), 1997) — type-and-effect inference of region alloc/dealloc, no GC; implemented in the ML Kit. https://www.sciencedirect.com/science/article/pii/S0890540196926139
- Tofte, Birkedal, Elsman, Hallenberg — "A Retrospective on Region-Based Memory Management" (2004) — the honest caveat: pure region inference sometimes needed hybrid GC. https://link.springer.com/article/10.1023/B:LISP.0000029446.78563.a4
- Grossman, Morrisett, Jim, Hicks, Wang, Cheney — "Region-Based Memory Management in Cyclone" (PLDI 2002) — statically-checked regions in a safe C dialect; a precursor to Rust lifetimes. https://www.cs.umd.edu/projects/cyclone/papers/cyclone-regions.pdf

### Provenance notes (pure pointers — details live in the sections above)

- **refterm number** — ~1000x is Muratori's own claim, "100x" is a community simplification; caveat stated inline at first mention in Section 1.
- **five dials were originally four** — flow control added on Chris Hecker's suggestion; stated in the "Designing and Evaluating Reusable Components" reading-list entry.
- **"more than barely a nod"** — not "two or three nods"; stated in Section 3 (Martin exchange).
- **Acton "purpose of all programs"** — the tight "only purpose" phrasing is a restatement, not verbatim; handled in Section 1.
- **Blow decline thesis** — carry the survivorship/nostalgia-bias caveat from Section 1.
- **handmadehero.org** 301-redirects to mollyrocket.com/handmade; Handmade Hero is retired; current education work is Computer Enhance (computerenhance.com).
- **"Compression-oriented Programming" forum thread** was *opened by user "Burmi"* (2015); Muratori only replied — do not cite as Muratori-authored. https://hero.handmade.network/forums/code-discussion/t/510-compression-oriented_programming
- **Sean Barrett's parallel immediate-mode treatment** (Game Developer Magazine, Sept 2005) is solidly attributed but has no verified online URL — cite the print attribution, not a guessed link.
- *(medium confidence)* **Allen Webster's** Handmade Network profile is real (handle misspelled "Mr4thDimention"); personal site mr4th.com. No single citable "how I program" essay verified — cite his example (build your own tools), not a quotation. https://handmade.network/m/Mr4thDimention

---

*Status: lineage and sources, v2. This is the demystification file — if you invoke a name or a number from the school, this is where you check it before repeating it. Amend when a source is re-verified, corrected, or added.*
