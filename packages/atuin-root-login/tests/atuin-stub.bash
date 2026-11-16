# A stand-in for atuin, built by tests/bin/atuin-root-login.nix into the
# package's PATH. It records what it was given in $REC: the arguments of each
# call (each in brackets), the standard input of a login, the environment, and
# a file it creates.
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
        # A file atuin makes, to show the mode the root half's umask gives it.
        rm -f "$REC/atuin.created"
        : >"$REC/atuin.created"
        exit "${ATUIN_LOGIN_RC:-0}"
        ;;
    sync) exit "${ATUIN_SYNC_RC:-0}" ;;
esac
