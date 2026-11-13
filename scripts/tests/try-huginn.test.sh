#!/usr/bin/env bash
# Tests for scripts/try-huginn.sh, the QEMU passthrough wrapper that boots the
# installed laptop from its raw disk. The guard, qemu, id and the disk are
# stand-ins: a fake ravnix-disk-guard answers with the exit code and the
# output a test sets, a fake qemu-system-x86_64 writes its arguments, one per
# record, to a file, and a fake id says who is running. No test touches a
# real disk, a real device node or a real guard. The script under test is a
# copy whose two firmware placeholders are replaced by fake files in the
# scratch directory, as the package does with the store paths (a test checks
# that the copy differs from the script in nothing else). Run it with:
#
#   bash scripts/tests/try-huginn.test.sh
#
# It prints PASS or FAIL per test and exits non-zero if any test failed.

# The stubs' bodies are written in single quotes on purpose.
# shellcheck disable=SC2016

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../try-huginn.sh"
# shellcheck source=scripts/tests/lib.sh
. "$here/lib.sh"

model="TEST MODEL 1"
serial="TESTSERIAL1"
dev="/dev/disk/by-id/nvme-TEST_MODEL_1_TESTSERIAL1"

bin="$scratch/bin"
calls="$scratch/calls"
copy="$scratch/try-huginn"
code_fd="$scratch/fake-OVMF_CODE.fd"
vars_fd="$scratch/fake-OVMF_VARS.fd"
mkdir -p "$bin" "$calls"
printf 'fake code' >"$code_fd"
printf 'fake vars' >"$vars_fd"
# The run's temporary directory, so a test can see that it is cleaned up.
run_tmp="$scratch/tmp"
mkdir -p "$run_tmp"

# The script as the package ships it, with the firmware paths filled in.
sed -e "s|@ovmfCode@|$code_fd|g" -e "s|@ovmfVars@|$vars_fd|g" "$script" >"$copy"
chmod +x "$copy"

# The guard: one line of its arguments per call in $calls/guard, then the
# n-th entry of GUARD_EXITS (a space separated list; the last one repeats) and
# of GUARD_OUTS (a "|" separated list), so a test can change the answer
# between the first call and the re-check. FAKE_GUARD_ERR goes to stderr.
write_script "$bin/ravnix-disk-guard" \
	'n=$(($(cat "$CALLS/guard-n" 2>/dev/null || echo 0) + 1))' \
	'echo "$n" >"$CALLS/guard-n"' \
	'printf "%s\037" "$@" >>"$CALLS/guard"; echo >>"$CALLS/guard"' \
	'read -r -a exits <<<"$GUARD_EXITS"' \
	'i=$((n - 1)); ((i < ${#exits[@]})) || i=$((${#exits[@]} - 1))' \
	'IFS="|" read -r -a outs <<<"$GUARD_OUTS"; outs+=("")' \
	'j=$((n - 1)); ((j < ${#outs[@]} - 1)) || j=$((${#outs[@]} - 2)); ((j >= 0)) || j=$((${#outs[@]} - 1))' \
	'[[ -z "${FAKE_GUARD_ERR:-}" ]] || echo "$FAKE_GUARD_ERR" >&2' \
	'[[ "${exits[$i]}" != 0 ]] || printf "${outs[$j]}"' \
	'exit "${exits[$i]}"'

# qemu: the arguments, each followed by a NUL, in $calls/qemu, and a copy of
# the writable firmware variables the run was given, so a test can read them
# after the script has deleted its own.
write_script "$bin/qemu-system-x86_64" \
	'printf "%s\0" "$@" >"$CALLS/qemu"' \
	'for a in "$@"; do' \
	'  case "$a" in *unit=1*) f="${a##*file=}"; cp -- "$f" "$CALLS/vars-copy"; echo "$f" >"$CALLS/vars-path"; stat -c %a "$f" >"$CALLS/vars-mode";; esac' \
	'done' \
	'exit "${QEMU_EXIT:-0}"'

write_script "$bin/id" 'echo "${FAKE_UID:-0}"'

setup() {
	rm -rf "$calls" "$run_tmp"
	mkdir -p "$calls" "$run_tmp"
	export CALLS="$calls" TMPDIR="$run_tmp" RAVNIX_HUGINN_LOCK="$scratch/lock"
	export GUARD_EXITS=0 GUARD_OUTS="$dev"
	unset FAKE_UID FAKE_GUARD_ERR QEMU_EXIT
}

