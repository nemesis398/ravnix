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

  # The web apps whose address is the user's. Claude and Apple Music are on
  # the public internet and need no option.
  selfHosted = {
    mealie = "recipes";
    nextcloud = "cloud";
    vaultwarden = "passwords";
    openwebui = "ai";
  };
in
{
  options.ravnix.apps = {
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
