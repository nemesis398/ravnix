# The link between the hosts: ravnix-link (tools/ravnix-link). On the server,
# muninn, `xdg-open` and `notify-send` go to the laptop, and so do Obsidian's
# move, rename and delete; on the laptop, huginn, a daemon carries them out.
# What the laptop cannot get while it is away waits in a queue on the
# server's disk and is delivered, once and in order, when it is back.
#
# The socket. The daemon listens on $XDG_RUNTIME_DIR/ravnix-link.sock on
# the laptop, mode 600. The main connection (modules/glue/terminal.nix)
# forwards it to the server as $XDG_RUNTIME_DIR/ravnix-link.sock of the same
# user, with an ssh RemoteForward; both names are ravnix.link.socket, a
# name in $XDG_RUNTIME_DIR on each host. ssh needs absolute paths, so the
# forward is
#
#   RemoteForward /run/user/<uid on muninn>/ravnix-link.sock
#                 /run/user/<uid on huginn>/ravnix-link.sock
#
# The server's sshd replaces a socket that a dropped connection left behind
# (StreamLocalBindUnlink, below), so the next connection can forward it
# again; without it the forward fails until the file is removed.
#
# Which end a host is: ravnix.shape, which the shapes set
# (modules/options/shape.nix). The server shape gets the server's end, the
# laptop shape the laptop's, and a host without a shape nothing of this
# module (tests/glue/link-shapes.nix checks both shapes).
#
# On the server:
#   - `xdg-open` is `ravnix-link open`, and `notify-send` runs the real one
#     (which finds no notification service on a server) and forwards the
#     notification. Both are in the system's profile and the user's, ahead
#     of xdg-utils and libnotify, so every caller gets them.
#   - `ravnix-link` knows the vault (ravnix.link.vault) and runs git from
#     the store; the user's git configuration and the vault's hooks apply.
#   - ravnix-link-deliver, a user unit from boot, delivers what waits as
#     soon as the socket appears or the queue changes, and runs the queued
#     vault commits. It has the user manager's environment, with only PATH
#     set here: a commit that is signed needs SSH_AUTH_SOCK there, which the
#     agent's module puts into the user manager (Task 4.3; the README of
#     tools/ravnix-link has the interface). Without it the commit fails and
#     is tried again, and `ravnix-link status` shows why.
# On the laptop:
#   - `ravnix-link` knows the laptop's copy of the vault (ravnix.link.vault,
#     the same path as the server's when both sync it to the same place) and
#     a forward: `ravnix-link vault-commit MESSAGE PATH...` reads each PATH
#     there, and sends the commit with the SHA-256 of each file to the
#     server, by `ssh ravnix-server /run/current-system/sw/bin/ravnix-link
#     receive` with the request on ssh's standard input. The remote command
#     is fixed, so no value of the request passes through a shell; the host
#     block of ./terminal.nix gives the key, with no agent and no touch of a
#     security key. The server queues the commit, which waits until its copy
#     of the vault has each file as the laptop had it (or 15 minutes), and
#     answers. A laptop that cannot reach the server says so, and nothing is
#     queued on the laptop (tools/ravnix-link/README.md).
#   - ravnix-link-daemon, a user unit of the graphical session: everything
#     it runs needs the session's display and bus. It runs xdg-open and
#     notify-send from the store, and obsidian from the user's PATH, where
#     the desktop puts Obsidian. Each program starts in a scope of its own
#     (systemd-run --user --scope), so a restart of the daemon does not end
#     the browser or the Obsidian it opened; their output goes to the
#     daemon's journal.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  os = config;
  cfg = os.ravnix.link;
  user = os.ravnix.user.username;
  tool = pkgs.ravnix.ravnix-link;
  profile = "/etc/profiles/per-user/${user}/bin";
  path = "${profile}:/run/current-system/sw/bin";

  # The server's ravnix-link: the tool with the vault and git.
  serverLink = pkgs.writeShellApplication {
    name = "ravnix-link";
    text = ''
      exec ${lib.getExe tool} ${
        lib.escapeShellArgs (
          lib.optionals (cfg.vault != null) [
            "--vault"
            cfg.vault
          ]
          ++ [
            "--git"
            (lib.getExe cfg.programs.git)
          ]
        )
      } "$@"
    '';
  };
  xdgOpen = pkgs.writeShellApplication {
    name = "xdg-open";
    text = ''exec ${lib.getExe serverLink} open "$@"'';
  };
  notifySend = pkgs.writeShellApplication {
    name = "notify-send";
    text = ''exec ${lib.getExe serverLink} --notify-send ${lib.escapeShellArg cfg.programs.notifySend} notify-send "$@"'';
  };
  serverPackages = map lib.hiPrio [
    serverLink
    xdgOpen
    notifySend
  ];

  # The laptop's way to the server's receive. The remote command is fixed:
  # ssh joins its words into a line for the server's shell, so nothing of
  # the request may be among them; the request goes on standard input.
  forward = pkgs.writeShellApplication {
    name = "ravnix-link-forward";
    text = ''
      exec ${lib.escapeShellArg cfg.programs.ssh} -T -o BatchMode=yes -- ${lib.escapeShellArg cfg.programs.server} /run/current-system/sw/bin/ravnix-link receive
    '';
  };
  # The laptop's ravnix-link: the tool with its copy of the vault and the
  # forward, for vault-commit. The forward rides along, for the tests.
  laptopLink = pkgs.writeShellApplication {
    name = "ravnix-link";
    text = ''
      exec ${lib.getExe tool} ${
        lib.escapeShellArgs (
          lib.optionals (cfg.vault != null) [
            "--vault"
            cfg.vault
          ]
          ++ [
            "--forward"
            (lib.getExe forward)
          ]
        )
      } "$@"
    '';
  }
  // {
    inherit forward;
  };
