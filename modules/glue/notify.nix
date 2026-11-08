# ravnix-notify on both hosts: the tool that posts a message to the Matrix
# room of a topic (tools/ravnix-notify), and the file it reads, which says
# where the homeserver is, which room each topic is, and which Bitwarden item
# holds each bot's token. The token is not in the file: the tool asks rbw for it
# each time, and puts it on neither a command line nor a disk.
#
# The same file on huginn and on muninn, so a message sent from either goes to
# the same room; the vault must be unlocked on the host that sends. The tool
# runs as the user whose rbw it asks, which is why rbw is the home-manager
# package of that user.
#
# A topic whose room is null (it does not exist yet, or the host sends no
# notifications for it) makes the tool exit with status 78 before it asks rbw
# for anything, and the build warns once for each such topic, so the gap is
# seen when the host is built and not when a message is needed.
#
# Nothing here calls the tool. A unit, a timer or a hook that wants to be
# heard runs it, and takes exit status 75 (the vault is locked, or the
# homeserver is out of reach) for a try that can be made again.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  user = config.ravnix.user.username;
  matrix = config.ravnix.matrix;
  rbw = lib.getExe' config.home-manager.users.${user}.programs.rbw.package "rbw";
in
{
  environment.systemPackages = [ pkgs.ravnix.ravnix-notify ];

  warnings = lib.concatMap (
    topic:
    lib.optional (matrix.rooms.${topic}.roomId == null) (
      "ravnix.matrix.rooms.${topic}.roomId is null: ravnix-notify exits with status 78 for the topic ${topic} and posts nothing."
      + " Create the room, invite the bot and set the room's id."
    )
  ) (lib.attrNames matrix.rooms);

  # tools/ravnix-notify/config.odin reads this file.
  environment.etc."ravnix/notify.json".text = builtins.toJSON {
    inherit (matrix) homeserver;
    inherit rbw;
    rooms = lib.mapAttrs (_: room: { inherit (room) roomId tokenItem; }) matrix.rooms;
  };
}
