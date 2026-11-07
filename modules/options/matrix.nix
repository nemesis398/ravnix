# Notifications that must reach you with the lid closed go to a Matrix
# room, one room and one bot per topic. The bots' access tokens come from
# rbw at runtime, never from here.
{ lib, ... }:
let
  inherit (lib) mkOption types;
  ravnix = import ./types.nix { inherit lib; };
in
{
  options.ravnix.matrix = {
    homeserver = mkOption {
      type = ravnix.url;
      example = "https://matrix.example.org";
      description = "The URL of your Matrix homeserver's client API.";
    };

    userId = mkOption {
      type = types.nullOr (types.strMatching "@[^:[:space:]]+:[^[:space:]]+");
      default = null;
      example = "@alice:example.org";
      description = ''
        Your own account on that homeserver, which iamb logs in as. It is
        not one of the bots below. Null: iamb is installed without a profile.
      '';
    };

    rooms = mkOption {
      default = { };
      description = "One room per notification topic (sessions, updates, backups, builds, services).";
      type = types.attrsOf (
        types.submodule (
          { name, ... }:
          {
            options = {
              roomId = mkOption {
                # Room version 12 ids have no server part; older ones do.
                type = types.nullOr (types.strMatching "![^[:space:]]+");
                default = null;
                example = "!AbCdEfGhIjKlMnOpQr:example.org";
                description = "The room's id, or null while the room does not exist yet.";
              };

              botUser = mkOption {
                type = types.strMatching "@[^:[:space:]]+:[^[:space:]]+";
                example = "@ravnix-${name}:example.org";
                description = "The bot account that posts to the room.";
              };
            };
          }
        )
      );
    };
  };
}
