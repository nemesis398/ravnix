#!/usr/bin/env bash
# ravnix-paperless-setup --url URL --token-file FILE --owners NAME,NAME,...
#                        --household NAME --family-group NAME
#                        --fallback-owner NAME [--consume-root DIR]
#
# Puts a Paperless-ngx instance into the shape of the household design over
# its REST API, as the superuser whose API token FILE holds:
#
#   - the group --family-group with view, add and change on documents, tags,
#     correspondents, document types, storage paths and saved views, and on
#     UI settings, which the web UI needs (each user's own); no other
#     permission (README.md says why not the tasks);
#   - the user --household, which owns the household's documents and never
#     signs in: inactive, no staff or superuser flag, no group, no
#     permission of its own, made without a password;
#   - one workflow "ravnix: fallback owner", order 0: every file the consume
#     folder takes (DIR/*) is --fallback-owner's, an existing superuser,
#     with no grant, so that no file is ever left without an owner, which
#     the whole group would see;
#   - for each owner one workflow, "ravnix: owner NAME", order 1, so it runs
#     after the fallback and its owner wins: a file the consume folder takes
#     from a path matching DIR/NAME/* is NAME's;
#   - for the household one workflow, "ravnix: household NAME", order 1: a
#     file from DIR/NAME/* is the household's, and the group may view and
#     change it.
#
# DIR is the consume folder as Paperless sees it, --consume-root,
# /usr/src/paperless/consume (the container's) unless given. Every filter
# starts with it: Paperless matches a filter against the file's whole path
# with fnmatch, whose * also matches /, so a filter of */consume/NAME/*
# would also take DIR/OTHER/consume/NAME/x.pdf, and a person could plant a
# file into another's account by making that folder in their own inbox.
#
# Each owner must have an account already (people sign in once through
# OIDC, which makes it). An owner without one gets no workflow, so their
# files are the fallback owner's: the rest is made, the run names the
# missing owners and exits 1, and a later run completes it. A fallback
# owner that is no superuser, or no one, stops the run with 1 before it
# changes anything. The household's name may be in --owners, as it is in the
# deployment's owner list; it stands for the household there.
#
# It is idempotent: what is already as described is left alone, what
# differs is put back (a group's permissions, the household user's flags, a
# workflow's order, trigger and action), and a run that changes nothing says so.
# It never deletes: a workflow of its own for an owner no longer listed is
# named and left as it is. Workflows of other names are not touched.
#
# The token reaches curl through a configuration file in a private
# directory (mode 700, removed on exit), never on a command line or in the
# environment of a program it starts.
#
# Exit status: 0 done, 1 an API call failed (printed with its endpoint), an
# owner has no account or the fallback owner is no superuser, 2 bad
# arguments.
set -euo pipefail
export LC_ALL=C

prog=ravnix-paperless-setup
# The API version the calls ask for: Paperless 3.x answers 9 and 10.
api_version=10
# The group's permissions, by codename.
permissions=()
for model in document tag correspondent documenttype storagepath savedview uisettings; do
	permissions+=("view_$model" "add_$model" "change_$model")
done

say() { printf '%s: %s\n' "$prog" "$*" >&2; }
usage() {
	if (($#)); then say "$*"; fi
	say "usage: $prog --url URL --token-file FILE --owners NAME,NAME,... --household NAME --family-group NAME --fallback-owner NAME [--consume-root DIR]"
	exit 2
}

url='' token_file='' owners_arg='' household='' group='' fallback=''
root=/usr/src/paperless/consume
seen=' '
while (($#)); do
	case $1 in
	-h | --help)
		printf 'usage: %s --url URL --token-file FILE --owners NAME,NAME,... --household NAME --family-group NAME --fallback-owner NAME [--consume-root DIR]\n' "$prog"
		exit 0
		;;
	--url | --token-file | --owners | --household | --family-group | --fallback-owner | --consume-root)
		(($# >= 2)) || usage "$1 needs a value"
		[[ $seen != *" $1 "* ]] || usage "$1 is given twice"
		seen+="$1 "
		case $1 in
		--url) url=$2 ;;
		--token-file) token_file=$2 ;;
		--owners) owners_arg=$2 ;;
		--household) household=$2 ;;
		--family-group) group=$2 ;;
		--fallback-owner) fallback=$2 ;;
		--consume-root) root=$2 ;;
		esac
		shift 2
		;;
	*) usage "unknown argument: $1" ;;
	esac
done
for option in --url --token-file --owners --household --family-group --fallback-owner; do
	[[ $seen == *" $option "* ]] || usage "$option is missing"
done

