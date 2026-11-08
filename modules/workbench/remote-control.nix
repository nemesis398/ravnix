# Claude Code's Remote Control on the server, as the development VM it
# replaces had it: a session that claude.ai and the phone app see by the
# host's name, and from which a session started on the phone gets a git
# worktree of ravnix.server.remoteControlDir. It makes only outbound
# connections; nothing listens, so no port is opened and the mesh is not
# involved.
#
# The unit is a user unit of the account (the manager runs without a login,
# modules/workbench/default.nix). It runs `claude` through the user's profile,
# so it is the Claude Code of the host, with the wrapper that sets
# DISABLE_AUTOUPDATER=1: Nix does the updating. The unit's text does not change
# with a new Claude Code, so a switch to a system that differs only in Claude
# Code does not end the phone's sessions (a change of the helper below, or of
# the programs it uses, does restart the unit). A running Remote Control stays
# on the version it started with until it is restarted
# (`systemctl --user restart claude-remote-control`), because the claude-roll
# tool (Task 6.2) restarts the sessions in herdr's panes and this one is not
# in a pane; Task 6.1 must include it in a Claude Code update.
#
# What that VM learned, and what is done about it:
#   - The first run asks "Enable Remote Control? (y/n)" on a terminal, which a
#     unit does not have, so the unit used to crash and restart every half
#     minute while `systemctl --user is-active` said "active". The answer is a
#     flag in ~/.claude.json (remoteDialogSeen), which ExecStartPre sets before
#     each start, in the file as it is. A ~/.claude.json that is not JSON stops
#     the start and is left alone.
#   - Claude Code must have had its first run on this machine. ~/.claude.json
#     is where it keeps the answers to every first-run dialog, and it lives in
#     $HOME beside ~/.claude/, so copying ~/.claude/ to a new machine leaves it
#     behind; without the answers Claude Code asks on a terminal that is not
#     there, which is the same loop. That the file exists proves nothing,
#     because other parts of ravnix make it too (the MCP servers of
#     ravnix.claude.mcpServers are merged into it, before any login). So an
#     ExecCondition= helper reads the key `hasCompletedOnboarding` and starts
#     the unit only when it is true. Evidence for that key, from the
#     packaged Claude Code 2.1.319 (`rg -a -o` over bin/.claude-unwrapped,
#     nothing run): `claude auth login` writes hasCompletedOnboarding: true
#     in its success path, right before it prints "Login successful."; the
#     interactive onboarding writes it when its last screen is confirmed; and
#     Claude Code's own repair of a damaged config treats it, with
#     oauthAccount, as the sign of a config that held a login. No ravnix
#     step writes it. oauthAccount was not taken, because the onboarding
#     screens are what block, and they key on hasCompletedOnboarding. A skip by
#     ExecCondition= (exit 1 to 254) leaves the unit inactive and not failed,
#     and Restart=always does not start it again, so nothing loops; the
#     helper says why on stderr, which is the journal.
#   - It must start in a project directory, never in $HOME: the trust dialog
#     does not save trust for $HOME. And Claude Code must trust that directory:
#     `claude remote-control` checks it before it starts and exits with
#     "Workspace not trusted: <dir>. Run `claude` in that directory first to
#     accept the trust dialog" (and with CI set it refuses at once, with no
#     dialog), which Restart=always would repeat every half minute. The same
#     helper therefore requires projects[<dir>].hasTrustDialogAccepted to be
#     true in ~/.claude.json. How 2.1.319 resolves it (read from the binary,
#     nothing run): the project key is the git root of the working directory,
#     as an absolute path with no trailing slash; trust is looked up for the
#     working directory and each folder above it, but only up to the git root,
#     and above the root only when there is no git root at all. The unit's
#     directory has a .git (a condition), so it is its own root, and the key is
#     the directory itself: trust on a parent folder is not honored, and the
#     helper does not honor it either. The directory is checked as configured
#     and as `realpath -m` resolves it, since Claude Code keys by the path the
#     process has, which is the resolved one.
#   - Which file Claude Code reads: ~/.claude/.config.json, when that legacy
#     file exists and is not empty, and $CLAUDE_CONFIG_DIR/.claude.json when
#     that variable is set, take the place of ~/.claude.json (2.1.319). The
#     unit sets neither and the helpers read ~/.claude.json only, so a
#     ~/.claude/ copied from a machine that has a legacy .config.json needs
#     the helpers to follow it (Task 4.5 copies ~/.claude/).
#   - It needs a claude.ai login; an API key or a setup token does not work.
#     `claude auth login` is interactive, so it is a step by hand (README.md),
#     and so is accepting the folder once (`cd` there and run `claude`). Until
#     the login, the first run, the trusted folder and the repository exist,
#     the unit does not
#     start and says so (a failed condition, or the helper's message), instead
#     of restarting every half minute behind an "active" that is not true.
#     Once they exist, `systemctl --user start claude-remote-control` starts
#     it, and it comes up by itself at every boot.
#   - ANTHROPIC_API_KEY and ANTHROPIC_BASE_URL are unset for it, so the login
#     is the one that counts.
#
# Known gap (Task 4.3): a session started from the phone does not get the
# tokens of ravnix.shell.secretEnv. They reach `claude` through the shell
# function that reads them from rbw when you run it in a terminal, and a unit
# has no such shell.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  os = config;
  user = os.ravnix.user.username;
  dir = os.ravnix.server.remoteControlDir;
  # The directory as Claude Code keys it: absolute, without a trailing slash.
  dirKey =
    let
      m = builtins.match "(.*[^/])/*" dir;
    in
    if m == null then dir else builtins.head m;
  profile = "/etc/profiles/per-user/${user}/bin";
