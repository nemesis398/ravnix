# The server shape, muninn: how the laptop's main terminal reaches it.
{ lib, ... }:
let
  inherit (lib) mkOption;
  ravnix = import ./types.nix { inherit lib; };
in
{
  options.ravnix.server = {
    sshTarget = mkOption {
      type = ravnix.sshTarget;
      example = "alice@muninn.example.org";
      description = ''
        How huginn reaches muninn over ssh: `[user@]host` (host an address or
        an ssh alias) or `ssh://[user@]host[:port]`. The main terminal key
        opens herdr there.
      '';
    };

    netbirdAddress = mkOption {
      type = ravnix.address;
      example = "198.51.100.20";
      description = ''
        muninn's address in your NetBird network, which reaches it from
        anywhere the laptop roams. The bare address, without the `/16` that
        `netbird status` prints after it.
      '';
    };
  };
}
