# The laptop shape, huginn: the one disk the installer may write, the
# monitor layouts kanshi switches between, and the security key's handles
# for the git hosts.
{ lib, ... }:
let
  inherit (lib) mkOption types;
  ravnix = import ./types.nix { inherit lib; };

  output = types.submodule {
    options = {
      criteria = mkOption {
        type = types.nonEmptyStr;
        example = "Example Corp Monitor 0x00000000";
        description = ''
          Which output: its connector name (`eDP-1`), its description as
          `swaymsg -t get_outputs` prints make, model and serial, or `*` for
          any output.
        '';
      };

      status = mkOption {
        type = types.nullOr (
          types.enum [
            "enable"
            "disable"
          ]
        );
        default = null;
        description = "Turn the output on or off in this layout; null leaves it as it is.";
      };

      mode = mkOption {
        type = types.nullOr (types.strMatching "[0-9]+x[0-9]+(@[0-9]+([.][0-9]+)?(Hz)?)?");
        default = null;
        example = "2560x1600@120Hz";
        description = "Resolution and refresh rate; null takes the output's preferred mode.";
      };

      position = mkOption {
        type = types.nullOr (types.strMatching "-?[0-9]+,-?[0-9]+");
        default = null;
        example = "0,0";
        description = "Top left corner in the layout, in logical pixels, as `x,y`.";
      };

      scale = mkOption {
        type = types.nullOr types.numbers.positive;
        default = null;
        example = 1.25;
        description = "Scale factor; null keeps 1.";
      };
    };
  };

  profile = types.submodule {
    options = {
      name = mkOption {
        type = types.strMatching "[A-Za-z0-9_.-]+";
        example = "docked";
        description = "The profile's name, as kanshi logs it.";
      };

      outputs = mkOption {
        type = types.nonEmptyListOf output;
        description = "The outputs of this layout. kanshi picks a profile whose outputs are exactly the connected ones.";
      };
    };
  };
in
{
  options.ravnix.laptop = {
    diskModel = mkOption {
      type = types.nonEmptyStr;
      example = "Example SSD 1TB";
      description = ''
        The model of the one disk the installer may write, as
        `lsblk -o MODEL` prints it. Together with diskSerial it picks the
        install target; a device name such as nvme0n1 never does, because
        those can swap between boots.
      '';
    };

    diskSerial = mkOption {
      # udev's by-id characters: the laptop shape names the disk by them and
      # matches the serial in a udev rule, which reads *?[ and | as a
      # pattern.
      type = types.strMatching "[0-9A-Za-z#+.:=@_-]+";
      example = "EXAMPLE0SERIAL";
      description = ''
        The serial of that disk, as `lsblk -o SERIAL` prints it: letters,
        digits and `#+-.:=@_` only. The laptop shape hides every other
        internal disk from udisks by it.
      '';
    };

    kanshiProfiles = mkOption {
      type = types.listOf profile;
      default = [ ];
      description = ''
        Your monitor layouts, in order: kanshi applies the first profile
        that matches the connected outputs.
      '';
    };

    gitKeys = mkOption {
      type = types.attrsOf (types.nonEmptyListOf ravnix.absolutePath);
      default = { };
      example = {
        "github.com" = [ "/home/alice/.ssh/keys/github-sk" ];
        "git.example.org" = [ "/home/alice/.ssh/keys/forge-sk" ];
      };
      description = ''
        The git hosts and, for each, the files of the security key's
        handles (`ssh-keygen -t ed25519-sk`) that log in there. On the
        laptop ssh uses those files alone for these hosts, and no agent:
        rbw's agent holds touch-free keys for the same hosts, which would
        log in without the touch. One touch holds for ten minutes (a
        control master, as `ssh -O check <host>` shows). Over ssh only: an
        HTTPS remote of github.com takes gh's token and no key. Lowercase
        host names, also for an alias's HostName; list every name a host
        has (GitHub's ssh.github.com too).
      '';
    };
  };
}
