# The prompt: the directory in bold accent, the branch in italic accent with
# the git status symbols after it in the accent, and a bold ❯ in the accent;
# a failed command shows a bold ✗ in Red instead (a row of the style spec's
# table). Nothing else: no time, no user, no host, no language versions.
#
# The palette is the theme's own, so the style names a color and the user's
# accent reaches the prompt: starship's colors are palette names, and the
# accent's name is one of them.
{ config, ... }:
let
  inherit (config.ravnix.theme) accent palette;
in
{
  programs.starship = {
    enable = true;
    # The shell init is written in bash.nix, in the order the Fedora bashrc
    # has: bash-preexec, starship, zoxide, fzf, atuin.
    enableBashIntegration = false;
    settings = {
      add_newline = true;
      command_timeout = 200;
      # Without this the palette is only registered, and every style that
      # names a color is an unknown color and falls back to the foreground.
      palette = "catppuccin_mocha";

      format = "$directory$git_branch$git_status$character";

      character = {
        error_symbol = "[✗](bold red)";
        success_symbol = "[❯](bold ${accent})";
      };

      directory = {
        style = "bold ${accent}";
        format = "[$path]($style)[$read_only]($read_only_style) ";
        truncation_length = 2;
        truncation_symbol = "…/";
        repo_root_style = "bold ${accent}";
        repo_root_format = "[$repo_root]($repo_root_style)[$path]($style)[$read_only]($read_only_style) ";
      };

      git_branch = {
        format = "[$branch(:$remote_branch)]($style) ";
        style = "italic ${accent}";
        ignore_branches = [ ];
        truncation_length = 30;
      };

      git_status = {
        format = "[$all_status$ahead_behind]($style)";
        style = accent;
        ahead = "⇡\${count} ";
        diverged = "⇕⇡\${ahead_count}⇣\${behind_count} ";
        behind = "⇣\${count} ";
        conflicted = " ";
        up_to_date = " ";
        untracked = "? ";
        modified = " ";
        stashed = "";
        staged = "";
        renamed = "";
        deleted = "";
      };

      palettes.catppuccin_mocha = palette;
    };
  };
}