in
{
  config = lib.mkIf (dir != null) {
    home-manager.users.${user} =
      { ... }:
      let
        ready = pkgs.writeShellApplication {
          name = "ravnix-remote-control-ready";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.jq
          ];
          text = ''
            file="$HOME/.claude.json"
            dir=${lib.escapeShellArg dirKey}
            # Every way out but success is exit 1, a skip that systemd takes
            # for a unit that does not need to run; 255 would be a failure
            # that Restart=always retries.
            if [ ! -f "$file" ]; then
              echo "$file does not exist, so Claude Code has not had its first run here; log in with claude auth login, then start this unit" >&2
              exit 1
            fi
            status=0
            jq -e '.hasCompletedOnboarding == true' "$file" >/dev/null 2>&1 || status=$?
            case "$status" in
              0) ;;
              1 | 4)
                echo "$file does not say Claude Code finished its first run (hasCompletedOnboarding is not true), so Remote Control would ask its questions on no terminal; log in with claude auth login, then start this unit" >&2
                exit 1
                ;;
              *)
                echo "$file is not JSON that holds an object (jq exit $status); Remote Control does not start, and the file is as it was" >&2
                exit 1
                ;;
            esac
            # The folder: claude remote-control refuses one it does not trust.
            physical=$(realpath -m -- "$dir")
            status=0
            jq -e --arg a "$dir" --arg b "$physical" \
              '.projects[$a].hasTrustDialogAccepted == true or .projects[$b].hasTrustDialogAccepted == true' \
              "$file" >/dev/null 2>&1 || status=$?
            case "$status" in
              0) exit 0 ;;
              1 | 4)
                echo "$dir is not trusted by Claude Code (projects.\"$dir\".hasTrustDialogAccepted is not true in $file), and claude remote-control refuses a folder it does not trust; run claude once in $dir, accept the folder, then start this unit" >&2
                ;;
              *)
                echo "$file is not JSON that holds an object (jq exit $status); Remote Control does not start, and the file is as it was" >&2
                ;;
            esac
            exit 1
          '';
        };

        prepare = pkgs.writeShellApplication {
          name = "ravnix-remote-control-prepare";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.jq
          ];
          text = ''
            file="$HOME/.claude.json"
            # The unit's condition has checked the file; if it is gone since,
            # the start stops here and says so, because Claude Code would
            # ask its first-run questions on a terminal that is not there.
            [ -f "$file" ] || {
              echo "$file is gone; Remote Control does not start" >&2
              exit 1
            }
            seen=$(jq -r '.remoteDialogSeen // false' "$file") || {
              echo "$file is not JSON; Remote Control does not start, and the file is as it was" >&2
              exit 1
            }
            [ "$seen" != true ] || exit 0
            # The file is rewritten beside itself and moved over it, so the
            # whole file is either the old one or the new one.
            tmp=$(mktemp "$file.XXXXXX")
            trap 'rm -f -- "$tmp"' EXIT
            jq '.remoteDialogSeen = true' "$file" >"$tmp"
            chmod --reference="$file" "$tmp"
            mv -f -- "$tmp" "$file"
          '';
        };
      in
      {
        systemd.user.services.claude-remote-control = {
          Unit = {
            Description = "Claude Code Remote Control session";
            # Not started until the login and the repository exist (see the
            # header); the condition fails quietly and `systemctl --user
            # status` says which one. The first run is checked by
            # ExecCondition= below.
            ConditionPathExists = [
              "%h/.claude/.credentials.json"
              "${dir}/.git"
            ];
          };
          Service = {
            Type = "simple";
            WorkingDirectory = dir;
            Environment = [
              "TERM=xterm-256color"
              "PATH=${profile}:/run/current-system/sw/bin"
            ];
            UnsetEnvironment = [
              "ANTHROPIC_API_KEY"
              "ANTHROPIC_BASE_URL"
            ];
            ExecCondition = lib.getExe ready;
            ExecStartPre = lib.getExe prepare;
            ExecStart = "${profile}/claude remote-control --name ${os.networking.hostName} --spawn worktree";
            Restart = "always";
            RestartSec = 30;
          };
          Install.WantedBy = [ "default.target" ];
        };
      };
  };
}