# A user name: what Django takes, without the non-ASCII letters, and
# without a character that means something in the workflow's path filter
# (*, ?, [) or in a path (/).
name_ok() { [[ ${#1} -le 150 && $1 =~ ^[A-Za-z0-9][A-Za-z0-9._@+-]*$ ]]; }

[[ $url =~ ^https?://[^[:space:]]+$ ]] || usage "--url must be an http:// or https:// address, not \"$url\""
while [[ $url == */ ]]; do url=${url%/}; done
name_ok "$household" || usage "--household must be a user name (letters, digits, . _ @ + -), not \"$household\""
name_ok "$fallback" || usage "--fallback-owner must be a user name (letters, digits, . _ @ + -), not \"$fallback\""
[[ -n $group && ${#group} -le 150 && $group != *[[:cntrl:]]* ]] ||
	usage "--family-group must be a group name of one line and at most 150 characters"
# The consume root: an absolute path of plain segments, so that it means
# itself in a filter (no *, ? or [) and is the path Paperless reports (no .
# or .. segment, no trailing /).
while [[ $root == ?*/ ]]; do root=${root%/}; done
[[ $root =~ ^(/[A-Za-z0-9._@+-]+)+$ && /$root/ != */./* && /$root/ != */../* ]] ||
	usage "--consume-root must be an absolute path of letters, digits, . _ @ + - and /, without a . or .. segment, not \"$root\""

owners=()
[[ -n $owners_arg && $owners_arg != *, ]] || usage "--owners must name at least one owner, with no empty entry"
IFS=, read -r -a listed <<<"$owners_arg"
for owner in "${listed[@]}"; do
	name_ok "$owner" || usage "--owners: \"$owner\" is no user name (letters, digits, . _ @ + -)"
	for other in "${owners[@]}"; do
		[[ $other != "$owner" ]] || usage "--owners names $owner twice"
	done
	owners+=("$owner")
done

[[ -f $token_file && -r $token_file ]] || usage "--token-file $token_file is not a readable file"
token=$(<"$token_file")
[[ $token =~ ^[A-Za-z0-9._~+/=-]+$ ]] || usage "--token-file $token_file must hold one API token, on one line"

umask 077
work=$(mktemp -d "${TMPDIR:-/tmp}/$prog.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
printf 'header = "Authorization: Token %s"\n' "$token" >"$work/auth"
unset token

# api METHOD PATH [BODY]: one call, its JSON answer in $work/answer. A call
# that fails, or answers anything but 2xx with JSON, ends the run with 1,
# naming the call.
api() {
	local method=$1 path=$2 body=${3-} code
	# --disable (first) keeps a ~/.curlrc out of the calls.
	local args=(
		--disable
		--silent --show-error --max-time 60
		--config "$work/auth"
		--header "Accept: application/json; version=$api_version"
		--request "$method"
		--output "$work/answer"
		--write-out '%{http_code}'
	)
	if [[ -n $body ]]; then
		printf '%s' "$body" >"$work/request"
		args+=(--header 'Content-Type: application/json' --data-binary "@$work/request")
	fi
	: >"$work/answer"
	if ! code=$(curl "${args[@]}" "$url$path" 2>"$work/error"); then
		say "$method $path: $(tr '\n' ' ' <"$work/error" | head -c 300)"
		exit 1
	fi
	if [[ $code != 2?? ]]; then
		say "$method $path: HTTP $code: $(tr -s '\n\t' '  ' <"$work/answer" | head -c 500)"
		exit 1
	fi
	if ! jq -e . "$work/answer" >/dev/null 2>&1; then
		say "$method $path: HTTP $code, but the answer is not JSON"
		exit 1
	fi
}

# list PATH FILE: all objects of a list endpoint into FILE, as one page.
list() {
	api GET "$1?page_size=100000"
	if ! jq -e '.next == null and (.results | type) == "array"' "$work/answer" >/dev/null; then
		say "GET $1: the answer is not one page of results"
		exit 1
	fi
	jq -c '.results' "$work/answer" >"$2"
}

changes=0
changed() {
	printf '%s\n' "$*"
	changes=$((changes + 1))
}

# --- the fallback owner, before any change -------------------------------
list /api/users/ "$work/users"
fallback_id=$(jq --arg n "$fallback" 'map(select(.username == $n and .is_superuser and .is_active)) | first | .id // empty' "$work/users")
if [[ -z $fallback_id ]]; then
	say "GET /api/users/: the fallback owner $fallback is no active superuser here; nothing was changed"
	exit 1
fi

# --- the group -------------------------------------------------------------
want_perms=$(printf '%s\n' "${permissions[@]}" | jq -Rsc 'split("\n") | map(select(. != "")) | sort')
list /api/groups/ "$work/groups"
existing=$(jq -c --arg n "$group" 'map(select(.name == $n)) | first // empty' "$work/groups")
if [[ -z $existing ]]; then
	api POST /api/groups/ "$(jq -nc --arg n "$group" --argjson p "$want_perms" '{name: $n, permissions: $p}')"
	group_id=$(jq '.id' "$work/answer")
	changed "made the group $group: view, add and change on documents, tags, correspondents, document types, storage paths, saved views and UI settings"
else
	group_id=$(jq '.id' <<<"$existing")
	if [[ $(jq -c '.permissions | sort' <<<"$existing") != "$want_perms" ]]; then
		api PATCH "/api/groups/$group_id/" "$(jq -nc --argjson p "$want_perms" '{permissions: $p}')"
		changed "set the permissions of the group $group back to view, add and change on the seven models (it had: $(jq -r '.permissions | sort | join(", ")' <<<"$existing"))"
	fi
fi

# --- the household user ----------------------------------------------------
want_user='{"is_active": false, "is_staff": false, "is_superuser": false, "groups": [], "user_permissions": []}'
existing=$(jq -c --arg n "$household" 'map(select(.username == $n)) | first // empty' "$work/users")
if [[ -z $existing ]]; then
	api POST /api/users/ "$(jq -c --arg n "$household" '. + {username: $n}' <<<"$want_user")"
	household_id=$(jq '.id' "$work/answer")
	changed "made the user $household: inactive, without a password, group or permission"
else
	household_id=$(jq '.id' <<<"$existing")
	have=$(jq -c '{is_active, is_staff, is_superuser, groups: (.groups | sort), user_permissions: (.user_permissions | sort)}' <<<"$existing")
	if [[ $have != "$(jq -c . <<<"$want_user")" ]]; then
		api PATCH "/api/users/$household_id/" "$want_user"
		changed "put the user $household back to inactive, without a group or permission (it was: $have)"
	fi
fi

# --- the workflows ---------------------------------------------------------
list /api/workflows/ "$work/workflows"

# What decides a workflow's effect: its trigger (which files) and its action
# (whose they become, who else may see and change them). A workflow that
# differs in any of this is written anew.
norm='def norm: {
	enabled, order,
	triggers: [.triggers[] | {type, sources: ([.sources[] | tostring] | sort), filter_path, filter_filename, filter_mailrule}],
	actions: [.actions[] | {type, assign_owner,
		assign_view_users: (.assign_view_users | sort), assign_view_groups: (.assign_view_groups | sort),
		assign_change_users: (.assign_change_users | sort), assign_change_groups: (.assign_change_groups | sort)}]
};'

# workflow NAME ORDER PATH OWNER_ID GRANT WHAT: the workflow NAME, at ORDER,
# that gives a file from the consume folder whose path matches PATH to
# OWNER_ID, and view and change on it to the groups of GRANT (a JSON list);
# WHAT says it in the run's output.
workflow() {
	local name=$1 order=$2 path=$3 owner_id=$4 grant=$5 what=$6 want existing id
	want=$(jq -nc --arg name "$name" --argjson order "$order" --arg path "$path" \
		--argjson owner "$owner_id" --argjson grant "$grant" '{
			name: $name,
			order: $order,
			enabled: true,
			triggers: [{type: 1, sources: [1], filter_path: $path, filter_filename: null, filter_mailrule: null}],
			actions: [{type: 1, assign_owner: $owner,
				assign_view_users: [], assign_view_groups: $grant,
				assign_change_users: [], assign_change_groups: $grant}]
		}')
	existing=$(jq -c --arg n "$name" 'map(select(.name == $n)) | first // empty' "$work/workflows")
	if [[ -z $existing ]]; then
		api POST /api/workflows/ "$want"
		changed "made the workflow \"$name\": $what"
	elif ! jq -en --argjson have "$existing" --argjson want "$want" "$norm"' ($have | norm) == ($want | norm)' >/dev/null; then
		id=$(jq '.id' <<<"$existing")
		api PUT "/api/workflows/$id/" "$want"
		changed "put the workflow \"$name\" back: $what"
	fi
}

workflow "ravnix: fallback owner" 0 "$root/*" "$fallback_id" '[]' \
	"files from $root/* are $fallback's unless a later workflow names their owner"
missing=()
wanted=("ravnix: household $household")
for owner in "${owners[@]}"; do
	[[ $owner != "$household" ]] || continue
	owner_id=$(jq --arg n "$owner" 'map(select(.username == $n)) | first | .id // empty' "$work/users")
	if [[ -z $owner_id ]]; then
		missing+=("$owner")
		continue
	fi
	wanted+=("ravnix: owner $owner")
	workflow "ravnix: owner $owner" 1 "$root/$owner/*" "$owner_id" '[]' \
		"files from $root/$owner/* are $owner's"
done
workflow "ravnix: household $household" 1 "$root/$household/*" "$household_id" "[$group_id]" \
	"files from $root/$household/* are $household's, and the group $group may view and change them"

# The tool's own workflows that this run did not ask for: named, not touched.
jq -r --argjson wanted "$(printf '%s\n' "${wanted[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')" \
	'.[] | .name | select((startswith("ravnix: owner ") or startswith("ravnix: household ")) and (IN($wanted[]) | not))' \
	"$work/workflows" | while IFS= read -r name; do
	printf 'the workflow "%s" is for no one in --owners; left as it is (delete it in Paperless if it is stale)\n' "$name"
done

if ((${#missing[@]})); then
	names=$(printf '%s, ' "${missing[@]}")
	say "GET /api/users/: no account for ${names%, }; each signs in once, then run this again (until then their files are $fallback's)"
	exit 1
fi
if ((changes == 0)); then
	printf 'nothing to change\n'
else
	printf 'done: %d changes\n' "$changes"
fi
