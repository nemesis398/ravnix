#!/usr/bin/env bash
# The gate. The git hooks and the Claude Code Stop hook run it, and there is
# no CI behind it: what it does not check, nothing does.
#
#   scripts/check.sh --fast   the fast steps, which .githooks/pre-commit and
#                             the Stop hook run
#   scripts/check.sh          the fast steps and then the slow ones, which
#                             .githooks/pre-push runs
#
# The fast steps:
#   - boundary: scripts/check-public.sh with the deny list that git config
#     ravnix.denyList names, over the index (what the next commit holds,
#     read from git's objects, so an unstaged edit cannot hide a staged
#     value) and over each tracked file whose work-tree copy differs from it.
#     Untracked files are not read. Without ravnix.denyList the step says it
#     was skipped and passes, so a clone without a private flake still works.
#   - style: scripts/check-style.sh over the same two sets: a hex color
#     outside modules/theme/, a radius other than 0, anything translucent
#     but the inside of the lock ring, a transition or animation, a Mermaid
#     init block that is not the shared one (docs/style.md). It needs rg and
#     runs without a deny list.
#   - shellcheck: every tracked shell script, found by its extension (.sh,
#     .bash) or by its shebang (sh, bash, dash, ksh), hooks included: the
#     staged copy, and the work-tree copy where it differs.
# The slow steps:
#   - flake: what nix flake check checked, in a process per check, so the
#     step stays within the laptop's RAM. nix flake check evaluates all of
#     the flake's checks, NixOS systems among them, in one evaluator that
#     keeps every one of them alive: it peaked at 15.6 GB without building
#     and at about 18 GB while building, on a 27 GB laptop. The step:
#       1. asks nix for the system it builds for (nix config show system),
#          as nix flake check takes it;
#       2. copies the source once (nix flake prefetch, the work tree's
#          tracked files), kept from garbage collection by a link in the
#          gate's work directory, and points every later call at that copy
#          (path:STORE_PATH#...), so the verdict is about one tree, as nix
#          flake check's was, even when the work tree changes while the
#          step runs. A source of type path has no rev or dirtyRev, so
#          self.rev and its kin are absent in the checks (nothing in
#          ravnix reads them);
#       3. lists the names of checks.SYSTEM with builtins.attrNames, which
#          evaluates no check (tests/flake/check-names.nix keeps it so);
#       4. checks every other output in one nix eval that reads no check,
#          with scripts/lib/flake-outputs.nix, which holds what is checked
#          and how: packages.SYSTEM (each a derivation, its drvPath
#          evaluated), overlays (each a function of final), nixosModules
#          and homeModules (each an attribute set, a function or a path
#          that exists), templates (path, description, welcomeText and
#          nothing else); other systems are omitted, as nix flake check
#          omits them. Any other output fails the step until that file
#          checks it, so a new output is never silently unchecked;
#       5. for each check, in the order of the listing: evaluates its
#          derivation in a nix eval of its own, through
#          scripts/lib/check-drv.nix, which refuses a check that is no
#          derivation (nix build alone would pass a path or a string with
#          store context, nix flake check did not), and then builds that
#          derivation with nix build DRV^* and --keep-going, which
#          evaluates nothing again; DRV must be a .drv in the source's
#          store. A check that fails, also one that fails
#          to evaluate, stops none of the others. A name no attribute path
#          on the command line can hold (a double quote, a control
#          character, the empty name) fails as a check. The attribute
#          paths are absolute (#.checks...), so nix does not try
#          packages.SYSTEM first.
#     Then it names every failed check, and exits with the first failing
#     status, in the order listing, outputs, checks.
#
#     RAVNIX_CHECK_JOBS=N runs N checks' nix processes at once, each line
#     marked with its check's name; N is any whole number from 1 (one too
#     long for bash's arithmetic counts as more than any number of checks).
#     The default, 1, is for the RAM: the largest check's evaluation peaked at
#     4.3 GB (measured on 2026-11-08), so N of them take up to N times that
#     beside the user's applications, and the step is to stay under 85 % of
#     the RAM. Nix's own max-jobs and cores still decide the builds inside
#     a check.
#
#     A Ctrl-C or a SIGTERM to the gate's process group ends the step in
#     every phase and either mode, and the gate says the flake step failed
#     with 130 or 143. Every nix process of the step runs as a background
#     job, the system query, the copy, the listing and the outputs check
#     included, and the step waits for it; so a foreground nix, which
#     catches SIGINT and exits 1 so that bash goes on as if handled, never
#     decides it. On its way out the step sends SIGTERM to every nix
#     process it started and has not reaped, waits for them, and sends
#     SIGKILL to any still running after 10 s, since nix can ignore
#     SIGTERM for minutes in the middle of an evaluation.
#   - claude-code: claude-code-verify checks the Claude Code download that
#     packages.claude-code was made from, for the version in ravnix's own
#     flake.lock, against Anthropic's release manifest. A private flake whose
#     claude-code input ravnix's follows checks its own version itself. The
#     check needs the network, so it runs here and not in the
#     build sandbox (tools/claude-code-verify/README.md). Each verified
#     pair of version and download is recorded in
#     ${XDG_STATE_HOME:-$HOME/.local/state}/ravnix/claude-code-verified. An
#     unreachable manifest (exit 3) passes the gate for a pair recorded
#     there and fails it for any other: the check is the only one there is,
#     and a push that bumps Claude Code would otherwise go out unverified. A
#     mismatch (exit 1) always fails, and removes the pair from the record.
#
# The gate stops at the first failing step and exits with that step's status,
# and with 0 when every step passed.
#
# Changing this file so it checks less needs the maintainer's explicit
# approval (AGENTS.md, rule 6).

