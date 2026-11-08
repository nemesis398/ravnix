# The two terminal keys and the main connection: the laptop, huginn, reaches
# the server, muninn, where the terminal applications run in herdr, so that
# a closed lid ends nothing there. Which end a host is comes from
# ravnix.shape; the values are ravnix.serverAccess (modules/options/
# server-access.nix) and the server's NetBird address
# (ravnix.server.netbirdAddress), which reaches it from any network the
# laptop roams to.
#
# The laptop end.
#
#   ssh       The user's ~/.ssh/config begins with an Include of one block,
#             `Host ravnix-server`: the server's NetBird address, the user's
#             account (the same on both hosts), and the key of
#             serverAccess.identityFile with no agent, so neither the YubiKey
#             nor Bitwarden's agent is asked and a reconnect after a suspend
#             finds nothing locked. The host key is serverAccess.hostKey,
#             pinned; without one, the first key the server shows is
#             remembered under the name ravnix-server and any other refused.
#             A dead connection is noticed within 3 to 4 s (ServerAlive), and
#             BatchMode keeps every prompt out: nobody may be there to answer.
#   the main key ($mod+Return; ravnix.desktop.terminal.main, which the Sway
#             config and its session layout read) opens ghostty running
#             ravnix-terminal: herdr's own remote attach, `herdr --remote
#             ravnix-server`, to the one herdr session of the server's
#             herdr-server unit. herdr 0.9.5 draws the UI on the laptop and
#             keeps nothing running there, but it does not attach again by
#             itself: when the connection drops it prints "lost connection to
#             remote Herdr ... run `herdr --remote ...` to reattach" and
#             exits with status 1. That was seen in a VM made to explore
#             herdr before this module was written, after a killed TCP
#             connection and after an IP change; it is no test here, because
#             tests/glue/reconnect.nix runs herdr inside ravnix-terminal,
#             whose loop hides it. So ravnix-terminal attaches again
#             whenever herdr ends with another status than 0, until a detach
#             (prefix+d) ends herdr with 0 and the window closes.
#             Not mosh: herdr's remote attach is what bridges the laptop's
#             clipboard and notifications, and mosh would run the UI on the
#             server, and needs UDP ports open there. Not herdr's saved
#             machines (`herdr machine add`, `herdr --machine`): they need a
#             herdr server on the laptop too, with a "Local" entry, and
#             herdr's documented back-off retries a dropped machine soon only
#             when its connection had stayed up for a minute, so two drops
#             in a row, a suspend and then a new network, would take longer
#             than the few seconds this is for.
#   the second key ($mod+Alt+Return; ravnix.desktop.terminal.plain) stays
#             the desktop's: a ghostty with a bash on the laptop.
#   herdr     The laptop's herdr reads the server's settings
#             (modules/workbench/herdr-settings.nix): the theme, the keys and
#             the UI are drawn and read on the laptop in a remote attach.
#   OSC 52    A program in a remote pane copies into the laptop's clipboard
#             with OSC 52: herdr hands it to the terminal it runs in, and
#             ghostty writes it (clipboard-write). Reading the clipboard that
#             way is refused (clipboard-read): an agent in a pane could read
#             what you copied elsewhere, and ghostty's default would ask in a
#             dialog each time.
#   the main connection, ravnix-connection, a user unit of the graphical
#             session: one ssh connection that forwards the glue's sockets to
#             the server, each from the laptop's runtime directory to the
#             server's under the same name (ravnix.link.socket, the link's;
#             ravnix.skAgent.socket, the security key agent's). ssh needs
#             absolute paths, and the account's uid on the server is not
#             known here, so it asks the server first, over a short
#             connection of its own, and then forwards
#
#               /run/user/<uid on muninn>/NAME  ->  $XDG_RUNTIME_DIR/NAME
#
#             The server's sshd replaces a socket that a dropped connection
#             left behind (StreamLocalBindUnlink, set by link.nix and
#             sk-agent.nix), and the connection ends when a forward fails
#             (ExitOnForwardFailure), so systemd starts it again, every 2 s,
#             forever: a laptop that is offline or asleep gets its forwards
#             back as soon as it can reach the server. Until then the socket
#             on the server is still the one of the dead connection, and a
#             program that connects to it in those seconds is taken and gets
#             no answer until the server's sshd ends that session (below,
#             30 to 40 s); the security key's check gives up after 3 s, and
#             tests/glue/reconnect.nix asks again. A socket of the
#             laptop that nobody listens on is forwarded too; whoever
#             connects to it on the server gets an error, which the link and
#             the security key's check report. It is not the terminal's
#             connection: the forwards are there as long as the session runs,
#             not as long as some window does, and one window or five make no
#             second forward of the same socket.
#
# The server end: the public half of the key (serverAccess.publicKey) is a
# key of the account, for a shell, commands and forwarding, and for neither
# an agent nor a display (`restrict,port-forwarding,pty`). sshd checks a
# client that has gone quiet every 10 s and ends it after 30 s, so a laptop
# that vanished (a closed lid, another network) leaves no session behind
# that would hold an old forward or keep herdr sized for a window that is
# gone.
#
# Left out on purpose: the shell's terminal auto-attach of the Fedora
# laptop (ravnix.shell.autoAttach stays empty). The main key opens herdr
# itself; any other terminal on the laptop is a local shell, so a laptop
# without the server still has one.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  os = config;
  cfg = os.ravnix.serverAccess;
  user = os.ravnix.user.username;
  alias = "ravnix-server";

  sockets = [
    os.ravnix.link.socket
    os.ravnix.skAgent.socket
  ];

  knownHosts = pkgs.writeText "ravnix-server-known-hosts" "${alias} ${toString cfg.hostKey}\n";

  hostBlock = pkgs.writeText "ravnix-server.ssh_config" (
    lib.concatStringsSep "\n" (
      [
        "Host ${alias}"
        "  HostName ${os.ravnix.server.netbirdAddress}"
        "  User ${user}"
        "  HostKeyAlias ${alias}"
      ]
      ++ lib.optionals (cfg.identityFile != null) [
        "  IdentityFile ${cfg.identityFile}"
        "  IdentitiesOnly yes"
        "  IdentityAgent none"
      ]
      ++ (
        if cfg.hostKey != null then
          [
            "  UserKnownHostsFile ${knownHosts}"
            "  GlobalKnownHostsFile /dev/null"
            "  StrictHostKeyChecking yes"
          ]
        else
          [ "  StrictHostKeyChecking accept-new" ]
      )
      ++ [
        "  BatchMode yes"
        "  ConnectTimeout 5"
        "  ServerAliveInterval 1"
        "  ServerAliveCountMax 3"
        "  ForwardAgent no"
        "  ForwardX11 no"
        ""
      ]
    )
  );

  # The two commands, Bash in ./terminal/ (./terminal/scripts.nix).
  inherit
    (import ./terminal/scripts.nix {
      inherit lib pkgs sockets alias;
      openssh = os.programs.ssh.package;
    })
    terminal
    connection
    ;
