# The prompt, asserted on the starship.toml that home-manager generates: the
# Fedora prompt (directory, branch, git status, character, nothing else), the
# accent where Fedora had Mauve, and the one row of the style spec's table that
# differs: a failed command shows ✗ in Red, not in the accent.
{
  self,
  inputs,
  pkgs,
  lib,
  ...
}:
let
  hm = import ./helpers/hm.nix {
    inherit
      self
      inputs
      pkgs
      lib
      ;
  };
  configOf = accent: (hm [ { ravnix.theme.accent = accent; } ]).config;
  mauve = configOf "mauve";
  palette = mauve.ravnix.theme.palette;

  # The whole file, written out: what Fedora's starship.toml says, with the
  # accent for its Mauve, the palette from the theme, and Red for the error.
  expected = accent: {
    add_newline = true;
    command_timeout = 200;
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

  cases =
    map
      (accent: {
        inherit accent;
        toml =
          let
            c = configOf accent;
          in
          c.home.file.${c.programs.starship.configPath}.source;
        expected = pkgs.writeText "starship-${accent}.json" (builtins.toJSON (expected accent));
      })
      [
        "mauve"
        "teal"
      ];
in
pkgs.runCommand "common-starship"
  {
    nativeBuildInputs = [
      pkgs.jq
      pkgs.remarshal
    ];
  }
  ''
    status=0
    ${lib.concatMapStrings (c: ''
      echo "==> ${c.accent}"
      remarshal -if toml -of json < ${c.toml} | jq -S . > got.json
      jq -S . ${c.expected} > want.json
      diff -u want.json got.json || status=1
      # The row of the style spec's table, on its own so a failure names it.
      jq -e '.character.error_symbol == "[✗](bold red)"' got.json >/dev/null || {
        echo "${c.accent}: the error symbol is not Red" >&2
        status=1
      }
      jq -e '.palettes.catppuccin_mocha.red == "${palette.red}"' got.json >/dev/null || {
        echo "${c.accent}: red is not the theme's Red" >&2
        status=1
      }
    '') cases}
    [ "$status" = 0 ]
    touch $out
  ''