run() { capture env PATH="$bin:$PATH" "$copy" "$@"; }
run_ok_args() { run --model "$model" --serial "$serial"; }

qemu_called() { [[ -e "$calls/qemu" ]]; }
expect_no_qemu() { ! qemu_called || {
	echo "  qemu was started"
	return 1
}; }
# The NUL separated arguments of the qemu call, one per line (an argument
# with a newline would show as two, which a test for that reads raw).
qemu_args() { tr '\0' '\n' <"$calls/qemu"; }
expect_qemu_arg() {
	qemu_args | grep -Fxq -- "$1" || {
		echo "  qemu did not get the argument '$1'; it got:"
		qemu_args | sed 's/^/    /'
		return 1
	}
}
expect_no_qemu_arg() {
	! qemu_args | grep -Fxq -- "$1" || {
		echo "  qemu got the argument '$1'"
		return 1
	}
}
guard_calls() { wc -l <"$calls/guard" | tr -d ' '; }

test_placeholders_are_the_only_difference() {
	# The copy the tests run is the shipped script with two strings replaced.
	grep -q '@ovmfCode@' "$script"
	grep -q '@ovmfVars@' "$script"
	if grep -q '@ovmf' "$copy"; then
		echo "  a placeholder is left in the copy"
		return 1
	fi
	[[ "$(diff <(sed -e 's|@ovmfCode@||g' -e 's|@ovmfVars@||g' "$script") \
		<(sed -e "s|$code_fd||g" -e "s|$vars_fd||g" "$copy") | wc -l)" == 0 ]]
}

test_guard_then_qemu_with_the_printed_device() {
	setup
	run_ok_args
	expect_status 0
	# The guard got the model and the serial as one argument each, and
	# --print-device; no test seam.
	[[ "$(head -n 1 "$calls/guard")" == "--model"$'\037'"$model"$'\037'--serial$'\037'"$serial"$'\037'--print-device$'\037' ]] ||
		{
			echo "  guard got: $(head -n 1 "$calls/guard")"
			return 1
		}
	qemu_called
	expect_qemu_arg "if=none,id=huginn,format=raw,cache=none,aio=native,file=$dev"
	expect_qemu_arg "if=pflash,format=raw,unit=0,readonly=on,file=$code_fd"
	expect_qemu_arg "-device"
	expect_qemu_arg "nvme,drive=huginn,serial=huginn,bootindex=0"
	expect_qemu_arg "-accel"
	expect_qemu_arg "kvm"
	# The device appears once, in the drive, and never as an argument of its own.
	[[ "$(tr '\0' '\n' <"$calls/qemu" | grep -cF -- "$dev")" == 1 ]]
	expect_no_qemu_arg "-snapshot"
	expect_no_qemu_arg "-hda"
	expect_no_qemu_arg "-drive $dev"
}

test_the_guard_is_asked_again_right_before_qemu() {
	setup
	run_ok_args
	expect_status 0
	[[ "$(guard_calls)" == 2 ]]
}

test_the_guards_stderr_reaches_the_user() {
	setup
	FAKE_GUARD_ERR="verdict: free" run_ok_args
	expect_status 0
	expect_err "verdict: free"
}

test_qemus_exit_status_is_the_scripts() {
	setup
	QEMU_EXIT=7 run_ok_args
	expect_status 7
}

