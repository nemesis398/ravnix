#!/usr/bin/env bash
# Tests for ravnix-paperless-copy (packages/ravnix-paperless-copy), run by the
# check bin-ravnix-paperless-copy on scripts/tests/lib.sh. The script under
# test is a copy of the package's whose PATH starts with $STUB_PATH
# (tests/bin/helpers/stub-first.nix), so that curl and sleep can be stand-ins
# when a test wants them: curl records the arguments and the standard input it
# was given and answers with the status in $fake/curl.status, sleep logs its
# argument and ends the loop after a few rounds. rsync, find, cp and date are
# the real ones.
#
# Every test builds its own throwaway tree under the test file's scratch
# directory ($media, $targets, $outside), so the tool, which runs rsync
# --delete, never sees a real path. $outside is the stand-in for everything the
# tool must not touch.
#
# The cases that matter most are the negative ones: a missing or empty source
# changes nothing and exits 3, a symlink in a target never reaches what it
# points at, a symlink in the source never shows its target to the owner, and
# the push URL, which is a token, is on no command line.
#
# COPY_UNDER_TEST names the copy, TEST_LIB scripts/tests/lib.sh.

# shellcheck source=scripts/tests/lib.sh
. "${TEST_LIB:?}"

SUT=${COPY_UNDER_TEST:?}

media="$scratch/media"
targets="$scratch/targets"
outside="$scratch/outside"
fake="$scratch/fake"
bin="$scratch/bin"
tmp="$scratch/tmp"
export STUB_PATH="$bin"
export TMPDIR="$tmp"
export LC_ALL=C
export TZ=Europe/Berlin
unset KUMA_PUSH_URL

fresh() {
	rm -rf -- "$media" "$targets" "$outside" "$fake" "$bin" "$tmp"
	mkdir -p "$media/documents/archive" "$media/documents/originals" "$targets" \
		"$outside" "$fake" "$bin" "$tmp"
}

# put FILE CONTENT: a file with its parents.
put() {
	mkdir -p -- "$(dirname -- "$1")"
	printf '%s' "$2" >"$1"
}
archive() { put "$media/documents/archive/$1" "${2-pdf of $1}"; }
original() { put "$media/documents/originals/$1" "${2-original of $1}"; }

# A listing of a tree that tells names, kinds, contents and symlink targets
# apart: any change to the tree changes it.
snapshot() {
	(
		cd -- "$1"
		find . -mindepth 1 -printf '%p|%y|%l|%s\0' | sort -z | tr '\0' '\n'
		find . -type f -print0 | sort -z | xargs -0 -r cat --
	)
}

run() { capture "$SUT" --once "$@"; }
run_copy() { run --media "$media" --targets "$targets"; }

want() { # FILE: a regular file with that content, in $targets
	[[ -f $1 && ! -L $1 ]] || {
		echo "  missing: $1"
		return 1
	}
}
absent() {
	[[ ! -e $1 && ! -L $1 ]] || {
		echo "  should not exist: $1"
		return 1
	}
}
never() { # COMMAND...: fails the test when the command succeeds
	if "$@"; then
		echo "  succeeded, and should not have: $*"
		return 1
	fi
}
same() { # FILE CONTENT
	[[ $(cat -- "$1") == "$2" ]] || {
		echo "  $1 holds '$(cat -- "$1")', not '$2'"
		return 1
	}
}

# ── the copy ──────────────────────────────────────────────────────────────

test_per_owner() {
	fresh
	mkdir -p "$targets/alice" "$targets/bob"
	archive "alice/2026/Bank/2026-01-02 Statement.pdf" "alice-1"
	archive "bob/2026/Doctor/2026-03-04 Bill.pdf" "bob-1"
	archive "carol/2026/X/2026-05-06 Not mine.pdf" "carol-1"
	run_copy
	expect_status 0
	same "$targets/alice/2026/Bank/2026-01-02 Statement.pdf" "alice-1"
	same "$targets/bob/2026/Doctor/2026-03-04 Bill.pdf" "bob-1"
	absent "$targets/alice/2026/Doctor"
	absent "$targets/bob/2026/Bank"
	absent "$targets/carol"
	# Nothing of another owner's name or content is in a target.
	names=$(find "$targets/alice" -type f ! -name LIESMICH.txt)
	[[ $names != *bob* && $names != *carol* && $names != *Doctor* ]]
	never command grep -rlq -e bob-1 -e carol-1 "$targets/alice"
	never command grep -rlq -e alice-1 -e carol-1 "$targets/bob"
}

