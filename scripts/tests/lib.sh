# Shared by the shell tests in scripts/tests/, which source it; it is not a
# test itself. A test file defines one function per test, lists them in an
# array and ends with:
#
#   run_tests "${tests[@]}"
#
# Each test runs in a subshell with errexit, so the first failing check ends
# it. The expect_* helpers print why they failed and return non-zero. Every
# test file gets its own scratch directory, removed on exit.
# shellcheck shell=bash

set -euo pipefail

# Keep the user's git configuration (signing, hooks, templates) out of the
# temporary repositories.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

scratch="$(mktemp -d -p "${TMPDIR:-/tmp}" ravnix-tests.XXXXXX)"
trap 'chmod -R u+rwX -- "$scratch" 2>/dev/null; rm -rf -- "$scratch"' EXIT

# The full gate records the Claude Code downloads it verified under
# XDG_STATE_HOME (scripts/README.md); a test's gate records into its scratch,
# never into the user's state.
export XDG_STATE_HOME="$scratch/state"

# Set by capture for the test that is running.
status=0
out=""
err=""

# Runs a command and records its exit code, stdout and stderr.
capture() {
	status=0
	"$@" >"$scratch/.out" 2>"$scratch/.err" || status=$?
	out="$(cat "$scratch/.out")"
	err="$(cat "$scratch/.err")"
}

# Writes an executable script whose first line runs the bash running the
# tests, since /usr/bin/env does not exist in the Nix build sandbox.
write_script() {
	local path="$1"
	shift
	mkdir -p "$(dirname "$path")"
	printf '#!%s\n' "$BASH" >"$path"
	printf '%s\n' "$@" >>"$path"
	chmod +x "$path"
}

expect_status() {
	[[ "$status" == "$1" ]] || {
		echo "  expected exit $1, got $status"
		echo "  stdout: $out"
		echo "  stderr: $err"
		return 1
	}
}
expect_out() {
	[[ "$out" == *"$1"* ]] || {
		echo "  expected stdout to contain '$1', got: $out"
		return 1
	}
}
expect_no_out() {
	[[ "$out" != *"$1"* ]] || {
		echo "  expected stdout not to contain '$1', got: $out"
		return 1
	}
}
expect_err() {
	[[ "$err" == *"$1"* ]] || {
		echo "  expected stderr to contain '$1', got: $err"
		return 1
	}
}
expect_no_err() {
	[[ "$err" != *"$1"* ]] || {
		echo "  expected stderr not to contain '$1', got: $err"
		return 1
	}
}
# stdout and stderr together, for messages whose stream does not matter.
expect_said() {
	[[ "$out$err" == *"$1"* ]] || {
		echo "  expected the output to contain '$1', got: $out $err"
		return 1
	}
}
expect_lines() {
	local n
	n="$(printf '%s' "$out" | awk 'END { print NR }')"
	[[ "$n" == "$1" ]] || {
		echo "  expected $1 lines on stdout, got $n: $out"
		return 1
	}
}

run_tests() {
	local name t rc failed=0
	name="$(basename "$0")"
	# An empty or mistyped list of tests must not pass for a green run.
	if (($# == 0)); then
		echo "$name: no tests given to run_tests"
		exit 1
	fi
	for t in "$@"; do
		# Bash ignores errexit inside an if condition, so the status is read
		# afterwards.
		set +e
		(
			set -e
			"$t"
		) >"$scratch/.log" 2>&1
		rc=$?
		set -e
		if ((rc == 0)); then
			echo "PASS $t"
		else
			echo "FAIL $t"
			sed 's/^/  /' "$scratch/.log"
			failed=$((failed + 1))
		fi
	done
	if ((failed > 0)); then
		echo "$name: $failed of $# tests failed"
		exit 1
	fi
	echo "$name: all $# tests passed"
}

# The style check that the gate's tests (check.test.sh, githooks.test.sh)
# give the gate of their scratch repositories: the program CHECK_STYLE names,
# which is what tools/check-style builds (the check scripts-tests sets it).
# Prints it, or says how to set it and fails.
style_check_program() {
	if [[ -z "${CHECK_STYLE:-}" || ! -x "$CHECK_STYLE" || -d "$CHECK_STYLE" ]]; then
		# shellcheck disable=SC2016 # the command to run, not to expand here
		printf '%s\n' "CHECK_STYLE names no program (${CHECK_STYLE:-unset}). The gate's style step runs" \
			"tools/check-style; run the test with" \
			'  CHECK_STYLE="$(nix build --no-link --print-out-paths .#check-style)/bin/check-style"' >&2
		return 1
	fi
	printf '%s\n' "$CHECK_STYLE"
}

# Writes $1/style-build, which the fake nix of a gate test runs, with all of
# nix's arguments, for the style step's build of check-style. Like nix build
# --out-link LINK --print-out-paths path:SRC#check-style, it makes an output
# under $1/store, links LINK to it (by a rename, so the link is never half
# written) and prints it. The output's bin/check-style runs the program $2,
# and src/ holds what SRC/tools/check-style held, so a test can tell which
# tree the build read; style.sources lists the SRC of each build. The files
# in $1 that change what it does:
#
#   style.status   the build fails with this status, and makes no link
#   style.delay    the build takes this many seconds
#   style.empty    the output has no program in it
#   style.running  while present, a build runs; a second one at the same
#                  time writes style.overlap
#   style.slow     the built program takes this many seconds per run, with
#                  its pid in prog.running while it runs; a build that
#                  starts then writes style.while-in-use
style_build_script() {
	local dir="$1" program="$2"
	# shellcheck disable=SC2016 # the fake build's code, for its own shell
	write_script "$dir/style-build" \
		"d='$dir' program='$program'" \
		'link="" src=""
prev=""
for a; do
	[[ "$prev" != --out-link ]] || link="$a"
	case "$a" in path:*"#check-style") src="${a#path:}"; src="${src%#check-style}" ;; esac
	prev="$a"
done
[[ -n "$link" && -n "$src" ]] || { echo "fake nix: a style build without --out-link or path:SRC#check-style: $*" >&2; exit 64; }
printf "%s\n" "$src" >>"$d/style.sources"
[[ ! -e "$d/style.running" ]] || : >"$d/style.overlap"
[[ ! -e "$d/prog.running" ]] || : >"$d/style.while-in-use"
: >"$d/style.running"
[[ ! -e "$d/style.delay" ]] || sleep "$(cat -- "$d/style.delay")"
rm -f -- "$d/style.running"
if [[ -e "$d/style.status" ]]; then
	echo "error: builder for check-style failed" >&2
	exit "$(cat -- "$d/style.status")"
fi
mkdir -p "$d/store"
out="$(mktemp -d -p "$d/store" XXXXXX-check-style)"
if [[ ! -e "$d/style.empty" ]]; then
	mkdir -p "$out/bin"
	{
		printf "#!%s\n" "$BASH"
		printf "d=%q\n" "$d"
		printf "%s\n" "if [[ -e \"\$d/style.slow\" ]]; then echo \$\$ >\"\$d/prog.running\"; sleep \"\$(cat -- \"\$d/style.slow\")\"; rm -f -- \"\$d/prog.running\"; fi"
		printf "exec %q \"\$@\"\n" "$program"
	} >"$out/bin/check-style"
	chmod +x "$out/bin/check-style"
fi
[[ ! -d "$src/tools/check-style" ]] || cp -r -- "$src/tools/check-style" "$out/src"
ln -s -- "$out" "$link.fake-tmp.$$"
mv -fT -- "$link.fake-tmp.$$" "$link"
printf "%s\n" "$out"'
}
