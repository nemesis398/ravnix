# The Odin harness (lib/odin.nix, bench/callgrind.nix) under test: what
# buildOdinTool refuses before it builds anything, and how the test runner
# and the callgrind gate end on each case the fixtures in ./fixtures set up.
# The template tool's own checks show the happy path; this test keeps the
# failures failing, above all a leak, which odin test alone only warns about,
# and it shows that a count does not depend on the CPU glibc sees or on the
# start of the process.
{ pkgs, lib, ... }:
let
  odin = import ../../lib/odin.nix { inherit pkgs lib; };
  inherit (odin) callgrind;
  fixtures = ./fixtures;
  tool = fixtures + "/tool";

  # Evaluation: the problems buildOdinTool names, and that it refuses them.
  problemsOf = args: odin.toolProblems ({ name = "fixture"; } // args);
  names = text: args: lib.any (lib.hasInfix text) (problemsOf args);
  refuses = args: !(builtins.tryEval (odin.buildOdinTool ({ name = "fixture"; } // args))).success;
  expectProblem =
    what: text: args:
    lib.optional (!names text args)
      "${what}: expected a problem naming \"${text}\", got: ${lib.concatStringsSep "; " (problemsOf args)}"
    ++ lib.optional (!refuses args) "${what}: buildOdinTool did not refuse it";

  good = odin.buildOdinTool {
    name = "fixture";
    src = tool;
    benchArgs = [ "input.txt" ];
  };
  # The same tool, benched on its standard input.
  fromStdin = odin.buildOdinTool {
    name = "fixture";
    src = tool;
    benchStdin = "input.txt";
  };
  # A program whose count is mostly glibc's memmove and memset, and the same
  # program with more start-up work: four more libraries for the dynamic
  # loader to load and relocate before main.
  copier = odin.buildOdinTool {
    name = "copier";
    src = fixtures + "/copier";
  };
  copierWithLibraries = odin.buildOdinTool {
    name = "copier";
    src = fixtures + "/copier";
    odinFlags = [ "-extra-linker-flags:-Wl,--no-as-needed -lrt -ldl -lutil -lresolv" ];
  };

  evalFailures =
    lib.optional (problemsOf { src = tool; } != [ ])
      "the fixture tool should have no problem, got: ${lib.concatStringsSep "; " (problemsOf { src = tool; })}"
    ++ lib.optional (
      builtins.attrNames good.checks != [
        "fixture-bench"
        "fixture-tests"
      ]
    ) "expected the checks fixture-bench and fixture-tests, got: ${toString (builtins.attrNames good.checks)}"
    ++ lib.optional (good.name != "fixture") "the result does not carry the tool's name"
    ++ lib.optional (good.package.meta.mainProgram or null != "fixture") "the package's mainProgram is not the tool's name"
    ++ lib.optional (
      !(good.checks.fixture-bench.preferLocalBuild or false)
      || (good.checks.fixture-bench.allowSubstitutes or true)
    ) "the bench check may come from a remote builder or a cache"
    ++ lib.optional (
      !(good.checks.fixture-bench.measure.preferLocalBuild or false)
      || (good.checks.fixture-bench.measure.allowSubstitutes or true)
    ) "the measurement may come from a remote builder or a cache"
    ++ expectProblem "no tests directory" "no tests directory" {
      src = tool;
      tests = tool + "/no-such-tests";
    }
    ++ expectProblem "a tests directory without .odin files" "holds no .odin file" {
      src = fixtures + "/empty-tests";
    }
    ++ expectProblem "tests outside src" "subdirectory of src" {
      src = tool;
      tests = fixtures + "/no-source/tests";
    }
    ++ expectProblem "tests that are src itself" "subdirectory of src" {
      src = tool + "/tests";
      tests = tool + "/tests";
    }
    ++ expectProblem "a bench outside src" "subdirectory of src" {
      src = tool;
      bench = fixtures + "/empty-tests/bench";
    }
    ++ expectProblem "no bench directory" "no bench directory" {
      src = tool;
      bench = tool + "/no-such-bench";
    }
    ++ expectProblem "a bench stdin that bench/ does not hold" "benchStdin" {
      src = tool;
      benchStdin = "no-such-input.txt";
    }
    ++ expectProblem "no .odin file at the top of src" "no .odin file at its top" {
      src = fixtures + "/no-source";
    }
    ++ expectProblem "src that does not exist" "not a directory" {
      src = fixtures + "/no-such-tool";
    }
    ++ expectProblem "src given as a string" "must be paths" {
      src = toString tool;
    }
    ++ expectProblem "no src" "no src" { }
    ++ expectProblem "a misspelt argument" "unknown argument benchArg" {
      src = tool;
      benchArg = [ "input.txt" ];
    }
    ++ expectProblem "a name with capitals and a space" "lowercase" {
      name = "Bad Name";
      src = tool;
    }
    ++ expectProblem "a name the store refuses" "lowercase" {
      name = "-dash";
      src = tool;
    };

  # Build: each case runs the real scripts and expects an exit status and a
  # line of output.
  baselines = pkgs.runCommand "odin-harness-baselines" { } ''
    mkdir "$out"
    : > "$out/empty.json"
    printf '\n  \n' > "$out/blank.json"
    printf '{"instructions": ' > "$out/truncated.json"
    printf '{}\n' > "$out/no-key.json"
    printf '{"instructions": "1000"}\n' > "$out/string.json"
    printf '{"instructions": 0}\n' > "$out/zero.json"
    printf '{"instructions": -5}\n' > "$out/negative.json"
    printf '{"instructions": 10.5}\n' > "$out/fraction.json"
    printf '[1000]\n' > "$out/array.json"
    printf '{"instructions": 1000}\n{"instructions": 2000}\n' > "$out/two.json"
    printf '{"instructions": 1000}\n' > "$out/1000.json"
    printf '{"instructions": 900}\n' > "$out/900.json"
  '';
in
pkgs.runCommand "odin-harness"
  {
    nativeBuildInputs = [
      odin.testRunner
      callgrind.measure
      callgrind.compare
      pkgs.jq
      pkgs.binutils-unwrapped
    ];
    evalFailures = lib.concatStringsSep "\n" evalFailures;
    measured = good.checks.fixture-bench.measure;
    measuredFromStdin = fromStdin.checks.fixture-bench.measure;
    passing = good.checks.fixture-tests;
    program = "${good.package}/bin/fixture";
    copier = "${copier.package}/bin/copier";
    copierWithLibraries = "${copierWithLibraries.package}/bin/copier";
    valgrind = "${callgrind.valgrind}/bin/valgrind";
    bench = tool + "/bench";
    inherit tool baselines;
    bash = "${pkgs.bash}/bin/bash";
    failing = "${pkgs.coreutils}/bin/false";
    sleeping = "${pkgs.coreutils}/bin/sleep";
  }
  ''
    export HOME="$TMPDIR"
    status=0
    if [ -n "$evalFailures" ]; then
      printf '%s\n' "$evalFailures" | sed 's/^/FAIL /'
      status=1
    fi

    # expect NAME STATUS PATTERN COMMAND...: COMMAND exits with STATUS (0, or
    # any failure for "fail") and prints a line matching PATTERN.
    n=0
    expect() {
      local name=$1 want=$2 pattern=$3 got=0
      shift 3
      n=$((n + 1))
      "$@" >"log.$n" 2>&1 || got=$?
      if [ "$want" = fail ] && [ "$got" = 0 ]; then
        echo "FAIL $name: exited 0, expected a failure"
      elif [ "$want" != fail ] && [ "$got" != "$want" ]; then
        echo "FAIL $name: exited $got, expected $want"
      elif ! grep -q -- "$pattern" "log.$n"; then
        echo "FAIL $name: no line matching '$pattern'"
      else
        echo "ok   $name"
        return 0
      fi
      sed 's/^/     | /' "log.$n"
      status=1
    }
    # same NAME A B: the counts A and B are equal.
    same() {
      if [ "$2" = "$3" ]; then
        echo "ok   $1 ($2)"
      else
        echo "FAIL $1: $2 against $3"
        status=1
      fi
    }
    # differ NAME A B: the counts A and B differ.
    differ() {
      if [ "$2" != "$3" ]; then
        echo "ok   $1 ($2 against $3)"
      else
        echo "FAIL $1: both $2"
        status=1
      fi
    }
    # measure OUT [HOST_TUNABLES] PROGRAM: the count callgrind-measure takes
    # of PROGRAM with no input, starting from HOST_TUNABLES.
    measure() {
      CALLGRIND_MEASURE_HOST_TUNABLES="$2" callgrind-measure "$1" "$bench" - "$3" >/dev/null
      cat "$1/instructions"
    }
    # unpinned TUNABLES PROGRAM [TOGGLE]: one callgrind count without the
    # pin, from main or, with TOGGLE empty, of the whole process.
    unpinned() {
      local out toggle=("--toggle-collect=''${3-main}")
      out="$(mktemp -p "$TMPDIR")"
      [ -n "''${3-main}" ] || toggle=()
      env -i GLIBC_TUNABLES="$1" "$valgrind" --tool=callgrind --vgdb=no -q "''${toggle[@]}" \
        --callgrind-out-file="$out" -- "$2" >/dev/null
      awk '$1 == "totals:" { print $2 }' "$out"
    }

    # The test runner.
    expect "passing tests pass" 0 "2 tests passed" odin-tool-tests fixture "$tool" ./tests out.pass
    expect "a leak fails although its assertion holds" fail "Memory failure" \
      odin-tool-tests fixture "$tool" ./tests-leak out.leak
    expect "a failed assertion fails" fail "expected 1 + 1 to be 3" odin-tool-tests fixture "$tool" ./tests-fail out.fail
    expect "a panic fails" fail "Index 3 is out of range 0..<3" odin-tool-tests fixture "$tool" ./tests-panic out.panic
    expect "a package without tests fails" fail "no @(test) procedure" \
      odin-tool-tests fixture "$tool" ./tests-none out.none
    expect "a test that exits early fails" fail "ended the process" \
      odin-tool-tests fixture "$tool" ./tests-exit out.exit
    expect "a missing tests directory fails" fail "was not found" \
      odin-tool-tests fixture "$tool" ./no-such-tests out.missing
    expect "a test that hangs fails at the time limit and names the tool" fail \
      "fixture: odin test ./tests-sleep did not finish within 10 s" \
      env ODIN_TOOL_TESTS_TIMEOUT=10 odin-tool-tests fixture "$tool" ./tests-sleep out.sleep
    expect "the runner wants four arguments" 2 "usage" odin-tool-tests fixture "$tool" ./tests
    expect "the tests check keeps the report" 0 '"total": 2' cat "$passing/report.json"

    # The callgrind measurement.
    expect "the bench check measures the fixture" 0 '^[1-9][0-9]*$' cat "$measured/instructions"
    expect "it writes a baseline to commit" 0 '"instructions": [1-9]' cat "$measured/baseline.json"
    expect "it keeps the top functions" 0 "PROGRAM TOTALS" cat "$measured/annotate.txt"
    expect "it keeps the program's output" 0 "^43$" cat "$measured/stdout"
    expect "it keeps the glibc pin it ran with" 0 "^glibc.cpu.hwcaps=-AVX,-AVX2," cat "$measured/glibc-tunables"
    expect "a bench reads its stdin file" 0 "^43$" cat "$measuredFromStdin/stdout"
    expect "a program that fails fails the bench" fail "false exited 1 on run 1" \
      callgrind-measure out.false "$bench" - "$failing"
    expect "a missing bench input fails the bench" fail "cannot read no-such-input.txt" \
      callgrind-measure out.noinput "$bench" - "$program" no-such-input.txt
    expect "a missing stdin file fails the bench" fail "no-such-stdin" \
      callgrind-measure out.nostdin "$bench" no-such-stdin "$program" input.txt
    # A program that does more work on its second run than on its first.
    marker="$TMPDIR/second-run"
    expect "a count that differs between two runs fails" fail "not deterministic" \
      callgrind-measure out.drift "$bench" - "$bash" -c \
      'if [ -e "$1" ]; then i=0; while [ $i -lt 500 ]; do i=$((i + 1)); done; else : >"$1"; fi' \
      drift "$marker"
    expect "a program that hangs fails at the time limit and names it" fail "sleep did not finish within 5 s on run 1" \
      env CALLGRIND_MEASURE_TIMEOUT=5 callgrind-measure out.slow "$bench" - "$sleeping" 3600
    cp "$copier" stripped
    chmod u+w stripped
    strip --strip-all stripped
    expect "a program without a main symbol fails" fail "never ran a function named main" \
      callgrind-measure out.stripped "$bench" - ./stripped
    printf '#!/bin/sh\n' >script
    chmod +x script
    expect "a program without an ELF interpreter fails" fail "no ELF interpreter" \
      callgrind-measure out.script "$bench" - ./script
    expect "a file that is no program fails" fail "is not an executable file" \
      callgrind-measure out.text "$bench" - "$bench/input.txt"
    expect "the measurement wants four arguments" 2 "usage" callgrind-measure out.usage "$bench"

    # The start of the process is not in the count: four more libraries to
    # load cost instructions before main, and none after.
    pin="$(cat "$measured/glibc-tunables")"
    differ "more start-up work costs instructions in the whole process" \
      "$(unpinned "$pin" "$copier" "")" "$(unpinned "$pin" "$copierWithLibraries" "")"
    plain="$(measure out.copier "" "$copier")"
    same "and none in the count from main" "$plain" "$(measure out.libraries "" "$copierWithLibraries")"

    # The CPU glibc sees is not in the count. Without the pin, another cache
    # layout changes how the copier's 4 MiB copies run, on any host.
    other_cache='glibc.cpu.x86_data_cache_size=0x10000:glibc.cpu.x86_shared_cache_size=0x2000000:glibc.cpu.x86_non_temporal_threshold=0x800000'
    differ "without the pin, another cache layout changes the count" \
      "$(unpinned "" "$copier")" "$(unpinned "$other_cache" "$copier")"
    echo "     (without the pin, AVX, AVX2, ERMS and FSRM off: $(unpinned "" "$copier") against $(unpinned 'glibc.cpu.hwcaps=-AVX,-AVX2,-ERMS,-FSRM' "$copier"))"
    same "with the pin, a host without AVX, AVX2, ERMS and FSRM counts the same" \
      "$plain" "$(measure out.v2 'glibc.cpu.hwcaps=-AVX,-AVX2,-ERMS,-FSRM' "$copier")"
    same "with the pin, a host with other preferred bits counts the same" \
      "$plain" "$(measure out.preferred 'glibc.cpu.hwcaps=-Fast_Unaligned_Copy,-Fast_Unaligned_Load,-Fast_Rep_String,-Prefer_PMINUB_for_stringop' "$copier")"
    same "with the pin, a host with another cache layout counts the same" \
      "$plain" "$(measure out.cache "$other_cache" "$copier")"

    # The check that the pin holds, on glibc's own report of its state.
    help=out.copier/glibc-help diagnostics=out.copier/glibc-diagnostics
    expect "the pin holds here" 0 "the glibc pin holds" callgrind-measure --check-glibc-state "$help" "$diagnostics"
    { cat "$diagnostics"; echo "x86.cpu_features.preferred.Prefer_Something_New=0x1"; } >new-bit
    expect "a preferred bit the pin does not clear fails" fail "add -Prefer_Something_New to hwcapsPin" \
      callgrind-measure --check-glibc-state "$help" new-bit
    sed 's/^x86\.cpu_features\.non_temporal_threshold=.*/x86.cpu_features.non_temporal_threshold=0x400000/' \
      "$diagnostics" >other-threshold
    expect "a threshold the pin did not set fails" fail "non_temporal_threshold=0x100000, the value the pin sets" \
      callgrind-measure --check-glibc-state "$help" other-threshold
    grep -v '^x86\.cpu_features\.preferred\.' "$diagnostics" >no-bits
    expect "diagnostics without preferred bits fail" fail "no preferred bit" \
      callgrind-measure --check-glibc-state "$help" no-bits
    sed 's/^\( *x86-64-v3\)$/\1 (supported, searched)/' "$help" >v3-help
    expect "a feature above x86-64-v2 left on fails" fail "x86-64-v3" \
      callgrind-measure --check-glibc-state v3-help "$diagnostics"
    sed 's/^\( *x86-64-v2\) (supported, searched)$/\1/' "$help" >v1-help
    expect "a CPU below x86-64-v2 fails" fail "as x86-64-v2" \
      callgrind-measure --check-glibc-state v1-help "$diagnostics"
    expect "the check wants two files" 2 "usage" callgrind-measure --check-glibc-state "$help"

    # The comparison with the baseline.
    b="$baselines"
    expect "the same count passes" 0 "+0.00 %" callgrind-compare fixture 1000 "$b/1000.json"
    expect "exactly +2 % passes" 0 "+2.00 %" callgrind-compare fixture 1020 "$b/1000.json"
    expect "+2.1 % fails" fail "above the limit of +2 %" callgrind-compare fixture 1021 "$b/1000.json"
    expect "a baseline lowered by 10 % fails" fail "+11.11 %" \
      callgrind-compare fixture 1000 "$b/900.json"
    expect "a lower count passes and says so" 0 "below the baseline" \
      callgrind-compare fixture 900 "$b/1000.json"
    expect "a failure says how to record a baseline" fail "fixture-bench.measure" \
      callgrind-compare fixture 2000 "$b/1000.json"
    expect "no baseline file fails" fail "no bench/baseline.json" \
      callgrind-compare fixture 1000 "$b/no-such.json"
    expect "an empty baseline fails" fail "is empty" callgrind-compare fixture 1000 "$b/empty.json"
    expect "a blank baseline fails" fail "no positive whole number" \
      callgrind-compare fixture 1000 "$b/blank.json"
    expect "truncated JSON fails" fail "not valid JSON" callgrind-compare fixture 1000 "$b/truncated.json"
    for case in no-key string zero negative fraction array two; do
      expect "a baseline that is $case fails" fail "no positive whole number" \
        callgrind-compare fixture 1000 "$b/$case.json"
    done
    expect "a measured count that is no number fails" fail "not a positive whole number" \
      callgrind-compare fixture 12abc "$b/1000.json"
    expect "the comparison wants three arguments" 2 "usage" callgrind-compare fixture 1000

    [ "$status" = 0 ] || exit 1
    touch "$out"
  ''
