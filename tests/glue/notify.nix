# ravnix-notify on both hosts, and the config it reads. nixosModules.glue is
# evaluated on the server shape and on the laptop shape, as the private flake
# will build muninn and huginn, with the template's values and one room made
# up; nothing is built but the tool's own run:
#
#   - the tool is installed on both hosts, and so is its config
#     (/etc/ravnix/notify.json);
#   - the config holds the homeserver, the vault client and, per topic, the
#     room and the NAME of the Bitwarden item with the bot's token, never a
#     token or a bot's password;
#   - the tool the build produced accepts that very file: the Nix that writes
#     the config and the Odin that reads it are checked against each other,
#     with --dry-run, so nothing is sent and no vault is asked;
#   - a topic whose room is null warns at evaluation, once, naming the topic
#     and exit status 78; a topic with a room does not; and a host that sets
#     no room at all gets the defaults (no room, the token item's naming rule);
#   - the tool puts the priority in front of its line only when standard
#     error is the very stream JOURNAL_STREAM names (device and inode), not
#     when the variable is merely set, as it is in a child of a unit.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  me = import ../../templates/default/me.nix;
  topics = [
    "sessions"
    "updates"
    "backups"
    "builds"
    "services"
  ];

  # extra: what the host sets about the rooms. One room that exists, the
  # others as the template has them; or none set at all.
  build =
    extra: modules:
    inputs.nixpkgs.lib.nixosSystem {
      modules = [
        ../../templates/default/me.nix
        {
          system.stateVersion = "26.05";
          ravnix.editor.languages = lib.mkForce [ "nix" ];
        }
        extra
        self.nixosModules.glue
      ]
      ++ modules;
    };
  oneRoom.ravnix.matrix.rooms.builds.roomId = lib.mkForce "!builds:example.org";
  noRooms.ravnix.matrix.rooms = lib.mkForce { };

  server = [
    self.nixosModules.server
    {
      nixpkgs.hostPlatform = system;
      boot.loader.grub.enable = false;
      fileSystems."/" = {
        device = "none";
        fsType = "tmpfs";
      };
    }
  ];
  muninn = build oneRoom server;
  huginn = build oneRoom [
    self.nixosModules.laptop
    self.nixosModules.hardware-ideapad-pro-5-16ahp9
  ];
  bare = build noRooms server;

  # The text names the vault client's store path, which fromJSON refuses; the
  # dry run below never starts it, so the file need not keep it alive either.
  textOf =
    host: builtins.unsafeDiscardStringContext host.config.environment.etc."ravnix/notify.json".text;
  configOf = host: builtins.fromJSON (textOf host);
  installed =
    host: lib.any (p: lib.getName p == "ravnix-notify") host.config.environment.systemPackages;
  check = cond: msg: lib.optional (!cond) msg;
  tokenItemOf = topic: "Matrix - access token (ravnix-${topic})";
  # name: the host's name in a message; roomIds: the room each topic has.
  checksOf =
    name: host: roomIds:
    let
      cfg = configOf host;
      # The glue module's warnings; the placeholders of the template warn too.
      warned = lib.filter (w: lib.hasPrefix "ravnix.matrix.rooms." w && lib.hasInfix ".roomId is null" w) host.config.warnings;
    in
    check (installed host) "${name}: ravnix-notify is not installed"
    ++ check (
      host.config.environment.etc ? "ravnix/notify.json"
    ) "${name}: there is no /etc/ravnix/notify.json"
    ++
      check
        (
          lib.attrNames cfg == [
            "homeserver"
            "rbw"
            "rooms"
          ]
        )
        "${name}: the config has other keys than homeserver, rbw and rooms: ${toString (lib.attrNames cfg)}"
    ++ check (
      cfg.homeserver == me.ravnix.matrix.homeserver
    ) "${name}: the homeserver is ${cfg.homeserver}"
    ++ check (lib.hasSuffix "/bin/rbw" cfg.rbw) "${name}: rbw is ${cfg.rbw}, not a program called rbw"
    ++ check (
      lib.attrNames cfg.rooms == lib.sort lib.lessThan topics
    ) "${name}: the topics are ${toString (lib.attrNames cfg.rooms)}"
    ++ lib.concatMap (
      topic:
      let
        room = cfg.rooms.${topic};
        want = roomIds.${topic} or null;
        warnings = lib.filter (lib.hasPrefix "ravnix.matrix.rooms.${topic}.roomId is null") warned;
      in
      check (
        lib.attrNames room == [
          "roomId"
          "tokenItem"
        ]
      ) "${name}: ${topic} has other keys than roomId and tokenItem"
      ++ check (
        room.tokenItem == tokenItemOf topic
      ) "${name}: ${topic}'s token item is ${room.tokenItem}, not the naming rule's"
      ++ check (room.roomId == want) "${name}: ${topic}'s room is ${toString room.roomId}"
      # One warning for a topic without a room, naming the topic and the exit
      # status; none for a topic with one.
      ++ (
        if want == null then
          check (
            lib.length warnings == 1
            && lib.hasInfix "exits with status 78 for the topic ${topic} " (lib.head warnings)
          ) "${name}: ${topic} has no room, and the warnings for it are ${builtins.toJSON warnings}"
        else
          check (warnings == [ ]) "${name}: ${topic} has a room, and still warns: ${builtins.toJSON warnings}"
      )
    ) topics
    ++ check (
      lib.length warned == lib.length (lib.filter (t: (roomIds.${t} or null) == null) topics)
    ) "${name}: the warnings about rooms are ${builtins.toJSON warned}";

  failures =
    checksOf "muninn" muninn { builds = "!builds:example.org"; }
    ++ checksOf "huginn" huginn { builds = "!builds:example.org"; }
    # Nothing set: every topic has the defaults, and every topic warns.
    ++ checksOf "bare" bare { };

  tool = self.packages.${system}.ravnix-notify;
  fileOf = host: pkgs.writeText "notify.json" (textOf host);
  config = fileOf muninn;
  sameConfig = fileOf huginn;
