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
directory, and two directories that give one name (`_x` and `x`) are
evaluation errors.

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
no bench directory, or no `.odin` file at the top of `src` is refused when
the flake is evaluated, with the reason.

## The toolchain

The compiler is `odin` from the flake's nixpkgs, and valgrind comes from the
same nixpkgs, so `flake.lock` pins both: Odin `dev-2026-10` and valgrind
3.27.1 when this was written. Every build and test run passes
`-microarch:x86-64-v2`, which is what this Odin picks by default, so the
binary never depends on the CPU of the machine that builds it, and `-vet`,
which refuses unused variables and imports and shadowing. The package is
built with `-o:speed`.

## Tests

`NAME-tests` runs `odin test` on `tests/` with:

- `ODIN_TEST_RANDOM_SEED=1`, so a failure reproduces;
- `ODIN_TEST_TRACK_MEMORY=true` and `ODIN_TEST_FAIL_ON_BAD_MEMORY=true`. A
  test that leaks or frees badly fails even when its assertions hold. With
  tracking alone, the runner only warns and exits 0, which is why the second
  define is there.

The check also fails when the runner reports no test at all: `odin test`
exits 0 on a package without a `@(test)` procedure, and when a test ends the
process (`os.exit`) before the runner reports. The runner's JSON report is
the check's output, `report.json`.

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
`LC_ALL`, `TZ` and `TMPDIR` set to the same values every time and nothing
else, so nothing of the build reaches the program. It counts the
instructions the program executed, and fails when the count is more than
2 % above `bench/baseline.json`, which holds one positive whole number:

```json
{
  "instructions": 456200
}
```

The program runs twice, each time in a fresh copy at the same path, and the
two counts must be equal: a bench that reads the clock, draws a random seed
or depends on addresses fails with "not deterministic". A program that
exits with a status other than 0 fails the bench too. When the count falls
by more than 2 %, the check passes and says so: record the new count, so a
later rise cannot hide in the gain. When the check fails, its log shows the
top functions, inclusive; the full `callgrind_annotate` output and the
`callgrind.out` file for KCachegrind are in the measurement's output.

The count includes the start of the process, about 180 000 instructions in
the dynamic loader before the tool runs. Give the bench enough input that
the tool's own work outweighs it, or a regression in the tool is diluted:
the template's `main` is 60 % of its count.

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

- A count is valid for one machine and one pin. glibc picks its string and
  memory functions by CPU (the template runs `__memset_avx2_unaligned_erms`)
  and reads the CPU's cache layout at start, so a different CPU can give a
  different count for the same binary; so can a bump of nixpkgs, which moves
  Odin, glibc and valgrind. The measurement is therefore built on the
  machine that runs the check, never on a remote builder or taken from a
  cache. Record the baselines again in the commit that bumps `flake.lock`,
  and on the machine that runs the gate.
- The count also depends a little on the working directory and `TMPDIR` the
  program sees: in the build those are fixed, and outside it the template
  counted 14 instructions more (0.003 %).
- The bench runs with `PATH` set to nothing usable, so a tool that starts
  other programs cannot be benched as it is; such a tool needs a
  `benchPath` argument that does not exist yet.
- Valgrind runs a program's threads one at a time. A threaded tool's count
  is then the sum over its threads and may differ between runs, which the
  double run turns into a failure, not a wrong number.
- The baselines hold only the count, not the Odin, glibc and valgrind
  versions they were taken with; a stale baseline is noticed only through
  the counts.
