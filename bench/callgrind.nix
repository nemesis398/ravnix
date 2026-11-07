# The callgrind gate: runs a program on a fixed input under valgrind's
# callgrind, counts the instructions it executes from its main function on,
# and fails when that count is more than limitPercent above a committed
# baseline. An instruction count does not move with CPU load or a busy
# machine, so it can gate a push where wall clock cannot; valgrind and glibc
# come from the flake's nixpkgs, so a baseline stays valid until that pin
# moves.
#
#   mkBench { name; program; bench; args ? [ ]; stdin ? null; }
#
# returns the check NAME-bench. Its passthru `measure` measures without
# comparing and writes the baseline.json to commit, which is how a baseline
# is recorded or updated (tools/README.md); nothing writes one by itself.
{ pkgs, lib }:
let
  inherit (pkgs) valgrind jq;
  inherit (pkgs.stdenv.hostPlatform) system;

  # The most a count may rise above its baseline, in percent.
  limitPercent = 2;

  # How long one run may take before the bench fails, in seconds; the
  # environment variable CALLGRIND_MEASURE_TIMEOUT overrides it.
  timeoutSeconds = 600;

  # glibc picks its string and memory functions (memcpy, memset, strlen) by
  # the CPU, and valgrind shows glibc one of a few synthetic CPUs chosen by
  # what the host can do: on an AVX2 host an Intel Haswell, on a host
  # without AVX2 another model, with other preferred bits and cache sizes.
  # Without a pin, a memcpy-heavy count moved by 4 % between the two. The pin
  # makes glibc choose the same on every x86-64-v2 host: it turns off every
  # feature above x86-64-v2, the level the tools are built for, and every
  # preferred bit (glibc 2.44 clears one on "-" and ignores "+", so clearing
  # all of them is the only state every host can reach), and it fixes the
  # cache sizes and thresholds. callgrind-measure checks on every run that
  # glibc ended up in that state, and fails when it did not.
  hwcapsPin = [
    "-AVX"
    "-AVX2"
    "-AVX512F"
    "-AVX512CD"
    "-AVX512BW"
    "-AVX512DQ"
    "-AVX512ER"
    "-AVX512PF"
    "-AVX512VL"
    "-BMI1"
    "-BMI2"
    "-LZCNT"
    "-MOVBE"
    "-FMA"
    "-FMA4"
    "-F16C"
    "-ERMS"
    "-FSRM"
    "-RTM"
    "-XSAVE"
    "-XSAVEC"
    "-OSXSAVE"
    "-Fast_Rep_String"
    "-Fast_Unaligned_Load"
    "-Fast_Unaligned_Copy"
    "-Fast_Copy_Backward"
    "-Prefer_PMINUB_for_stringop"
    "-Slow_BSF"
    "-Slow_SSE4_2"
    "-Prefer_ERMS"
    "-Prefer_FSRM"
    "-Prefer_No_VZEROUPPER"
    "-AVX_Fast_Unaligned_Load"
    "-Avoid_Short_Distance_REP_MOVSB"
    "-Avoid_Non_Temporal_Memset"
    "-Avoid_STOSB"
    "-Prefer_No_AVX512"
    "-MathVec_Prefer_No_AVX512"
    "-Prefer_EVEX512"
  ];
  # The values valgrind's AVX2 CPU gives, so the pin changes least there.
  cachePin = {
    x86_data_cache_size = "0x8000";
    x86_shared_cache_size = "0x800000";
    x86_non_temporal_threshold = "0x100000";
    x86_memset_non_temporal_threshold = "0x100000";
    x86_rep_movsb_threshold = "0x2000";
    x86_rep_stosb_threshold = "0x800";
  };
  pinnedHwcaps = lib.concatStringsSep "," hwcapsPin;
  pinnedCache = lib.concatStringsSep ":" (lib.mapAttrsToList (n: v: "glibc.cpu.${n}=${v}") cachePin);
  # What glibc's diagnostics show when the cache pin holds.
  expectedState = lib.mapAttrsToList (n: v: "x86.cpu_features.${lib.removePrefix "x86_" n}=${v}") cachePin;

  # callgrind-measure OUT BENCH STDIN PROGRAM [ARG...]
  # callgrind-measure --check-glibc-state HELP DIAGNOSTICS
  measure = pkgs.writeShellApplication {
    name = "callgrind-measure";
    runtimeInputs = [
      valgrind
      jq
      pkgs.coreutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.gnused
      pkgs.patchelf
    ];
    text = ''
      usage() {
        echo "usage: callgrind-measure OUT BENCH STDIN PROGRAM [ARG...]" >&2
        echo "       callgrind-measure --check-glibc-state HELP DIAGNOSTICS" >&2
        echo "  STDIN is a file in BENCH to read on standard input, or - for none." >&2
        exit 2
      }
      fail() {
        printf 'callgrind-measure: %s\n' "$*" >&2
        exit 1
      }
      expected=(${lib.escapeShellArgs expectedState})

      # check_state HELP DIAGNOSTICS: whether glibc, as the output of its
      # ld.so --help and --list-diagnostics under the pin shows, chose what
      # the pin means: x86-64-v2 and nothing above it, no preferred bit
      # but the two that are always set, and the pinned cache values.
      check_state() {
        local help=$1 diagnostics=$2 bit want problems=()
        grep -q '^ *x86-64-v2 (supported' "$help" ||
          problems+=("glibc does not count this CPU, as valgrind presents it, as x86-64-v2, the level the tools are built for")
        if grep -q '^ *x86-64-v3 (supported' "$help"; then
          problems+=("glibc still counts this CPU as x86-64-v3: the pin leaves a feature above x86-64-v2 on")
        fi
        grep -q '^x86\.cpu_features\.preferred\.' "$diagnostics" ||
          problems+=("glibc's diagnostics list no preferred bit, so the pin cannot be checked")
        while IFS= read -r bit; do
          problems+=("glibc sets the preferred bit $bit, which the pin does not clear: add -$bit to hwcapsPin")
        done < <(sed -n 's/^x86\.cpu_features\.preferred\.\([A-Za-z0-9_]*\)=0x0*[1-9a-f][0-9a-f]*$/\1/p' "$diagnostics" |
          grep -vx -e I586 -e I686 || true)
        for want in "''${expected[@]}"; do
          grep -qx -- "$want" "$diagnostics" ||
            problems+=("glibc does not use ''${want#x86.cpu_features.}, the value the pin sets")
        done
        if ((''${#problems[@]} > 0)); then
          echo "callgrind-measure: the glibc pin does not hold on this host, so its counts would not match another's:" >&2
          printf '  - %s\n' "''${problems[@]}" >&2
          return 1
        fi
      }

      if [[ "''${1:-}" == --check-glibc-state ]]; then
        (($# == 3)) || usage
        check_state "$2" "$3" || exit 1
        echo "callgrind-measure: the glibc pin holds"
        exit 0
      fi
      (($# >= 4)) || usage
      out=$1 bench=$2 stdin=$3 program=$4
      shift 4
      timeout_s="''${CALLGRIND_MEASURE_TIMEOUT:-${toString timeoutSeconds}}"
      [[ "$timeout_s" =~ ^[1-9][0-9]*$ ]] || fail "CALLGRIND_MEASURE_TIMEOUT is '$timeout_s', not a number of seconds"
      [[ -d "$bench" ]] || fail "$bench is not a directory"
      # Absolute, since the runs change into a copy of the bench.
      bench="$(cd -- "$bench" && pwd)"
      mkdir -p -- "$out"
      out="$(cd -- "$out" && pwd)"
      if [[ "$stdin" == - ]]; then
        stdin=/dev/null
      else
        [[ -f "$bench/$stdin" ]] || fail "the bench reads $stdin on standard input, and $bench does not hold it"
        stdin="$bench/$stdin"
      fi
      # Absolute as well, without following symlinks, so the name stays.
      case "$program" in
      /*) ;;
      */*) program="$PWD/$program" ;;
      *)
        found="$(command -v -- "$program")" || fail "no program $program on PATH"
        program=$found
        ;;
      esac
      [[ -f "$program" && -x "$program" ]] || fail "$program is not an executable file"
      tool="$(basename -- "$program")"
      scratch="$(mktemp -d)"
      trap 'rm -rf -- "$scratch"' EXIT
      # Every run gets a fresh copy of the bench directory at the same path,
      # so a program that writes into its working directory starts the
      # second run as it started the first.
      work="$scratch/bench"

      # The pin. CALLGRIND_MEASURE_HOST_TUNABLES, in GLIBC_TUNABLES syntax,
      # stands for what another host would start from; it goes in front of
      # the pin, so the pin has the last word. Only the harness sets it.
      host_hwcaps="" host_rest=""
      if [[ -n "''${CALLGRIND_MEASURE_HOST_TUNABLES:-}" ]]; then
        IFS=: read -ra parts <<<"$CALLGRIND_MEASURE_HOST_TUNABLES"
        for part in "''${parts[@]}"; do
          case "$part" in
          glibc.cpu.hwcaps=*) host_hwcaps+="''${part#glibc.cpu.hwcaps=}," ;;
          ?*) host_rest+="$part:" ;;
          esac
        done
      fi
      tunables="''${host_rest}glibc.cpu.hwcaps=''${host_hwcaps}${pinnedHwcaps}:${pinnedCache}"
      printf '%s\n' "$tunables" >"$out/glibc-tunables"

      # isolated COMMAND...: COMMAND in a fixed, minimal environment, so
      # nothing of the build (the output path, the store paths of the build
      # tools) reaches the program, with the pin, and with a time limit.
      isolated() {
        timeout --kill-after=10 "$timeout_s" \
          env -i HOME=/homeless-shelter PATH=/no-path LC_ALL=C TZ=UTC TMPDIR="$scratch" \
          GLIBC_TUNABLES="$tunables" "$@"
      }
      timed_out() {
        fail "$tool did not finish within $timeout_s s $1 (CALLGRIND_MEASURE_TIMEOUT sets the limit)"
      }

      # Check the pin with the program's own glibc.
      interpreter="$(patchelf --print-interpreter "$program" 2>/dev/null)" ||
        fail "$program has no ELF interpreter; the bench measures a dynamically linked program, whose glibc it can pin"
      status=0
      isolated ${valgrind}/bin/valgrind --tool=none -q "$interpreter" --help >"$out/glibc-help" 2>&1 || status=$?
      ((status != 124 && status != 137)) || timed_out "while the glibc pin was checked"
      status=0
      isolated ${valgrind}/bin/valgrind --tool=none -q "$interpreter" --list-diagnostics >"$out/glibc-diagnostics" 2>&1 ||
        status=$?
      ((status != 124 && status != 137)) || timed_out "while the glibc pin was checked"
      check_state "$out/glibc-help" "$out/glibc-diagnostics" || exit 1

      # run N: one run under callgrind, counting from main on, inclusive,
      # so the start of the process (the dynamic loader, glibc's own start
      # and its CPU detection) is not in the count. Prints the count.
      run() {
        local n=$1 status=0 total
        shift
        rm -rf -- "$work"
        cp -r -- "$bench" "$work"
        chmod -R u+w -- "$work"
        (
          cd "$work"
          isolated ${valgrind}/bin/valgrind --tool=callgrind --vgdb=no --toggle-collect=main \
            --callgrind-out-file="$out/callgrind.$n.out" --log-file="$out/valgrind.$n.log" \
            -- "$program" "$@" <"$stdin" >"$out/stdout" 2>"$out/stderr"
        ) || status=$?
        ((status != 124 && status != 137)) || timed_out "on run $n"
        if ((status != 0)); then
          echo "callgrind-measure: $tool exited $status on run $n. Its error output:" >&2
          sed 's/^/  | /' "$out/stderr" >&2
          exit 1
        fi
        total="$(awk '$1 == "totals:" { print $2 }' "$out/callgrind.$n.out")"
        [[ "$total" =~ ^[0-9]+$ ]] || fail "run $n left no instruction count in $out/callgrind.$n.out"
        ((total > 0)) ||
          fail "$tool never ran a function named main, from which the bench counts; is its symbol table stripped?"
        printf '%s\n' "$total"
      }

      # Two runs, which must agree: the gate compares exact counts, so a
      # bench whose count drifts would fail or pass by chance.
      first="$(run 1 "$@")"
      second="$(run 2 "$@")"
      if [[ "$first" != "$second" ]]; then
        fail "the count is not deterministic: run 1 gave $first instructions, run 2 gave $second." \
          "A bench must not depend on the time, randomness, addresses or the environment."
      fi
      rm -f -- "$out/callgrind.2.out" "$out/valgrind.2.log"
      mv -- "$out/callgrind.1.out" "$out/callgrind.out"
      mv -- "$out/valgrind.1.log" "$out/valgrind.log"

      printf '%s\n' "$first" >"$out/instructions"
      jq -n --argjson n "$first" '{ instructions: $n }' >"$out/baseline.json"
      callgrind_annotate --inclusive=yes "$out/callgrind.out" >"$out/annotate.txt"
      echo "callgrind-measure: $first instructions"
    '';
  };

  # callgrind-compare NAME MEASURED BASELINE_JSON
  compare = pkgs.writeShellApplication {
    name = "callgrind-compare";
    runtimeInputs = [
      jq
      pkgs.gawk
    ];
    text = ''
      if (($# != 3)); then
        echo "usage: callgrind-compare NAME MEASURED BASELINE_JSON" >&2
        exit 2
      fi
      name=$1 measured=$2 file=$3
      limit=${toString limitPercent}
      record="To record a new baseline, run: nix build .#checks.${system}.$name-bench.measure, then copy result/baseline.json to the tool's bench/baseline.json."
      fail() {
        printf '%s: %s\n' "$name" "$*" >&2
        exit 1
      }
      [[ "$measured" =~ ^[1-9][0-9]*$ ]] || fail "the measured count '$measured' is not a positive whole number"
      [[ -e "$file" ]] || fail "no bench/baseline.json. $record"
      [[ -s "$file" ]] || fail "bench/baseline.json is empty. $record"
      jq empty "$file" 2>/dev/null || fail "bench/baseline.json is not valid JSON. $record"
      baseline="$(jq -r -s '
        if length == 1 and (.[0] | type) == "object"
          and (.[0].instructions | type) == "number"
          and .[0].instructions > 0 and .[0].instructions == (.[0].instructions | floor)
        then .[0].instructions else empty end' "$file")"
      [[ "$baseline" =~ ^[1-9][0-9]*$ ]] ||
        fail "bench/baseline.json holds no positive whole number under \"instructions\", such as {\"instructions\": 123456}. $record"

      change="$(awk -v m="$measured" -v b="$baseline" 'BEGIN { printf "%+.2f %%", (m - b) * 100 / b }')"
      echo "$name: $measured instructions, baseline $baseline: $change"
      if ((measured * 100 > baseline * (100 + limit))); then
        fail "$change is above the limit of +$limit %. Find what grew in the top functions below; if the rise is wanted, record the new count as the baseline. $record"
      fi
      if ((measured * 100 < baseline * (100 - limit))); then
        echo "$name: the count is below the baseline by more than $limit %; record it, so the gain is kept. $record"
      fi
    '';
  };

  # A count holds only with the pin above, measured here: neither the
  # measurement nor the check that links to it comes from a remote builder
  # or a cache.
  localOnly = {
    preferLocalBuild = true;
    allowSubstitutes = false;
  };

  mkBench =
    {
      name,
      program,
      bench,
      args ? [ ],
      stdin ? null,
    }:
    let
      # The input without the baseline, so that recording a baseline does
      # not measure again.
      input = lib.fileset.toSource {
        root = bench;
        fileset = lib.fileset.difference bench (lib.fileset.maybeMissing (bench + "/baseline.json"));
      };
      measured =
        pkgs.runCommand "${name}-bench-measure"
          (
            localOnly
            // {
              nativeBuildInputs = [ measure ];
            }
          )
          ''
            callgrind-measure "$out" ${input} ${if stdin == null then "-" else lib.escapeShellArg stdin} \
              ${lib.escapeShellArg program} ${lib.escapeShellArgs args}
          '';
    in
    pkgs.runCommand "${name}-bench"
      (
        localOnly
        // {
          nativeBuildInputs = [ compare ];
          passthru.measure = measured;
        }
      )
      ''
        status=0
        callgrind-compare ${lib.escapeShellArg name} "$(cat ${measured}/instructions)" ${bench}/baseline.json ||
          status=$?
        if [ "$status" != 0 ]; then
          echo "The top functions, inclusive (${measured}/annotate.txt):"
          sed -n '/^Ir .*file:function/,$p' ${measured}/annotate.txt | head -n 30
          exit "$status"
        fi
        mkdir "$out"
        cp ${measured}/instructions "$out/instructions"
        ln -s ${measured} "$out/measure"
      '';
in
{
  inherit
    valgrind
    limitPercent
    timeoutSeconds
    measure
    compare
    mkBench
    ;
}
