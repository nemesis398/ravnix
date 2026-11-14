# Patterns of the Muratori school — a language-independent catalog

These are recurring *moves*, not rules. Each one names a default it displaces, shows the same idea in 2–3 languages (idiomatic, not transliterated C), and ends with the boundary where the move stops paying — because a pattern you can't say "no" to is folklore (R3), and an abstraction applied before its second occurrence is speculation (R1).

> **Notation.** R-numbers and "allergy #1/#2" refer to the rules and named traps defined in SKILL.md; they are *used*, not redefined, here. Quick key for the ones cited most: **R1** don't abstract before the second occurrence · **R2** usable before reusable · **R3** demystify, and keep the right to say "no" · **R4** know the work each line asks of the machine · **R6** measure the specific runtime, don't assume · **R7** do the speed-of-light arithmetic first · **R8** name which dial you turn (granularity, redundancy, coupling, retention, flow control) · **allergy #1** cargo-cult copy-paste · **allergy #2** speculative abstraction.

Standing questions to keep in hand while reading:
- **R1** What is the second occurrence? (don't compress before it)
- **R4** What work does this ask of the machine?
- **R8** Which dial does this turn — granularity, redundancy, coupling, retention, flow control?

---

## 1. Tagged union + dispatch on a tag, instead of class hierarchy + virtual dispatch

**Idea:** For a *closed* set of variants, model the variants as data (a tag plus per-variant fields) and put each operation in one place that switches on the tag — rather than scattering the operation across subclasses behind virtual calls.

**Why it beats the default:**
- **One place to read and change.** All the cases of an operation sit together, so you read and edit `area()` on one screen instead of hunting through N files.
- **The compiler can force exhaustiveness.** A new variant produces a compile error at every switch that forgot it.
- **The layout is flat.** No per-object method-table pointer, no per-element indirect call — which is the door to the *table-compression* follow-on (the shapes example). Once `area()` is a switch, you can see that every branch is `coefficient[kind] * width * height`, collapse it to a coefficient table, and the loop gets strictly faster in this order: virtual dispatch (slowest) < switch < coefficient table (fastest). That table was *visible from the switch and invisible from inside the hierarchy*.

In Muratori's "Clean Code, Horrible Performance" benchmark, the coefficient-table version ran on the order of 10x faster than the virtual baseline (with more on top from a light SIMD pass). Treat that as a *direction, not a constant*: those figures come from an x86/C++ microbenchmark and will not reproduce verbatim from a Rust `match`, a TypeScript `switch`, or Python — measure your own runtime (R6, R7).

This is the expression-problem tradeoff stated honestly: sum-type + match makes **adding operations** cheap and **adding variants** a deliberate edit; class hierarchies make adding variants cheap and adding operations invasive. Pick the axis your code actually changes on.

**Rust** — the idiomatic closed set is an `enum`, and `match` is checked for exhaustiveness:

```rust
enum Shape {
    Circle { r: f64 },
    Rect { w: f64, h: f64 },
    Triangle { b: f64, h: f64 },
}

fn area(s: &Shape) -> f64 {
    match s {
        Shape::Circle { r } => std::f64::consts::PI * r * r,
        Shape::Rect { w, h } => w * h,
        Shape::Triangle { b, h } => 0.5 * b * h,
    }
}
```

**OCaml** — the same shape as an algebraic data type; the compiler warns on a non-exhaustive match:

```ocaml
type shape =
  | Circle of float
  | Rect of float * float
  | Triangle of float * float

let area = function
  | Circle r -> Float.pi *. r *. r
  | Rect (w, h) -> w *. h
  | Triangle (b, h) -> 0.5 *. b *. h
```

**Java 17+** — a `sealed` interface makes the variant set closed at author time; `record`s carry the per-variant fields; a `switch` over the patterns is checked for exhaustiveness (no `default` needed). This is the idiomatic modern JVM answer:

```java
sealed interface Shape permits Circle, Rect, Triangle {}
record Circle(double r) implements Shape {}
record Rect(double w, double h) implements Shape {}
record Triangle(double b, double h) implements Shape {}

static double area(Shape s) {
    return switch (s) {
        case Circle c   -> Math.PI * c.r() * c.r();
        case Rect r     -> r.w() * r.h();
        case Triangle t -> 0.5 * t.b() * t.h();
    };
}
```

**TypeScript** — a discriminated union on a literal `kind` field; `switch` with a `never` fallthrough turns "forgot a case" into a type error:

```ts
type Shape =
  | { kind: "circle"; r: number }
  | { kind: "rect"; w: number; h: number }
  | { kind: "triangle"; b: number; h: number };

function area(s: Shape): number {
  switch (s.kind) {
    case "circle":   return Math.PI * s.r * s.r;
    case "rect":     return s.w * s.h;
    case "triangle": return 0.5 * s.b * s.h;
    default: {
      const _exhaustive: never = s; // compile error if a variant is unhandled
      return _exhaustive;
    }
  }
}
```

The table-compression endpoint, once you have measured that this loop is hot:

```ts
// coefficient[kind] * a * b — the switch made this visible
const COEFF = { circle: Math.PI, rect: 1, triangle: 0.5 } as const;
```

**When NOT / trap:** This is for *closed* variant sets that change rarely. If third parties must add variants you don't control (plugins, an open protocol), the hierarchy/interface is the better fit — a new sum-type variant forces edits to every switch, which is exactly wrong when "add a variant" is the common case. Also, a measured caveat matters (R7): in the shapes benchmark *nearly all* the slowness was virtual dispatch specifically, and a modern tagged-union type (C++ `std::variant` + `std::visit`, and its equivalents elsewhere) can match a method-table dispatch — so the win is "remove per-element indirection on a hot homogeneous loop," not "switches are morally superior." Off the hot path, on cold or small-N code, this is a comprehensibility choice, not a performance one — decide it as such.

---

## 2. Plain data + free functions, instead of encapsulated objects (and SoA when measured)

**Idea:** Represent state as transparent data and write functions that transform it; reach for structure-of-arrays only after a profile shows a pass is memory-bound. A program is a transformation of input data into output data — design from the real data and its volume, not from an object model.

**Why it beats the default:**
- **"Where there is one, there are many."** The unit of work is usually a *collection*, so expose the loop and let the transform see the whole batch.
- **Shallow call graphs, small states.** Free functions over plain structs keep the call graph shallow and the states small (Carmack: most bugs come from not understanding all the states code can be in), and they don't pre-commit you to a class boundary before you know where the seams are (R1: abstraction is an *output* of programming).
- **Layout is a dial.** SoA (R8, granularity/coupling) lays out by the fields a pass actually touches, so the cache lines you pull carry only useful bytes.

**Go** — data is a struct; behavior is a function that takes it; no ceremony:

```go
type Order struct {
    ID     int64
    Cents  int64
    Region string
}

// operate on the batch, not one-at-a-time
func TotalCents(orders []Order) int64 {
    var sum int64
    for i := range orders {
        sum += orders[i].Cents
    }
    return sum
}
```

**Python** — resist wrapping every row in an object; when the batch is large and numeric, columnar layout (SoA) *is* the performance move, and libraries make it idiomatic:

```python
# Array-of-structs, fine for small N / glue code:
orders = [{"id": 1, "cents": 500, "region": "eu"}, ...]

# Structure-of-arrays: each field becomes its own contiguous column.
# Use when a pass is hot and touches only a few columns:
import numpy as np
cents  = np.array([500, 1200, 300], dtype=np.int64)
region = np.array(["eu", "us", "eu"])        # parallel column, same row order
total    = cents.sum()                        # one vectorized pass over contiguous memory
eu_total = cents[region == "eu"].sum()        # boolean mask selects the eu rows
```

Columnar stores (Arrow, Parquet, ClickHouse) are exactly SoA at scale, and set-at-a-time SQL is the same instinct: say what transform you want over the whole relation, not a per-row loop. The general form is the **entity-component-system / relational-table** model — rows are entities, columns are components, and a "system" is a query over just the columns it touches (Unity DOTS, Bevy, and EnTT make this concrete). For most developers outside C, ECS or a columnar dataframe is where they actually first meet data-oriented design.

**When NOT / trap:** DOD's cache-line/10x framing is domain-bound to hot, high-volume, homogeneous transforms. Transplanted onto IO-bound CRUD it is unmeasured micro-optimization — an N+1 query dwarfs any layout win (Amdahl). SoA also trades away data-structure stability and readability: inserting/removing a whole entity now touches many arrays, and encapsulation (a real asset when invariants must hold across a team) is deliberately given up. That concession is real — but the school makes a counter-claim worth holding next to it (Muratori): well-compressed code can also be *easier* to maintain, because all the places doing identical things go through the same path, so a fix lands once instead of in N scattered subclasses. Both are true; weigh them per case. Default to the clearest AoS representation; switch to SoA at the specific pass the profiler indicts (R6), not across the whole program.

---

## 3. Grouped lifetimes / arenas — and their GC-language translations, plus ZII

**Idea:** Bucket many allocations that share a lifetime into one region tied to a boundary the program already has (whole run, per-frame, per-request, per-parse), and reclaim the whole group in one motion instead of freeing items individually.

**Why it beats the default:**
- **Most allocations share a lifetime,** so per-item `free`/refcount/GC-tracking is bookkeeping the task didn't ask for (R4).
- **Allocation becomes an O(1) pointer bump and deallocation a single offset reset** — and a whole class of use-after-free and leak bugs disappears, because you reason about *one* lifetime, not thousands.
- **Passing the arena in as a parameter** (`parse(arena, input) -> tree`) makes lifetime an explicit caller choice instead of hidden global state (R8: retention/coupling).
- **ZII pairs with this:** design types whose all-zero state is a valid, no-op default, so zeroed arena memory is already initialized and allocation-plus-init collapse into one step.

**Zig** — explicit allocators are idiomatic; the arena is a first-class stdlib allocator:

```zig
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();           // frees everything at once at the boundary
const a = arena.allocator();

const tree = try parse(a, input); // every node bump-allocated; no per-node free
// ... use tree ...
// deinit reclaims the whole group; no traversal to free individual nodes
```

**Go** — you don't hand-roll arenas against a generational GC; the translation is *reuse buffers* and *pool* only where a profile shows allocation churn dominates:

```go
// clear-and-reuse instead of reallocating per iteration
buf = buf[:0]
for _, item := range items {
    buf = append(buf, transform(item)...)
}
process(buf)

// sync.Pool only when profiling shows GC pressure is the bottleneck:
var bufPool = sync.Pool{New: func() any { return new(bytes.Buffer) }}
```

Go also gives ZII for free: a zero `struct` is meant to be usable (`var b bytes.Buffer` is ready to write to). Lean on it.

**When NOT / trap:** Arenas fit *homogeneous, grouped* lifetimes. When lifetimes are heterogeneous and independent — a per-entry cache, a long-lived object graph with churn — an arena either retains to a high-water mark (a slow leak) or degrades to a general allocator anyway; even Tofte et al.'s region-inference work conceded it sometimes needed hybrid GC. In managed runtimes, object pooling can be a *net loss* versus a generational collector and is justified only by measurement (R6/R7), not reflex. And ZII fails for types whose valid state is not all-zero (a `time.Time`, a non-nullable ID, a socket fd) — forcing zero-as-valid there just relocates the bug. Non-nullable-by-default languages (Rust, Swift, Kotlin) intentionally reject ZII; there, `Default`/`Option`/constructors are the idiom, and fighting that is pessimizing the language, not the machine.

---

## 4. Immediate-mode: redeclare desired state, instead of mutate-and-sync a retained model

**Idea:** Each cycle, describe the desired end state directly from your own authoritative data, and let a thin layer diff/apply — rather than building a persistent mirror object model that you must mutate and keep synchronized with your data.

**Why it beats the default:**
- **A retained mirror is a second copy of the truth** (R8: retention), and every mirror invites desync bugs — the tree and the model drift, and you write reconciliation code by hand.
- **Redeclaring from one source of truth deletes the sync problem:** the view is a pure function of state.
- **It generalizes far past GUIs** — declarative UI rebuilds (React render), idempotent infrastructure reconcilers (Kubernetes, Terraform), and "render the frame from the world" are all the same stance: *say what should be true; let the layer make it so.*

**React/TSX** — you return the desired UI from state; you never imperatively `appendChild`:

```tsx
function Cart({ items }: { items: Item[] }) {
  // desired DOM re-declared from data every render; the reconciler diffs it
  return <ul>{items.map(i => <li key={i.id}>{i.name}: {i.qty}</li>)}</ul>;
}
```

**Kubernetes-style reconciler (Go)** — declare the target, converge idempotently, run to a fixpoint regardless of current state:

```go
// immediate-mode as a control loop: desired is authoritative; apply is idempotent
func reconcile(desired []Pod, cluster *Cluster) {
    running := cluster.List()
    for _, d := range desired {
        if !running.Has(d) { cluster.Create(d) } // converge toward desired
    }
    for _, r := range running {
        if !contains(desired, r) { cluster.Delete(r) } // prune drift
    }
}
```

Note the important correction (Cornut): immediate-mode is *not* stateless. The layer keeps ephemeral, ID-keyed interaction/diff state (React's fiber tree, ImGui's active-widget id). What's immediate is that *your application data stays the single source of truth* and views are derived, not mutated in parallel.

**When NOT / trap:** Retained mode is right when rebuilding the description each cycle is genuinely expensive relative to mutating it, and the state is large and mostly-static — a 100k-node scene where one node moved, a virtualized list, a physics broadphase. Then you keep a retained structure and mutate deltas (React itself falls back to memoization/keys for this reason). The identity trap is the recurring hazard: immediate-mode is keyed on stable IDs, and a mismatched or index-based key silently swaps state between elements (the classic React `key={index}` bug). If you can't produce stable identity for your items, immediate-mode reconciliation will bite you.

---

## 5. Write the usage first: design the call site before the implementation

**Idea:** Write the line you *wish* you could call — the ideal call site — and implement toward it, so the interface is shaped by real use, not by what was convenient to build (R2: usable before reusable).

**Why it beats the default:** Interfaces designed inside-out expose the implementation's accidents (you pass a handle because the impl has a handle) and produce *integration discontinuities* — easy in the demo, a cliff near ship, because the intermediate options you needed were never exposed. Writing the caller first forces the ergonomic decisions (granularity, what's mandatory, who owns what) while they're still cheap, and it keeps flow control with the caller — a library you call, not a framework that calls you (R8).

