# The desktop of the laptop shape: where its workspaces live, and the seams
# that ravnix's own modules use to change what a key or a hook does. The
# first is a value a user may set in me.nix; the others are `internal` (they
# are not values to fill in) and are read by modules/desktop. They sit here,
# with the other options, so that me.nix is checked against the options module
# alone and so that home-manager sees them too.
{ lib, ... }:
let
  inherit (lib) mkOption types;
  ravnix = import ./types.nix { inherit lib; };

  workspace = types.submodule {
    options = {
      number = mkOption {
        type = types.ints.between 1 10;
        example = 2;
        description = "The workspace, 1 to 10: the bar shows exactly these ten.";
      };

      outputs = mkOption {
        # Written into Sway's config in double quotes: no quote, backslash or
        # line break, which would end the quote or the line.
        type = types.nonEmptyListOf (types.strMatching "[^\"\\\n]+");
        example = [
          "Example Corp Monitor 0x00000000"
          "eDP-1"
        ];
        description = ''
          The outputs the workspace prefers, the first connected one wins:
          a connector name (`eDP-1`) or a description as
          `swaymsg -t get_outputs` prints make, model and serial. Prefer the
          description: a connector name can change (the panel is `eDP-1` or
          `eDP-2` depending on which GPU registers first, and a monitor moves
          from HDMI to USB-C), a description does not. Put the built-in panel
          last so that every workspace is still reachable undocked.
        '';
      };
    };
  };
in
{
  options.ravnix.desktop = {
    workspaceOutputs = mkOption {
      type = types.listOf workspace;
      default = [ ];
      description = ''
        Which output each workspace lives on, in Sway's `workspace N output
        ...` form. Empty means Sway decides: a workspace opens on the output
        that has the focus. Docked, you usually want the working workspaces on
        the large monitor and the browser on the panel; undocked, the panel is
        the second name in every list and takes them all.
      '';
    };

    terminal = {
      main = mkOption {
        type = types.nonEmptyStr;
        default = "ghostty";
        internal = true;
        example = "ghostty -e herdr --remote user@host";
        description = ''
          The command of the main terminal key (`$mod+Return`), as Sway's
          `exec` takes it. Until the glue (Task 5.2) sets it, it is a local
          terminal; the glue changes it to open herdr on the server. The
          session layout at login starts the same command on workspace 2.
        '';
      };

      plain = mkOption {
        type = types.nonEmptyStr;
        default = "env NO_MUX=1 ghostty";
        internal = true;
        example = "ghostty";
        description = ''
          The command of the key that opens a plain local shell
          (`$mod+Alt+Return`), whatever the main terminal does. `NO_MUX=1` is
          the escape hatch of the shell's terminal auto-attach.
        '';
      };
    };

    gpu.primary = mkOption {
      type = types.nullOr (types.strMatching "[0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}[.][0-7]");
      default = null;
      internal = true;
      example = "0000:00:02.0";
      description = ''
        The PCI address of the GPU that Sway renders on and every display
        connector hangs off, as `lspci -D` prints it. Set by the hardware
        module of a hybrid laptop, which knows it; null on a host with one
        GPU, where Sway finds it. The desktop module gives that GPU a stable,
        colon-free device path (`/dev/dri/primary-gpu`, a udev rule matching
        the address, so a renumbered cardN cannot break it) and names it in
        `WLR_DRM_DEVICES`. The by-path name cannot be used there: wlroots
        splits the variable at every colon, and a PCI address is full of them.
      '';
    };

    ask = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            url = mkOption {
              type = ravnix.url;
              example = "https://chat.example.org";
              description = ''
                The address of your Open WebUI, without a path. The popup talks
                to its API, and its Helium window is named after this host.
              '';
            };

            model = mkOption {
              type = types.strMatching "[A-Za-z0-9._:/-]+";
              example = "quick";
              description = "The id of the model the popup asks, as Open WebUI lists it.";
            };

            rbwItem = mkOption {
              type = types.strMatching "[^\"\\\n]+";
              example = "Open WebUI - API key";
              description = ''
                The Bitwarden item whose password is the API key. The popup
                reads it through rbw when you ask; the key is never written
                down.
              '';
            };
          };
        }
      );
      default = null;
      example = {
        url = "https://chat.example.org";
        model = "quick";
        rbwItem = "Open WebUI - API key";
      };
      description = ''
        The quick AI popup (`sway-ask`, `$mod+Shift+a`), a fuzzel window that
        sends your question to a model of your Open WebUI and shows the answer
        with a prompt for the follow-up. Null leaves it out: no command, no
        launcher entry, and the key stays free.
      '';
    };

    kanshi.exec = mkOption {
      type = types.listOf types.nonEmptyStr;
      default = [
        "panel-crtc --fix"
        "energy refresh"
        "backdrop wallpaper"
      ];
      internal = true;
      description = ''
        What every kanshi profile runs once its outputs are set, in order,
        each as `command arguments`. A command that is not installed is
        skipped, so a module that provides one does not have to be there for
        the profile to apply. The defaults are the three that settle a layout:
        the panel back on the CRTC the console uses, the refresh rate of the
        power profile, and the wallpaper redrawn at the new size.
      '';
    };
  };
}