test_owner_names_are_just_names() {
	fresh
	# A name that starts with a dash or holds a space is an owner like any.
	mkdir -p "$targets/-rf" "$targets/a b"
	archive "-rf/2026/X/one.pdf" "dash"
	archive "a b/2026/X/two.pdf" "space"
	run_copy
	expect_status 0
	same "$targets/-rf/2026/X/one.pdf" "dash"
	same "$targets/a b/2026/X/two.pdf" "space"
}

test_original_fallback() {
	fresh
	mkdir -p "$targets/alice"
	# a document with an archive version: the archive wins, the original stays out
	archive "alice/2026/Bank/2026-01-02 Both.pdf" "archive-both"
	original "alice/2026/Bank/2026-01-02 Both.jpg" "original-both"
	# one with no archive version, in a folder of its own
	original "alice/2026/Land Registry/2026-02-03 Plan.png" "original-plan"
	# one in a folder that the archive has too
	original "alice/2026/Bank/2026-04-05 Scan.tiff" "original-scan"
	# a PDF original with no archive twin
	original "alice/2025/Bank/2025-06-07 Raw.pdf" "original-raw"
	run_copy
	expect_status 0
	same "$targets/alice/2026/Bank/2026-01-02 Both.pdf" "archive-both"
	absent "$targets/alice/2026/Bank/2026-01-02 Both.jpg"
	same "$targets/alice/2026/Land Registry/2026-02-03 Plan.png" "original-plan"
	same "$targets/alice/2026/Bank/2026-04-05 Scan.tiff" "original-scan"
	same "$targets/alice/2025/Bank/2025-06-07 Raw.pdf" "original-raw"
}

test_fallback_survives_the_delete_pass() {
	fresh
	mkdir -p "$targets/alice"
	archive "alice/2026/Bank/a.pdf" "a"
	original "alice/2026/Land Registry/plan.png" "plan"
	original "alice/2026/Bank/scan.png" "scan"
	run_copy
	expect_status 0
	# Later nights keep the fallback and what is beside it.
	run_copy
	expect_status 0
	run_copy
	expect_status 0
	same "$targets/alice/2026/Land Registry/plan.png" "plan"
	same "$targets/alice/2026/Bank/scan.png" "scan"
	same "$targets/alice/2026/Bank/a.pdf" "a"
	# The archive version arrives: it replaces the fallback original.
	archive "alice/2026/Land Registry/plan.pdf" "plan-archived"
	run_copy
	expect_status 0
	same "$targets/alice/2026/Land Registry/plan.pdf" "plan-archived"
	absent "$targets/alice/2026/Land Registry/plan.png"
	# The original goes away in Paperless: the fallback goes with it, and the
	# folder that only it was in.
	rm -- "$media/documents/originals/alice/2026/Bank/scan.png"
	run_copy
	expect_status 0
	absent "$targets/alice/2026/Bank/scan.png"
	same "$targets/alice/2026/Bank/a.pdf" "a"
}

test_restore_deleted() {
	fresh
	mkdir -p "$targets/alice"
	archive "alice/2026/Bank/a.pdf" "a"
	original "alice/2026/Bank/b.png" "b"
	run_copy
	expect_status 0
	rm -- "$targets/alice/2026/Bank/a.pdf" "$targets/alice/2026/Bank/b.png"
	rm -- "$targets/alice/LIESMICH.txt"
	run_copy
	expect_status 0
	same "$targets/alice/2026/Bank/a.pdf" "a"
	same "$targets/alice/2026/Bank/b.png" "b"
	want "$targets/alice/LIESMICH.txt"
	# a changed copy is put back, and a file put there by hand goes
	printf 'changed' >"$targets/alice/2026/Bank/a.pdf"
	printf 'mine' >"$targets/alice/2026/mine.txt"
	mkdir -p "$targets/alice/my folder"
	run_copy
	expect_status 0
	same "$targets/alice/2026/Bank/a.pdf" "a"
	absent "$targets/alice/2026/mine.txt"
	absent "$targets/alice/my folder"
}

