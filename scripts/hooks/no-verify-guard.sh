#!/usr/bin/env bash
# The Claude Code PreToolUse hook for Bash. The git hooks in .githooks/ are
# the only check this repository has; there is no CI behind them. So this
# guard refuses a command that would skip them or point git at other hooks:
#
#   - --no-verify, or an abbreviation git accepts, on git commit, push,
#     merge, pull, am or rebase, and -n on git commit, also inside a cluster
#     such as -anm (git push -n is --dry-run and goes through)
#   - core.hooksPath set for one command: git -c, -c attached to the name,
#     --config-env, GIT_CONFIG_PARAMETERS and GIT_CONFIG_KEY_<n>; and
#     include.path or includeIf, which can load such a setting
#   - git config writing core.hooksPath to anything but .githooks, unsetting
#     it, removing or renaming the core section, or opening the config in an
#     editor
#
# It reads the command the way bash does: quotes, escapes, comments,
# heredocs, command and process substitution, and commands joined by ;, &&,
# ||, | and newlines. It follows bash -c, sh -c, eval, git rebase --exec and
# git aliases (from -c and from git's configuration), and finds git behind
# wrappers such as env, sudo, timeout or xargs. A message that mentions
# --no-verify, a heredoc body and a quoted argument are data, not options.
#
# What it does not catch: a command built at run time (a variable that holds
# the option, base64, printf escapes), a configuration file edited by hand,
# and hooks deleted or made non-executable. It stops the habit, not a
# determined bypass; the reviewer and the maintainer are the rest of the net.
#
# Claude Code passes the event as JSON on stdin. Exit 2 refuses the call and
# shows stderr to Claude; exit 0 lets it through. When the guard cannot read
# the command (no jq, input that is not JSON, a bug of its own), it refuses
# what looks like a git command and lets everything else through, so a
# broken guard never locks the agent out of the tools that would repair it.
#
# Changing this file so it refuses less needs the maintainer's explicit
# approval (AGENTS.md, rule 6).

set -euo pipefail
shopt -s inherit_errexit
export LC_ALL=C

decided=""
input=""
command_text=""

refuse() {
	decided=1
	printf 'no-verify-guard: refused: %s.\n' "$1" >&2
	echo "The git hooks are the only check this repository has, with no CI behind" \
		"them, so a command may neither skip them nor point git at other hooks" \
		"(AGENTS.md, rule 6). Leave that part out and fix what the hook reports." >&2
	exit 2
}

allow() {
	decided=1
	exit 0
}

mentions_git() {
	[[ "$1" =~ (^|[^[:alnum:]_./-])git([^[:alnum:]_.-]|$) || "$1" == *GIT_CONFIG_* ]]
}

# The guard cannot judge the command.
fallback() {
	if mentions_git "${command_text:-$input}"; then
		refuse "$1, so it refuses every command that looks like git until that is fixed"
	fi
	allow
}

# shellcheck disable=SC2329 # the EXIT trap calls it
on_exit() {
	local rc=$?
	if [[ -z "$decided" ]] && ((rc != 0)); then
		trap - EXIT
		fallback "the guard failed unexpectedly (exit $rc)"
	fi
}
trap on_exit EXIT

# Reading the command.
#
# tokenize splits a text into simple commands: W holds every word, after
# quote removal, and C one "start length" pair per simple command. A command
# or process substitution adds its own simple commands and stands in its
# word as a placeholder. P is the position in T; peek reads the characters at
# P and P+1 into ch and nx through a window of T, because bash takes time in
# proportion to a string's length for each ${T:P:1}.

T=""
N=0
P=0
win=""
wbase=0
ch=""
nx=""
RW=""
RQ=""
IN_BT=0
W=()
C=()
HD=()
texts=()

plain_re=$'^[^\t\n ;&|()<>`\\\'"$]+'
dq_plain_re=$'^[^"\\`$]+'

