# A stand-in for atuin, built by tests/bin/atuin-root-login.nix into the
# package's PATH. It records what it was given in $REC: the arguments of each
# call (each in brackets), the standard input of a login, and the environment.
# login exits with $ATUIN_LOGIN_RC (0 without it), and sync with
# $ATUIN_SYNC_RC.
{
    printf '[%s]' "$@"
    echo
} >>"$REC/atuin.calls"
case ${1:-} in
    login)
        cat >"$REC/atuin.stdin"
        printf '%s' "${ATUIN_ENCRYPTION_KEY-<unset>}" >"$REC/atuin.key"
        printf '%s' "$HOME" >"$REC/atuin.home"
        env | sort >"$REC/atuin.env"
        exit "${ATUIN_LOGIN_RC:-0}"
        ;;
    sync) exit "${ATUIN_SYNC_RC:-0}" ;;
esac
