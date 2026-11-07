# Shell text for a unit that reads a password from the vault: it stops with
# status 75 (EX_TEMPFAIL) and says why when the vault is locked. rbw would
# otherwise ask for the master password on a terminal the unit does not have.
# The unit shows as failed, which is true (nothing was synced) and is what
# `systemctl --failed` and fastfetch's failed-units row report; the next run
# of its timer works again once someone has run `ai-unlock`.
#
# Not a module: modules call it as
#   import ./unlocked.nix { rbw = lib.getExe' pkg "rbw"; what = "..."; }
{ rbw, what }:
''
  if ! ${rbw} unlocked >/dev/null 2>&1; then
    echo "the vault is locked, so ${what} cannot be read; unlock it with ai-unlock, and the next run picks it up" >&2
    exit 75
  fi
''
