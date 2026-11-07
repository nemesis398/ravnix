# Where the secrets come from. Secrets live in neither flake: rbw reads them
# from your Bitwarden at runtime. These options say only which server and
# which account.
{ lib, ... }:
let
  inherit (lib) mkOption;
  ravnix = import ./types.nix { inherit lib; };
in
{
  options.ravnix.secrets = {
    rbwBaseUrl = mkOption {
      type = ravnix.url;
      example = "https://vault.example.org";
      description = "The Bitwarden or Vaultwarden server rbw logs in to (`rbw config set base_url`).";
    };

    rbwEmail = mkOption {
      type = ravnix.mail;
      example = "alice@example.org";
      description = "The account rbw logs in as (`rbw config set email`).";
    };
  };
}