peek() {
	if ((P < wbase || P + 2 > wbase + ${#win})); then
		wbase=$P
		win="${T:P:4096}"
	fi
	ch="${win:P-wbase:1}"
	nx="${win:P-wbase+1:1}"
}

flush() {
	if ((${#words[@]} > 0)); then
		C+=("${#W[@]} ${#words[@]}")
		W+=("${words[@]}")
		words=()
	fi
}

skip_blanks() {
	while ((P < N)); do
		peek
		[[ "$ch" == ' ' || "$ch" == $'\t' ]] || break
		P=$((P + 1))
	done
}

comment() {
	local seg
	while ((P < N)); do
		peek
		seg="${win:P-wbase}"
		seg="${seg%%$'\n'*}"
		P=$((P + ${#seg}))
		((P >= wbase + ${#win})) || break
	done
}

# After a newline: the bodies of the heredocs started on that line are data.
heredocs() {
	local entry strip delim rest line
	for entry in "${HD[@]}"; do
		strip="${entry:0:1}"
		delim="${entry:1}"
		rest="${T:P}"
		if ((strip == 0)); then
			if [[ "$rest" == "$delim" || "$rest" == "$delim"$'\n'* ]]; then
				P=$((P + ${#delim} + 1))
			elif [[ "$rest" == *$'\n'"$delim"$'\n'* ]]; then
				line="${rest%%$'\n'"$delim"$'\n'*}"
				P=$((P + ${#line} + ${#delim} + 2))
			else
				P=$N
			fi
		else
			while ((P < N)); do
				line="${rest%%$'\n'*}"
				P=$((P + ${#line} + 1))
				rest="${rest:${#line}+1}"
				line="${line#"${line%%[!$'\t']*}"}"
				[[ "$line" != "$delim" ]] || break
			done
		fi
	done
	HD=()
}

read_dq() {
	local q=""
	while ((P < N)); do
		peek
		case "$ch" in
		'"')
			P=$((P + 1))
			break
			;;
		\\)
			case "$nx" in
			'$' | '`' | '"' | \\) q+="$nx" ;;
			$'\n') ;;
			*) q+="\\$nx" ;;
			esac
			P=$((P + 2))
			;;
		'`')
			P=$((P + 1))
			scan backtick
			q+="\`...\`"
			;;
		'$')
			case "$nx" in
			'(')
				P=$((P + 2))
				scan paren
				q+="\$(...)"
				;;
			'{')
				P=$((P + 2))
				skip_braces
				q+="\${...}"
				;;
			*)
				q+='$'
				P=$((P + 1))
				;;
			esac
			;;
		*)
			if [[ "${win:P-wbase}" =~ $dq_plain_re ]]; then
				q+="${BASH_REMATCH[0]}"
				P=$((P + ${#BASH_REMATCH[0]}))
			else
				q+="$ch"
				P=$((P + 1))
			fi
			;;
		esac
	done
	RQ="$q"
}

read_ansi() {
	local q=""
	while ((P < N)); do
		peek
		case "$ch" in
		"'")
			P=$((P + 1))
			break
			;;
		\\)
			case "$nx" in
			n) q+=$'\n' ;;
			t) q+=$'\t' ;;
			*) q+="$nx" ;;
			esac
			P=$((P + 2))
			;;
		*)
			q+="$ch"
			P=$((P + 1))
			;;
		esac
	done
	RQ="$q"
}

skip_braces() {
	local depth=1
	while ((P < N && depth > 0)); do
		peek
		case "$ch" in
		'{') depth=$((depth + 1)) ;;
		'}') depth=$((depth - 1)) ;;
		\\) P=$((P + 1)) ;;
		esac
		P=$((P + 1))
	done
}

# Reads one word at P into RW, with its quotes removed.
read_word() {
	local w="" seg
	while ((P < N)); do
		peek
		case "$ch" in
		' ' | $'\t' | $'\n' | ';' | '&' | '|' | '(' | ')' | '<' | '>') break ;;
		'`')
			((IN_BT == 0)) || break
			P=$((P + 1))
			scan backtick
			w+="\`...\`"
			;;
		\\)
			[[ "$nx" == $'\n' ]] || w+="$nx"
			P=$((P + 2))
			;;
		"'")
			P=$((P + 1))
			while ((P < N)); do
				peek
				seg="${win:P-wbase}"
				seg="${seg%%\'*}"
				w+="$seg"
				P=$((P + ${#seg}))
				if ((P < wbase + ${#win})); then
					P=$((P + 1))
					break
				fi
			done
			;;
		'"')
			P=$((P + 1))
			read_dq
			w+="$RQ"
			;;
		'$')
			case "$nx" in
			'(')
				P=$((P + 2))
				scan paren
				w+="\$(...)"
				;;
			'{')
				P=$((P + 2))
				skip_braces
				w+="\${...}"
				;;
			"'")
				P=$((P + 2))
				read_ansi
				w+="$RQ"
				;;
			'"') P=$((P + 1)) ;;
			*)
				w+='$'
				P=$((P + 1))
				;;
			esac
			;;
		*)
			if [[ "${win:P-wbase}" =~ $plain_re ]]; then
				w+="${BASH_REMATCH[0]}"
				P=$((P + ${#BASH_REMATCH[0]}))
			else
				w+="$ch"
				P=$((P + 1))
			fi
			;;
		esac
	done
	RW="$w"
}

# At < or >: a redirection, whose target is dropped, a heredoc, whose
# delimiter is noted, or a process substitution.
redirect() {
	local op strip=0
	peek
	op="$ch"
	P=$((P + 1))
	peek
	if [[ "$ch" == '(' ]]; then
		P=$((P + 1))
		scan paren
		words+=("$op(...)")
		return 0
	fi
	if [[ "$op" == '<' && "$ch" == '<' ]]; then
		P=$((P + 1))
		peek
		if [[ "$ch" == '<' ]]; then
			P=$((P + 1))
			skip_blanks
			read_word
			return 0
		fi
		if [[ "$ch" == '-' ]]; then
			strip=1
			P=$((P + 1))
		fi
		skip_blanks
		read_word
		HD+=("$strip$RW")
		return 0
	fi
	case "$ch" in
	'>' | '&' | '|') P=$((P + 1)) ;;
	esac
	skip_blanks
	peek
	case "$ch" in
	'' | $'\n' | ';' | '&' | '|' | '(' | ')' | '<' | '>') ;;
	*) read_word ;;
	esac
	return 0
}

