# The Odin harness (lib/odin.nix, bench/callgrind.nix) under test: what
# buildOdinTool refuses before it builds anything, and how the test runner
# and the callgrind gate end on each case the fixtures in ./fixtures set up.
# The template tool's own checks show the happy path; this test keeps the
# failures failing, above all a leak, which odin test alone only warns about.
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
    ];
    evalFailures = lib.concatStringsSep "\n" evalFailures;
    measured = good.checks.fixture-bench.measure;
    passing = good.checks.fixture-tests;
    program = "${good.package}/bin/fixture";
    bench = tool + "/bench";
    inherit tool baselines;
    bash = "${pkgs.bash}/bin/bash";
    failing = "${pkgs.coreutils}/bin/false";
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

    # The test runner.
    expect "passing tests pass" 0 "2 tests passed" odin-tool-tests "$tool" ./tests out.pass
    expect "a leak fails although its assertion holds" fail "Memory failure" \
      odin-tool-tests "$tool" ./tests-leak out.leak
    expect "a failed assertion fails" fail "expected 1 + 1 to be 3" odin-tool-tests "$tool" ./tests-fail out.fail
    expect "a panic fails" fail "panics" odin-tool-tests "$tool" ./tests-panic out.panic
    expect "a package without tests fails" fail "no @(test) procedure" \
      odin-tool-tests "$tool" ./tests-none out.none
    expect "a test that exits early fails" fail "ended the process" \
      odin-tool-tests "$tool" ./tests-exit out.exit
    expect "a missing tests directory fails" fail "odin test" \
      odin-tool-tests "$tool" ./no-such-tests out.missing
    expect "the runner wants three arguments" 2 "usage" odin-tool-tests "$tool"
    expect "the tests check keeps the report" 0 '"total": 2' cat "$passing/report.json"

    # The callgrind measurement.
    expect "the bench check measures the fixture" 0 '^[1-9][0-9]*$' cat "$measured/instructions"
    expect "it writes a baseline to commit" 0 '"instructions": [1-9]' cat "$measured/baseline.json"
    expect "it keeps the top functions" 0 "PROGRAM TOTALS" cat "$measured/annotate.txt"
    expect "it keeps the program's output" 0 "^43$" cat "$measured/stdout"
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
    expect "the measurement wants four arguments" 2 "usage" callgrind-measure out.usage "$bench"

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
