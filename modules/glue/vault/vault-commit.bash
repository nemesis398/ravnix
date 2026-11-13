# vault-commit MESSAGE [PATH...]: commit PATHs of the vault, or what is
# staged, the way this host commits: the one entry point of the vault
# skills, on both hosts. ./scripts.nix fills in every @name@.
#
# How is vault.commitVia of the skill values (~/.config/ravnix/
# skill-values.json, or $RAVNIX_SKILL_VALUES), which modules/glue/vault.nix
# sets to ravnix-link on both shapes:
#
#   ravnix-link  `ravnix-link vault-commit MESSAGE PATH...`: on the server
#                it commits in the link's queue, after the Obsidian
#                operations queued before it and never beside the delivery
#                service's git; on the laptop it goes to the server, which
#                commits once its copy of the vault has the files as they
#                are here.
#   git          for a host whose vault no ravnix-link serves: git add the
#                PATHs that are there, then git commit them (a PATH that is
#                gone commits its removal), or commit what is staged, at
#                once. One run at a time per repository, by a lock in its
#                .git that ravnix-link does not take: on a ravnix server
#                this gives up the order after queued Obsidian operations
#                and may race the delivery service.
#
# A PATH is relative to the vault's root; an absolute one inside the vault
# is made relative. The vault is ravnix.link.vault, or $VAULT_COMMIT_VAULT.
# Exit 0 done (or queued, or nothing to commit), 64 bad usage, otherwise
# the failure's, with what failed on standard error.

jq=@jq@
git=@git@
flock=@flock@
link=@link@
vault=${VAULT_COMMIT_VAULT:-@vault@}

usage() {
	cat <<'EOF'
usage: vault-commit MESSAGE [PATH...]

Commit PATHs of the vault (relative to its root, or absolute inside it),
or what is staged when no PATH is given, the way this host commits:
vault.commitVia of the skill values, git or ravnix-link.
EOF
}

die_usage() {
	printf 'vault-commit: %s\n' "$1" >&2
	echo "run vault-commit --help for the usage" >&2
	exit 64
}

fail() {
	printf 'vault-commit: %s\n' "$1" >&2
	exit 1
}

if (($# == 1)) && [[ $1 == --help || $1 == -h ]]; then
	usage
	exit 0
fi
(($# >= 1)) || die_usage "no message"
message=$1
shift
[[ -n $message ]] || die_usage "the message is empty"

values=${RAVNIX_SKILL_VALUES:-${XDG_CONFIG_HOME:-$HOME/.config}/ravnix/skill-values.json}
[[ -r $values ]] ||
	fail "cannot read the skill values, $values: ravnix writes them from ravnix.claude.skillValues"
via=$("$jq" -r '(.vault.commitVia)? | strings' -- "$values" 2>&1) ||
	fail "the skill values, $values, are not JSON: $via"
case $via in
git | ravnix-link) ;;
"") fail "the skill values, $values, have no vault.commitVia, git or ravnix-link (ravnix.claude.skillValues.vault.commitVia)" ;;
*) fail "vault.commitVia in $values is \"$via\", which is neither git nor ravnix-link" ;;
esac

paths=()
for p in "$@"; do
	if [[ $p == /* ]]; then
		[[ -n $vault && $p == "${vault%/}"/?* ]] ||
			die_usage "$p is not in the vault${vault:+, $vault}: a path is relative to the vault's root"
		p=${p#"${vault%/}"/}
	fi
	case /$p/ in
	// | */../* | */./* | *//*)
		die_usage "\"$p\" is no path in the vault: no empty, . or .. part"
		;;
	esac
	paths+=("$p")
done

if [[ $via == ravnix-link ]]; then
	if ! command -v "$link" >/dev/null 2>&1; then
		fail "vault.commitVia is ravnix-link, and ravnix-link is not installed here ($link)"
	fi
	exec "$link" vault-commit "$message" "${paths[@]}"
fi

[[ -n $vault ]] || fail "no vault is configured here (ravnix.link.vault)"
export LC_ALL=C
gitdir=$("$git" -C "$vault" rev-parse --absolute-git-dir 2>&1) ||
	fail "the vault, $vault, is no git repository here: $gitdir"
# A repository around the vault (its own .git not there yet) is not the
# vault's: its commits must not go there.
top=$("$git" -C "$vault" rev-parse --show-toplevel 2>&1) ||
	fail "the vault, $vault, has no work tree here: $top"
real=$(cd -- "$vault" && pwd -P) || fail "cannot enter the vault, $vault"
[[ $top == "$real" ]] ||
	fail "the repository at $top is not the vault's own; the vault, $vault, has no .git of its own here"
# One run at a time: git's index.lock would fail the second at once.
exec 9>>"$gitdir/ravnix-vault-commit.lock" ||
	fail "cannot open the lock in $gitdir"
"$flock" -w 120 9 || fail "another vault-commit has held the lock in $gitdir for 2 minutes"

present=()
for p in "${paths[@]}"; do
	if [[ -e $vault/$p || -L $vault/$p ]]; then
		present+=("$p")
	fi
done
if ((${#present[@]} > 0)); then
	if ! out=$("$git" --literal-pathspecs -C "$vault" add -A -- "${present[@]}" 2>&1); then
		fail "git add failed: $out"
	fi
fi
argv=("$git" --literal-pathspecs -C "$vault" commit -m "$message")
if ((${#paths[@]} > 0)); then
	argv+=(-- "${paths[@]}")
fi
status=0
out=$("${argv[@]}" 2>&1) || status=$?
if ((status == 0)); then
	printf '%s\n' "$out"
	exit 0
fi
case $out in
*"nothing to commit"* | *"nothing added to commit"* | *"no changes added to commit"*)
	echo "vault-commit: nothing to commit" >&2
	exit 0
	;;
esac
printf '%s\n' "$out" >&2
fail "git commit failed (exit $status)"