test_renamed_document() {
	fresh
	mkdir -p "$targets/alice"
	archive "alice/2026/Old Bank/2026-01-02 Old title.pdf" "doc"
	archive "alice/2026/Old Bank/2026-01-03 Stays.pdf" "stays"
	run_copy
	expect_status 0
	same "$targets/alice/2026/Old Bank/2026-01-02 Old title.pdf" "doc"
	# Paperless moves the file when the title changes ...
	mv "$media/documents/archive/alice/2026/Old Bank/2026-01-02 Old title.pdf" \
		"$media/documents/archive/alice/2026/Old Bank/2026-01-02 New title.pdf"
	run_copy
	expect_status 0
	same "$targets/alice/2026/Old Bank/2026-01-02 New title.pdf" "doc"
	absent "$targets/alice/2026/Old Bank/2026-01-02 Old title.pdf"
	# ... and when the correspondent changes, with the folder of the old one.
	mkdir -p "$media/documents/archive/alice/2026/New Bank"
	mv "$media/documents/archive/alice/2026/Old Bank/2026-01-02 New title.pdf" \
		"$media/documents/archive/alice/2026/New Bank/"
	mv "$media/documents/archive/alice/2026/Old Bank/2026-01-03 Stays.pdf" \
		"$media/documents/archive/alice/2026/New Bank/"
	rmdir "$media/documents/archive/alice/2026/Old Bank"
	run_copy
	expect_status 0
	same "$targets/alice/2026/New Bank/2026-01-02 New title.pdf" "doc"
	same "$targets/alice/2026/New Bank/2026-01-03 Stays.pdf" "stays"
	absent "$targets/alice/2026/Old Bank"
	[[ $(find "$targets/alice" -type f ! -name LIESMICH.txt | wc -l) == 2 ]]
}

test_refuse_missing_source() {
	fresh
	mkdir -p "$targets/alice"
	archive "alice/2026/Bank/a.pdf" "a"
	run_copy
	expect_status 0
	before=$(snapshot "$targets")
	# The media folder is not mounted: documents/archive is gone.
	rm -r -- "$media/documents"
	run_copy
	expect_status 3
	expect_err "refus"
	[[ $(snapshot "$targets") == "$before" ]]
	want "$targets/alice/2026/Bank/a.pdf"
	# The media folder itself is not there.
	run --media "$scratch/not-mounted" --targets "$targets"
	expect_status 3
	[[ $(snapshot "$targets") == "$before" ]]
}

test_refuse_empty_source() {
	fresh
	mkdir -p "$targets/alice"
	archive "alice/2026/Bank/a.pdf" "a"
	original "alice/2026/Bank/b.png" "b"
	run_copy
	expect_status 0
	before=$(snapshot "$targets")
	# documents/archive is there and empty, as an unmounted volume's mount point is.
	rm -r -- "$media/documents/archive"
	mkdir "$media/documents/archive"
	run_copy
	expect_status 3
	[[ $(snapshot "$targets") == "$before" ]]
	# Originals alone do not make the archive tree one.
	run_copy
	expect_status 3
	[[ $(snapshot "$targets") == "$before" ]]
}

test_empty_source_and_empty_targets_is_nothing_to_do() {
	fresh
	mkdir -p "$targets/alice"
	cat >"$bin/curl" <<-EOF
		#!$BASH
		echo called >>"$fake/curl.log"
	EOF
	chmod +x "$bin/curl"
	export KUMA_PUSH_URL=https://kuma.invalid/api/push/token
	# A new install with no documents: not a refusal, but nothing to report as done.
	run_copy
	expect_status 0
	[[ ! -e $fake/curl.log ]]
	# The notice is not "files"; an unmounted source still counts as empty.
	rm -r -- "$media/documents"
	run_copy
	expect_status 0
	[[ ! -e $fake/curl.log ]]
}

