#!/usr/bin/env bash
# Tests for the shell functions of modules/common/bash/: the ones ported from
# the Fedora .bashrc, and ai-unlock. Each test runs the function in a fresh
# bash that has sourced the files, with stand-in tools on PATH that record
# their arguments in $scratch/calls. Run it with git, jq, file, script, awk
# and sort on PATH:
#
#   bash tests/common/helpers/functions.test.bash modules/common/bash
#
# It prints PASS or FAIL per test and exits non-zero if any test failed.

# The test scripts hand strings to a bash -c; they are data for that shell.
# shellcheck disable=SC2016

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/tests/lib.sh
. "$here/../../../scripts/tests/lib.sh"

dir="$(cd "${1:?usage: functions.test.bash MODULE_BASH_DIR}" && pwd)"
bin="$scratch/bin"
calls="$scratch/calls"
mkdir -p "$bin"
: >"$calls"

# A stand-in tool: records its name and arguments, one call per line with the
# arguments separated by '|', and then runs the optional body lines.
stub() {
	local name="$1"
	shift
	write_script "$bin/$name" \
		'IFS="|"; printf "%s|%s\n" "'"$name"'" "$*" >>"'"$calls"'"' \
		"$@"
}

# Runs SCRIPT in a bash that has sourced the module's files, in the current
# directory, with the stand-ins first on PATH.
run() {
	capture env PATH="$bin:$PATH" LC_ALL=C.UTF-8 XDG_CACHE_HOME="$scratch/cache" \
		HOME="$scratch/home" \
		bash -c '
			for f in "$1"/functions.bash "$1"/secrets.bash; do
				. "$f" || exit 99
			done
			shift
			eval "$1"
		' bash "$dir" "$1" </dev/null
}

# Whether the stand-ins were called with exactly these arguments.
called() {
	grep -qxF -- "$1" "$calls" || {
		echo "  expected the call '$1'; calls were:"
		sed 's/^/    /' "$calls"
		return 1
	}
}
# Whether the stand-in NAME was never called.
not_called() {
	! grep -q -- "^$1|" "$calls" || {
		echo "  expected no call of '$1'; calls were:"
		sed 's/^/    /' "$calls"
		return 1
	}
}

# Whether the stand-ins were never called with a first word matching the
# extended regular expression $1 (a call is "name|arguments").
never_called() {
	if grep -qE -- "^($1)(\||\$)" "$calls"; then
		echo "  expected no call matching '$1'; calls were:"
		sed 's/^/    /' "$calls"
		return 1
	fi
}