**Any language, the move looks the same** — write the aspirational caller as if it already worked:

```rust
// 1. The line I wish I could write (before any impl exists):
let tree = parse(&arena, source)?;
let html = render(&tree);

// 2. Now the signatures are dictated by the call site, not the reverse:
fn parse<'a>(arena: &'a Arena, source: &str) -> Result<Tree<'a>, ParseError> { ... }
fn render(tree: &Tree) -> String { ... }
```

```python
# Sketch the desired usage in a docstring/example first:
#   summary = summarize(doc, max_sentences=3)
#   assert isinstance(summary, str)
# then implement summarize() to make that call read well.
```

**How it differs from TDD:** TDD drives on *behavioral examples* and can pin down an awkward interface just as firmly as a good one — a green test says nothing about whether the call site is pleasant. Usage-first is specifically about the *shape and ergonomics of the interface*: you're not asserting a result, you're deciding what the call should look like and feel like to hold. The two compose (write the call you want, then a test that the call yields the right answer), but usage-first is design pressure, TDD is correctness pressure. They answer different questions.

**When NOT / trap:** Don't over-fit the interface to the *first* call site and ship it as reusable — one caller is not evidence of the right abstraction (that's R1's whole point). Write the usage first to get *this* use right; extract a reusable API only when a second real caller shows what's genuinely shared. Also beware designing a beautiful call site that hides ruinous machine cost (R4): a lovely `config.get("a.b.c")` that reparses a file every call is a usable interface pessimizing the machine.

