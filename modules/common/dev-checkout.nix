# ravnix-dev-checkout CHECKOUT [DENY_LIST]: what the home-manager activation
# runs when ravnix.dev.checkout is set. It turns the checkout's git hooks on
# (core.hooksPath = .githooks) and, when a deny list is given, tells the hooks
# where it is (ravnix.denyList). Both go into the checkout's own git
# configuration, which the hooks and the gate read, and nothing else is
# touched.
#
# The checkout is the repository whose top level is that path. A directory
# that merely lies inside another repository (an empty submodule directory, a
# clone that failed after mkdir, a home directory under git) is not it: the
# enclosing repository's hooks would be redirected to a .githooks it does not
# have. A bare repository, the inside of a .git directory and a repository
# that git refuses to read are not a checkout either.
#
# It never fails the activation over what it finds: a checkout that is not
# cloned yet, a directory that is no repository, a configuration it cannot
# write. It exits 0, because a system switch must not stop for a developer's
# convenience, but it says so on stderr, as a WARNING: the hooks and the
# boundary check may then be off until a later switch (or a restart of the
# user's home-manager service) finds the repository, and nothing else tells
# the developer. The one failure is a call that is not absolute (exit 2),
# which the module never makes.
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
    # warn WHAT: the activation goes on, but a developer must see that the
    # hooks are not on.
    warn() {
      printf 'ravnix-dev-checkout: WARNING: %s\n' "$*" >&2
      printf 'ravnix-dev-checkout: WARNING: the git hooks and the boundary check of the ravnix checkout may be OFF; they come on at the next switch (or a restart of the home-manager service) once the checkout is a repository git can configure.\n' >&2
    }

    (($# >= 1 && $# <= 2)) || usage
    checkout=$1
    deny_list=''${2-}
    # An absolute path only, so that nothing can be read as an option.
    [[ $checkout == /?* ]] || usage

    # A GIT_DIR in the environment would send every git call below to another
    # repository, whatever the path says.
    unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR

    if [[ ! -d $checkout ]]; then
      warn "ravnix.dev.checkout $checkout does not exist, so its git hooks stay off."
      exit 0
    fi
    if ! top=$(git -C "$checkout" rev-parse --show-toplevel 2>&1); then
      warn "$checkout is not a git repository with a work tree ($top), so its git hooks stay off."
      exit 0
    fi
    # Both are physical paths: git resolves symbolic links, so the directory
    # is resolved the same way, and a link to the repository still matches.
    here=$(cd -- "$checkout" && pwd -P)
    if [[ $top != "$here" ]]; then
      warn "$checkout is not the top level of a git repository; it lies inside the repository at $top, which is left alone."
      exit 0
    fi

    # set_config KEY VALUE: in the checkout's own configuration, which a
    # linked work tree shares with its main one.
    set_config() {
      local reason
      if ! reason=$(git -C "$checkout" config --local "$1" "$2" 2>&1); then
        warn "could not set $1 in $checkout: $reason"
      fi
    }

    set_config core.hooksPath .githooks
    if [[ -n $deny_list ]]; then
      set_config ravnix.denyList "$deny_list"
    fi
  '';
}