# Reads simple commands until the end of T (mode top), the ) that closes a
# $( or <( (mode paren), or the closing backtick (mode backtick).
scan() {
	local mode="$1" words=() depth=0 at saved_bt="$IN_BT"
	if [[ "$mode" == backtick ]]; then IN_BT=1; else IN_BT=0; fi
	while ((P < N)); do
		at=$P
		peek
		case "$ch" in
		' ' | $'\t') P=$((P + 1)) ;;
		$'\n')
			P=$((P + 1))
			flush
			heredocs
			;;
		';' | '|')
			P=$((P + 1))
			flush
			;;
		'&')
			P=$((P + 1))
			if [[ "$nx" == '>' ]]; then
				redirect
			else
				flush
			fi
			;;
		'(')
			P=$((P + 1))
			flush
			depth=$((depth + 1))
			;;
		')')
			P=$((P + 1))
			flush
			if ((depth > 0)); then
				depth=$((depth - 1))
			elif [[ "$mode" == paren ]]; then
				IN_BT="$saved_bt"
				return 0
			fi
			;;
		'<' | '>') redirect ;;
		'#') comment ;;
		\\)
			if [[ "$nx" == $'\n' ]]; then
				P=$((P + 2))
			else
				read_word
				words+=("$RW")
			fi
			;;
		'`')
			if [[ "$mode" == backtick ]]; then
				P=$((P + 1))
				flush
				IN_BT="$saved_bt"
				return 0
			fi
			read_word
			words+=("$RW")
			;;
		*)
			read_word
			words+=("$RW")
			;;
		esac
		# Never stand still, whatever the text holds.
		((P > at)) || P=$((at + 1))
	done
	flush
	IN_BT="$saved_bt"
	return 0
}

tokenize() {
	T="$1"
	N=${#T}
	P=0
	win=""
	wbase=0
	IN_BT=0
	W=()
	C=()
	HD=()
	scan top
}

# Judging the commands.

is_no_verify() {
	[[ ${#1} -ge 9 && "--no-verify" == "$1"* ]]
}

# A variable assignment anywhere in a command: a prefix, export or env.
judge_assignment() {
	local name value
	# A cheap test first: bash takes time in the square of a word's length
	# for ${1#*=}, and a word can be a whole file.
	[[ "$1" == GIT_CONFIG_* && "$1" == *=* ]] || return 0
	name="${1%%=*}"
	value="${1:${#name}+1}"
	case "$name" in
	GIT_CONFIG_PARAMETERS)
		if [[ "${value,,}" == *hookspath* || "${value,,}" == *include* ]]; then
			refuse "GIT_CONFIG_PARAMETERS sets core.hooksPath or includes a configuration for the commands it reaches"
		fi
		;;
	GIT_CONFIG_KEY_*)
		case "${value,,}" in
		core.hookspath | include.path | includeif.* | alias.*)
			refuse "$name=$value sets core.hooksPath, an include or an alias for the commands it reaches"
			;;
		esac
		;;
	esac
	return 0
}

# The name of a setting given for one git command.
judge_setting_name() {
	local name="${1%%=*}"
	case "${name,,}" in
	core.hookspath) refuse "the command sets core.hooksPath, which points git at other hooks; it must stay .githooks" ;;
	include.path | includeif.*) refuse "the command includes a git configuration (${name}), which can set core.hooksPath" ;;
	esac
	return 0
}

