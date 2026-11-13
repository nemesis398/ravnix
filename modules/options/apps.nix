# The graphical applications of the laptop (modules/desktop/apps.nix and
# webapps.nix): the values in them that are the user's own. A self-hosted
# service is a web app only when the user says where it runs, and the
# userstyles repository is the user's own, so neither has a default that
# could pass for a real one.
{ lib, ... }:
let
  inherit (lib) mkOption types;
  ravnix = import ./types.nix { inherit lib; };

  # The address of a web app goes into the Exec line of a launcher, where a
  # double quote, a backslash, a dollar sign and a backtick would need escapes
  # inside quotes. An address that holds one writes it percent-encoded.
  webappUrl = types.strMatching "https?://[^[:space:]\"\\`$]+" // {
    description = "http or https URL without a quote, backslash, dollar sign or backtick";
  };

  # The values of bitwarden-menu's config.ini (modules/desktop/bitwarden-menu.nix)
  # go through Python's configparser, which reads a line break as a new key, a
  # section header or a continuation, and a percent sign as interpolation. So
  # neither, nor a space, may be in them.
  iniValue = re: description: types.strMatching re // { inherit description; };

  # The web apps whose address is the user's. Claude and Apple Music are on
  # the public internet and need no option. There is none for the password
  # vault: Bitwarden desktop and the browser extension are its clients.
  selfHosted = {
    mealie = "recipes";
    nextcloud = "cloud";
    openwebui = "ai";
  };
in
{
  options.ravnix.apps = {
    packetTracer = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = ''
        Install Cisco Packet Tracer. Cisco's download needs a login, so no
        build can fetch it, and a host that asks for it stops with a message
        until the file is in the Nix store. That is why it is off unless you
        say so. The one step is in the header of `modules/desktop/apps.nix`:
        download `CiscoPacketTracer_901_Ubuntu_64bit.deb` from the Networking
        Academy and run `nix-store --add-fixed sha256` on it, on the machine
        that builds the host.
      '';
    };

    widevine = mkOption {
      type = types.bool;
      default = false;
      example = true;
      description = ''
        Give Helium the Widevine library, so that sites with DRM play. Apple
        Music in a web app streams full tracks only under DRM; without the
        library it plays 30-second previews. The library is Google's, unfree
        and not redistributable: nixpkgs refuses it unless it is allowed, ravnix
        allows that one name only when you set this, and the built host must not
        be pushed to a binary cache other people read.
      '';
    };

    userstylesUrl = mkOption {
      type = types.nullOr ravnix.url;
      default = null;
      example = "https://github.com/alice-example/catppuccin-userstyles";
      description = ''
        The web address of your own Catppuccin userstyles repository, the
        styles for the sites the official collection does not cover. Helium
        gets a managed bookmark to it, beside one to the official collection,
        for the step that installs the styles into Stylus (the header of
        `modules/desktop/apps.nix` says why that step cannot be declarative).
        Null when you have no repository of your own.
      '';
    };

    bitwardenMenu = mkOption {
      description = ''
        bitwarden-menu (`bwm`), a keyboard-driven menu to your Bitwarden or
        Vaultwarden vault in fuzzel, beside Bitwarden desktop, which it leaves
        as it is. It drives the official CLI, which sends what a current
        Vaultwarden asks for when it adds or edits an item. Off by default;
        when on, the three values must be set in me.nix (an assertion says so).
      '';
      default = { };
      type = types.submodule {
        options = {
          enable = mkOption {
            type = types.bool;
            default = false;
            example = true;
            description = "Install bwm, write its configuration and add its launcher.";
          };
          server = mkOption {
            type = types.nullOr (
              iniValue "https?://[^[:space:]%]+" "http or https URL without a space or percent sign"
            );
            default = null;
            example = "https://vault.example.org";
            description = ''
              The address of your Bitwarden or Vaultwarden server, as `bw
              config server` takes it. Null until you set it; required when
              the menu is on.
            '';
          };
          email = mkOption {
            type = types.nullOr (
              iniValue "[^@[:space:]%]+@[^@[:space:]%]+[.][^@[:space:]%]+" "mail address without a percent sign"
            );
            default = null;
            example = "alice@example.org";
            description = ''
              The mail address of your vault account. Null until you set it;
              required when the menu is on.
            '';
          };
          twoFactor = mkOption {
            type = types.nullOr (
              types.enum [
                0
                1
                3
              ]
            );
            default = null;
            example = 0;
            description = ''
              How the account's second factor is given, by bwm's number for
              it: 0 for an authenticator app (TOTP), 1 for a code by mail,
              3 for a YubiKey. Null until you set it; required when the menu
              is on. An account without two-factor login is not supported by
              this option.
            '';
          };
        };
      };
    };

    webapps = lib.mapAttrs (
      name: subdomain:
      mkOption {
        description = "The ${name} web app, a Helium window without browser chrome.";
        default = { };
        type = types.submodule {
          options.url = mkOption {
            type = types.nullOr webappUrl;
            default = null;
            example = "https://${subdomain}.example.org/";
            description = ''
              Where your ${name} runs, with the path the window opens on.
              Null installs no ${name} web app.
            '';
          };
        };
      }
    ) selfHosted;
  };
}
