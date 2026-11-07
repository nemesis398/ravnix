# The command-line tools both hosts have, configured as on the Fedora laptop,
# in Catppuccin Mocha with the accent where the catppuccin/nix port has one.
# What the design spec drops stays out: httpie, tmux, procs, dust, hyperfine
# and the like stay one `nix shell` away.
#
# TUIs draw the single light line (docs/style.md): lazygit's border is
# `single`, btop's corners are not rounded, and the fastfetch frame uses
# square corners where the Fedora one had rounded ones.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (config.ravnix) secrets;
  inherit (config.ravnix.theme) palette roles;

  # "#rrggbb" as the ANSI truecolor parameters fastfetch takes.
  ansi =
    hex:
    "38;2;${
      lib.concatMapStringsSep ";" (i: toString (lib.fromHexString (builtins.substring i 2 hex))) [
        1
        3
        5
      ]
    }";

  # The rows of the fastfetch frame: a module with a key, a module with
  # settings of its own, and a module that runs a command.
  row = key: type: { inherit key type; };
  rowWith =
    key: type: extra:
    { inherit key type; } // extra;
  shellRow = key: text: {
    inherit key text;
    type = "command";
  };
in
{
  catppuccin = {
    bat.enable = true;
    btop.enable = true;
    eza.enable = true;
    lazygit.enable = true;
  };

  programs = {
    ripgrep.enable = true;
    fd.enable = true;
    jq.enable = true;

    # fzf: completion, Ctrl-T (file), Alt-C (cd). The init is in bash.nix; it
    # has to come before atuin's, which takes Ctrl-R back.
    fzf = {
      enable = true;
      enableBashIntegration = false;
    };

    zoxide = {
      enable = true;
      enableBashIntegration = false;
    };

    # The aliases are Fedora's and live in bash.nix.
    eza = {
      enable = true;
      enableBashIntegration = false;
    };

    # The theme is the catppuccin/nix port, set above.
    bat = {
      enable = true;
      config = {
        map-syntax = [
          "*.conf:ini"
          "*.cfg:ini"
          "*.nix:nix"
        ];
        # Comments in italics.
        italic-text = "always";
        # Long lines (git diffs with long paths) wrap and do not truncate.
        wrap = "character";
        # -R keeps colors, -F quits when the output fits one screen. Not -X:
        # it breaks the mouse wheel.
        pager = "less -RF";
      };
    };

    btop = {
      enable = true;
      # Single light line, not rounded corners (docs/style.md).
      settings.rounded_corners = false;
    };

    lazygit = {
      enable = true;
      settings = {
        gui = {
          nerdFontsVersion = "3";
          border = "single";
          language = "auto";
          timeFormat = "2006-01-02 15:04:05";
          shortTimeFormat = "15:04";
          mouseEvents = true;
        };
        # Diffs through delta, like the git command line. It reads its
        # settings from git's configuration; --paging=never because lazygit
        # owns the scrolling.
        git.diffRenderers = [
          {
            colorArg = "always";
            useConfig = false;
            command = "delta --dark --paging=never";
          }
        ];
        # Nix installs lazygit, so it must not offer to replace itself.
        update.method = "never";
        confirmOnQuit = false;
      };
    };

    # The vault client behind ai-unlock. The server and the account are the
    # user's; the pinentry is the terminal one, so that it works over ssh and
    # in a herdr pane alike. A host can say otherwise.
    rbw = {
      enable = true;
      settings = {
        email = lib.mkDefault secrets.rbwEmail;
        base_url = lib.mkDefault secrets.rbwBaseUrl;
        pinentry = lib.mkDefault pkgs.pinentry-curses;
      };
    };

    # Keys and the logo of the accent; the NixOS logo in Blue and Sapphire,
    # as the style spec has it for the facts on the desktop. A host adds its
    # own rows (a laptop's battery profile, its radios) to `modules`.
    fastfetch = {
      enable = true;
      settings = {
        logo = {
          type = "builtin";
          source = "nixos";
          color = {
            "1" = ansi palette.blue;
            "2" = ansi palette.sapphire;
          };
          padding = {
            top = 1;
            left = 1;
            right = 4;
          };
        };
        display = {
          separator = "  ";
          key.width = 20;
          color = {
            keys = ansi roles.accent;
            separator = ansi roles.muted;
          };
          percent = {
            type = 9;
            color = {
              green = ansi roles.accent;
              yellow = ansi palette.yellow;
              red = ansi palette.red;
            };
          };
        };
        modules = [
          {
            type = "title";
            key = "┌─ system";
            keyWidth = 0;
            format = "{user-name}@{host-name}";
            color = {
              user = ansi roles.text;
              at = ansi roles.muted;
              host = ansi roles.text;
            };
          }
          (rowWith "│   OS" "os" { format = "{pretty-name}"; })
          (rowWith "│   Host" "host" { format = "{family}"; })
          (rowWith "│   Kernel" "kernel" { format = "{release}"; })
          (row "│   Uptime" "uptime")
          (row "│   Packages" "packages")
          (rowWith "│   Shell" "shell" { format = "{pretty-name} {version}"; })
          {
            type = "custom";
            key = "│";
            keyWidth = 0;
            format = "";
          }
          {
            type = "custom";
            key = "├─ hardware";
            keyWidth = 0;
            format = "";
          }
          (rowWith "│   CPU" "cpu" { format = "{name} ({cores-logical})"; })
          (rowWith "│   GPU" "gpu" { format = "{name} [{type}]"; })
          (rowWith "│   Memory" "memory" { format = "{used} / {total} {percentage}"; })
          (rowWith "│   Swap" "swap" { format = "{used} / {total} {percentage}"; })
          (rowWith "│   Disk" "disk" {
            folders = "/";
            format = "{size-used} / {size-total} {size-percentage} ({filesystem})";
          })
          (rowWith "│   Battery" "battery" { format = "{capacity} {status}"; })
          {
            type = "custom";
            key = "│";
            keyWidth = 0;
            format = "";
          }
          {
            type = "custom";
            key = "├─ services";
            keyWidth = 0;
            format = "";
          }
          (shellRow "│   Failed" ''n=$(( $(systemctl --failed --no-legend | wc -l) + $(systemctl --user --failed --no-legend | wc -l) )); if [ "$n" -eq 0 ]; then echo none; else echo "$n (systemctl --failed)"; fi'')
          {
            type = "custom";
            key = "│";
            keyWidth = 0;
            format = "";
          }
          (rowWith "│   Palette" "colors" { symbol = "circle"; })
          {
            type = "custom";
            key = "│";
            keyWidth = 0;
            format = "";
          }
          {
            type = "custom";
            key = "└─";
            keyWidth = 0;
            format = "";
          }
        ];
      };
    };
  };

  home.packages = [
    # The Python client, as on Fedora: its colors are the TLDR_COLOR_*
    # variables in bash.nix.
    pkgs.tldr
    # `cat` on an image draws it (functions.bash), and finds out what it is.
    pkgs.chafa
    pkgs.file
  ];
}
