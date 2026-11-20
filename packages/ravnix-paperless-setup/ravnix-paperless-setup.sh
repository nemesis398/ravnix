#!/usr/bin/env bash
# ravnix-paperless-setup --url URL --token-file FILE --owners NAME,NAME,...
#                        --household NAME --family-group NAME
#
# Puts a Paperless-ngx instance into the shape of the household design over
# its REST API, as the superuser whose API token FILE holds:
#
#   - the group --family-group with view, add and change on documents, tags,
#     correspondents, document types, storage paths and saved views, and no
#     other permission;
#   - the user --household, which owns the household's documents and never
#     signs in: inactive, no staff or superuser flag, no group, no
#     permission of its own, made without a password;
#   - for each owner one workflow, "ravnix: owner NAME": a file the consume
#     folder takes from a path matching */consume/NAME/* is NAME's;
#   - for the household one workflow, "ravnix: household NAME": a file from
#     */consume/NAME/* is the household's, and the group may view and change
#     it.
#
# Each owner must have an account already (people sign in once through
# OIDC, which makes it). An owner without one gets no workflow: the rest is
# made, the run names the missing owners and exits 1, and a later run
# completes it. The household's name may be in --owners, as it is in the
# deployment's owner list; it stands for the household there.
#
# It is idempotent: what is already as described is left alone, what
# differs is put back (a group's permissions, the household user's flags, a
# workflow's trigger and action), and a run that changes nothing says so.
# It never deletes: a workflow of its own for an owner no longer listed is
# named and left as it is. Workflows of other names are not touched.
#
# The token reaches curl through a configuration file in a private
# directory (mode 700, removed on exit), never on a command line or in the
# environment of a program it starts.
#
# Exit status: 0 done, 1 an API call failed (printed with its endpoint) or
# an owner has no account, 2 bad arguments.
set -euo pipefail
export LC_ALL=C

prog=ravnix-paperless-setup
# The API version the calls ask for: Paperless 3.x answers 9 and 10.
api_version=10
# The group's permissions, by codename.
permissions=()
for model in document tag correspondent documenttype storagepath savedview; do
	permissions+=("view_$model" "add_$model" "change_$model")
done

say() { printf '%s: %s\n' "$prog" "$*" >&2; }
usage() {
	if (($#)); then say "$*"; fi
	say "usage: $prog --url URL --token-file FILE --owners NAME,NAME,... --household NAME --family-group NAME"
	exit 2
}

url='' token_file='' owners_arg='' household='' group=''
seen=' '
while (($#)); do
	case $1 in
	-h | --help)
		printf 'usage: %s --url URL --token-file FILE --owners NAME,NAME,... --household NAME --family-group NAME\n' "$prog"
		exit 0
		;;
	--url | --token-file | --owners | --household | --family-group)
		(($# >= 2)) || usage "$1 needs a value"
		[[ $seen != *" $1 "* ]] || usage "$1 is given twice"
		seen+="$1 "
		case $1 in
		--url) url=$2 ;;
		--token-file) token_file=$2 ;;
		--owners) owners_arg=$2 ;;
		--household) household=$2 ;;
		--family-group) group=$2 ;;
		esac
		shift 2
		;;
	*) usage "unknown argument: $1" ;;
	esac
done
for option in --url --token-file --owners --household --family-group; do
	[[ $seen == *" $option "* ]] || usage "$option is missing"
done

