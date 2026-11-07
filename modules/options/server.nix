# The server shape, muninn: how the laptop's main terminal reaches it.
{ lib, ... }:
let
  inherit (lib) mkOption types;
in
{
  options.ravnix.server = {
    sshTarget = mkOption {
      type = types.nonEmptyStr;
      example = "alice@muninn.example.org";
      description = ''
        How huginn reaches muninn over ssh, as user@host or an ssh alias:
        the main terminal key opens herdr there.
      '';
    };

    netbirdAddress = mkOption {
      type = types.nonEmptyStr;
      example = "198.51.100.20";
      description = "muninn's address in your NetBird network, which reaches it from anywhere the laptop roams.";
    };
  };
}
