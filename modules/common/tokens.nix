# HTTPS tokens for git, from the vault (ravnix.secrets.gitTokens): for each
# remote, a credential helper that git asks for that remote alone, and that
# answers with the forge's user and the token, read with rbw at that moment.
# On the server this is how the update timer (Task 6.1, claude-roll's
# remote) pushes the private flake with the write token; another remote,
# even one on the same host, gets nothing from it.
#
# How narrow it is:
#   - git asks the helper only for URLs under its remote
#     (`[credential "<url>"]`), and sends the path (useHttpPath), which the
#     helper compares with the remote, scheme, host, port and path, exactly:
#     another repository, plain http, or a path that only starts the same
#     gets nothing. A URL that names another user than the token's gets
#     nothing either.
#   - The remote's helper list starts empty (the empty `helper =` line), so
#     a helper configured for every URL, `store` or `cache`, neither answers
#     for it nor is handed the token to keep.
#   - It never prompts: with the vault locked it says so and gives nothing,
#     and git then asks its own way (or fails, with GIT_TERMINAL_PROMPT=0
#     in a unit). The token goes from rbw to git through a pipe, never onto
#     a command line or into a file.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  tokens = config.ravnix.secrets.gitTokens;
  rbw = config.programs.rbw.package;

  helper = pkgs.writeShellApplication {
    name = "ravnix-git-token";
    text = ''
      # ravnix-git-token URL USER ITEM ACTION, as git runs it.
      url=$1 user=$2 item=$3 action=''${4-}
      protocol="" host="" path="" asked_user=""
      while IFS= read -r line && [[ -n $line ]]; do
        case $line in
          protocol=*) protocol=''${line#*=} ;;
          host=*) host=''${line#*=} ;;
          path=*) path=''${line#*=} ;;
          username=*) asked_user=''${line#*=} ;;
        esac
      done
      # store and erase: there is nothing to keep, and nothing to forget.
      [[ $action == get ]] || exit 0
      [[ -n $path && "$protocol://$host/$path" == "$url" ]] || exit 0
      say() { printf 'ravnix-git-token: %s\n' "$*" >&2; }
      if [[ -n $asked_user && $asked_user != "$user" ]]; then
        say "$url asks for the user $asked_user, and the token is $user's; giving none"
        exit 0
      fi
      if ! ${rbw}/bin/rbw unlocked >/dev/null 2>&1; then
        say "the vault is locked, so the token for $url cannot be read; unlock it with ai-unlock"
        exit 0
      fi
      if ! token=$(${rbw}/bin/rbw get -- "$item" 2>/dev/null </dev/null) || [[ -z $token || $token == *$'\n'* ]]; then
        say "rbw cannot read the item \"$item\" for $url"
        exit 0
      fi
      printf 'username=%s\npassword=%s\n' "$user" "$token"
    '';
  };
in
{
  programs.git.settings.credential = lib.mkIf (tokens != [ ]) (
    lib.listToAttrs (
      map (t: {
        name = t.url;
        value = {
          helper = [
            ""
            "${lib.getExe helper} ${
              lib.escapeShellArgs [
                t.url
                t.username
                t.item
              ]
            }"
          ];
          useHttpPath = true;
        };
      }) tokens
    )
  );
}