in
{
  # Declared here and not in modules/options: they are the glue's alone, and
  # home-manager has no use for them (modules/common/nixos.nix forwards only
  # what modules/options declares).
  options.ravnix.link.command = lib.mkOption {
    type = lib.types.nullOr lib.types.package;
    default = null;
    internal = true;
    description = ''
      The host's ravnix-link, as its shape has it: the server's, which
      commits in the vault, or the laptop's, which sends a commit to the
      server; null on a host without a shape. ./vault.nix gives it to
      vault-commit.
    '';
  };

  options.ravnix.link.programs = {
    xdgOpen = lib.mkOption {
      type = lib.types.str;
      default = lib.getExe' pkgs.xdg-utils "xdg-open";
      defaultText = lib.literalExpression ''lib.getExe' pkgs.xdg-utils "xdg-open"'';
      internal = true;
      description = "The xdg-open the laptop's daemon runs.";
    };
    notifySend = lib.mkOption {
      type = lib.types.str;
      default = lib.getExe' pkgs.libnotify "notify-send";
      defaultText = lib.literalExpression ''lib.getExe' pkgs.libnotify "notify-send"'';
      internal = true;
      description = "The real notify-send: the laptop's daemon runs it, and so does the server's notify-send.";
    };
    obsidian = lib.mkOption {
      type = lib.types.str;
      default = "obsidian";
      internal = true;
      description = "The Obsidian CLI the laptop's daemon runs, a name on the daemon's PATH or a path.";
    };
    git = lib.mkOption {
      type = lib.types.package;
      default = pkgs.git;
      defaultText = lib.literalExpression "pkgs.git";
      internal = true;
      description = "The git that vault-commit runs on the server.";
    };
    ssh = lib.mkOption {
      type = lib.types.str;
      default = lib.getExe' os.programs.ssh.package "ssh";
      defaultText = lib.literalExpression ''lib.getExe' config.programs.ssh.package "ssh"'';
      internal = true;
      description = "The ssh that carries a commit from the laptop to the server.";
    };
    server = lib.mkOption {
      type = lib.types.str;
      default = "ravnix-server";
      internal = true;
      description = ''
        The host the laptop sends a commit to, a name of the user's ssh
        configuration: ravnix-server, the block of ./terminal.nix.
      '';
    };
    systemdRun = lib.mkOption {
      type = lib.types.str;
      default = lib.getExe' pkgs.systemd "systemd-run";
      defaultText = lib.literalExpression ''lib.getExe' pkgs.systemd "systemd-run"'';
      internal = true;
      description = ''
        The systemd-run that starts each program of the laptop's daemon in a
        scope of its own; "" starts them in the daemon's unit, where a
        restart of the daemon ends them.
      '';
    };
  };

  config = lib.mkMerge [
    (lib.mkIf (os.ravnix.shape == "server") {
      ravnix.link.command = serverLink;
      services.openssh.settings.StreamLocalBindUnlink = true;
      environment.systemPackages = serverPackages;
      home-manager.users.${user} = {
        home.packages = serverPackages;
        systemd.user.services.ravnix-link-deliver = {
          Unit.Description = "ravnix-link: deliver to the laptop what waits for it";
          Service = {
            Type = "simple";
            # Only PATH: the rest of the environment is the user manager's,
            # SSH_AUTH_SOCK for a signed commit included.
            Environment = [ "PATH=${path}" ];
            ExecStart = "${lib.getExe serverLink} deliver";
            Restart = "always";
            RestartSec = 5;
          };
          Install.WantedBy = [ "default.target" ];
        };
      };
    })

    (lib.mkIf (os.ravnix.shape == "laptop") {
      ravnix.link.command = laptopLink;
      home-manager.users.${user} = {
        home.packages = [ laptopLink ];
        systemd.user.services.ravnix-link-daemon = {
          Unit = {
            Description = "ravnix-link: carry out what the server sends";
            PartOf = [ "graphical-session.target" ];
            After = [ "graphical-session.target" ];
          };
          Service = {
            Type = "simple";
            Environment = [ "PATH=${path}" ];
            ExecStart = lib.escapeShellArgs (
              [
                (lib.getExe tool)
                "--xdg-open"
                cfg.programs.xdgOpen
                "--notify-send"
                cfg.programs.notifySend
                "--obsidian"
                cfg.programs.obsidian
              ]
              ++ lib.optionals (cfg.programs.systemdRun != "") [
                "--systemd-run"
                cfg.programs.systemdRun
              ]
              ++ [ "daemon" ]
            );
            Restart = "on-failure";
            RestartSec = 2;
          };
          Install.WantedBy = [ "graphical-session.target" ];
        };
      };
    })
  ];
}
