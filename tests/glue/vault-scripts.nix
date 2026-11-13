# vault-commit (modules/glue/vault/), built by its own
# modules/glue/vault/scripts.nix with a stand-in for ravnix-link, and tested
# in helpers/vault-commit.test.bash: what it reads from the skill values and
# what it refuses there, the git route on a real repository (odd names and
# messages, removals, what is staged, nothing to commit, a hook, concurrent
# runs, no repository) and what the ravnix-link route hands on. The two
# hosts together are tests/glue/link.nix.
{
  self,
  pkgs,
  lib,
  ...
}:
let
  # The stand-in ravnix-link: its arguments, each ended by a NUL, into
  # $FAKE_DIR/link.argv; it writes $FAKE_DIR/link.err to stderr and exits
  # with $FAKE_DIR/link.status (0 without it).
  link = pkgs.writeShellScript "ravnix-link" ''
    printf '%s\0' "$@" >"$FAKE_DIR/link.argv"
    if [ -f "$FAKE_DIR/link.err" ]; then cat "$FAKE_DIR/link.err" >&2; fi
    if [ -f "$FAKE_DIR/link.status" ]; then exit "$(cat "$FAKE_DIR/link.status")"; fi
    exit 0
  '';
  build = args: lib.getExe (import ../../modules/glue/vault/scripts.nix ({ inherit lib pkgs; } // args));
in
pkgs.runCommand "glue-vault-scripts"
  {
    nativeBuildInputs = [
      pkgs.bash
      pkgs.coreutils
      pkgs.git
    ];
    VAULT_COMMIT = build { link = toString link; };
    VAULT_COMMIT_NOLINK = build { link = "/no/such/ravnix-link"; };
    VAULT_COMMIT_BUILTIN = build {
      link = toString link;
      vault = "/nonexistent/vault";
    };
  }
  ''
    bash ${self}/tests/glue/helpers/vault-commit.test.bash
    touch "$out"
  ''