---

## 6. Compress on the second occurrence — the rule of three, done with discipline

**Idea:** No shared abstraction until the same *semantic* pattern appears twice in real working code; then extract the *smallest* shareable unit. "I don't reuse anything until I have at least two instances of it occurring."

**Why it beats the default:** Premature DRY couples call sites that only *look* alike, and the wrong abstraction is far more expensive than the duplication it replaced — Sandi Metz: *"duplication is far cheaper than the wrong abstraction."* Waiting for the second (Fowler/Roberts: the third) occurrence lets the *actual* shared shape reveal itself, so you extract the real invariant instead of a coincidence. Compress *at* the recurrence — not before (speculation) and not never (folklore copy-paste, allergy #1). And extract the *smallest* unit: keep the tiers continuous, "never supply a higher-level function that can't be trivially replaced by a few lower-level functions."

**The anti-pattern and its repair (TypeScript):**

```ts
// Two call sites that DIFFER; forcing them through one "reusable" helper:
function render(user: User, opts: { admin?: boolean; compact?: boolean;
                                    export?: boolean; locale?: string }) {
  // a thicket of if(opts.admin) ... if(opts.export) ... — a boolean minefield
}
```

When a parameter exists only to select *which unrelated behavior* runs, that's the wrong abstraction. Metz's repair: **re-inline back into the callers**, let the duplication sit visibly, and wait to see what's truly common.

```ts
// Back to two honest, concrete functions:
function renderAdminRow(u: User) { ... }
function renderExportRow(u: User) { ... }
// If a genuine shared unit emerges (e.g. name formatting), extract THAT — small:
function fullName(u: User) { return `${u.first} ${u.last}`; }
```

**Rust** — the smallest-shareable-unit instinct: extract the tiny common core, not a mega-trait:

```rust
// Second occurrence of "clamp then scale" appears — extract just that:
fn clamp_scale(x: f64, lo: f64, hi: f64, k: f64) -> f64 {
    x.clamp(lo, hi) * k
}
// ...not a Normalizer trait with a builder and three strategy impls.
```

**When NOT / trap:** "Second occurrence" means the same *meaning*, not the same *characters*. Two 5-line blocks that are textually identical but will evolve for different reasons (a tax calc and a discount calc that happen to both multiply) are not a real duplication — merging them creates a coupling you'll fight later. Conversely, don't fetishize the rule into "never abstract" — some patterns are known-common from domain knowledge (an HTTP client, a logger) and waiting for a contrived "second occurrence" is its own dogma. And the goal is *the total lifecycle cost and only that* — sometimes the right move is to stop compressing because the next extraction saves nothing.

---

## 7. Non-pessimization checklist — cheap wins available in any language

**Idea:** Before any "optimization," stop *asking the machine for work the task doesn't require*. Non-pessimization is defined against the task, not the machine, so it ports everywhere and usually makes code *shorter*, not more complex.

**Why it beats the default:** The amount of needless work you can pile on is unbounded, so the gap between pessimized and non-pessimized code typically *exceeds* the gap between non-optimized and optimized code — and removing waste costs nothing because non-pessimized code is normally simpler. This is the everyday default, distinct from **actual optimization** (rare, measured, machine-specific, on a proven hot path) and **fake optimization** (folklore like "never use X," applied without measuring — allergy, a vice).

**The checklist (know the work each line asks of the machine — R4):**

- **N+1 queries** — batch instead of looping the DB:

  ```python
  # pessimized: one query per user
  for uid in ids:
      u = db.query("select * from users where id=%s", uid)
  # non-pessimized: one query, total
  users = db.query("select * from users where id = any(%s)", ids)
  ```

- **Accidental quadratic** — membership test in a list inside a loop is O(n²); use a set/map:

  ```python
  seen = set(existing)          # was: `if x in existing_list` → O(n) each time
  new = [x for x in incoming if x not in seen]   # now O(1) per check
  ```

- **Gratuitous allocation/copying in hot loops** — reuse buffers, take references, avoid re-boxing:

  ```rust
  // pessimized: allocate a String per iteration
  for line in &lines { let s = line.to_string(); consume(&s); }
  // non-pessimized: borrow; no allocation
  for line in &lines { consume(line); }
  ```

- **Recomputed invariants** — hoist work that doesn't depend on the loop variable out of the loop.
- **Redundant serialization / re-parsing** — parse once, pass the parsed value.
- **Per-element indirection on hot homogeneous loops** — the cross-language dispatch tax (Go interface dispatch, Java megamorphic call sites, Python attribute lookup, Rust `dyn`): if a tight loop does the same thing every element, a tagged union + switch or a tag-indexed table removes the indirect call (see pattern 1).

**Speed-of-light estimate** (R7): before optimizing, do the arithmetic — bytes to move ÷ memory bandwidth, or rows × work/row ÷ clock. If you're already near the bound, stop. If you're 100x off it, the waste is findable.

**When NOT / trap:** In JIT/managed runtimes the compiler may *already* devirtualize, inline, or vectorize, so hand-ported C tactics (manual SoA, hoisting, dispatch flattening) can be neutral or *negative* — always measure the specific runtime (R6), don't reason from an imagined machine. Non-pessimization is the free default; *actual* optimization past it must be justified by a profile, or it's just fake optimization wearing a lab coat. And never trade a real maintainability asset for cycles the workload doesn't need — most software runs in under 1% of a modern processor, and programmer cycles usually cost more than machine cycles off the hot path.

---

## 8. Explicit dispatch where dynamism is genuinely required — and nowhere else

**Idea:** When you truly need runtime-selected behavior (plugins, user-registered handlers, a strategy chosen at load time), use an explicit, visible mechanism — a function table, a strategy map, a small interface — deliberately, at that one seam. Don't make everything dynamic to serve the one place that needs it.

**Why it beats the default:** Blanket polymorphism pays the indirection tax (and the reasoning tax — more possible states) on *every* call to serve the *few* call sites that are genuinely open. An explicit dispatch table localizes the dynamism: you can *see* the set of handlers in one place, the coupling is named, and the 99% of code that isn't extensible stays direct and inspectable (R8: this is a granularity/coupling decision made on purpose). This is manual function-pointer dispatch used *only where dynamism is real* — the deliberate opposite of "make the base class virtual just in case."

**Go** — a registry map is the idiomatic open extension point:

```go
type Handler func(Event) error

var registry = map[string]Handler{} // the dynamism lives here, visibly

func Register(kind string, h Handler) { registry[kind] = h }

func Dispatch(e Event) error {
    h, ok := registry[e.Kind]
    if !ok {
        return fmt.Errorf("no handler for %q", e.Kind)
    }
    return h(e) // one indirect call, exactly where openness is required
}
```

**Rust** — trait objects are the right tool *specifically* for the open/heterogeneous set (contrast pattern 1's closed enum):

```rust
trait Plugin { fn run(&self, ctx: &mut Ctx); }

// open set: third parties implement Plugin; we hold them behind dyn on purpose
struct Engine { plugins: Vec<Box<dyn Plugin>> }

impl Engine {
    fn tick(&self, ctx: &mut Ctx) {
        for p in &self.plugins { p.run(ctx); } // dispatch confined to the plugin seam
    }
}
```

The choice between pattern 1 and pattern 8 is the whole point: **closed set that changes rarely → tagged union + switch; open set others extend → explicit dispatch table / trait objects.** Naming which one you're in is the design decision.

**When NOT / trap:** Don't reach for a dispatch table when the set of behaviors is closed and known at author time — that's a sum type + switch (pattern 1), and a map keyed on strings there just trades compile-time exhaustiveness for a runtime "unknown kind" error and a hash lookup you didn't need. Equally, don't build the registry, the plugin ABI, and the config-driven strategy loader for a customer who hasn't arrived (allergy #2, speculative abstraction): a `map[string]Handler` with two entries you control at compile time is a switch statement cosplaying as extensibility — pay for the dynamism when a second, genuinely external implementer actually exists (R1).

---

## 9. Functional core, imperative shell — and the replay/hot-reload loop it buys (R5)

**Idea:** Split the program into a *pure core* that maps `(state, input) -> new state` with no IO, and a thin *imperative shell* that does all the IO (reads input, draws, talks to the network) and calls the core. Because the core is a pure function of a recorded input stream, you can record inputs once and *replay them deterministically*, and you can swap the core's code without losing the running state.

**Why it beats the default:** This is the concrete machinery behind R5 (*protect the iteration loop*), which otherwise floats as a preference.
- **Determinism makes bugs reproducible.** Record the input stream to a file; replay reproduces the exact state that triggered a bug, every time.
- **The loop stays fast under change.** With state owned by the shell and logic in a reloadable core, you can hot-swap the core (recompiled logic) while the program keeps running on the same state — the edit/see-it cycle drops from a full restart to a keystroke.
- **Testing is cheap.** A pure `(state, input) -> state` core is testable without mocks; the untestable IO is quarantined in the shell.

**Shell/core split (Rust-ish):**

```rust
// core: pure, no IO — this is the reloadable, replayable unit
fn update(state: &State, input: Input) -> State { /* ... */ }

// shell: owns state and all IO; records inputs so the run can be replayed
loop {
    let input = read_input();       // or, in replay mode: pop the next recorded input
    recorder.push(&input);          // record for deterministic replay
    state = update(&state, input);  // one pure step
    render(&state);                 // IO lives only out here
}
```

**Elixir/Erlang** express the same split as a process: a pure `handle_event(state, msg) -> new_state` reduced over a message stream, with IO at the process boundary. **Clojure** and **Haskell** push it further — values in, values out, with `IO` quarantined at `main` — which is the immutability-first version of the same stance.

(Sources: Handmade Hero Day 23, "Looped Live Code Editing," for record/replay and live code reload; Gary Bernhardt, "Functional Core, Imperative Shell.")

**When NOT / trap:** The split costs indirection, and a core that must reach back into IO mid-computation (streaming, backpressure, interactive prompts) fights the model — then the honest shape is a smaller pure kernel with an explicit IO effect at the seam, not a forced-pure core doing hidden IO. Deterministic replay also requires *all* nondeterminism (wall-clock time, RNG, network ordering) to enter through the recorded input stream; miss one source and replay silently diverges, which is worse than no replay because you'll trust it.

---

## 10. Existence-based processing — membership *is* the state, instead of per-item flags

**Idea:** Represent an optional or boolean property of an item by its *membership in a set or table*, not by a flag or nullable field carried on every item. "Is this entity on fire?" becomes "is its id in the `on_fire` set?" — and the loop that processes burning entities iterates the small set, touching nothing else.

**Why it beats the default:** A per-item `bool is_active` (or nullable field) forces every pass to load and branch on every item, most of which fail the test. Moving the property into a set inverts that: the items that *have* the property are exactly the ones present, so you iterate only them and delete the branch. It is the same instinct as a database — a row's presence in a table *is* the fact — and it composes with SoA (pattern 2) and the ECS framing.

**Python:**

```python
# flag-per-item: every pass loads and branches on all entities
for e in entities:
    if e.on_fire:           # branch taken rarely, paid always
        apply_burn(e)

# existence-based: the set IS the state; iterate only what qualifies
on_fire = {e.id for e in entities if starts_burning(e)}
for eid in on_fire:         # no per-entity flag, no branch on the cold majority
    apply_burn(world[eid])
```

**SQL** is the everyday form: a row in `active_subscriptions` needs no `is_active` column — its presence is the truth, and a join processes exactly the active set.

(Source: Richard Fabian, *Data-Oriented Design*, "Existential Processing.")

**When NOT / trap:** A set/map has its own cost — hashing, pointer-chasing, cache misses — so for a property that is present on *most* items, a dense flag column (or an SoA byte-per-item) is faster and simpler than a huge set. Existence-based processing pays when the property is *sparse* and the qualifying pass is hot; measure the density before reaching for it (R6).

---

## A partner discipline: make invalid states crash loudly

Pattern 1's exhaustive `match` and Carmack's "understand every state your code can reach" share a practical partner: assert your invariants and *panic on the impossible* rather than limping past it. An `assert` at the top of a function, and an `InvalidCodePath`/`InvalidDefaultCase`-style abort in the branch that "can never happen," turn a silent wrong-state into a loud, located failure. It ports to every language — `assert`, `panic!`, `unreachable!()`, `throw new Error("unreachable")`, a `default:` that aborts — and it keeps the set of states you must reason about small by refusing to let the program continue in a state you didn't design for.

---

## Coda

None of these are laws. Each is a default with a stated boundary, and the discipline is naming the boundary out loud: *which dial am I turning, what work am I asking of the machine, where is the second occurrence, and can I explain every line if you delete it?* Keep the cheap habits everywhere — no cargo-cult lines, no speculative abstraction, no gratuitous waste. Reserve data-oriented optimization for measured hot paths. Let comprehensibility lead where change-rate and team size dominate. The number and the manual get the final vote (R7).