setup() {
	rm -r -- "${scratch:?}/home" "${scratch:?}/cache" "${scratch:?}/work" "${scratch:?}/rbw" 2>/dev/null || true
	rm -f -- "${bin:?}"/*
	mkdir -p "$scratch/home" "$scratch/cache" "$scratch/work"
	: >"$calls"
	rm -f -- "${scratch:?}"/claude.*
	unset TERM_PROGRAM CLAUDECODE
	cd "$scratch/work"
}

# A repository at $1 with one commit on main.
new_repo() {
	git init -q -b main "$1"
	git -C "$1" config user.name t
	git -C "$1" config user.email t@example.org
	git -C "$1" config commit.gpgsign false
	git -C "$1" commit -q --allow-empty -m init
}

# A clone of a fresh repository, as new_repo makes it, at $2.
new_clone() {
	new_repo "$1"
	git clone -q "$1" "$2"
	git -C "$2" config user.name t
	git -C "$2" config user.email t@example.org
	git -C "$2" config commit.gpgsign false
}

# --- over ---------------------------------------------------------------

over_prints_the_lines_wider_than_eighty_with_their_numbers() {
	setup
	printf 'short\n%81s\nalso short\n%90s\n' x y >in.txt
	run 'over 80 in.txt'
	expect_status 0
	expect_lines 2
	[[ "$(printf '%s\n' "$out" | cut -c1-5)" == $'   2 \n   4 ' ]]
}

over_takes_the_width_and_reads_stdin() {
	setup
	run 'printf "abc\nabcdef\n" | over 4'
	expect_status 0
	expect_out '   2 abcdef'
	expect_lines 1
}

over_counts_a_tab_as_the_columns_it_occupies() {
	setup
	# A tab at the start occupies 8 columns, so the line is 9 wide.
	run 'printf "\tx\n" | over 8; printf "\tx\n" | over 9'
	expect_status 0
	expect_out '   1 '
	expect_lines 1
}

over_on_empty_input_prints_nothing() {
	setup
	run 'printf "" | over'
	expect_status 0
	[[ -z "$out" ]]
}

over_counts_characters_and_not_bytes() {
	setup
	# 80 umlauts are 160 bytes and 80 columns.
	run 'awk "BEGIN { for (i = 0; i < 80; i++) printf \"ä\"; print \"\" }" | over'
	expect_status 0
	[[ -z "$out" ]]
}

# --- gr, gmb, gbd, gsm, gmm ---------------------------------------------

gr_goes_to_the_root_or_below_it() {
	setup
	new_repo repo
	mkdir -p repo/sub/deeper "repo/with space"
	cd repo/sub/deeper
	run 'gr; pwd; gr sub/deeper; pwd; gr "with space"; pwd'
	expect_status 0
	[[ "$out" == "$scratch/work/repo"$'\n'"$scratch/work/repo/sub/deeper"$'\n'"$scratch/work/repo/with space" ]]
}

gr_outside_a_repository_stays_and_fails() {
	setup
	run 'gr; echo "after $?"; pwd'
	expect_status 0
	expect_said 'not a git repository'
	expect_out "$scratch/work"
	expect_no_out 'after 0'
}

gr_uses_the_builtin_cd_even_when_cd_is_something_else() {
	setup
	new_repo repo
	mkdir repo/sub
	cd repo/sub
	# cd is zd on the laptop, which would hand a missing directory to zoxide.
	run 'cd() { echo CD-CALLED; }; gr; pwd'
	expect_status 0
	expect_no_out CD-CALLED
	expect_out "$scratch/work/repo"
}

gmb_names_the_main_branch_from_origin_head() {
	setup
	new_clone up repo
	run 'cd repo && gmb'
	expect_status 0
	[[ "$out" == main ]]
}

gmb_keeps_a_slash_in_the_branch_name() {
	setup
	new_repo repo
	git -C repo update-ref refs/remotes/origin/release/1 HEAD
	git -C repo symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/release/1
	run 'cd repo && gmb'
	expect_status 0
	[[ "$out" == release/1 ]]
}

gmb_without_origin_head_says_what_to_do() {
	setup
	new_repo repo
	run 'cd repo && gmb; echo "status $?"'
	expect_said 'origin/HEAD is not set'
	expect_said 'git remote set-head origin --auto'
	expect_out 'status 1'
}

gmb_outside_a_repository_fails() {
	setup
	run 'gmb; echo "status $?"'
	expect_out 'status 1'
}

gbd_shows_what_the_branch_changed_and_not_what_main_gained() {
	setup
	new_clone up repo
	git -C repo switch -q -c topic
	echo topic >repo/topic.txt
	git -C repo add topic.txt
	git -C repo commit -q -m topic
	git -C repo switch -q main
	echo gained >repo/gained.txt
	git -C repo add gained.txt
	git -C repo commit -q -m gained
	git -C repo switch -q topic
	run 'cd repo && gbd | command cat'
	expect_status 0
	expect_out 'topic.txt'
	expect_no_out 'gained.txt'
}

gsm_switches_to_main_and_pulls() {
	setup
	new_clone up repo
	git -C repo switch -q -c topic
	git -C up commit -q --allow-empty -m "newer on the remote"
	run 'cd repo && gsm && git branch --show-current && git log -1 --format=%s'
	expect_status 0
	expect_out $'main\nnewer on the remote'
}

gmm_merges_main_into_the_branch() {
	setup
	new_clone up repo
	git -C repo switch -q -c topic
	git -C repo commit -q --allow-empty -m "on topic"
	git -C repo switch -q main
	git -C repo commit -q --allow-empty -m "on main"
	git -C repo switch -q topic
	run 'cd repo && gmm >/dev/null && git log --format=%s | tr "\n" ,'
	expect_status 0
	expect_out 'on main'
	expect_out 'on topic'
}

# --- gho ----------------------------------------------------------------

gho_builds_a_github_url_from_an_scp_remote_and_opens_it() {
	setup
	new_repo repo
	git -C repo remote add origin git@github.com:alice/proj.git
	run 'open() { echo "OPEN $1"; }; cd repo && gho'
	expect_status 0
	[[ "$out" == $'https://github.com/alice/proj/tree/main\nOPEN https://github.com/alice/proj/tree/main' ]]
}

gho_builds_a_forgejo_url_from_an_ssh_remote_and_drops_the_port() {
	setup
	new_repo repo
	git -C repo remote add origin ssh://git@forge.example.org:2222/alice/proj.git
	run 'open() { :; }; cd repo && gho'
	expect_status 0
	[[ "$out" == https://forge.example.org/alice/proj/src/branch/main ]]
}

gho_uses_blob_for_a_file_and_the_path_below_the_repository() {
	setup
	new_repo repo
	mkdir -p repo/sub
	: >repo/sub/a.txt
	git -C repo remote add origin https://github.com/alice/proj
	run 'open() { :; }; cd repo/sub && gho a.txt; gho'
	expect_status 0
	[[ "$out" == $'https://github.com/alice/proj/blob/main/sub/a.txt\nhttps://github.com/alice/proj/tree/main/sub' ]]
}

gho_takes_a_dot_for_the_directory_it_is_in() {
	setup
	new_repo repo
	mkdir -p repo/sub
	git -C repo remote add origin https://github.com/alice/proj
	run 'open() { :; }; cd repo/sub && gho .; cd .. && gho .'
	expect_status 0
	[[ "$out" == $'https://github.com/alice/proj/tree/main/sub\nhttps://github.com/alice/proj/tree/main' ]]
}

gho_escapes_spaces_in_the_path() {
	setup
	new_repo repo
	mkdir "repo/a dir"
	git -C repo remote add origin https://github.com/alice/proj
	run 'open() { :; }; cd repo && gho "a dir"'
	expect_out 'https://github.com/alice/proj/tree/main/a%20dir'
}

gho_names_the_commit_when_head_is_detached() {
	setup
	new_repo repo
	git -C repo remote add origin https://forge.example.org/alice/proj.git
	git -C repo checkout -q --detach
	run 'open() { :; }; cd repo && gho'
	expect_out "https://forge.example.org/alice/proj/src/commit/$(git -C repo rev-parse HEAD)"
}

gho_takes_another_remote() {
	setup
	new_repo repo
	git -C repo remote add origin https://github.com/alice/proj
	git -C repo remote add backup https://forge.example.org/alice/proj
	run 'open() { :; }; cd repo && gho "" backup'
	expect_out 'https://forge.example.org/alice/proj/src/branch/main'
}

gho_without_the_remote_fails_and_opens_nothing() {
	setup
	new_repo repo
	run 'open() { echo OPENED; }; cd repo && gho; echo "status $?"'
	expect_said "no remote named 'origin'"
	expect_no_out OPENED
	expect_out 'status 1'
}

gho_refuses_a_remote_url_it_cannot_read() {
	setup
	new_repo repo
	git -C repo remote add origin 'not a url'
	run 'open() { echo OPENED; }; cd repo && gho; echo "status $?"'
	expect_said 'cannot read the remote URL'
	expect_no_out OPENED
	expect_out 'status 1'
}

# --- open, sudo, sff ----------------------------------------------------

open_returns_at_once_and_stays_silent() {
	setup
	stub xdg-open 'echo noise; echo more >&2; sleep 2'
	local start=$SECONDS
	run 'open "a file.txt" https://example.org'
	expect_status 0
	[[ -z "$out" && -z "$err" ]]
	((SECONDS - start < 2))
	# The call is written by the background job; wait for it, up to 10 s,
	# instead of guessing how long a loaded builder needs.
	local _
	for _ in $(seq 100); do
		grep -qxF 'xdg-open|a file.txt|https://example.org' "$calls" && break
		sleep 0.1
	done
	called 'xdg-open|a file.txt|https://example.org'
}

sudo_nvim_with_a_file_becomes_sudoedit() {
	setup
	stub sudo
	stub sudoedit
	run 'sudo nvim /etc/hosts "/etc/a b"'
	expect_status 0
	called 'sudoedit|/etc/hosts|/etc/a b'
	not_called sudo
}

sudo_leaves_every_other_call_to_sudo() {
	setup
	stub sudo
	stub sudoedit
	run 'sudo nvim; sudo ls -l /root; sudo -u bob nvim file; sudo'
	expect_status 0
	called 'sudo|nvim'
	called 'sudo|ls|-l|/root'
	called 'sudo|-u|bob|nvim|file'
	called 'sudo|'
	not_called sudoedit
}

sff_wants_a_destination() {
	setup
	run 'sff; echo "status $?"'
	expect_out 'Usage: sff <destination>'
	expect_out 'status 1'
}

# --- zd -----------------------------------------------------------------

zd_goes_home_into_a_directory_or_asks_zoxide() {
	setup
	mkdir -p "$scratch/home/sub"
	run 'z() { echo "Z $*"; return 0; }
		zd; pwd; zd "$HOME/sub"; pwd; zd nowhere dir; pwd'
	expect_status 0
	[[ "$out" == "$scratch/home"$'\n'"$scratch/home/sub"$'\n'"Z nowhere dir"$'\n'"$scratch/home/sub" ]]
}

zd_reports_a_directory_zoxide_does_not_know() {
	setup
	run 'z() { return 1; }; zd nowhere; echo "status $?"'
	expect_out 'Error: Directory not found'
	expect_out 'status 1'
}

zd_enters_a_directory_with_an_odd_name_without_asking_zoxide() {
	setup
	mkdir -- "-odd" "a b"
	run 'z() { echo ZOXIDE; }; zd ./-odd; pwd; cd "$OLDPWD"; zd "a b"; pwd'
	expect_no_out ZOXIDE
	expect_out "$scratch/work/-odd"
	expect_out "$scratch/work/a b"
}

# --- ob, ot -------------------------------------------------------------

ob_builds_the_package_in_the_directory() {
	setup
	stub odin
	mkdir pkg
	run 'ob pkg'
	expect_status 0
	called "odin|build|.|-vet"
}

ob_names_the_output_before_or_after_the_directory() {
	setup
	stub odin
	mkdir pkg
	run 'ob -o tool pkg; ob pkg -o sub/tool; ob -o /abs/tool pkg'
	expect_status 0
	called 'odin|build|.|-vet|-out:tool'
	called "odin|build|.|-vet|-out:$scratch/work/sub/tool"
	called 'odin|build|.|-vet|-out:/abs/tool'
}

ob_wants_one_directory_and_a_name_for_o() {
	setup
	stub odin
	run 'ob a b; echo "status $?"'
	expect_said 'ob: one directory only'
	expect_out 'status 2'
	run 'ob -o; echo "status $?"'
	expect_said 'ob: -o needs a file name'
	not_called odin
}

ob_does_not_move_the_callers_directory() {
	setup
	stub odin
	mkdir pkg
	run 'ob pkg; pwd'
	expect_out "$scratch/work"
}

ot_runs_the_tests_of_the_package_or_its_tests_folder() {
	setup
	stub odin
	mkdir -p plain withdir/tests
	run 'ot plain; ot withdir'
	expect_status 0
	called 'odin|test|.'
	called 'odin|test|tests'
}

ot_with_b_builds_first_and_tests_only_when_the_build_passed() {
	setup
	stub odin 'case "$1" in build) exit 1 ;; esac'
	mkdir pkg
	run 'ot -b pkg; echo "status $?"'
	expect_out 'status 1'
	called 'odin|build|.|-vet'
	never_called 'odin\|test'
}

# --- cat ----------------------------------------------------------------

png() {
	printf '\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1f\x15\xc4\x89' >"$1"
}

# Runs cat in a pseudo terminal (script), because it draws images only when
# stdout is a terminal.
cat_on_a_tty() {
	capture env PATH="$bin:$PATH" LC_ALL=C.UTF-8 HOME="$scratch/home" COLUMNS=100 \
		TERM_PROGRAM="${TERM_PROGRAM-}" \
		script -qec "bash -c '. \"$dir\"/functions.bash; $1'" /dev/null
}

cat_sends_text_and_pipes_to_bat() {
	setup
	stub bat
	stub chafa
	: >text.txt
	run 'cat text.txt other.txt; cat < text.txt | cat'
	expect_status 0
	called 'bat|text.txt|other.txt'
	called 'bat|'
	not_called chafa
}

cat_sends_a_text_file_on_a_terminal_to_bat_too() {
	setup
	stub bat
	stub chafa
	: >text.txt
	cat_on_a_tty 'cat text.txt'
	called 'bat|text.txt'
	not_called chafa
}

cat_draws_images_on_a_terminal_half_the_width() {
	setup
	stub bat
	stub chafa
	png a.png
	png b.png
	cat_on_a_tty 'cat a.png b.png'
	called 'chafa|-c|full|--animate=off|--scale|max|--view-size|50x|--|a.png|b.png'
	not_called bat
}

cat_forces_the_kitty_protocol_under_herdr_and_ghostty() {
	setup
	stub bat
	stub chafa
	png a.png
	TERM_PROGRAM=ghostty cat_on_a_tty 'cat a.png'
	called 'chafa|-f|kitty|-c|full|--animate=off|--scale|max|--view-size|50x|--|a.png'
	: >"$calls"
	TERM_PROGRAM=herdr cat_on_a_tty 'cat a.png'
	called 'chafa|-f|kitty|-c|full|--animate=off|--scale|max|--view-size|50x|--|a.png'
}

cat_takes_a_size_for_the_image_as_its_first_argument() {
	setup
	stub bat
	stub chafa
	png a.png
	cat_on_a_tty 'cat -s 40x20 a.png; cat --size=30 a.png'
	called 'chafa|-c|full|--animate=off|--scale|max|-s|40x20|--|a.png'
	called 'chafa|-c|full|--animate=off|--scale|max|-s|30|--|a.png'
}

cat_hands_a_mix_of_text_and_images_to_bat_whole() {
	setup
	stub bat
	stub chafa
	png a.png
	: >text.txt
	cat_on_a_tty 'cat a.png text.txt'
	called 'bat|a.png|text.txt'
	not_called chafa
}

cat_hands_a_missing_file_or_an_option_to_bat() {
	setup
	stub bat
	stub chafa
	cat_on_a_tty 'cat nothing.png; cat -n x.png'
	called 'bat|nothing.png'
	called 'bat|-n|x.png'
	not_called chafa
}

cat_without_arguments_reads_stdin_through_bat() {
	setup
	stub bat
	stub chafa
	cat_on_a_tty 'cat </dev/null'
	called 'bat|'
	not_called chafa
}

# --- ai-unlock, claude --------------------------------------------------

# A stand-in rbw whose behavior the test sets in files under $scratch/rbw/:
#   sync        its exit code ("0" by default) and sync.msg its stderr
#   unlock      its exit code ("0" by default)
#   unlocked    its exit code ("0" by default)
#   config.json what `rbw config show` prints (a default account if missing)
#   items/NAME  the secret rbw get prints for the item NAME (a missing file is
#               an item that does not exist)
# Like the real one it may read its standard input, which `get` does here:
# a caller that leaves its own input open to rbw loses it. And `get` records,
# as "rbwenv|N" in $calls, how many of A_TOKEN and B_TOKEN it finds in its own
# environment.
fake_rbw() {
	mkdir -p "$scratch/rbw/items"
	write_script "$bin/rbw" \
		'IFS="|"; printf "rbw|%s\n" "$*" >>"'"$calls"'"' \
		'r="'"$scratch"'/rbw"' \
		'case "$1" in' \
		'sync) [ -f "$r/sync.msg" ] && cat "$r/sync.msg" >&2; exit "$(cat "$r/sync" 2>/dev/null || echo 0)" ;;' \
		'unlock) exit "$(cat "$r/unlock" 2>/dev/null || echo 0)" ;;' \
		'unlocked) exit "$(cat "$r/unlocked" 2>/dev/null || echo 0)" ;;' \
		'stop-agent) exit 0 ;;' \
		'config) if [ -f "$r/config.json" ]; then cat "$r/config.json"; else printf "{\"base_url\":\"https://vault.example.org\",\"email\":\"alice@example.org\"}\n"; fi ;;' \
		'get) cat >/dev/null; printf "rbwenv|%s\n" "$(env | grep -cE "^(A|B)_TOKEN=")" >>"'"$calls"'"; shift; [ "$1" = -- ] && shift; [ -f "$r/items/$1" ] && { cat "$r/items/$1"; exit 0; }; echo "no item $1" >&2; exit 1 ;;' \
		'esac'
}

# A stand-in claude: it writes its environment (NUL-separated), its arguments
# (NUL-separated) and its standard input to $scratch/claude.{env,args,stdin},
# and exits with the code in $scratch/claude.rc (0 by default).
fake_claude() {
	write_script "$bin/claude" \
		'IFS="|"; printf "claude|%s\n" "$*" >>"'"$calls"'"' \
		'env -0 >"'"$scratch"'/claude.env"' \
		'printf "%s\0" "$@" >"'"$scratch"'/claude.args"' \
		'cat >"'"$scratch"'/claude.stdin"' \
		'exit "$(cat "'"$scratch"'/claude.rc" 2>/dev/null || echo 0)"'
}

# A directory with env and cat only, for the tests that must run without rbw
# or without claude on PATH while the stand-ins still find their tools.
bare_path() {
	mkdir -p "$scratch/nobin"
	ln -sf "$(command -v env)" "$scratch/nobin/env"
	ln -sf "$(command -v cat)" "$scratch/nobin/cat"
}

# Whether the stand-in claude had NAME=VALUE in its environment, exactly.
claude_env_has() {
	local rec
	while IFS= read -r -d '' rec; do
		[[ $rec == "$1=$2" ]] && return 0
	done <"$scratch/claude.env"
	echo "  claude had no $1 with that value in its environment"
	return 1
}
# Whether the stand-in claude had no variable NAME at all.
claude_env_lacks() {
	local rec
	while IFS= read -r -d '' rec; do
		if [[ $rec == "$1="* ]]; then
			echo "  claude had $1 in its environment"
			return 1
		fi
	done <"$scratch/claude.env"
}

# The table bash.nix writes from ravnix.shell.secretEnv, "NAME=item" in name
# order, for two secrets.
two_secrets='_ravnix_secrets=("A_TOKEN=Item One" "B_TOKEN=Item Two")'

ai_unlock_unlocks_and_loads_nothing() {
	setup
	fake_rbw
	printf 'token-one\n' >"$scratch/rbw/items/Item One"
	printf 'token-two' >"$scratch/rbw/items/Item Two"
	run "$two_secrets"'
		ai-unlock; echo "status $?"; echo "[${A_TOKEN-unset}][${B_TOKEN-unset}]"; env | grep -cE "token-(one|two)"'
	expect_out 'status 0'
	called 'rbw|sync'
	called 'rbw|unlock'
	# Unlocking reads no item, and no secret is in the shell or its children.
	never_called 'rbw\|get'
	expect_out '[unset][unset]'
	expect_no_out 'token-'
	# It says what claude will get, by variable name.
	expect_out 'A_TOKEN B_TOKEN'
	expect_out 'claude'
}

ai_unlock_syncs_before_it_unlocks() {
	setup
	fake_rbw
	run '_ravnix_secrets=(); ai-unlock'
	[[ "$(grep -n '^rbw|sync' "$calls" | cut -d: -f1)" -lt "$(grep -n '^rbw|unlock' "$calls" | cut -d: -f1)" ]]
}

ai_unlock_fails_when_the_unlock_fails() {
	setup
	fake_rbw
	echo 1 >"$scratch/rbw/unlock"
	run "$two_secrets"'; ai-unlock; echo "status $?"'
	expect_out 'status 1'
	never_called 'rbw\|get'
}

ai_unlock_uses_the_cached_copy_when_the_sync_fails() {
	setup
	fake_rbw
	echo 1 >"$scratch/rbw/sync"
	echo "network is down" >"$scratch/rbw/sync.msg"
	mkdir -p "$scratch/cache/rbw"
	local db="$scratch/cache/rbw/https%3A%2F%2Fvault.example.org:alice@example.org.json"
	echo '{}' >"$db"
	run "$two_secrets"'; ai-unlock; echo "status $?"'
	expect_out 'status 0'
	expect_err 'network is down'
	expect_err 'using the cached vault copy'
	# The cache is left as it was.
	[[ -f "$db" ]]
	never_called 'rbw\|stop-agent'
}

rejected_token() {
	echo 1 >"$scratch/rbw/sync"
	printf 'rbw sync: failed to parse JSON: missing field `access_token`\n' >"$scratch/rbw/sync.msg"
}

ai_unlock_logs_in_again_when_the_refresh_token_was_rejected() {
	setup
	fake_rbw
	rejected_token
	mkdir -p "$scratch/cache/rbw"
	local db="$scratch/cache/rbw/https%3A%2F%2Fvault.example.org:alice@example.org.json"
	echo '{"stale":true}' >"$db"
	# The unlock logs in and writes a new cache, as rbw does; the stand-in
	# does it by hand once it is asked to unlock.
	run '_ravnix_secrets=(); rbw() { if [[ $1 == unlock ]]; then echo "{\"fresh\":true}" >"'"$db"'"; fi; command rbw "$@"; }
		ai-unlock; echo "status $?"'
	expect_out 'status 0'
	expect_err 'logging in again'
	called 'rbw|stop-agent'
	called 'rbw|unlock'
	# The new cache is the one rbw made. The dead copy is gone: once the
	# unlock worked it has nothing the user needs, and it holds the encrypted
	# vault.
	[[ "$(cat "$db")" == '{"fresh":true}' ]]
	local stale=("$db".stale-*)
	[[ ! -e "${stale[0]}" ]]
}

ai_unlock_keeps_the_dead_copy_when_the_login_fails() {
	setup
	fake_rbw
	rejected_token
	echo 1 >"$scratch/rbw/unlock"
	mkdir -p "$scratch/cache/rbw"
	local db="$scratch/cache/rbw/https%3A%2F%2Fvault.example.org:alice@example.org.json"
	echo '{"stale":true}' >"$db"
	run '_ravnix_secrets=(); ai-unlock; echo "status $?"'
	expect_out 'status 1'
	[[ ! -e "$db" ]]
	# Moved aside and not deleted: it is all there is until a login works.
	local stale=("$db".stale-*)
	[[ -e "${stale[0]}" && "$(cat "${stale[0]}")" == '{"stale":true}' ]]
}

ai_unlock_survives_a_missing_cache_when_the_refresh_token_was_rejected() {
	setup
	fake_rbw
	rejected_token
	run '_ravnix_secrets=(); ai-unlock; echo "status $?"'
	expect_out 'status 0'
	called 'rbw|unlock'
	expect_no_err 'logging in again'
}

# rbw names the cache after the server as written in its config, with the
# control characters, "/", "%" and ":" in percent form (rbw's src/dirs.rs),
# and after the email as it is.
ai_unlock_finds_the_cache_of_a_server_url_with_reserved_characters() {
	setup
	fake_rbw
	rejected_token
	printf '{"base_url":"https://vault.example.org:8443/a+b=c@d?e%%f;g,h~i","email":"al+ice@example.org"}\n' >"$scratch/rbw/config.json"
	mkdir -p "$scratch/cache/rbw"
	local db="$scratch/cache/rbw/https%3A%2F%2Fvault.example.org%3A8443%2Fa+b=c@d?e%25f;g,h~i:al+ice@example.org.json"
	echo '{"stale":true}' >"$db"
	run '_ravnix_secrets=(); ai-unlock; echo "status $?"'
	expect_err 'logging in again'
	[[ ! -e "$db" ]]
	local stale=("$db".stale-*)
	[[ -e "${stale[0]}" ]]
}

ai_unlock_encodes_what_is_not_ascii_the_way_rbw_does() {
	setup
	fake_rbw
	rejected_token
	printf '{"base_url":"https://vault.example.org/k\xc3\xb6ln\\t","email":"a@example.org"}\n' >"$scratch/rbw/config.json"
	mkdir -p "$scratch/cache/rbw"
	local db="$scratch/cache/rbw/https%3A%2F%2Fvault.example.org%2Fk%C3%B6ln%09:a@example.org.json"
	echo '{"stale":true}' >"$db"
	run '_ravnix_secrets=(); ai-unlock'
	[[ ! -e "$db" ]]
	local stale=("$db".stale-*)
	[[ -e "${stale[0]}" ]]
}

ai_unlock_names_the_default_server_when_the_config_has_none() {
	setup
	fake_rbw
	rejected_token
	printf '{"base_url":null,"email":"a@example.org"}\n' >"$scratch/rbw/config.json"
	mkdir -p "$scratch/cache/rbw"
	local db="$scratch/cache/rbw/default:a@example.org.json"
	echo '{"stale":true}' >"$db"
	run '_ravnix_secrets=(); ai-unlock'
	[[ ! -e "$db" ]]
}

ai_unlock_honors_the_rbw_profile() {
	setup
	fake_rbw
	rejected_token
	mkdir -p "$scratch/cache/rbw-work" "$scratch/cache/rbw"
	local name="https%3A%2F%2Fvault.example.org:alice@example.org.json"
	echo '{"profile":true}' >"$scratch/cache/rbw-work/$name"
	echo '{"default":true}' >"$scratch/cache/rbw/$name"
	run 'export RBW_PROFILE=work; _ravnix_secrets=(); ai-unlock'
	# The profile's cache is the one moved, and the default one is left alone.
	[[ ! -e "$scratch/cache/rbw-work/$name" ]]
	[[ -e "$scratch/cache/rbw/$name" ]]
}

ai_unlock_cleans_up_the_dead_copies_of_its_own_cache_only_after_an_unlock() {
	setup
	fake_rbw
	mkdir -p "$scratch/cache/rbw"
	local name="https%3A%2F%2Fvault.example.org:alice@example.org.json"
	local db="$scratch/cache/rbw/$name"
	echo '{}' >"$db"
	echo old >"$db.stale-2026-01-01-000000"
	echo older >"$db.stale-2025-12-31-000000"
	echo other >"$scratch/cache/rbw/https%3A%2F%2Fvault.example.org:bob@example.org.json.stale-2026-01-01-000000"
	# A failed unlock keeps them.
	echo 1 >"$scratch/rbw/unlock"
	run '_ravnix_secrets=(); ai-unlock'
	[[ -e "$db.stale-2026-01-01-000000" && -e "$db.stale-2025-12-31-000000" ]]
	# A good one removes the copies of this account, and nothing else.
	echo 0 >"$scratch/rbw/unlock"
	run '_ravnix_secrets=(); ai-unlock'
	[[ ! -e "$db.stale-2026-01-01-000000" && ! -e "$db.stale-2025-12-31-000000" ]]
	[[ -e "$db" ]]
	[[ -e "$scratch/cache/rbw/https%3A%2F%2Fvault.example.org:bob@example.org.json.stale-2026-01-01-000000" ]]
}

ai_unlock_does_not_clean_up_when_there_is_no_live_cache() {
	setup
	fake_rbw
	mkdir -p "$scratch/cache/rbw"
	local db="$scratch/cache/rbw/https%3A%2F%2Fvault.example.org:alice@example.org.json"
	echo old >"$db.stale-2026-01-01-000000"
	run '_ravnix_secrets=(); ai-unlock'
	# An unlock that left no cache behind has not replaced the dead copy.
	[[ -e "$db.stale-2026-01-01-000000" ]]
}

ai_unlock_with_no_secrets_configured_says_so() {
	setup
	fake_rbw
	run '_ravnix_secrets=(); ai-unlock; echo "status $?"'
	expect_out 'status 0'
	expect_out 'ravnix.shell.secretEnv'
	called 'rbw|unlock'
}

ai_unlock_never_prints_a_secret() {
	setup
	fake_rbw
	printf 'hunter2-secret' >"$scratch/rbw/items/Item One"
	run "$two_secrets"'; ai-unlock'
	expect_no_out 'hunter2-secret'
	expect_no_err 'hunter2-secret'
	never_called 'rbw\|get'
}

# What `claude` is: a bash function and not a script on PATH. A script named
# claude would stand in front of the package that home-manager puts on PATH
# for every program, not only the interactive shell, and would have to be
# installed beside it. The function adds the secrets for the one command a
# person types, and everything else (a launcher, ssh host claude, an editor)
# runs the binary as it is.

claude_gives_the_secrets_to_claude_and_to_nothing_else() {
	setup
	fake_rbw
	fake_claude
	printf 'token-one\n' >"$scratch/rbw/items/Item One"
	printf 'token-two' >"$scratch/rbw/items/Item Two"
	run "$two_secrets"'
		# (stdenv exports a `name` of its own in the build sandbox.)
		before=${name-unset}
		claude; echo "status $?"
		echo "[${A_TOKEN-unset}][${B_TOKEN-unset}]"
		# Nothing of it is in the shell, in its exported variables, or in the
		# environment of a child started afterwards.
		echo "TOKENS $({ declare -p; export -p; env; sh -c env; } | grep -cE token-\(one\|two\))"
		for v in item value entry bin; do [[ -v $v ]] && echo "LEFT $v"; done
		[[ ${name-unset} == "$before" ]] || echo "LEFT name"
		true'
	expect_out 'status 0'
	expect_out '[unset][unset]'
	expect_no_out 'LEFT'
	# No line of the shell's variables, of its exports, of its own environment
	# or of a child's holds a token.
	expect_out 'TOKENS 0'
	[[ -z "$err" ]]
	claude_env_has A_TOKEN token-one
	claude_env_has B_TOKEN token-two
	called 'rbw|unlocked'
	called 'rbw|get|--|Item One'
	called 'rbw|get|--|Item Two'
}

claude_passes_arguments_standard_input_and_the_exit_status_on() {
	setup
	fake_rbw
	fake_claude
	printf 'token-one' >"$scratch/rbw/items/Item One"
	echo 7 >"$scratch/claude.rc"
	run "$two_secrets"'; printf "piped in\nsecond line\n" | claude -p "two words" "" --flag="a b" -- -x; echo "status $?"'
	expect_out 'status 7'
	[[ "$(cat "$scratch/claude.stdin")" == $'piped in\nsecond line' ]]
	[[ "$(tr '\0' '|' <"$scratch/claude.args")" == '-p|two words||--flag=a b|--|-x|' ]]
}

claude_passes_straight_through_inside_claude_code() {
	setup
	fake_rbw
	fake_claude
	printf 'token-one' >"$scratch/rbw/items/Item One"
	run "$two_secrets"'; export CLAUDECODE=1 A_TOKEN=inherited; claude --version; echo "status $?"'
	expect_out 'status 0'
	# Nothing was asked of rbw, and the environment is what it was.
	never_called 'rbw'
	claude_env_has A_TOKEN inherited
	claude_env_lacks B_TOKEN
	[[ "$(tr '\0' '|' <"$scratch/claude.args")" == '--version|' ]]
}

claude_starts_without_the_secrets_when_the_vault_is_locked() {
	setup
	fake_rbw
	fake_claude
	printf 'token-one' >"$scratch/rbw/items/Item One"
	echo 1 >"$scratch/rbw/unlocked"
	run "$two_secrets"'; claude --version; echo "status $?"'
	expect_out 'status 0'
	# It never asks for a password, never reads an item, and says what to do.
	never_called 'rbw\|(get|unlock|sync)'
	expect_err 'ai-unlock'
	expect_err 'A_TOKEN'
	expect_err 'B_TOKEN'
	claude_env_lacks A_TOKEN
	called 'claude|--version'
}

claude_starts_without_the_secrets_when_rbw_is_not_installed() {
	setup
	fake_claude
	bare_path
	run "$two_secrets"'; PATH='"$scratch/nobin:$bin"'; claude --version; echo "status $?"'
	expect_out 'status 0'
	expect_err 'ai-unlock'
	claude_env_lacks A_TOKEN
	called 'claude|--version'
}

claude_is_the_plain_binary_when_no_secrets_are_configured() {
	setup
	fake_rbw
	fake_claude
	run '_ravnix_secrets=(); claude --version; echo "status $?"'
	expect_out 'status 0'
	never_called 'rbw'
	[[ -z "$err" ]]
}

claude_names_an_item_it_cannot_read_and_goes_on_with_the_others() {
	setup
	fake_rbw
	fake_claude
	printf 'there' >"$scratch/rbw/items/Item One"
	run '_ravnix_secrets=("A_TOKEN=Item One" "B_TOKEN=Gone"); claude; echo "status $?"'
	expect_out 'status 0'
	expect_err 'B_TOKEN'
	expect_err 'Gone'
	claude_env_has A_TOKEN there
	claude_env_lacks B_TOKEN
}

claude_passes_a_secret_on_as_it_is_and_never_evaluates_it() {
	setup
	fake_rbw
	fake_claude
	# Values a human might store: spaces, a comment, command substitutions, a
	# quote, a glob, an equals sign and a leading dash; and one with a newline.
	local odd='a b #c $(touch pwned) `touch pwned2` "q" '"'"'s'"'"' * = -x'
	printf '%s' "$odd" >"$scratch/rbw/items/Item One"
	printf 'first\nsecond' >"$scratch/rbw/items/Item Two"
	run "$two_secrets"'; claude'
	[[ ! -e pwned && ! -e pwned2 ]]
	claude_env_has A_TOKEN "$odd"
	claude_env_has B_TOKEN $'first\nsecond'
}

claude_never_puts_a_secret_on_a_command_line_or_into_a_message() {
	setup
	fake_rbw
	fake_claude
	printf 'hunter2-secret' >"$scratch/rbw/items/Item One"
	run '_ravnix_secrets=("A_TOKEN=Item One" "B_TOKEN=Gone"); claude --version'
	expect_no_out 'hunter2-secret'
	expect_no_err 'hunter2-secret'
	# The stand-ins log every argument they get: item names, no values.
	! grep -q 'hunter2-secret' "$calls"
}

claude_leaves_no_loader_variable_behind_even_under_allexport() {
	setup
	fake_rbw
	fake_claude
	printf 'token-one' >"$scratch/rbw/items/Item One"
	printf 'token-two' >"$scratch/rbw/items/Item Two"
	run "$two_secrets"'; set -a; claude'
	local rec seen=0
	while IFS= read -r -d '' rec; do
		case $rec in
		name=* | item=* | value=* | entry=* | bin=* | _ravnix_secrets=*) echo "  leaked: ${rec%%=*}" && return 1 ;;
		*token-one* | *token-two*) seen=$((seen + 1)) ;;
		esac
	done <"$scratch/claude.env"
	# Each secret is in the environment once, under its own name.
	((seen == 2))
}

# xtrace prints every command with its words expanded, so `export A_TOKEN=...`
# would put the value on stderr, or into the file BASH_XTRACEFD names. The
# function turns it off before it reads anything, and gives it back.
claude_never_traces_a_secret_to_stderr() {
	setup
	fake_rbw
	fake_claude
	printf 'token-one' >"$scratch/rbw/items/Item One"
	printf 'token-two' >"$scratch/rbw/items/Item Two"
	# A PS4 that shows the loader's variables, and a trace that is on.
	run "$two_secrets"'; PS4="+<\${value-}\${A_TOKEN-}\${B_TOKEN-}> "; set -x; claude; set +x'
	claude_env_has A_TOKEN token-one
	claude_env_has B_TOKEN token-two
	expect_no_err 'token-one'
	expect_no_err 'token-two'
	expect_no_out 'token-one'
	expect_no_out 'token-two'
}

claude_never_traces_a_secret_to_the_trace_file() {
	setup
	fake_rbw
	fake_claude
	printf 'token-one' >"$scratch/rbw/items/Item One"
	printf 'token-two' >"$scratch/rbw/items/Item Two"
	run "$two_secrets"'; exec {fd}>"'"$scratch"'/trace.log"; BASH_XTRACEFD=$fd; set -x; claude; set +x; exec {fd}>&-'
	claude_env_has A_TOKEN token-one
	claude_env_has B_TOKEN token-two
	# The trace is there (the call is in it), and holds neither value.
	[[ -s "$scratch/trace.log" ]]
	if grep -qE 'token-(one|two)' "$scratch/trace.log"; then
		echo "  the trace holds a secret:"
		grep -E 'token-(one|two)' "$scratch/trace.log" | sed 's/^/    /'
		return 1
	fi
	expect_no_err 'token-one'
	expect_no_err 'token-two'
}

claude_gives_xtrace_back_to_the_caller() {
	setup
	fake_rbw
	fake_claude
	printf 'token-one' >"$scratch/rbw/items/Item One"
	run "$two_secrets"'; set -x; claude 2>/dev/null; case $- in *x*) echo "XTRACE-ON" ;; *) echo "XTRACE-OFF-" ;; esac; set +x
		claude; case $- in *x*) echo "XTRACE-ON2" ;; *) echo "XTRACE-OFF2" ;; esac'
	expect_out 'XTRACE-ON'
	expect_no_out 'XTRACE-OFF-'
	expect_out 'XTRACE-OFF2'
}

# The reads happen before any export: an `rbw get` is a child, and a child
# of the loop would carry every value read so far.
claude_reads_every_item_before_it_exports_one() {
	setup
	fake_rbw
	fake_claude
	printf 'token-one' >"$scratch/rbw/items/Item One"
	printf 'token-two' >"$scratch/rbw/items/Item Two"
	run "$two_secrets"'; claude'
	# Two reads, and neither found a secret in its environment.
	[[ "$(grep -c '^rbwenv|' "$calls")" == 2 ]]
	[[ "$(grep -c '^rbwenv|0$' "$calls")" == 2 ]] || {
		echo "  an rbw get inherited a secret:"
		grep '^rbwenv|' "$calls" | sed 's/^/    /'
		return 1
	}
	claude_env_has A_TOKEN token-one
	claude_env_has B_TOKEN token-two
}

claude_exports_the_secrets_that_could_be_read_when_one_item_is_missing() {
	setup
	fake_rbw
	fake_claude
	printf 'token-two' >"$scratch/rbw/items/Item Two"
	run '_ravnix_secrets=("A_TOKEN=Gone" "B_TOKEN=Item Two"); claude'
	claude_env_has B_TOKEN token-two
	claude_env_lacks A_TOKEN
	[[ "$(grep -c '^rbwenv|0$' "$calls")" == 2 ]]
}

claude_with_nothing_readable_starts_with_nothing_added_and_prints_no_environment() {
	setup
	fake_rbw
	fake_claude
	run '_ravnix_secrets=("A_TOKEN=Gone" "B_TOKEN=Gone too"); claude --version; echo "status $?"'
	expect_out 'status 0'
	# A bare `export` would list the whole environment on stdout.
	expect_no_out 'declare -x'
	expect_no_out 'PATH='
	claude_env_lacks A_TOKEN
	claude_env_lacks B_TOKEN
	called 'claude|--version'
}

claude_takes_an_item_name_that_starts_with_a_dash_as_a_name() {
	setup
	fake_rbw
	fake_claude
	printf 'dashed' >"$scratch/rbw/items/-odd"
	run '_ravnix_secrets=("A_TOKEN=-odd"); claude'
	claude_env_has A_TOKEN dashed
	called 'rbw|get|--|-odd'
}

claude_that_is_not_installed_fails_like_any_missing_command() {
	setup
	fake_rbw
	printf 'token-one' >"$scratch/rbw/items/Item One"
	bare_path
	run "$two_secrets"'; PATH='"$scratch/nobin"'; claude; echo "status $?"'
	expect_out 'status 127'
	# It did not read the vault for a program it could not start.
	never_called 'rbw'
}

claude_runs_the_binary_and_not_itself() {
	setup
	fake_rbw
	fake_claude
	printf 'token-one' >"$scratch/rbw/items/Item One"
	# A binary that is claude's own name must be the one that runs, and the
	# function must not call itself.
	run "$two_secrets"'; claude; type -t claude; type -P claude'
	expect_out 'function'
	expect_out "$bin/claude"
	called 'claude|'
}

tests=(
	over_prints_the_lines_wider_than_eighty_with_their_numbers
	over_takes_the_width_and_reads_stdin
	over_counts_a_tab_as_the_columns_it_occupies
	over_on_empty_input_prints_nothing
	over_counts_characters_and_not_bytes
	gr_goes_to_the_root_or_below_it
	gr_outside_a_repository_stays_and_fails
	gr_uses_the_builtin_cd_even_when_cd_is_something_else
	gmb_names_the_main_branch_from_origin_head
	gmb_keeps_a_slash_in_the_branch_name
	gmb_without_origin_head_says_what_to_do
	gmb_outside_a_repository_fails
	gbd_shows_what_the_branch_changed_and_not_what_main_gained
	gsm_switches_to_main_and_pulls
	gmm_merges_main_into_the_branch
	gho_builds_a_github_url_from_an_scp_remote_and_opens_it
	gho_builds_a_forgejo_url_from_an_ssh_remote_and_drops_the_port
	gho_uses_blob_for_a_file_and_the_path_below_the_repository
	gho_takes_a_dot_for_the_directory_it_is_in
	gho_escapes_spaces_in_the_path
	gho_names_the_commit_when_head_is_detached
	gho_takes_another_remote
	gho_without_the_remote_fails_and_opens_nothing
	gho_refuses_a_remote_url_it_cannot_read
	open_returns_at_once_and_stays_silent
	sudo_nvim_with_a_file_becomes_sudoedit
	sudo_leaves_every_other_call_to_sudo
	sff_wants_a_destination
	zd_goes_home_into_a_directory_or_asks_zoxide
	zd_reports_a_directory_zoxide_does_not_know
	zd_enters_a_directory_with_an_odd_name_without_asking_zoxide
	ob_builds_the_package_in_the_directory
	ob_names_the_output_before_or_after_the_directory
	ob_wants_one_directory_and_a_name_for_o
	ob_does_not_move_the_callers_directory
	ot_runs_the_tests_of_the_package_or_its_tests_folder
	ot_with_b_builds_first_and_tests_only_when_the_build_passed
	cat_sends_text_and_pipes_to_bat
	cat_sends_a_text_file_on_a_terminal_to_bat_too
	cat_draws_images_on_a_terminal_half_the_width
	cat_forces_the_kitty_protocol_under_herdr_and_ghostty
	cat_takes_a_size_for_the_image_as_its_first_argument
	cat_hands_a_mix_of_text_and_images_to_bat_whole
	cat_hands_a_missing_file_or_an_option_to_bat
	cat_without_arguments_reads_stdin_through_bat
	ai_unlock_unlocks_and_loads_nothing
	ai_unlock_syncs_before_it_unlocks
	ai_unlock_fails_when_the_unlock_fails
	ai_unlock_uses_the_cached_copy_when_the_sync_fails
	ai_unlock_logs_in_again_when_the_refresh_token_was_rejected
	ai_unlock_keeps_the_dead_copy_when_the_login_fails
	ai_unlock_survives_a_missing_cache_when_the_refresh_token_was_rejected
	ai_unlock_finds_the_cache_of_a_server_url_with_reserved_characters
	ai_unlock_encodes_what_is_not_ascii_the_way_rbw_does
	ai_unlock_names_the_default_server_when_the_config_has_none
	ai_unlock_honors_the_rbw_profile
	ai_unlock_cleans_up_the_dead_copies_of_its_own_cache_only_after_an_unlock
	ai_unlock_does_not_clean_up_when_there_is_no_live_cache
	ai_unlock_with_no_secrets_configured_says_so
	ai_unlock_never_prints_a_secret
	claude_gives_the_secrets_to_claude_and_to_nothing_else
	claude_passes_arguments_standard_input_and_the_exit_status_on
	claude_passes_straight_through_inside_claude_code
	claude_starts_without_the_secrets_when_the_vault_is_locked
	claude_starts_without_the_secrets_when_rbw_is_not_installed
	claude_is_the_plain_binary_when_no_secrets_are_configured
	claude_names_an_item_it_cannot_read_and_goes_on_with_the_others
	claude_passes_a_secret_on_as_it_is_and_never_evaluates_it
	claude_never_puts_a_secret_on_a_command_line_or_into_a_message
	claude_leaves_no_loader_variable_behind_even_under_allexport
	claude_never_traces_a_secret_to_stderr
	claude_never_traces_a_secret_to_the_trace_file
	claude_gives_xtrace_back_to_the_caller
	claude_reads_every_item_before_it_exports_one
	claude_exports_the_secrets_that_could_be_read_when_one_item_is_missing
	claude_with_nothing_readable_starts_with_nothing_added_and_prints_no_environment
	claude_takes_an_item_name_that_starts_with_a_dash_as_a_name
	claude_that_is_not_installed_fails_like_any_missing_command
	claude_runs_the_binary_and_not_itself
)

run_tests "${tests[@]}"