set -euo pipefail
shopt -s inherit_errexit

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
# shellcheck source=scripts/lib/git-snapshot.sh
. scripts/lib/git-snapshot.sh

fail() {
	printf 'check.sh: %s\n' "$@" >&2
	exit 1
}

mode=full
case "$#:${1:-}" in
0:) ;;
1:--fast) mode=fast ;;
*)
	echo "usage: scripts/check.sh [--fast]" >&2
	exit 2
	;;
esac

# The steps, in order. A new check is a function step_NAME below and its name
# in one of these lists.
fast_steps=(boundary style shellcheck)
slow_steps=(flake claude-code)
steps=("${fast_steps[@]}")
[[ "$mode" == fast ]] || steps+=("${slow_steps[@]}")

# Find every tool before the first step, so a missing one fails at once.
command -v git >/dev/null 2>&1 || fail "git not found."
git rev-parse --is-inside-work-tree >/dev/null 2>&1 ||
	fail "$root is not a git work tree; the gate checks what git tracks."
deny_list="$(ravnix_deny_list)" || exit 2
command -v rg >/dev/null 2>&1 || fail "rg not found. Install ripgrep."
command -v shellcheck >/dev/null 2>&1 || fail "shellcheck not found. Install ShellCheck."
if [[ "$mode" == full ]]; then
	command -v nix >/dev/null 2>&1 ||
		fail "nix not found on PATH, and the full gate builds the flake's checks." \
			"Outside NixOS, open a new shell or source" \
			"/nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh."
fi