test_one_owner_empty_is_copied_empty() {
	fresh
	mkdir -p "$targets/alice" "$targets/bob"
	archive "alice/2026/a.pdf" "a"
	archive "bob/2026/b.pdf" "b"
	run_copy
	expect_status 0
	rm -r -- "$media/documents/archive/bob"
	run_copy
	expect_status 0
	want "$targets/alice/2026/a.pdf"
	absent "$targets/bob/2026"
}

test_stays_inside() {
	fresh
	put "$outside/keep.txt" "keep"
	put "$outside/dir/deep.txt" "deep"
	put "$scratch/sibling-file" "sibling"
	mkdir -p "$targets/alice"
	archive "alice/2026/Bank/a.pdf" "a"
	archive "alice/2026/clash.pdf" "from-archive"
	archive "alice/sub/inner.pdf" "inner"
	# Symlinks inside an owner's target: one to a directory, one to a file,
	# one at a name the source has as a file, one at a name it has as a folder.
	ln -s "$outside" "$targets/alice/out-dir"
	ln -s "$outside/keep.txt" "$targets/alice/out-file"
	mkdir -p "$targets/alice/2026"
	ln -s "$outside/keep.txt" "$targets/alice/2026/clash.pdf"
	ln -s "$outside" "$targets/alice/sub"
	# An owner that is a symlink to the targets' parent, a symlink to a
	# directory outside, and a file.
	ln -s .. "$targets/up"
	ln -s "$outside" "$targets/escape"
	printf 'x' >"$targets/stray-file"
	archive "up/2026/u.pdf" "u"
	archive "escape/2026/e.pdf" "e"
	run_copy
	# The owners that are symlinks are refused; alice is still copied.
	expect_status 3
	expect_err "up"
	expect_err "symlink"
	same "$outside/keep.txt" "keep"
	same "$outside/dir/deep.txt" "deep"
	same "$scratch/sibling-file" "sibling"
	[[ -d $outside/dir && $(find "$outside" -type f | wc -l) == 2 ]]
	absent "$outside/2026"
	absent "$scratch/2026"
	[[ -L $targets/up && -L $targets/escape ]]
	same "$targets/stray-file" "x"
	# alice: the symlinks are gone or replaced, never followed.
	same "$targets/alice/2026/Bank/a.pdf" "a"
	absent "$targets/alice/out-dir"
	absent "$targets/alice/out-file"
	same "$targets/alice/2026/clash.pdf" "from-archive"
	[[ -d $targets/alice/sub && ! -L $targets/alice/sub ]]
	same "$targets/alice/sub/inner.pdf" "inner"
	[[ -z $(find "$targets" -type l ! -name up ! -name escape) ]]
}

test_source_symlinks_stay_out() {
	fresh
	put "$outside/secret.txt" "secret"
	mkdir -p "$targets/alice" "$targets/bob" "$targets/carol"
	archive "alice/2026/a.pdf" "a"
	ln -s "$outside/secret.txt" "$media/documents/archive/alice/2026/leak.pdf"
	ln -s "$outside" "$media/documents/archive/alice/2026/leakdir"
	original "alice/2026/o.png" "o"
	ln -s "$outside/secret.txt" "$media/documents/originals/alice/2026/leak.png"
	mkfifo "$media/documents/archive/alice/2026/fifo.pdf"
	# an owner whose whole source folder is a symlink
	ln -s "$outside" "$media/documents/archive/bob"
	archive "carol/c.pdf" "c"
	run_copy
	expect_status 3
	expect_err "bob"
	same "$targets/alice/2026/a.pdf" "a"
	same "$targets/alice/2026/o.png" "o"
	absent "$targets/alice/2026/leak.pdf"
	absent "$targets/alice/2026/leak.png"
	absent "$targets/alice/2026/leakdir"
	absent "$targets/alice/2026/fifo.pdf"
	never command grep -rlq secret "$targets"
	[[ -z $(find "$targets/bob" -type f ! -name LIESMICH.txt) ]]
	# the other owners are not held back by the refused one
	same "$targets/carol/c.pdf" "c"
}

