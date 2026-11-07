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