# How many checks the flake step builds at once (the header says why 1).
check_jobs=1
if [[ "$mode" == full && -n "${RAVNIX_CHECK_JOBS:-}" ]]; then
	if [[ ! "$RAVNIX_CHECK_JOBS" =~ ^[1-9][0-9]*$ ]]; then
		printf 'check.sh: %s\n' \
			"RAVNIX_CHECK_JOBS is $(printf %q "$RAVNIX_CHECK_JOBS"); it is the number of checks the flake step builds at once," \
			"a whole number of 1, the default, or more. Each takes up to 4.3 GB of RAM (measured on" \
			"ravnix's largest check), so mind the RAM before you raise it." >&2
		exit 2
	fi
	# A number too long for bash's arithmetic is more than any count of
	# checks, and so is 10^9.
	check_jobs=1000000000
	((${#RAVNIX_CHECK_JOBS} > 9)) || check_jobs=$RAVNIX_CHECK_JOBS
fi

work="$(mktemp -d -p "${TMPDIR:-/tmp}" ravnix-check.XXXXXX)"
trap 'rm -rf -- "$work"' EXIT

# The index as files, and the tracked files whose work-tree copy differs.
staged=()
while IFS= read -r -d '' path; do
	staged+=("$path")
done < <(ravnix_snapshot_index "$work/index")
wait $! || fail "could not lay out the index."
unstaged=()
while IFS= read -r -d '' path; do
	[[ -f "$path" || -L "$path" ]] && unstaged+=("$path")
done < <(git diff --name-only -z --no-renames --diff-filter=AMTU)
wait $! || fail "git diff failed."

step_boundary() {
	if [[ -z "$deny_list" ]]; then
		ravnix_skip_note check.sh
		return 0
	fi
	local status=0 s=0
	echo "the index (what the next commit holds):"
	(cd "$work/index" && "$root/scripts/check-public.sh" "$deny_list" .) || status=$?
	if ((${#unstaged[@]} > 0)); then
		echo "unstaged changes in the work tree (${#unstaged[@]} files):"
		scripts/check-public.sh "$deny_list" "${unstaged[@]}" || s=$?
		((s <= status)) || status=$s
	fi
	((status != 0)) || echo "no value from the deny list found"
	return "$status"
}

step_style() {
	local status=0 s=0 theme=()
	# The shared Mermaid theme of the index, when the index has one, so a
	# commit that changes it and docs/style.md together is judged as a whole.
	[[ ! -f "$work/index/docs/mermaid-theme.json" ]] ||
		theme=(RAVNIX_MERMAID_THEME="$work/index/docs/mermaid-theme.json")
	echo "the index (what the next commit holds):"
	(cd "$work/index" && env "${theme[@]}" "$root/scripts/check-style.sh" .) || status=$?
	if ((${#unstaged[@]} > 0)); then
		echo "unstaged changes in the work tree (${#unstaged[@]} files):"
		scripts/check-style.sh "${unstaged[@]}" || s=$?
		((s <= status)) || status=$s
	fi
	((status != 0)) || echo "no style rule broken"
	return "$status"
}

# Whether the file $1 is a shell script.
is_shell() {
	local first=""
	case "$1" in
	*.sh | *.bash) return 0 ;;
	esac
	[[ -f "$1" && ! -L "$1" ]] || return 1
	IFS= read -r -n 256 first <"$1" 2>/dev/null || true
	[[ "$first" =~ ^#![[:space:]]*[^[:space:]]*/(env[[:space:]]+(-[^[:space:]]*[[:space:]]+)*)?(ba|da|k)?sh([[:space:]]|$) ]]
}

step_shellcheck() {
	local scripts=() path status=0 s=0
	for path in "${staged[@]}"; do
		is_shell "$work/index/$path" && scripts+=("$path")
	done
	echo "the index: ${#scripts[@]} shell scripts"
	if ((${#scripts[@]} > 0)); then
		(cd "$work/index" && shellcheck --external-sources -- "${scripts[@]}") || status=$?
	fi
	scripts=()
	for path in "${unstaged[@]}"; do
		if [[ ! -L "$path" ]] && is_shell "$path"; then
			scripts+=("$path")
		fi
	done
	if ((${#scripts[@]} > 0)); then
		echo "unstaged changes in the work tree: ${#scripts[@]} shell scripts"
		shellcheck --external-sources -- "${scripts[@]}" || s=$?
		((s <= status)) || status=$s
	fi
	return "$status"
}

# nix as every slow step runs it: flakes on, and the lock file never written.
nix_() {
	nix --extra-experimental-features 'nix-command flakes' "$@" --no-update-lock-file
}

# Lists the checks of checks.SYSTEM by name, which evaluates none of them:
# a line "ok NAME" each, or "bad JSON" for a name that no attribute path on
# the command line can hold, one that is empty or holds a double quote or a
# control character.
# shellcheck disable=SC2016 # Nix's ${...}, not the shell's.
list_checks='checks: builtins.concatStringsSep "" (map (name: if builtins.match "[^\"[:cntrl:]]+" name == null then "bad ${builtins.toJSON name}\n" else "ok ${name}\n") (builtins.attrNames checks))'
outputs_validator=scripts/lib/flake-outputs.nix
check_guard=scripts/lib/check-drv.nix

# The attribute path of the check named $1 below checks.SYSTEM: quoted, so
# a dot is part of the name, and each byte but A-Z a-z 0-9 . _ ~ -
# percent-encoded, since nix decodes a flake reference's fragment before it
# reads the path in it (a % or a # would change it otherwise).
check_attr() {
	local LC_ALL=C s="$1" i c out=""
	for ((i = 0; i < ${#s}; i++)); do
		c="${s:i:1}"
		case "$c" in
		[A-Za-z0-9._~-]) out+="$c" ;;
		*)
			printf -v c '%%%02X' "'$c"
			out+="$c"
			;;
		esac
	done
	printf '"%s"' "$out"
}

# Starts nix_ "${@:3}" in the background as the job itself (exec), so the
# job's pid is nix's and stopping the job stops nix. Its lines are marked
# [$1] unless $1 is empty, and its stdout goes to the file $2 unless $2 is
# empty. A script's background jobs ignore SIGINT, so a Ctrl-C reaches the
# step and not nix: the step stops nix on its way out (stop_nix). The flake
# step runs every nix this way, also the ones it waits for at once
# (run_nix), so the same stop covers all of them. `nix config show` reads
# no flake and refuses --no-update-lock-file, so it goes without.
start_nix() {
	local mark="$1" to="$2" line lock=(--no-update-lock-file)
	shift 2
	[[ "$1" != config ]] || lock=()
	(
		if [[ -n "$mark" ]]; then
			exec > >(while IFS= read -r line; do printf '[%s] %s\n' "$mark" "$line"; done) 2>&1
		fi
		[[ -z "$to" ]] || exec >"$to"
		exec nix --extra-experimental-features 'nix-command flakes' "$@" "${lock[@]}"
	) &
}

# Runs nix_ "${@:2}" as start_nix does and waits for it, with its stdout in
# the file $1 (or the step's, when $1 is empty). Returns nix's status.
run_nix() {
	local to="$1" status=0
	shift
	start_nix "" "$to" "$@"
	wait "$!" || status=$?
	return "$status"
}

# How long the nix processes of a stopped flake step get to end on SIGTERM
# before SIGKILL: nix can ignore SIGTERM for minutes in the middle of an
# evaluation.
stop_grace=10

# Stops every nix process the flake step started and has not reaped: all
# jobs of its shell, so also one started a moment before the signal came
# and not yet recorded. It waits for them, and kills those still running
# after stop_grace seconds.
stop_nix() {
	local pids=() list killer
	list="$(jobs -p)"
	[[ -n "$list" ]] || return 0
	mapfile -t pids <<<"$list"
	echo "check.sh: stopping ${#pids[@]} nix process(es) of the flake step" >&2
	kill -TERM -- "${pids[@]}" 2>/dev/null || true
	(
		sleep "$stop_grace"
		for pid in "${pids[@]}"; do
			if kill -0 "$pid" 2>/dev/null; then
				echo "check.sh: nix process $pid ignored SIGTERM for ${stop_grace} s; sending SIGKILL" >&2
				kill -KILL -- "$pid" 2>/dev/null || true
			fi
		done
	) &
	killer=$!
	wait -- "${pids[@]}" 2>/dev/null || true
	kill -- "$killer" 2>/dev/null || true
	wait -- "$killer" 2>/dev/null || true
}

# $1 and a newline as a Nix indented string: '' and ${ escaped, the only
# sequences such a string reads in its text, and the newline after $1, so a
# ' at its end does not run into the closing ''. For one line that starts
# with no blank, as nix's JSON does with --no-pretty, so no indentation is
# stripped.
nix_indented() {
	local s="$1"
	s="${s//\'\'/\'\'\'}"
	s="${s//\$\{/\'\'\$\{}"
	printf "''%s\n''" "$s"
}

# "N things", or "1 thing".
counted() {
	if (($1 == 1)); then printf '1 %s' "$2"; else printf '%d %ss' "$1" "$2"; fi
}

step_flake() {
	local system listing line i s pid phase drv mark source store flake first=0 list_status=0 outputs_status=0
	local out="$work/flake-step.out"
	local running=0 next=0
	local names=() attrs=() results=() failed=()
	local -A job_check=() job_phase=()

	# A Ctrl-C or a SIGTERM ends the step, not just the nix process running
	# then: nix catches SIGINT and exits 1, which bash takes as handled.
	trap 'exit 130' INT
	trap 'exit 143' TERM
	trap stop_nix EXIT

	if [[ ! -f "$check_guard" ]]; then
		echo "check.sh: $check_guard is missing, so no check can be told from a non-derivation" >&2
		return 1
	fi
	run_nix "$out" config show system || return $?
	system="$(<"$out")"
	if [[ ! "$system" =~ ^[A-Za-z0-9_]+(-[A-Za-z0-9_]+)+$ ]]; then
		printf 'check.sh: nix names the system it builds for %q, which is no system name\n' "$system" >&2
		return 1
	fi

	# One snapshot of the source for the whole step: nix copies the work
	# tree's tracked files to the store once, here, and every call below
	# reads that copy, so the verdict is about one tree even when the work
	# tree changes while the step runs. The link in the gate's work
	# directory keeps the copy from a garbage collection until the gate
	# ends. (nix flake metadata would name the path without copying.)
	run_nix "$out" flake prefetch --json --no-pretty --out-link "$work/source" . || return $?
	run_nix "$out.path" eval --raw --expr "(builtins.fromJSON $(nix_indented "$(<"$out")")).storePath" || return $?
	source="$(<"$out.path")"
	if [[ ! "$source" =~ ^(/[^/[:space:]]+)+$ ]]; then
		printf 'check.sh: nix names the copy of the source %q, which is no store path\n' "$source" >&2
		return 1
	fi
	store="${source%/*}"
	flake="path:$source"
	echo "the source: $source"

	run_nix "$out" eval --raw "$flake#.checks.$system" --apply "$list_checks" || list_status=$?
	listing="$(<"$out")"
	if ((list_status == 0)) && [[ -n "$listing" ]]; then
		while IFS= read -r line; do
			case "$line" in
			"ok "*)
				names+=("${line#ok }")
				attrs+=("$(check_attr "${line#ok }")")
				;;
			"bad "*)
				names+=("${line#bad }")
				attrs+=("")
				;;
			*)
				printf 'check.sh: the listing of the checks printed a line of another shape: %s\n' "$line" >&2
				list_status=1
				;;
			esac
		done <<<"$listing"
	fi
	if ((list_status != 0)); then
		printf 'check.sh: could not list the checks of checks.%s (exit %d)\n' "$system" "$list_status" >&2
		names=() attrs=()
	fi

	echo "the other outputs:"
	if [[ ! -f "$outputs_validator" ]]; then
		echo "check.sh: $outputs_validator is missing, so the other outputs cannot be checked" >&2
		outputs_status=1
	else
		run_nix "" eval --raw "$flake#." --apply "outputs: (($(<"$outputs_validator")) \"$system\" outputs).report" ||
			outputs_status=$?
	fi

	# Each check is two nix processes, one after the other: the evaluation
	# of its derivation through check_guard, which refuses a value that is
	# no derivation, and the build of that derivation, which evaluates
	# nothing. At most check_jobs of them run at once.
	printf 'checks.%s: %s, %d at a time\n' "$system" "$(counted "${#names[@]}" check)" "$check_jobs"
	while ((next < ${#names[@]} || running > 0)); do
		while ((running < check_jobs && next < ${#names[@]})); do
			i=$next
			next=$((next + 1))
			if [[ -z "${attrs[i]}" ]]; then
				printf 'check.sh: no attribute path on the command line can name the check %s\n' "${names[i]}" >&2
				results[i]=1
				continue
			fi
			mark=""
			if ((check_jobs == 1)); then
				printf -- '--> %s\n' "${names[i]}"
			else
				mark="${names[i]}"
			fi
			start_nix "$mark" "$work/drv.$i" eval --raw "$flake#.checks.$system.${attrs[i]}" --apply "$(<"$check_guard")"
			job_check[$!]=$i
			job_phase[$!]="eval"
			running=$((running + 1))
		done
		((running > 0)) || break
		s=0
		wait -n -p pid || s=$?
		i=${job_check[$pid]}
		phase=${job_phase[$pid]}
		unset 'job_check[$pid]' 'job_phase[$pid]'
		running=$((running - 1))
		if [[ "$phase" == build ]]; then
			results[i]=$s
			continue
		fi
		drv="$(cat -- "$work/drv.$i" 2>/dev/null)" || drv=""
		if ((s != 0)); then
			results[i]=$s
		elif [[ "$drv" != "$store"/* || ! "${drv#"$store"/}" =~ ^[^/[:space:]]+\.drv$ ]]; then
			printf 'check.sh: the evaluation of the check %s printed no derivation: %s\n' "${names[i]}" "$drv" >&2
			results[i]=1
		else
			mark=""
			((check_jobs == 1)) || mark="${names[i]}"
			start_nix "$mark" "" build --no-link --print-build-logs --keep-going "$drv^*"
			job_check[$!]=$i
			job_phase[$!]="build"
			running=$((running + 1))
		fi
	done

	((list_status == 0)) || first=$list_status
	if ((outputs_status != 0)); then
		printf 'check.sh: the other outputs failed (exit %d)\n' "$outputs_status" >&2
		((first != 0)) || first=$outputs_status
	fi
	for i in "${!names[@]}"; do
		if [[ -z "${results[i]:-}" ]]; then
			printf 'check.sh: the check %s was never built\n' "${names[i]}" >&2
			results[i]=1
		fi
		((results[i] == 0)) && continue
		failed+=("  ${names[i]} (exit ${results[i]})")
		((first != 0)) || first=${results[i]}
	done
	if ((${#failed[@]} > 0)); then
		printf 'check.sh: %d of %d checks failed:\n' "${#failed[@]}" "${#names[@]}" >&2
		printf '%s\n' "${failed[@]}" >&2
	fi
	((first == 0)) || return "$first"
	echo "flake: $(counted "${#names[@]}" check) built, and the other outputs checked"
}

# The record of the pairs the claude-code step verified: one line
# "<version> <download>" each, nothing secret. It is a cache: a record lost
# or unwritable only makes a run with the manifest unreachable fail. A
# record with any line of another shape counts as empty, and the next write
# replaces it.
verified_record() {
	local dir="${XDG_STATE_HOME:-}"
	# A relative XDG_STATE_HOME is to be ignored (XDG Base Directory).
	[[ "$dir" == /* ]] || dir="${HOME:+$HOME/.local/state}"
	[[ "$dir" == /* ]] || return 1
	printf '%s/ravnix/claude-code-verified\n' "$dir"
}

# Prints the pairs of record $1, or nothing when it is missing, unreadable
# or corrupt.
verified_pairs() {
	local shape='[^[:space:][:cntrl:]]+ /[^[:cntrl:]]*'
	[[ -f "$1" && -r "$1" ]] || return 0
	! LC_ALL=C grep -a -q -v -x -E -- "$shape" "$1" || return 0
	LC_ALL=C grep -a -x -E -- "$shape" "$1" || true
}

# Whether record $1 holds pair $2.
was_verified() {
	local line
	while IFS= read -r line; do
		[[ "$line" != "$2" ]] || return 0
	done < <(verified_pairs "$1")
	return 1
}

# Writes record $1 with pair $2 added (when not empty) and pair $3 removed,
# through a temporary file beside it.
rewrite_record() {
	local file="$1" add="$2" drop="$3" tmp line
	mkdir -p -- "${file%/*}" 2>/dev/null || return 1
	tmp="$(mktemp -- "$file.XXXXXX" 2>/dev/null)" || return 1
	if {
		while IFS= read -r line; do
			[[ "$line" == "$add" || "$line" == "$drop" ]] || printf '%s\n' "$line"
		done < <(verified_pairs "$file")
		[[ -z "$add" ]] || printf '%s\n' "$add"
	} >"$tmp" && mv -fT -- "$tmp" "$file" 2>/dev/null; then
		return 0
	fi
	rm -f -- "$tmp"
	return 1
}

step_claude-code() {
	local verify download version status=0 record pair
	verify="$(nix_ build --no-link --print-out-paths .#claude-code-verify)"
	download="$(nix_ build --no-link --print-out-paths .#claude-code.download)"
	version="$(nix_ eval --raw .#claude-code.version)"
	if [[ -z "$download" || ! -f "$download" ]]; then
		echo "check.sh: nix built no download for .#claude-code.download" >&2
		return 1
	fi
	echo "Claude Code $version, downloaded as $download"
	"$verify/bin/claude-code-verify" "$download" "$version" || status=$?
	pair="$version $download"
	record="$(verified_record)" || record=""
	# A pair the record could not hold as one line of its shape is never
	# written: reading it back would make the whole record corrupt.
	local recordable=1
	[[ "$version" =~ ^[^[:space:][:cntrl:]]+$ && "$download" == /* && "$download" != *[[:cntrl:]]* ]] ||
		recordable=""
	case "$status" in
	0)
		[[ -n "$record" && -n "$recordable" ]] && rewrite_record "$record" "$pair" "" ||
			printf 'check.sh: %s\n' \
				"could not record Claude Code $version as verified${record:+ in $record};" \
				"with the manifest unreachable, a later run fails for it." >&2
		;;
	1)
		# A pair that stayed recorded would pass a later run with the manifest
		# unreachable, so the whole record goes when the pair cannot.
		if [[ -n "$record" ]] && was_verified "$record" "$pair"; then
			if rewrite_record "$record" "" "$pair" || rm -f -- "$record" 2>/dev/null; then
				printf 'check.sh: %s\n' \
					"Claude Code $version, verified on an earlier run, is no longer recorded as verified." >&2
			else
				printf 'check.sh: %s\n' \
					"Claude Code $version, verified on an earlier run, could not be removed from $record; delete that file." \
					"Until then a run with the manifest unreachable passes for it." >&2
			fi
		fi
		;;
	3)
		if [[ -n "$record" ]] && was_verified "$record" "$pair"; then
			printf 'check.sh: %s\n' \
				"Anthropic's release manifest is unreachable, but Claude Code $version, downloaded as $download, was verified on an earlier run (recorded in $record)." \
				"The gate passes for it, as it would for no other download." >&2
			status=0
		else
			printf 'check.sh: %s\n' \
				"Anthropic's release manifest is unreachable, and Claude Code $version, downloaded as $download, was never verified here${record:+ (no record of it in $record)}." \
				"The gate fails rather than let an unverified binary out; push again once" \
				"downloads.claude.ai answers." >&2
		fi
		;;
	esac
	return "$status"
}

for name in "${steps[@]}"; do
	printf '\n==> %s\n' "$name"
	# A subshell with errexit, so a failing command inside the step fails it.
	set +e
	(
		set -e
		"step_$name"
	)
	status=$?
	set -e
	if ((status != 0)); then
		printf '\ncheck.sh: %s failed (exit %d)\n' "$name" "$status" >&2
		exit "$status"
	fi
done

if [[ -z "$deny_list" ]]; then
	printf '\ncheck.sh: all %d steps passed, but the public-boundary check was SKIPPED (ravnix.denyList is not set)\n' "${#steps[@]}"
else
	printf '\ncheck.sh: all %d steps passed\n' "${#steps[@]}"
fi