test_the_firmware_variables_are_a_writable_copy_in_a_temporary_directory() {
	setup
	run_ok_args
	expect_status 0
	local path
	path="$(cat "$calls/vars-path")"
	[[ "$path" != "$vars_fd" ]]
	[[ "$path" == "$run_tmp"/* ]]
	[[ "$(cat "$calls/vars-copy")" == "fake vars" ]]
	[[ "$(cat "$calls/vars-mode")" == 600 ]]
	# The source is untouched and the copy is gone after the run.
	[[ "$(cat "$vars_fd")" == "fake vars" ]]
	[[ ! -e "$path" ]]
	[[ -z "$(ls -A "$run_tmp")" ]] || {
		echo "  left in the temporary directory: $(ls -A "$run_tmp")"
		return 1
	}
}

test_the_temporary_directory_is_removed_when_qemu_fails() {
	setup
	QEMU_EXIT=3 run_ok_args
	expect_status 3
	[[ -z "$(ls -A "$run_tmp")" ]]
}

test_exit_2_refuses_naming_the_mounted_partition() {
	setup
	GUARD_EXITS=2 run_ok_args
	expect_status 2
	expect_no_qemu
	expect_err "in use"
	expect_err "mounted on this system"
	expect_err "Unmount"
}

test_exit_1_refuses() {
	setup
	GUARD_EXITS=1 run_ok_args
	expect_status 1
	expect_no_qemu
	expect_err "not exactly one disk"
}

test_other_guard_exits_refuse() {
	local rc
	for rc in 3 4 126 127 130 255; do
		setup
		GUARD_EXITS=$rc run_ok_args
		expect_status 1
		expect_no_qemu
		expect_err "exit $rc"
	done
}

test_a_guard_that_prints_nothing_refuses() {
	setup
	GUARD_OUTS="" run_ok_args
	expect_status 1
	expect_no_qemu
	expect_err "no device"
}

test_a_guard_that_prints_two_lines_refuses() {
	setup
	GUARD_OUTS="$dev\n$dev-part1" run_ok_args
	expect_status 1
	expect_no_qemu
	expect_err "one line"
}

test_a_guard_that_prints_only_a_newline_refuses() {
	setup
	GUARD_OUTS='\n' run_ok_args
	expect_status 1
	expect_no_qemu
}

test_a_device_that_is_not_a_by_id_name_refuses() {
	local bad
	# A leading dash, a kernel name, a path outside by-id, a relative path,
	# a traversal, a nested name, a name starting with a dot, and a bare dir.
	for bad in "-drive" "--snapshot" "/dev/nvme0n1" "/dev/sda" "/dev/disk/by-path/x" \
		"dev/disk/by-id/x" "/dev/disk/by-id/../../nvme0n1" "/dev/disk/by-id/a/b" \
		"/dev/disk/by-id/.hidden" "/dev/disk/by-id/" "/dev/disk/by-id/-x" "nvme-x"; do
		setup
		GUARD_OUTS="$bad" run_ok_args
		expect_status 1
		expect_no_qemu
	done
}

test_a_device_with_a_space_a_comma_or_other_odd_characters_refuses() {
	# One qemu option is "key=value,key=value": a comma in the path would
	# start another key, so it never reaches qemu; neither does a space, a
	# quote, a backslash, a dollar, a glob, or a control character.
	local bad
	for bad in "/dev/disk/by-id/a b" "/dev/disk/by-id/a,readonly=on" \
		"/dev/disk/by-id/a,file=/dev/nvme0n1" '/dev/disk/by-id/a"b' "/dev/disk/by-id/a'b" \
		'/dev/disk/by-id/a\\\\b' '/dev/disk/by-id/a$b' '/dev/disk/by-id/a*' \
		'/dev/disk/by-id/a\tb' '/dev/disk/by-id/a\x01b' '/dev/disk/by-id/a;b' \
		'/dev/disk/by-id/ä'; do
		setup
		GUARD_OUTS="$bad" run_ok_args
		expect_status 1
		expect_no_qemu
	done
}

test_a_realistic_by_id_name_passes_unchanged() {
	local good
	for good in "nvme-Some_Model_123-45_SERIAL9" "nvme-Some_Model_SERIAL9_1-part1" \
		"nvme-eui.0025385a01234567" "wwn-0x5002538d12345678" "ata-Model_9.1+x:y=z@w"; do
		setup
		GUARD_OUTS="/dev/disk/by-id/$good" run_ok_args
		expect_status 0
		expect_qemu_arg "if=none,id=huginn,format=raw,cache=none,aio=native,file=/dev/disk/by-id/$good"
	done
}

test_the_re_check_that_finds_a_mount_refuses() {
	setup
	GUARD_EXITS="0 2" run_ok_args
	expect_status 2
	expect_no_qemu
	expect_err "in use"
}

test_the_re_check_that_finds_another_device_refuses() {
	setup
	GUARD_OUTS="$dev|/dev/disk/by-id/nvme-OTHER" run_ok_args
	expect_status 1
	expect_no_qemu
	expect_err "changed"
}

test_the_re_check_that_fails_refuses() {
	setup
	GUARD_EXITS="0 1" run_ok_args
	expect_status 1
	expect_no_qemu
}

test_missing_model_or_serial_is_a_usage_error() {
	setup
	run --serial "$serial"
	expect_status 3
	expect_err "usage:"
	run --model "$model"
	expect_status 3
	run
	expect_status 3
	[[ ! -e "$calls/guard" ]]
	expect_no_qemu
}

test_bad_usage_is_a_usage_error_and_runs_nothing() {
	setup
	local args
	# An empty value, a repeated option, an unknown option, a stray
	# argument, a device path, the guard's test seams, and a value-less option.
	for args in "--model|--serial|$serial" "--model||--serial|$serial" "--model|$model|--serial|" \
		"--model|$model|--model|$model|--serial|$serial" \
		"--model|$model|--serial|$serial|--serial|$serial" \
		"--model|$model|--serial|$serial|--device|$dev" \
		"--model|$model|--serial|$serial|$dev" \
		"--model|$model|--serial|$serial|/dev/nvme0n1" \
		"--model|$model|--serial|$serial|--lsblk-json|/tmp/x" \
		"--model|$model|--serial|$serial|--by-id|/tmp/x" \
		"--model|$model|--serial|$serial|--print-device" \
		"--model|$model|--serial|$serial|--" "--model" "--serial" "-x" "$dev"; do
		IFS='|' read -r -a argv <<<"$args"
		run "${argv[@]}"
		expect_status 3
		expect_err "usage:"
	done
	[[ ! -e "$calls/guard" ]]
	expect_no_qemu
}

test_help_prints_usage_and_exits_0() {
	setup
	run --help
	expect_status 0
	expect_said "usage:"
	[[ ! -e "$calls/guard" ]]
}

test_a_model_with_a_leading_dash_is_a_value_not_an_option() {
	setup
	run --model "-x" --serial "$serial"
	expect_status 0
	[[ "$(head -n 1 "$calls/guard")" == "--model"$'\037'"-x"$'\037'--serial$'\037'"$serial"$'\037'--print-device$'\037' ]]
}

test_it_refuses_to_run_as_a_normal_user() {
	setup
	FAKE_UID=1000 run_ok_args
	expect_status 1
	expect_no_qemu
	expect_err "root"
	expect_err "sudo"
	# Before the guard, so the guard runs only under the privilege qemu has.
	[[ ! -e "$calls/guard" ]]
}

# A directory of links to the fake tools named in $2... and to the real ones
# the script needs, and to nothing else: a PATH with no other qemu or guard.
# Prints the directory.
limited_path() {
	local dir="$scratch/limited-$1" t
	shift
	rm -rf "$dir"
	mkdir -p "$dir"
	for t in id mktemp rm cp chmod flock; do
		if [[ -x "$bin/$t" ]]; then ln -s "$bin/$t" "$dir/$t"; else ln -s "$(command -v "$t")" "$dir/$t"; fi
	done
	for t in "$@"; do ln -s "$bin/$t" "$dir/$t"; done
	printf '%s' "$dir"
}

test_a_missing_qemu_refuses_before_the_guard() {
	setup
	capture env PATH="$(limited_path noqemu ravnix-disk-guard)" "$BASH" "$copy" --model "$model" --serial "$serial"
	expect_status 1
	expect_err "qemu-system-x86_64"
	[[ ! -e "$calls/guard" ]]
}

test_missing_firmware_refuses_before_the_guard() {
	setup
	sed -e "s|@ovmfCode@|$scratch/no-such-code.fd|g" -e "s|@ovmfVars@|$vars_fd|g" "$script" >"$scratch/nofw"
	chmod +x "$scratch/nofw"
	capture env PATH="$bin:$PATH" "$scratch/nofw" --model "$model" --serial "$serial"
	expect_status 1
	expect_err "firmware"
	[[ ! -e "$calls/guard" ]]
	expect_no_qemu
	# The script as it stands in the repository has no firmware at all.
	capture env PATH="$bin:$PATH" "$script" --model "$model" --serial "$serial"
	expect_status 1
	expect_err "firmware"
	expect_no_qemu
}

test_a_missing_guard_refuses() {
	setup
	capture env PATH="$(limited_path noguard qemu-system-x86_64)" "$BASH" "$copy" --model "$model" --serial "$serial"
	expect_status 1
	expect_no_qemu
	expect_err "ravnix-disk-guard"
}

test_a_held_lock_refuses_before_the_guard() {
	setup
	# The install step holds the same lock file; flock here plays it.
	(
		exec 9>"$RAVNIX_HUGINN_LOCK"
		flock -n 9
		run_ok_args
		[[ "$status" == 1 ]] || exit 11
		[[ "$err" == *"lock"* ]] || exit 12
		[[ ! -e "$calls/guard" ]] || exit 13
		[[ ! -e "$calls/qemu" ]] || exit 14
	)
}

test_the_lock_is_held_while_qemu_runs_and_free_after() {
	setup
	# A qemu that tries the lock from inside: it must be held then.
	write_script "$scratch/bin2/qemu-system-x86_64" \
		'if flock -n "$LOCK_FILE" true; then echo free >"$CALLS/lock-state"; else echo held >"$CALLS/lock-state"; fi'
	cp "$bin/ravnix-disk-guard" "$bin/id" "$scratch/bin2/"
	LOCK_FILE="$RAVNIX_HUGINN_LOCK" capture env PATH="$scratch/bin2:$PATH" "$copy" --model "$model" --serial "$serial"
	expect_status 0
	[[ "$(cat "$calls/lock-state")" == held ]]
	flock -n "$RAVNIX_HUGINN_LOCK" true
}

test_a_lock_file_that_cannot_be_opened_refuses() {
	setup
	RAVNIX_HUGINN_LOCK="$scratch/no-such-dir/lock" run_ok_args
	expect_status 1
	expect_no_qemu
	expect_err "lock"
}

test_the_script_never_writes_the_disk_or_takes_a_device_from_outside() {
	# Static: no tool that writes a disk, no -snapshot, no guard test seam,
	# and no device variable of the script's own besides the guard's answer.
	local code
	code="$(grep -v '^[[:space:]]*#' "$script")"
	if grep -Eq '(^|[^[:alnum:]_-])(dd|mkfs|wipefs|sgdisk|parted|sfdisk|cryptsetup|mount|umount)[[:space:]]' <<<"$code"; then
		echo "  the script runs a disk tool"
		return 1
	fi
	if grep -q -- '-snapshot' <<<"$code"; then
		echo "  the script passes -snapshot"
		return 1
	fi
	if grep -Eq 'lsblk-json|--by-id' <<<"$code"; then
		echo "  the script reaches for a guard test seam"
		return 1
	fi
}

tests=(
	test_placeholders_are_the_only_difference
	test_guard_then_qemu_with_the_printed_device
	test_the_guard_is_asked_again_right_before_qemu
	test_the_guards_stderr_reaches_the_user
	test_qemus_exit_status_is_the_scripts
	test_the_firmware_variables_are_a_writable_copy_in_a_temporary_directory
	test_the_temporary_directory_is_removed_when_qemu_fails
	test_exit_2_refuses_naming_the_mounted_partition
	test_exit_1_refuses
	test_other_guard_exits_refuse
	test_a_guard_that_prints_nothing_refuses
	test_a_guard_that_prints_two_lines_refuses
	test_a_guard_that_prints_only_a_newline_refuses
	test_a_device_that_is_not_a_by_id_name_refuses
	test_a_device_with_a_space_a_comma_or_other_odd_characters_refuses
	test_a_realistic_by_id_name_passes_unchanged
	test_the_re_check_that_finds_a_mount_refuses
	test_the_re_check_that_finds_another_device_refuses
	test_the_re_check_that_fails_refuses
	test_missing_model_or_serial_is_a_usage_error
	test_bad_usage_is_a_usage_error_and_runs_nothing
	test_help_prints_usage_and_exits_0
	test_a_model_with_a_leading_dash_is_a_value_not_an_option
	test_it_refuses_to_run_as_a_normal_user
	test_a_missing_qemu_refuses_before_the_guard
	test_missing_firmware_refuses_before_the_guard
	test_a_missing_guard_refuses
	test_a_held_lock_refuses_before_the_guard
	test_the_lock_is_held_while_qemu_runs_and_free_after
	test_a_lock_file_that_cannot_be_opened_refuses
	test_the_script_never_writes_the_disk_or_takes_a_device_from_outside
)
run_tests "${tests[@]}"
