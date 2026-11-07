# Shell history in atuin, as the Fedora laptop has it: Ctrl-R opens the fuzzy
# search and Enter runs the entry, the up arrow stays bash's own, and secrets
# are kept out of the history. The TUI is Catppuccin Mocha in the accent
# (catppuccin/nix, fed the accent by the theme module).
#
# History syncs only through the atuin service the user places with
# ravnix.services.atuin; without one nothing leaves the machine. The shell
# init is written in bash.nix.
{ config, lib, ... }:
let
  service = config.ravnix.services.atuin or null;
  sync = service != null && service.enable;
in
{
  catppuccin.atuin.enable = true;

  programs.atuin = {
    enable = true;
    enableBashIntegration = false;
    settings = {
      auto_sync = sync;
      # The binary comes from Nix, so a version bump is the flake's job.
      update_check = false;

      search_mode = "fuzzy";
      filter_mode = "global";
      search_mode_shell_up_key_binding = "fuzzy";
      filter_mode_shell_up_key_binding = "global";

      style = "compact";
      inline_height = 40;
      show_preview = true;
      max_preview_height = 4;
      show_help = true;
      show_tabs = true;
      auto_hide_height = 8;

      # Esc restores the command line as it was.
      exit_mode = "return-original";
      # Enter runs the entry; Tab copies it to the line for editing.
      enter_accept = true;

      store_failed = true;
      # The default filter: AWS keys, GitHub tokens, Slack, Stripe, ...
      secrets_filter = true;
      # Anything matching is dropped from the history, unanchored.
      history_filter = [
        # A key added to an ssh agent.
        "^ssh-add .*\\.ssh/.*"
        # The Bitwarden command line.
        "^rbw "
      ];

      keymap_mode = "emacs";
      keymap_cursor = {
        emacs = "steady-block";
        vim_insert = "steady-block";
        vim_normal = "steady-underline";
      };
      prefers_reduced_motion = false;

      stats = {
        common_subcommands = [
          "apt"
          "cargo"
          "dnf"
          "docker"
          "git"
          "go"
          "ip"
          "jj"
          "kubectl"
          "lazygit"
          "nix"
          "nmcli"
          "npm"
          "pnpm"
          "podman"
          "sudo"
          "systemctl"
          "yarn"
        ];
        # `sudo dnf install foo` counts as dnf.
        common_prefix = [ "sudo" ];
      };

      # time, host, user, directory, exit, command: the command is last and
      # takes the width that is left. atuin ignores a width on that column.
      ui.columns = [
        {
          type = "time";
          width = 10;
        }
        {
          type = "host";
          width = 20;
        }
        {
          type = "user";
          width = 10;
        }
        {
          type = "directory";
          width = 35;
        }
        {
          type = "exit";
          width = 5;
        }
        { type = "command"; }
      ];

      # The synchronous SQLite query is fast enough for a personal history.
      daemon.enabled = false;
    }
    // lib.optionalAttrs sync { sync_address = service.url; };
  };
}