# A user name: what Django takes, without the non-ASCII letters, and
# without a character that means something in the workflow's path filter
# (*, ?, [) or in a path (/).
name_ok() { [[ ${#1} -le 150 && $1 =~ ^[A-Za-z0-9][A-Za-z0-9._@+-]*$ ]]; }

[[ $url =~ ^https?://[^[:space:]]+$ ]] || usage "--url must be an http:// or https:// address, not \"$url\""
while [[ $url == */ ]]; do url=${url%/}; done
name_ok "$household" || usage "--household must be a user name (letters, digits, . _ @ + -), not \"$household\""
[[ -n $group && ${#group} -le 150 && $group != *[[:cntrl:]]* ]] ||
	usage "--family-group must be a group name of one line and at most 150 characters"

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

# --- the group -------------------------------------------------------------
want_perms=$(printf '%s\n' "${permissions[@]}" | jq -Rsc 'split("\n") | map(select(. != "")) | sort')
list /api/groups/ "$work/groups"
existing=$(jq -c --arg n "$group" 'map(select(.name == $n)) | first // empty' "$work/groups")
if [[ -z $existing ]]; then
	api POST /api/groups/ "$(jq -nc --arg n "$group" --argjson p "$want_perms" '{name: $n, permissions: $p}')"
	group_id=$(jq '.id' "$work/answer")
	changed "made the group $group: view, add and change on documents, tags, correspondents, document types, storage paths and saved views"
else
	group_id=$(jq '.id' <<<"$existing")
	if [[ $(jq -c '.permissions | sort' <<<"$existing") != "$want_perms" ]]; then
		api PATCH "/api/groups/$group_id/" "$(jq -nc --argjson p "$want_perms" '{permissions: $p}')"
		changed "set the permissions of the group $group back to view, add and change on the six models (it had: $(jq -r '.permissions | sort | join(", ")' <<<"$existing"))"
	fi
fi

# --- the household user ----------------------------------------------------
list /api/users/ "$work/users"
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
	enabled,
	triggers: [.triggers[] | {type, sources: ([.sources[] | tostring] | sort), filter_path, filter_filename, filter_mailrule}],
	actions: [.actions[] | {type, assign_owner,
		assign_view_users: (.assign_view_users | sort), assign_view_groups: (.assign_view_groups | sort),
		assign_change_users: (.assign_change_users | sort), assign_change_groups: (.assign_change_groups | sort)}]
};'

# workflow NAME OWNER_NAME OWNER_ID [GROUP_ID]: the workflow that gives a file
# from */consume/OWNER_NAME/* to OWNER_ID, and with GROUP_ID view and change
# on it to that group.
workflow() {
	local name=$1 folder=$2 owner_id=$3 grant=${4-} grants='[]' want existing id
	[[ -z $grant ]] || grants="[$grant]"
	want=$(jq -nc --arg name "$name" --arg path "*/consume/$folder/*" --argjson owner "$owner_id" \
		--argjson grant "$grants" '{
			name: $name,
			enabled: true,
			triggers: [{type: 1, sources: [1], filter_path: $path, filter_filename: null, filter_mailrule: null}],
			actions: [{type: 1, assign_owner: $owner,
				assign_view_users: [], assign_view_groups: $grant,
				assign_change_users: [], assign_change_groups: $grant}]
		}')
	existing=$(jq -c --arg n "$name" 'map(select(.name == $n)) | first // empty' "$work/workflows")
	if [[ -z $existing ]]; then
		api POST /api/workflows/ "$want"
		changed "made the workflow \"$name\": files from */consume/$folder/* are $folder's${grant:+, and the group $group may view and change them}"
	elif ! jq -en --argjson have "$existing" --argjson want "$want" "$norm"' ($have | norm) == ($want | norm)' >/dev/null; then
		id=$(jq '.id' <<<"$existing")
		api PUT "/api/workflows/$id/" "$want"
		changed "put the workflow \"$name\" back: files from */consume/$folder/* are $folder's${grant:+, and the group $group may view and change them}"
	fi
}

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
	workflow "ravnix: owner $owner" "$owner" "$owner_id"
done
workflow "ravnix: household $household" "$household" "$household_id" "$group_id"

# The tool's own workflows that this run did not ask for: named, not touched.
jq -r --argjson wanted "$(printf '%s\n' "${wanted[@]}" | jq -Rsc 'split("\n") | map(select(. != ""))')" \
	'.[] | .name | select((startswith("ravnix: owner ") or startswith("ravnix: household ")) and (IN($wanted[]) | not))' \
	"$work/workflows" | while IFS= read -r name; do
	printf 'the workflow "%s" is for no one in --owners; left as it is (delete it in Paperless if it is stale)\n' "$name"
done

if ((${#missing[@]})); then
	names=$(printf '%s, ' "${missing[@]}")
	say "GET /api/users/: no account for ${names%, }; each signs in once, then run this again (their files have no workflow and no owner until then)"
	exit 1
fi
if ((changes == 0)); then
	printf 'nothing to change\n'
else
	printf 'done: %d changes\n' "$changes"
fi