test_umlaut_path() {
	fresh
	mkdir -p "$targets/alice"
	# composed and decomposed umlauts, an ampersand, spaces, a division slash
	# (U+2215, which looks like a / and is not one), a colon and a quote.
	names=(
		"Müller & Söhne/2026-07-14 Prüfung.pdf"
		"Mu"$'̈'"ller/2026-07-14 Pru"$'̈'"fung.pdf"
		"Stadtwerke/2026-08-01 Rechnung 3∕4: \"Strom\" ß.pdf"
		"A  B/ leading and trailing .pdf"
	)
	for n in "${names[@]}"; do archive "alice/2026/$n" "x-$n"; done
	original "alice/2026/Hausmeister Löffel/2026-09-09 Übergabe.jpg" "j"
	run_copy
	expect_status 0
	for n in "${names[@]}"; do same "$targets/alice/2026/$n" "x-$n"; done
	same "$targets/alice/2026/Hausmeister Löffel/2026-09-09 Übergabe.jpg" "j"
	# byte for byte: the same names in both trees, no normalization
	diff <(cd "$media/documents/archive/alice" && find . -type f -print0 | sort -z | tr '\0' '\n') \
		<(cd "$targets/alice" && find . -type f ! -name LIESMICH.txt ! -name '*.jpg' -print0 | sort -z | tr '\0' '\n' | command grep -v Löffel)
	# a name with a newline in it
	archive "alice/2026/line"$'\n'"break.pdf" "nl"
	run_copy
	expect_status 0
	same "$targets/alice/2026/line"$'\n'"break.pdf" "nl"
}

test_wildcards_in_names() {
	fresh
	mkdir -p "$targets/alice"
	archive "alice/2026/[a]*?x.pdf" "star"
	original "alice/2026/[b]*?y.png" "star-original"
	archive "alice/2026/ax.pdf" "plain"
	run_copy
	run_copy
	expect_status 0
	same "$targets/alice/2026/[a]*?x.pdf" "star"
	same "$targets/alice/2026/[b]*?y.png" "star-original"
	same "$targets/alice/2026/ax.pdf" "plain"
}

test_files_are_readable() {
	fresh
	mkdir -p "$targets/alice"
	archive "alice/2026/a.pdf" "a"
	original "alice/2026/b.png" "b"
	chmod 600 "$media/documents/archive/alice/2026/a.pdf" "$media/documents/originals/alice/2026/b.png"
	chmod 700 "$media/documents/archive/alice/2026"
	run_copy
	expect_status 0
	[[ $(stat -c %a "$targets/alice/2026/a.pdf") == 644 ]]
	[[ $(stat -c %a "$targets/alice/2026/b.png") == 644 ]]
	[[ $(stat -c %a "$targets/alice/2026") == 755 ]]
	[[ $(stat -c %a "$targets/alice/LIESMICH.txt") == 644 ]]
	# a read-only copy (mode 644 is what the owner gets) is replaced by the
	# next run when the document changes
	printf 'new' >"$media/documents/archive/alice/2026/a.pdf"
	touch -d '+1 hour' "$media/documents/archive/alice/2026/a.pdf"
	run_copy
	expect_status 0
	same "$targets/alice/2026/a.pdf" "new"
}

test_liesmich() {
	fresh
	mkdir -p "$targets/alice" "$targets/bob"
	archive "alice/2026/a.pdf" "a"
	run_copy
	expect_status 0
	for o in alice bob; do
		f="$targets/$o/LIESMICH.txt"
		want "$f"
		[[ $(<"$f") == *"überschrieben"* ]]
		[[ $(<"$f") == *"Paperless"* ]]
		[[ $(<"$f") == *"Archiv"* ]]
		[[ $(<"$f") == *"nur gelesen"* || $(<"$f") == *"Nur lesen"* || $(<"$f") == *"nur zum Lesen"* ]]
	done
	# a second run leaves it alone and a new owner folder gets one
	mkdir "$targets/carol"
	archive "carol/c.pdf" "c"
	run_copy
	expect_status 0
	want "$targets/carol/LIESMICH.txt"
	same "$targets/alice/LIESMICH.txt" "$(<"$targets/bob/LIESMICH.txt")"
}

