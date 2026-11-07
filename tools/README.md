# tools

The tools ravnix writes itself, in Odin. Each directory here is one tool,
and the flake finds it: adding a tool never touches `flake.nix`.

| Path | Holds |
| --- | --- |
| `NAME/default.nix` | the tool's build: `buildOdinTool { name = "NAME"; ... }` |
| `NAME/*.odin` | the tool's package, at the top of its directory |
| `NAME/tests/` | an Odin package of `@(test)` procedures that imports the tool's package (`import tool ".."`) |
| `NAME/bench/` | the bench input, and `baseline.json` |
| `NAME/README.md` | what the tool does, and every finding its tests turned up that is not fixed |

Every `tools/NAME/` becomes the package `NAME` and the checks `NAME-tests`
and `NAME-bench` (`lib/discover-tools.nix`). A directory whose name starts
with `_` is built and checked under the name without it, but is no
package: that is `_template`, with the checks `template-tests` and
`template-bench`. A directory without `default.nix`, a `.nix` file directly
in `tools/`, a `default.nix` that names its tool differently from its
directory, a symlink in `tools/`, and two directories that give one name
(`_x` and `x`) are evaluation errors.

## Start a tool

```sh
cp -r tools/_template tools/NAME
```

Then, in `tools/NAME`: set `name = "NAME"` in `default.nix`; rename
`package template` in `main.odin` and the import in `tests/main_test.odin`
(an Odin package name has no dashes, so `my-tool` is `package my_tool`);
replace the counting with the tool's work and the tests with the tool's
own, written first and watched failing (AGENTS.md, rule 5); give the bench
an input that exercises the tool; and record its first baseline (below).

`buildOdinTool` (`lib/odin.nix`) takes:

| Argument | Default | Is |
| --- | --- | --- |
| `name` | | the package, its program and the checks' prefix: lowercase letters, digits and dashes |
| `src` | | the tool directory, as a path (`./.`) |
| `tests` | `src + "/tests"` | the test package, inside `src` |
| `bench` | `src + "/bench"` | the bench input and `baseline.json`, inside `src` |
| `benchArgs` | `[ ]` | the arguments of the bench run |
| `benchStdin` | `null` | a file in `bench/` that the bench run reads on standard input |
| `odinFlags` | `[ ]` | more flags for `odin build` and `odin test` |
| `meta` | `{ }` | merged into the package's `meta` |

A tool with no tests directory, a tests directory without an `.odin` file,
no bench directory, no `.odin` file at the top of `src`, or an argument
that `buildOdinTool` does not know (a misspelt `benchArg`) is refused when
the flake is evaluated, with the reason.

## The toolchain

The compiler is `odin` from the flake's nixpkgs, and valgrind comes from the
same nixpkgs, so `flake.lock` pins both: Odin `dev-2026-10` and valgrind
3.27.1 when this was written. Every build and test run passes
`-microarch:x86-64-v2`, which is what this Odin picks by default, so the
binary never depends on the CPU of the machine that builds it, and `-vet`,
which refuses unused variables and imports and shadowing. The package is
built with `-o:speed`.

The compiler stays at build time. A binary keeps the paths of the core
library files it was built from, for the location a panic or a failed
assertion prints, and each path is a store reference to `odin`, which would
pull the compiler and its LLVM into every host, about 2.3 GiB. The package
build overwrites the hash in those paths with `remove-references-to`, which
leaves the code and the bench count as they were, and it lists the
toolchain in `disallowedRequisites`, so a package that still reaches the
compiler fails to build. The package then needs only glibc at run time.

## Tests

`NAME-tests` runs `odin test` on `tests/` with:

- `ODIN_TEST_RANDOM_SEED=1`, so a failure reproduces;
- `ODIN_TEST_TRACK_MEMORY=true` and `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`. A
  test that leaks or frees badly fails even when its assertions hold. With
  tracking alone, the runner only warns and exits 0, which is why the second
  define is there.

The check also fails when the runner reports no test at all: `odin test`
exits 0 on a package without a `@(test)` procedure, and when a test ends the
process (`os.exit`) before the runner reports. A run that has not finished
after 600 seconds fails with the tool's name, so a test that hangs cannot
stall the gate; `ODIN_TOOL_TESTS_TIMEOUT` sets another limit. The runner's
JSON report is the check's output, `report.json`.

The tests run with the tool directory as their working directory, read-only
in the build. Load fixtures with `#load("../testdata/x")` or build their path
from `#directory`, so the tests pass from any directory, and write temporary
files under `TMPDIR`. To run them outside a build, with the same compiler:

```sh
nix build .#checks.x86_64-linux.NAME-tests
nix shell --inputs-from . nixpkgs#odin --command odin test tools/NAME/tests \
  -define:ODIN_TEST_RANDOM_SEED=1 -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true \
  -out:"${TMPDIR:-/tmp}/NAME-tests"
```

## Bench

`NAME-bench` runs the package's program under valgrind's callgrind, with
`benchArgs` and `benchStdin`, in a copy of `bench/` without `baseline.json`
as its working directory, and in a fixed environment: `HOME`, `PATH`,
`LC_ALL`, `TZ`, `TMPDIR` and `GLIBC_TUNABLES` set to the same values every
time and nothing else, so nothing of the build reaches the program. It
counts the instructions executed from the program's `main` on, inclusive,
and in every thread the program starts, and fails when the count is more
than 2 % above `bench/baseline.json`, which holds one positive whole number:

```json
{
  "instructions": 271731
}
```

