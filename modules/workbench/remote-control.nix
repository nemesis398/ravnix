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
#     the start and is left alone. The file has to exist: it is where Claude
#     Code keeps the answers to every first-run dialog, and it lives in $HOME
#     beside ~/.claude/, so copying ~/.claude/ to a new machine leaves it
#     behind. Without it Claude Code would ask on a terminal that is not there,
#     which is the same loop, so the unit's condition names it too.
#   - It must start in a project directory, never in $HOME: the trust dialog
#     does not save trust for $HOME.
#   - It needs a claude.ai login; an API key or a setup token does not work.
#     `claude auth login` is interactive, so it is a step by hand (README.md),
#     and so is accepting the folder once (`cd` there and run `claude`). Until
#     the login, the state file and the repository exist, the unit does not
#     start and says so (a failed condition), instead of restarting every half
#     minute behind an "active" that is not true. Once they exist,
#     `systemctl --user start claude-remote-control` starts it, and it comes up
#     by itself at every boot.
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
  profile = "/etc/profiles/per-user/${user}/bin";
in
{
  config = lib.mkIf (dir != null) {
    home-manager.users.${user} =
      { ... }:
      let
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
            # Not started until the login, the state file and the repository
            # exist (see the header); the condition fails quietly and
            # `systemctl --user status` says which one.
            ConditionPathExists = [
              "%h/.claude/.credentials.json"
              "%h/.claude.json"
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