test_no_leftovers() {
	fresh
	mkdir -p "$targets/alice"
	archive "alice/2026/a.pdf" "a"
	original "alice/2026/b.png" "b"
	run_copy
	expect_status 0
	[[ -z $(ls -A "$tmp") ]]
	# also when the copy fails: a document that cannot be read
	archive "alice/2026/c.pdf" "c"
	chmod 000 "$media/documents/archive/alice/2026/c.pdf"
	run_copy
	chmod 600 "$media/documents/archive/alice/2026/c.pdf"
	expect_status 1
	[[ -z $(ls -A "$tmp") ]]
}

test_failed_copy_exits_1() {
	fresh
	mkdir -p "$targets/alice" "$targets/bob"
	archive "alice/2026/a.pdf" "a"
	archive "bob/2026/b.pdf" "b"
	# one of alice's documents cannot be read; bob's can
	archive "alice/2026/unreadable.pdf" "u"
	chmod 000 "$media/documents/archive/alice/2026/unreadable.pdf"
	cat >"$bin/curl" <<-EOF
		#!$BASH
		echo called >>"$fake/curl.log"
	EOF
	chmod +x "$bin/curl"
	export KUMA_PUSH_URL=https://kuma.invalid/api/push/token
	run_copy
	chmod 600 "$media/documents/archive/alice/2026/unreadable.pdf"
	expect_status 1
	expect_err "alice"
	same "$targets/bob/2026/b.pdf" "b"
	[[ ! -e $fake/curl.log ]]
}

test_no_owner_folders_no_work() {
	# no directories in --targets: no owners, no work, and not a failure
	fresh
	run_copy
	expect_status 0
	[[ -z $(ls -A "$targets") ]]
}

# ── the push ──────────────────────────────────────────────────────────────

# curl: records its arguments and what it reads from standard input, ends with
# the status in curl.status.
curl_stub() {
	cat >"$bin/curl" <<-EOF
		#!$BASH
		printf '%s\n' "\$*" >>"$fake/curl.args"
		cat >>"$fake/curl.stdin"
		echo >>"$fake/curl.stdin"
		exit "\$(cat "$fake/curl.status" 2>/dev/null || echo 0)"
	EOF
	chmod +x "$bin/curl"
}

test_push_on_success() {
	fresh
	curl_stub
	mkdir -p "$targets/alice"
	archive "alice/2026/a.pdf" "a"
	export KUMA_PUSH_URL='https://kuma.invalid/api/push/SecretToken123?status=up&msg=OK&ping='
	run_copy
	expect_status 0
	[[ $(wc -l <"$fake/curl.args") == 1 ]]
	# the token is not on the command line, nor in the output
	[[ $(<"$fake/curl.args") != *SecretToken123* ]]
	[[ $(<"$fake/curl.stdin") == *SecretToken123* ]]
	[[ $(<"$fake/curl.stdin") == *'status=up&msg=OK&ping='* ]]
	expect_no_out SecretToken123
	expect_no_err SecretToken123
}

test_no_push_when_unset_or_empty() {
	fresh
	curl_stub
	mkdir -p "$targets/alice"
	archive "alice/2026/a.pdf" "a"
	run_copy
	expect_status 0
	KUMA_PUSH_URL='' run_copy
	expect_status 0
	[[ ! -e $fake/curl.args ]]
}

test_no_push_on_refusal() {
	fresh
	curl_stub
	mkdir -p "$targets/alice"
	archive "alice/2026/a.pdf" "a"
	export KUMA_PUSH_URL='https://kuma.invalid/api/push/SecretToken123'
	run_copy
	expect_status 0
	rm -f "$fake/curl.args"
	rm -r -- "$media/documents"
	run_copy
	expect_status 3
	ln -s "$outside" "$targets/bad"
	mkdir -p "$media/documents/archive/alice/2026"
	archive "alice/2026/a.pdf" "a"
	run_copy
	expect_status 3
	[[ ! -e $fake/curl.args ]]
}