The count starts at `main`, the entry point Odin generates (at `-o:speed`
the tool's own `main` procedure is inlined into it), so the start of the
process stays out: the dynamic loader, glibc's own start and its CPU
detection, about 180 000 instructions that would dilute a regression in a
small tool. Odin's own start, which `main` runs first (the runtime's setup
and every `@(init)` procedure), is in the count. A program whose symbol
table has been stripped has no `main` for callgrind to find, and fails.

A thread does not run under `main`: it starts in glibc's `start_thread`,
which `core:thread` reaches through `pthread_create`, and callgrind starts
every thread with counting off. The bench therefore also counts from
`start_thread` on. Without it, a worker thread's work was missing: in the
harness's threaded fixture, a million rounds in the worker added 484
instructions to the count from `main`. With it, ten times the rounds give
ten times the worker's share of the count. Valgrind runs one thread at a
time; the bench uses its fair scheduler, which hands the running slot from
thread to thread in order, because with the default one a thread waiting
for its worker woke once more in 2 of 27 runs.

### The same count on every host

glibc picks its string and memory functions (`memcpy`, `memset`, `strlen`)
by the CPU, and valgrind shows glibc one of a few synthetic CPUs, chosen by
what the host can do. Without a pin, the harness's memcpy-heavy fixture
counted 4 % less with AVX, AVX2, ERMS and FSRM masked than without, and
another cache layout alone changed its count almost sevenfold. The bench
therefore pins glibc (`hwcapsPin` and `cachePin` in `bench/callgrind.nix`):
it turns off every CPU feature above x86-64-v2, the level the tools are
built for, clears every preferred bit (glibc 2.44 clears one on `-` and
ignores `+`, so clearing all of them is the only state every host can
reach), and fixes the cache sizes and thresholds. With the pin, the fixture
counts the same under each of those host differences.

Before it measures, the bench asks the program's own glibc, under the pin
and under valgrind, which x86-64 level it supports and which preferred bits
and cache values it uses, and fails when that is not the pinned state: a
host below x86-64-v2, a feature the pin leaves on, or a preferred bit that a
newer glibc sets and the pin does not clear yet. An incomplete pin then
fails with the bit to add, instead of a count that differs from another
host's. The pin makes glibc use its plain SSE2 code, so a count measures
the tool's work, not what it costs on the fastest CPU.

The pin and its check cover glibc and nothing else. Code that asks the CPU
itself which path to take is neither pinned nor checked: Odin's
`core:crypto` picks its ChaCha20, AES and SHA-256 code at run time through
`core:sys/info`, by AVX2, AES-NI and the SHA extensions, and other `core`
packages may do the same. A tool whose hot path does that counts
differently on hosts whose valgrind CPUs differ in those features, and the
bench does not notice. Such a tool must say so in its own `README.md`. The
proof across hosts is a run of `template-bench` and `odin-harness` on the
server host, muninn, once it exists.

### What fails, and what does not

The program runs twice, each time in a fresh copy at the same path, and the
two counts must be equal: a bench that reads the clock, draws a random seed
or depends on addresses fails with "not deterministic". A program that
exits with a status other than 0 fails the bench, and so does a run that
has not finished after 600 seconds (`CALLGRIND_MEASURE_TIMEOUT` sets another
limit). When the check fails, its log shows the top functions, inclusive;
the full `callgrind_annotate` output and the `callgrind.out` file for
KCachegrind are in the measurement's output.

Only a rise fails. A count more than 2 % below the baseline passes, and the
build log says to record it, but that log appears once: the result is
cached, and the baseline keeps its slack until a person records the new
count. A later rise back up to the old baseline then passes. There is no
ratchet that fails on a gain.

Neither the measurement nor the check is built on a remote builder or taken
from a cache, since the check of glibc's state holds for the machine it ran
on.

### Recording a baseline

A baseline changes only by this command, run by a person, never by the
check itself. It measures without comparing and writes the file to commit:

```sh
nix build .#checks.x86_64-linux.NAME-bench.measure
install -m 644 result/baseline.json tools/DIR/bench/baseline.json
rm result
```

`DIR` is the tool's directory, `_template` for the template. Commit the new
baseline with the change that moved it, and say in the body why the count
rose. A missing, empty or malformed `baseline.json` fails the bench check
with this command in its message; the measurement still runs, so a new tool
records its first baseline the same way.

## Known gaps

Findings that are not fixed, so nobody mistakes them for covered.

- The glibc pin is shown complete only for the host differences the
  harness can stand in for on one machine: CPU features and preferred bits
  masked through `GLIBC_TUNABLES`, and other cache sizes. The synthetic
  CPUs that valgrind shows on a host without AVX2 are not measured
  directly; the check of glibc's state catches a difference in glibc there,
  and nothing catches one outside it.
- Run-time CPU dispatch outside glibc, as in `core:crypto`, is neither
  pinned nor checked (see "The same count on every host").
- A bump of nixpkgs moves Odin, glibc and valgrind, and with them every
  count. Record the baselines again in the commit that bumps `flake.lock`.
- The bench runs with `PATH` set to nothing usable, so a tool that starts
  other programs cannot be benched as it is; such a tool needs a
  `benchPath` argument that does not exist yet.
- A threaded tool's count is the sum over its threads, each from its
  start. Valgrind runs them one at a time, and the fair scheduler kept the
  harness's fixture steady in 132 runs, but threads that race for a lock or
  poll in a loop can still take another order and count differently. The
  double run turns that into a failure, not a wrong number. A thread made
  without `pthread_create` (a raw `clone`) does not pass through
  `start_thread`, and its work is not counted.
- The baselines hold only the count, not the Odin, glibc and valgrind
  versions they were taken with; a stale baseline is noticed only through
  the counts.
