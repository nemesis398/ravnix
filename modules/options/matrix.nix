# Notifications that must reach you with the lid closed go to a Matrix
# room, one room and one bot per topic. The bots' access tokens come from
# rbw at runtime, never from here: an option names the Bitwarden item that
# holds one (ravnix-notify, tools/ravnix-notify).
{ lib, ... }:
let
  inherit (lib) mkOption types;
  ravnix = import ./types.nix { inherit lib; };

  # The topics ravnix-notify posts to, and what each is for. A room for any
  # other name is refused when the option is read, so a misspelt topic fails
  # the build instead of a notification that never arrives.
  topics = {
    sessions = "the herdr and Claude Code sessions";
    updates = "updates, such as the Claude Code roll";
    backups = "backup runs";
    builds = "builds and checks";
    services = "services and timers that fail";
  };

  room =
    topic:
    types.submodule {
      options = {
        roomId = mkOption {
          # Room version 12 ids have no server part; older ones do. No blank,
          # quote, backslash or control character: ravnix-notify refuses a
          # config that has one, and the build should refuse it first.
          type = types.nullOr (types.strMatching ''![^[:cntrl:][:space:]"\\]+'');
          default = null;
          example = "!AbCdEfGhIjKlMnOpQr:example.org";
          description = ''
            The room's id, or null while the room does not exist yet. A topic
            without a room makes ravnix-notify exit with status 78 and say so
            (it neither asks rbw nor contacts the homeserver), and the build
            warns about it, once per topic.
          '';
        };

        botUser = mkOption {
          type = types.nullOr (types.strMatching "@[^:[:space:]]+:[^[:space:]]+");
          default = null;
          example = "@ravnix-${topic}:example.org";
          description = ''
            The bot account that posts to the room, for the record: nothing
            reads it, because the bot is whoever the access token belongs to.
          '';
        };

        tokenItem = mkOption {
          # No control character: ravnix-notify refuses a config that has one.
          type = types.strMatching "[^[:cntrl:]]+";
          default = "Matrix - access token (ravnix-${topic})";
          example = "Chat bots - ${topic}";
          description = ''
            The name of the Bitwarden item whose password is the bot's access
            token. Only the name is here; ravnix-notify asks rbw for the token
            each time it posts, so a locked vault stops the message (exit
            status 75) and it goes out once the vault is unlocked. The default
            is a naming rule, not a value of yours.
          '';
        };
      };
    };
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
      description = ''
        One room per notification topic, and the bot that posts to it. The
        topics are ${lib.concatStringsSep ", " (lib.attrNames topics)}, and
        there is no other. Set nothing, and every topic has no room: the
        build warns about each, and ravnix-notify exits with status 78 for it.
      '';
      type = types.submodule {
        options = lib.mapAttrs (
          topic: what:
          mkOption {
            type = room topic;
            default = { };
            description = "The room for ${what}, and its bot.";
          }
        ) topics;
      };
    };
  };
}