test_failed_push_is_said_not_fatal() {
	fresh
	curl_stub
	echo 22 >"$fake/curl.status"
	mkdir -p "$targets/alice"
	archive "alice/2026/a.pdf" "a"
	export KUMA_PUSH_URL='https://kuma.invalid/api/push/SecretToken123'
	run_copy
	expect_status 0
	expect_err "push"
	expect_no_err SecretToken123
	expect_no_out SecretToken123
}

test_push_url_with_quote_is_refused() {
	fresh
	curl_stub
	mkdir -p "$targets/alice"
	archive "alice/2026/a.pdf" "a"
	# a value that would add a line to curl's config
	export KUMA_PUSH_URL=$'https://kuma.invalid/x"\noutput = "/tmp/evil'
	run_copy
	expect_status 0
	[[ ! -e $fake/curl.stdin ]]
	expect_err "KUMA_PUSH_URL"
	expect_no_err evil
}

# ── the loop ──────────────────────────────────────────────────────────────

# sleep: logs its argument; the third call stops the loop by killing its parent.
sleep_stub() {
	cat >"$bin/sleep" <<-EOF
		#!$BASH
		echo "\$1" >>"$fake/sleep.log"
		n=\$(wc -l <"$fake/sleep.log")
		if ((n >= ${1:-3})); then kill -TERM "\$PPID"; fi
		exit 0
	EOF
	chmod +x "$bin/sleep"
}

test_loop_runs_each_round_and_sleeps_until_at() {
	fresh
	sleep_stub 3
	mkdir -p "$targets/alice"
	archive "alice/2026/a.pdf" "a"
	local at
	at=$(date -d '+2 hours' +%H:%M)
	capture timeout 20 "$SUT" --media "$media" --targets "$targets" --at "$at"
	# ended by the stub's SIGTERM, not by timeout (124) or an error
	[[ $status == 143 || $status == 0 ]]
	same "$targets/alice/2026/a.pdf" "a"
	[[ $(wc -l <"$fake/sleep.log") == 3 ]]
	# the first sleep is the wait to the next HH:MM, within the minute
	first=$(head -n 1 "$fake/sleep.log")
	((first >= 7140 && first <= 7260)) || {
		echo "  slept $first s for $at, now+2h"
		return 1
	}
}

test_loop_does_nothing_before_the_first_at() {
	fresh
	cat >"$bin/sleep" <<-EOF
		#!$BASH
		echo "\$1" >>"$fake/sleep.log"
		[[ -e "$targets/alice/2026" ]] && echo copied-before-sleep >>"$fake/early"
		kill -TERM "\$PPID"
		exit 0
	EOF
	chmod +x "$bin/sleep"
	mkdir -p "$targets/alice"
	archive "alice/2026/a.pdf" "a"
	capture timeout 20 "$SUT" --media "$media" --targets "$targets" --at "$(date -d '+3 hours' +%H:%M)"
	# the stub was reached, so the loop did sleep, and nothing had been copied
	[[ -s $fake/sleep.log ]]
	[[ ! -e $fake/early ]]
	absent "$targets/alice/2026"
}

test_loop_wraps_to_tomorrow() {
	fresh
	sleep_stub 1
	mkdir -p "$targets/alice"
	archive "alice/2026/a.pdf" "a"
	# one minute ago: the next one is tomorrow's, about a day away
	local at
	at=$(date -d '-1 minute' +%H:%M)
	capture timeout 20 "$SUT" --media "$media" --targets "$targets" --at "$at"
	first=$(head -n 1 "$fake/sleep.log")
	((first >= 86400 - 180 && first <= 86400 + 3600)) || {
		echo "  slept $first s for $at, a minute ago"
		return 1
	}
}