# -c name=value: the name, and an alias's expansion.
judge_setting() {
	local name="${1%%=*}" value=""
	[[ "$1" != *=* ]] || value="${1#*=}"
	judge_setting_name "$name"
	if [[ "${name,,}" == alias.* ]]; then
		aliases["${name#*.}"]="$value"
	fi
	return 0
}

judge_commit() {
	local args=("$@") n=$# i a opt cluster flags
	for ((i = 0; i < n; i++)); do
		a="${args[i]}"
		case "$a" in
		--) return 0 ;;
		--*)
			opt="${a%%=*}"
			if is_no_verify "$opt"; then
				refuse "git commit $a skips the pre-commit and commit-msg hooks"
			fi
			if [[ "$a" != *=* ]]; then
				case "$opt" in
				--message | --file | --reuse-message | --reedit-message | --fixup | --squash | \
					--author | --date | --template | --cleanup | --trailer | --pathspec-from-file)
					i=$((i + 1))
					;;
				esac
			fi
			;;
		-?*)
			# Short options up to the first that takes an argument: the rest
			# of the cluster, or the next word when it ends the cluster, is
			# that argument (-u and -S take one only when attached).
			cluster="${a#-}"
			flags="${cluster%%[mFCctuS]*}"
			if [[ "$flags" == *n* ]]; then
				refuse "git commit -n is --no-verify, which skips the pre-commit and commit-msg hooks"
			fi
			if ((${#flags} + 1 == ${#cluster})) && [[ "${cluster: -1}" == [mFCct] ]]; then
				i=$((i + 1))
			fi
			;;
		esac
	done
	return 0
}

judge_no_verify() {
	local sub="$1" a prev=""
	shift
	for a in "$@"; do
		[[ "$a" != -- ]] || return 0
		case "$prev" in
		-m | --message | -F | --file | -o | --push-option | -X | --strategy-option | -s | --strategy)
			prev=""
			continue
			;;
		-x | --exec)
			texts+=("$a")
			prev=""
			continue
			;;
		esac
		if [[ "$a" == --* ]] && is_no_verify "${a%%=*}"; then
			refuse "git $sub $a skips its hooks"
		fi
		[[ "$a" != --exec=* ]] || texts+=("${a#--exec=}")
		prev="$a"
	done
	return 0
}

