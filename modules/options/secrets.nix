# Where the secrets come from. Secrets live in neither flake: rbw reads them
# from your Bitwarden at runtime. These options say only which server and
# which account.
{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.ravnix.secrets = {
    rbwBaseUrl = mkOption {
      type = types.strMatching "https?://[^[:space:]]+";
      example = "https://vault.example.org";
      description = "The Bitwarden or Vaultwarden server rbw logs in to (`rbw config set base_url`).";
    };

    rbwEmail = mkOption {
      type = types.strMatching "[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+";
      example = "alice@example.org";
      description = "The account rbw logs in as (`rbw config set email`).";
    };
  };
}