in
pkgs.runCommand "glue-notify" { nativeBuildInputs = [ tool ]; } (
  if failures != [ ] then
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
  else
    ''
      fail() { echo "glue-notify: $*" >&2; exit 1; }
      status() { # status EXPECTED COMMAND...
        want=$1; shift
        set +e; "$@" >out 2>err; got=$?; set -e
        [ "$got" = "$want" ] || { cat err >&2; fail "$* exited $got, not $want"; }
      }

      # Both hosts get the same file.
      cmp ${config} ${sameConfig} || fail "the two hosts' configs differ"

      # The tool takes the file the module writes.
      status 0 ravnix-notify --config ${config} --dry-run --topic builds '**built**'
      grep -q '^PUT ${me.ravnix.matrix.homeserver}/_matrix/client/v3/rooms/%21builds%3Aexample.org/send/m.room.message/<transaction id>$' out || { cat out >&2; fail "the request is not for the builds room"; }
      grep -q '"formatted_body":"<p><strong>built</strong></p>"' out || fail "the message is not rendered"

      # A topic whose room does not exist yet is the config's fault, not usage.
      status 78 env -u JOURNAL_STREAM ravnix-notify --config ${config} --topic sessions hello
      grep -q 'no room yet' err || fail "no word about the missing room"
      if grep -q '<3>' err; then fail "a priority in front of a line that is not for the journal"; fi

      # A topic that is none of the five.
      status 64 ravnix-notify --config ${config} --topic nonsense hello
      grep -q 'known topics: backups, builds, services, sessions, updates' err || fail "the known topics are not listed"

      # Standard error is the journal only when it is the stream that
      # JOURNAL_STREAM names, by device and inode (systemd.exec(5)); a child
      # of a unit inherits the variable and has a stderr of its own. Here the
      # stream is the file err itself: stat gives its device and inode, and
      # status redirects standard error into that same file.
      : > err
      status 78 env JOURNAL_STREAM="$(stat -c %d:%i err)" ravnix-notify --config ${config} --topic sessions hello
      grep -q '^<3>ravnix-notify: sessions: ' err || { cat err >&2; fail "no priority in front of the line on the stream"; }

      # Set, but for another stream: no prefix, the line is plain. (It goes to
      # the journal's socket as well, which the sandbox has none of; the tool's
      # own tests check that with a socket of their own.)
      status 78 env JOURNAL_STREAM=8:1 ravnix-notify --config ${config} --topic sessions hello
      grep -q '^ravnix-notify: sessions: ' err || { cat err >&2; fail "no plain line for a variable that names another stream"; }
      if grep -q '<3>' err; then fail "a priority in front of a line, though the variable names another stream"; fi

      # The stream of a file other than standard error: same device, other inode.
      : > other
      status 78 env JOURNAL_STREAM="$(stat -c %d:%i other)" ravnix-notify --config ${config} --topic sessions hello
      if grep -q '<3>' err; then fail "a priority in front of a line, though the variable names the inode of another file"; fi

      # A value that is no device and inode at all.
      for value in "" 1 : a:b 1:2:3 " 1:2" "$(stat -c %d:%i err)x"; do
        status 78 env JOURNAL_STREAM="$value" ravnix-notify --config ${config} --topic sessions hello
        if grep -q '<3>' err; then fail "a priority in front of a line, though JOURNAL_STREAM is '$value'"; fi
      done

      touch $out
    ''
)
