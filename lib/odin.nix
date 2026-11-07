# The Odin toolchain of ravnix. buildOdinTool turns one tool directory into
# its package and two checks:
#
#   buildOdinTool {
#     name;                    # the package, its program, and the checks' prefix
#     src;                     # the tool directory, a path: the package's .odin files at its top
#     tests ? src + "/tests";  # an Odin package of @(test) procedures, inside src
#     bench ? src + "/bench";  # the bench input and baseline.json, inside src
#     benchArgs ? [ ];         # the arguments of the bench run, in a copy of bench/
#     benchStdin ? null;       # a file in bench/ that the bench run reads on stdin
#     odinFlags ? [ ];         # more flags for odin build and odin test
#     meta ? { };
#   }
#   => { name; package; checks = { "NAME-tests"; "NAME-bench"; }; }
#
# NAME-tests runs odin test with a fixed seed and fails on a leak or a bad
# free; NAME-bench is the callgrind gate of bench/callgrind.nix on the
# package's program. The compiler is the flake's nixpkgs odin, pinned by
# flake.lock (dev-2026-10 when this was written). tools/README.md has the
# conventions, and lib/discover-tools.nix finds the tools.
{ pkgs, lib }:
let
  inherit (pkgs) odin jq;
  callgrind = import ../bench/callgrind.nix { inherit pkgs lib; };

  # The flags of every build and test run. -microarch pins what Odin picks
  # without it (x86-64-v2 for dev-2026-10, checked by comparing the
  # binaries), so a build never depends on the machine that runs it. -vet
  # refuses unused variables and imports, and shadowing.
  commonFlags = [
    "-microarch:x86-64-v2"
    "-vet"
  ];

  # The defines of every test run. The seed is fixed, so a failure
  # reproduces; 0 would draw a new one each run. A leak or a bad free fails
  # the test: with memory tracking alone, the runner only warns about them
  # and still exits 0, so ODIN_TEST_FAIL_ON_BAD_MEMORY is what makes the
  # leak count.
  testDefines = [
    "-define:ODIN_TEST_RANDOM_SEED=1"
    "-define:ODIN_TEST_TRACK_MEMORY=true"
    "-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true"
    "-define:ODIN_TEST_FANCY=false"
  ];

  # How long a test run may take before the check fails, in seconds; the
  # environment variable ODIN_TOOL_TESTS_TIMEOUT overrides it.
  testTimeoutSeconds = 600;

  # odin-tool-tests NAME TOOL_DIR TESTS OUT [ODIN_FLAG...]: runs the tests of
  # the tool NAME in TOOL_DIR/TESTS with TOOL_DIR as the working directory,
  # and keeps the runner's JSON report in OUT. odin test exits 0 when it
  # finds no test, and when a test ends the process before the runner
  # reports, so the report must exist and count at least one test.
  testRunner = pkgs.writeShellApplication {
    name = "odin-tool-tests";
    runtimeInputs = [
      odin
      jq
      pkgs.coreutils
    ];
    text = ''
      if (($# < 4)); then
        echo "usage: odin-tool-tests NAME TOOL_DIR TESTS OUT [ODIN_FLAG...]" >&2
        exit 2
      fi
      name=$1 tool=$2 tests=$3 out=$4
      shift 4
      fail() {
        printf 'odin-tool-tests: %s: %s\n' "$name" "$*" >&2
        exit 1
      }
      timeout_s="''${ODIN_TOOL_TESTS_TIMEOUT:-${toString testTimeoutSeconds}}"
      [[ "$timeout_s" =~ ^[1-9][0-9]*$ ]] || fail "ODIN_TOOL_TESTS_TIMEOUT is '$timeout_s', not a number of seconds"
      mkdir -p "$out"
      report="$(realpath -- "$out")/report.json"
      scratch="$(mktemp -d)"
      trap 'rm -rf -- "$scratch"' EXIT
      cd "$tool"
      status=0
      # Without --foreground, timeout signals its whole process group, so the
      # test program that odin test starts ends with it.
      timeout --kill-after=10 "$timeout_s" odin test "$tests" -out:"$scratch/tests" \
        ${lib.escapeShellArgs testDefines} -define:ODIN_TEST_JSON_REPORT="$report" "$@" ||
        status=$?
      if ((status == 124 || status == 137)); then
        fail "odin test $tests did not finish within $timeout_s s, so a test hangs (ODIN_TOOL_TESTS_TIMEOUT sets the limit)"
      fi
      ((status == 0)) || fail "odin test $tests failed (exit $status)"
      [[ -s "$report" ]] ||
        fail "odin test $tests wrote no report: $tests holds no @(test) procedure, or a test ended the process (os.exit) before the runner reported"
      total="$(jq -r .total "$report")"
      success="$(jq -r .success "$report")"
      ((total > 0)) || fail "odin test $tests ran no test: $tests holds no @(test) procedure"
      ((success == total)) || fail "odin test $tests: $success of $total tests passed"
      echo "odin-tool-tests: $name: $total tests passed"
    '';
  };

  isDir = path: builtins.pathExists path && builtins.readFileType path == "directory";
  odinFilesIn =
    dir: lib.attrNames (lib.filterAttrs (n: t: t == "regular" && lib.hasSuffix ".odin" n) (builtins.readDir dir));

  # The arguments of buildOdinTool, and the defaults of the optional ones,
  # filled in once, so the checks below and the build see the same paths.
  arguments = [
    "name"
    "src"
    "tests"
    "bench"
    "benchArgs"
    "benchStdin"
    "odinFlags"
    "meta"
  ];
  withDefaults =
    args:
    {
      tests = args.src + "/tests";
      bench = args.src + "/bench";
      benchArgs = [ ];
      benchStdin = null;
      odinFlags = [ ];
      meta = { };
    }
    // args;

  # The problems that keep a tool from being built, as sentences; an empty
  # list when there is none. buildOdinTool throws them; a missing or broken
  # baseline is no such problem, since `measure` must still run to record
  # one, so the bench check fails on it when it is built.
  toolProblems =
    args:
    let
      unknown = lib.subtractLists arguments (lib.attrNames args);
      missing = lib.filter (n: !(args ? ${n})) [
        "name"
        "src"
      ];
    in
    if unknown != [ ] || missing != [ ] then
      lib.optional (unknown != [ ]) "unknown argument ${lib.concatStringsSep ", " unknown}; buildOdinTool takes ${lib.concatStringsSep ", " arguments}"
      ++ lib.optional (missing != [ ]) "no ${lib.concatStringsSep " and no " missing}, which buildOdinTool needs"
    else
      problemsOf (withDefaults args);

  problemsOf =
    {
      name,
      src,
      tests,
      bench,
      benchStdin,
      ...
    }:
    let
      rel = path: if lib.path.hasPrefix src path then lib.path.removePrefix src path else toString path;
      inside =
        what: why: path:
        lib.optional (!lib.path.hasPrefix src path || path == src) "${what} must be a subdirectory of src, ${why}";
    in
    lib.optional (builtins.match "[a-z][a-z0-9-]*" name == null)
      "the name \"${name}\" is not lowercase letters, digits and dashes, starting with a letter"
    ++ (
      if !builtins.isPath src || !builtins.isPath tests || !builtins.isPath bench then
        [ "src, tests and bench must be paths, such as ./. and ./tests, not strings" ]
      else if !isDir src then
        [ "src ${toString src} is not a directory" ]
      else
        lib.optional (odinFilesIn src == [ ]) "src holds no .odin file at its top, where the tool's package goes"
        ++ (
          if !isDir tests then
            [ "no tests directory ${rel tests}; every tool has tests (AGENTS.md, rule 5)" ]
          else
            inside "tests" "since the tests import the tool's package by a relative path" tests
            ++ lib.optional (odinFilesIn tests == [ ]) "the tests directory ${rel tests} holds no .odin file"
        )
        ++ (
          if !isDir bench then
            [
              "no bench directory ${rel bench}; every tool has a callgrind bench: its input, and bench/baseline.json (tools/README.md)"
            ]
          else
            inside "bench" "so that a tool is one directory" bench
            ++ lib.optional (
              benchStdin != null && !builtins.pathExists (bench + "/${benchStdin}")
            ) "benchStdin names ${benchStdin}, which ${rel bench} does not hold"
        )
    );

  buildOdinTool =
    args:
    let
      problems = toolProblems args;
      inherit (withDefaults args)
        name
        src
        tests
        bench
        benchArgs
        benchStdin
        odinFlags
        meta
        ;
      flags = lib.escapeShellArgs (commonFlags ++ odinFlags);
      notCode = lib.fileset.unions [
        (lib.fileset.maybeMissing (src + "/default.nix"))
        (lib.fileset.maybeMissing (src + "/README.md"))
      ];
      # The package is built from the tool's code alone, so editing a test,
      # the bench or the README does not rebuild it; the tests see everything
      # but the bench.
      packageSrc = lib.fileset.toSource {
        root = src;
        fileset = lib.fileset.difference src (
          lib.fileset.unions [
            tests
            bench
            notCode
          ]
        );
      };
      testSrc = lib.fileset.toSource {
        root = src;
        fileset = lib.fileset.difference src (lib.fileset.unions [ bench notCode ]);
      };

      package = pkgs.stdenvNoCC.mkDerivation {
        inherit name;
        src = packageSrc;
        nativeBuildInputs = [ odin ];
        buildPhase = ''
          runHook preBuild
          export HOME="$TMPDIR"
          odin build . -out:${lib.escapeShellArg name} -o:speed ${flags}
          runHook postBuild
        '';
        installPhase = ''
          runHook preInstall
          install -Dm755 ${lib.escapeShellArg name} "$out/bin/${name}"
          runHook postInstall
        '';
        meta = {
          mainProgram = name;
          platforms = [ "x86_64-linux" ];
        }
        // meta;
      };

      testsCheck =
        pkgs.runCommand "${name}-tests"
          {
            nativeBuildInputs = [ testRunner ];
          }
          ''
            export HOME="$TMPDIR"
            odin-tool-tests ${lib.escapeShellArg name} ${testSrc} ${lib.escapeShellArg (lib.path.removePrefix src tests)} "$out" ${flags}
          '';

      benchCheck = callgrind.mkBench {
        inherit name bench;
        program = lib.getExe package;
        args = benchArgs;
        stdin = benchStdin;
      };
    in
    if problems != [ ] then
      throw "buildOdinTool ${name}: ${lib.concatStringsSep "; " problems}"
    else
      {
        inherit name package;
        checks = {
          "${name}-tests" = testsCheck;
          "${name}-bench" = benchCheck;
        };
      };
in
{
  inherit
    odin
    callgrind
    testRunner
    testTimeoutSeconds
    toolProblems
    buildOdinTool
    ;
}