judge_config() {
	local args=("$@") n=$# i a action="" pos=() name
	for ((i = 0; i < n; i++)); do
		a="${args[i]}"
		case "$a" in
		--)
			pos+=("${args[@]:i+1}")
			break
			;;
		--get | --get-all | --get-regexp | --get-urlmatch | --get-color | --get-colorbool | -l | --list)
			action="get"
			;;
		--add | --replace-all) action="set" ;;
		--unset | --unset-all) action="unset" ;;
		--rename-section | --remove-section) action="section" ;;
		-e | --edit) action="edit" ;;
		-f | --file | --blob | --type | --default | --comment | --value | --url) i=$((i + 1)) ;;
		-*) ;;
		*) pos+=("$a") ;;
		esac
	done
	if [[ -z "$action" && ${#pos[@]} -gt 0 ]]; then
		case "${pos[0]}" in
		list | get) action="get" ;;
		set) action="set" ;;
		unset) action="unset" ;;
		rename-section | remove-section) action="section" ;;
		edit) action="edit" ;;
		esac
		[[ -z "$action" ]] || pos=("${pos[@]:1}")
	fi
	name="${pos[0]:-}"
	name="${name,,}"
	case "$action" in
	get) ;;
	edit) refuse "git config --edit can change core.hooksPath unseen; set one key with git config instead" ;;
	unset)
		[[ "$name" != core.hookspath ]] ||
			refuse "unsetting core.hooksPath turns the git hooks off"
		;;
	section)
		[[ "$name" != core ]] ||
			refuse "removing or renaming the core section drops core.hooksPath"
		;;
	*)
		if [[ "$name" == core.hookspath && ${#pos[@]} -ge 2 && "${pos[1]}" != .githooks ]]; then
			refuse "git config core.hooksPath ${pos[1]} points git at other hooks; it must stay .githooks"
		fi
		;;
	esac
	return 0
}

judge_git() {
	local args=("$@") n=$# i=0 a sub="" value
	local -A aliases=()
	while ((i < n)); do
		a="${args[i]}"
		case "$a" in
		-c)
			judge_setting "${args[i + 1]:-}"
			i=$((i + 2))
			;;
		-c*)
			judge_setting "${a#-c}"
			i=$((i + 1))
			;;
		--config-env=*)
			judge_setting_name "${a#--config-env=}"
			i=$((i + 1))
			;;
		--config-env)
			judge_setting_name "${args[i + 1]:-}"
			i=$((i + 2))
			;;
		-C | --git-dir | --work-tree | --namespace | --super-prefix | --attr-source | --list-cmds)
			i=$((i + 2))
			;;
		-*) i=$((i + 1)) ;;
		*)
			sub="$a"
			i=$((i + 1))
			break
			;;
		esac
	done
	[[ -n "$sub" ]] || return 0
	local rest=("${args[@]:i}")
	case "$sub" in
	commit) judge_commit "${rest[@]}" ;;
	push | merge | pull | am | rebase) judge_no_verify "$sub" "${rest[@]}" ;;
	config) judge_config "${rest[@]}" ;;
	*)
		# An alias: judge what it expands to, with the same arguments.
		if [[ -n "${aliases[$sub]+set}" ]]; then
			value="${aliases[$sub]}"
		else
			value="$(git config --get "alias.$sub" 2>/dev/null)" || value=""
		fi
		if [[ "$value" == '!'* ]]; then
			texts+=("${value#!} ${rest[*]}")
		elif [[ -n "$value" ]]; then
			texts+=("git $value ${rest[*]}")
		fi
		;;
	esac
	return 0
}

# A shell's -c string.
judge_shell() {
	local a want=0 skip=0
	for a in "$@"; do
		if ((skip)); then
			skip=0
			continue
		fi
		case "$a" in
		-o | +o | -O | +O | --rcfile | --init-file) skip=1 ;;
		--*) ;;
		-* | +*) [[ "$a" != *c* ]] || want=1 ;;
		*)
			((want == 0)) || texts+=("$a")
			return 0
			;;
		esac
	done
	return 0
}

judge() {
	local words=("$@") n=$# i w
	for w in "${words[@]}"; do
		judge_assignment "$w"
	done
	for ((i = 0; i < n; i++)); do
		w="${words[i]}"
		# Only a short word can name a command, and ${w##*/} takes time in
		# the square of a long one's length.
		((${#w} <= 256)) || continue
		case "${w##*/}" in
		bash | sh | dash | zsh | ksh | mksh | ash) judge_shell "${words[@]:i+1}" ;;
		eval) texts+=("${words[*]:i+1}") ;;
		git)
			judge_git "${words[@]:i+1}"
			return 0
			;;
		esac
	done
	return 0
}

input="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
	command_re='"command"[[:space:]]*:[[:space:]]*"(([^"\\]|\\.)*)"'
	if [[ "$input" =~ $command_re ]]; then
		command_text="${BASH_REMATCH[1]}"
	fi
	fallback "jq not found, so the guard cannot read the command (install jq)"
fi
tool="$(jq -r '.tool_name // empty' <<<"$input" 2>/dev/null)" ||
	fallback "could not read the hook input"
[[ "$tool" == Bash ]] || allow
command_text="$(jq -r '.tool_input.command // empty' <<<"$input" 2>/dev/null)" ||
	fallback "could not read the command from the hook input"

# Nothing to refuse without git or a git setting in the text, once quotes
# and backslashes, which can split a word, are gone.
bare="${command_text//[\"\'\\]/}"
[[ "$bare" == *git* || "$bare" == *GIT_CONFIG_* ]] || allow

texts=("$command_text")
judged=0
while ((${#texts[@]} > 0)); do
	judged=$((judged + 1))
	((judged <= 64)) || fallback "the command nests more than 64 commands deep"
	tokenize "${texts[0]}"
	texts=("${texts[@]:1}")
	for entry in "${C[@]}"; do
		judge "${W[@]:${entry% *}:${entry#* }}"
	done
done
allow