in
{
  config = lib.mkMerge [
    (lib.mkIf (os.ravnix.shape == "laptop") {
      ravnix.desktop.terminal.main = "ghostty -e ${lib.getExe terminal}";

      home-manager.users.${user} =
        { config, ... }:
        {
          home.packages = [
            terminal
            connection
          ];

          programs.ssh = {
            enable = true;
            # Its defaults are ssh's own, but for a warning on every build
            # that they will go.
            enableDefaultConfig = lib.mkDefault false;
            includes = [ "${hostBlock}" ];
          };

          programs.herdr = {
            enable = true;
            settings = import ../workbench/herdr-settings.nix {
              accent = config.ravnix.theme.roles.accent;
            };
          };

          programs.ghostty.settings = {
            clipboard-write = "allow";
            clipboard-read = "deny";
          };

          systemd.user.services.ravnix-connection = {
            Unit = {
              Description = "ravnix: the main connection, which forwards the glue's sockets to the server";
              PartOf = [ "graphical-session.target" ];
              After = [ "graphical-session.target" ];
              # Never give up: the server is away for as long as the laptop
              # is offline.
              StartLimitIntervalSec = 0;
            };
            Service = {
              Type = "simple";
              ExecStart = lib.getExe connection;
              Restart = "always";
              RestartSec = 2;
            };
            Install.WantedBy = [ "graphical-session.target" ];
          };
        };
    })

    (lib.mkIf (os.ravnix.shape == "server") {
      users.users.${user}.openssh.authorizedKeys.keys = lib.optional (
        cfg.publicKey != null
      ) "restrict,port-forwarding,pty ${cfg.publicKey}";
      services.openssh.settings = {
        ClientAliveInterval = lib.mkDefault 10;
        ClientAliveCountMax = lib.mkDefault 3;
      };
    })
  ];
}