test_loop_survives_a_refusal() {
	fresh
	sleep_stub 2
	mkdir -p "$targets/alice"
	archive "alice/2026/a.pdf" "a"
	# The first round runs when the stub's first sleep returns.
	capture timeout 20 "$SUT" --media "$media" --targets "$targets" --at "$(date -d '+2 hours' +%H:%M)"
	rm -r -- "$media/documents"
	rm -f "$fake/sleep.log"
	capture timeout 20 "$SUT" --media "$media" --targets "$targets" --at "$(date -d '+2 hours' +%H:%M)"
	[[ $(wc -l <"$fake/sleep.log") == 2 ]]
	want "$targets/alice/2026/a.pdf"
}

test_default_at_is_0330_berlin() {
	fresh
	sleep_stub 1
	# no TZ in the environment: Berlin's clock
	capture env -u TZ timeout 20 "$SUT" --media "$media" --targets "$targets"
	first=$(head -n 1 "$fake/sleep.log")
	want=$(($(TZ=Europe/Berlin date -d '03:30' +%s) - $(date +%s)))
	((want > 0)) || want=$(($(TZ=Europe/Berlin date -d 'tomorrow 03:30' +%s) - $(date +%s)))
	((first >= want - 3 && first <= want + 3)) || {
		echo "  slept $first s, 03:30 Berlin is $want s away"
		return 1
	}
	# the clock is TZ's: 03:30 in Tokyo is not 03:30 in Berlin
	rm -f "$fake/sleep.log"
	TZ=Asia/Tokyo capture timeout 20 "$SUT" --media "$media" --targets "$targets"
	first=$(head -n 1 "$fake/sleep.log")
	want=$(($(TZ=Asia/Tokyo date -d '03:30' +%s) - $(date +%s)))
	((want > 0)) || want=$(($(TZ=Asia/Tokyo date -d 'tomorrow 03:30' +%s) - $(date +%s)))
	((first >= want - 3 && first <= want + 3)) || {
		echo "  slept $first s, 03:30 Tokyo is $want s away"
		return 1
	}
}

# ── usage ─────────────────────────────────────────────────────────────────

test_usage() {
	fresh
	capture "$SUT"
	expect_status 2
	expect_err "usage"
	capture "$SUT" --once --media "$media"
	expect_status 2
	capture "$SUT" --once --targets "$targets"
	expect_status 2
	capture "$SUT" --once --media "$media" --targets "$targets" --bogus
	expect_status 2
	# the push URL is a token: no option takes it on the command line
	capture "$SUT" --once --media "$media" --targets "$targets" --push-url https://kuma.invalid/x
	expect_status 2
	capture "$SUT" --once --media "$media" --targets "$targets" --push-url-file /dev/null
	expect_status 2
	capture "$SUT" --media "$media" --targets "$targets" --at 25:00
	expect_status 2
	capture "$SUT" --media "$media" --targets "$targets" --at 3:30
	expect_status 2
	capture "$SUT" --media "$media" --targets "$targets" --at ''
	expect_status 2
	capture "$SUT" --once --media "$media" --targets
	expect_status 2
	capture "$SUT" --once --media "$media" --targets "$scratch/no-such-dir"
	expect_status 2
	expect_err "no-such-dir"
	capture "$SUT" --help
	expect_status 0
	expect_out "usage"
}

tests=(
	test_per_owner
	test_owner_names_are_just_names
	test_original_fallback
	test_fallback_survives_the_delete_pass
	test_restore_deleted
	test_renamed_document
	test_refuse_missing_source
	test_refuse_empty_source
	test_empty_source_and_empty_targets_is_nothing_to_do
	test_one_owner_empty_is_copied_empty
	test_stays_inside
	test_source_symlinks_stay_out
	test_umlaut_path
	test_wildcards_in_names
	test_files_are_readable
	test_liesmich
	test_no_leftovers
	test_failed_copy_exits_1
	test_no_owner_folders_no_work
	test_push_on_success
	test_no_push_when_unset_or_empty
	test_no_push_on_refusal
	test_failed_push_is_said_not_fatal
	test_push_url_with_quote_is_refused
	test_loop_runs_each_round_and_sleeps_until_at
	test_loop_does_nothing_before_the_first_at
	test_loop_wraps_to_tomorrow
	test_loop_survives_a_refusal
	test_default_at_is_0330_berlin
	test_usage
)
run_tests "${tests[@]}"
