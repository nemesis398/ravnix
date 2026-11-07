# ravnix-dev-checkout CHECKOUT [DENY_LIST]: what the home-manager activation
# runs when ravnix.dev.checkout is set. It turns the checkout's git hooks on
# (core.hooksPath = .githooks) and, when a deny list is given, tells the hooks
# where it is (ravnix.denyList). Both go into the checkout's own git
# configuration, which the hooks and the gate read, and nothing else is
# touched.
#
# It never fails the activation over what it finds: a checkout that is not
# cloned yet, a directory that is no repository, a configuration it cannot
# write. It says so on stderr and exits 0, because a system switch must not
# stop for a developer's convenience. The one failure is a call that is not
# absolute (exit 2), which the module never makes.
#
# The tests are tests/common/dev-checkout.nix.
{ writeShellApplication, git }:
writeShellApplication {
  name = "ravnix-dev-checkout";
  runtimeInputs = [ git ];
  text = ''
    usage() {
      echo "usage: ravnix-dev-checkout ABSOLUTE_CHECKOUT [DENY_LIST]" >&2
      exit 2
    }
    note() {
      printf 'ravnix-dev-checkout: %s\n' "$*" >&2
    }

    (($# >= 1 && $# <= 2)) || usage
    checkout=$1
    deny_list=''${2-}
    # An absolute path only, so that nothing can be read as an option.
    [[ $checkout == /?* ]] || usage

    if [[ ! -d $checkout ]]; then
      note "ravnix.dev.checkout $checkout does not exist, so its git hooks stay off."
      exit 0
    fi
    if ! reason=$(git -C "$checkout" rev-parse --git-dir 2>&1 >/dev/null); then
      note "$checkout is not a git repository ($reason), so its git hooks stay off."
      exit 0
    fi

    # set_config KEY VALUE: in the checkout's own configuration, which a
    # linked work tree shares with its main one.
    set_config() {
      local reason
      if ! reason=$(git -C "$checkout" config --local "$1" "$2" 2>&1); then
        note "could not set $1 in $checkout: $reason"
      fi
    }

    set_config core.hooksPath .githooks
    if [[ -n $deny_list ]]; then
      set_config ravnix.denyList "$deny_list"
    fi
  '';
}
