# The link (modules/glue/link.nix) on the two shapes, evaluated as the
# private flake builds them, with the template's values: the server shape
# is the server end, whose xdg-open and notify-send are the link's and come
# before xdg-utils and libnotify, with the service that delivers what waits
# in the user manager's environment; the laptop shape is the laptop end,
# with the daemon of the graphical session, the real xdg-open and a scope
# for each program. And the socket the module names is the one the tool
# uses. tests/glue/link.nix runs both ends in VMs.
{
  self,
  inputs,
  lib,
  pkgs,
  system,
  ...
}:
let
  me = ../../templates/default/me.nix;
  user = (import me).ravnix.user.username;
  vault = (import me).ravnix.link.vault;
  build =
    modules:
    inputs.nixpkgs.lib.nixosSystem {
      modules = [
        me
        {
          nixpkgs.hostPlatform = system;
          system.stateVersion = "26.05";
        }
      ]
      ++ modules;
    };
  # Each shape brings the glue itself.
  muninn = build [ self.nixosModules.server ];
  huginn = build [
    self.nixosModules.laptop
    self.nixosModules.hardware-ideapad-pro-5-16ahp9
  ];
  # The server without the vault: vault-commit is refused.
  noVault = build [
    self.nixosModules.server
    { ravnix.link.vault = lib.mkForce null; }
  ];

  check = cond: msg: lib.optional (!cond) msg;
  # A store path in a pattern is refused, so the context goes first.
  plain = builtins.unsafeDiscardStringContext;
  infix = a: b: lib.hasInfix (plain a) (plain b);
  suffix = a: b: lib.hasSuffix (plain a) (plain b);
  named = name: c: lib.filter (p: lib.getName p == name) c.environment.systemPackages;
  homeNamed = name: c: lib.filter (p: lib.getName p == name) c.home-manager.users.${user}.home.packages;
  units = c: c.home-manager.users.${user}.systemd.user.services;
  text = p: p.text or "";
  # home-manager keeps ExecStart as a list.
  execOf = u: lib.concatStringsSep " " (lib.toList u.Service.ExecStart);

  m = muninn.config;
  h = huginn.config;
  link = named "ravnix-link" m;
  xdgOpen = named "xdg-open" m;
  notifySend = named "notify-send" m;
  deliver = (units m).ravnix-link-deliver or null;
  daemon = (units h).ravnix-link-daemon or null;

  # The tool's own name of the socket, as protocol.odin declares it.
  toolSocket = lib.head (
    builtins.match ''.*SOCKET_NAME :: "([^"]+)".*'' (builtins.readFile ../../tools/ravnix-link/protocol.odin)
  );

  failures =
    check (m.ravnix.shape == "server") "the server shape is not the server (${toString m.ravnix.shape})"
    ++ check (h.ravnix.shape == "laptop") "the laptop shape is not the laptop (${toString h.ravnix.shape})"

    # The server: xdg-open and notify-send are the link's, ahead of the
    # programs they stand in for, in the system's profile and the user's.
    ++ check (lib.length xdgOpen == 1) "the server has no xdg-open of the link"
    ++ check (lib.length notifySend == 1) "the server has no notify-send of the link"
    ++ check (lib.length link == 1) "the server has no ravnix-link"
    ++ lib.concatMap (
      p: check ((p.meta.priority or 5) < 5) "${lib.getName p} on the server does not come before what it stands in for"
    ) (xdgOpen ++ notifySend ++ link)
    ++ check (lib.all (p: infix "ravnix-link" (text p) && infix " open " (text p)) xdgOpen) "the server's xdg-open is not ravnix-link open"
    ++ check (lib.all (
      p: infix " notify-send " (text p) && infix "--notify-send ${lib.getExe' pkgs.libnotify "notify-send"}" (text p)
    ) notifySend) "the server's notify-send does not run the real one and forward"
    ++ check (lib.all (p: infix "--vault ${vault}" (text p)) link) "the server's ravnix-link does not know the vault"
    ++ check (lib.all (p: !infix "--vault" (text p)) (named "ravnix-link" noVault.config)) "a server without a vault still passes --vault"
    ++ check (lib.length (homeNamed "xdg-open" m) == 1) "the user's profile on the server has no xdg-open of the link"
    ++ check (lib.length (homeNamed "notify-send" m) == 1) "the user's profile on the server has no notify-send of the link"
    ++ check (deliver != null) "the server has no ravnix-link-deliver unit"
    ++ check (
      deliver != null && suffix "/bin/ravnix-link deliver" (execOf deliver)
    ) "ravnix-link-deliver does not run ravnix-link deliver"
    ++ check (deliver != null && deliver.Install.WantedBy == [ "default.target" ]) "ravnix-link-deliver does not start at boot"
    # A signed commit needs SSH_AUTH_SOCK from the user manager: the unit
    # sets PATH and nothing else.
    ++ check (
      deliver != null && lib.all (e: lib.hasPrefix "PATH=" e) (lib.toList deliver.Service.Environment)
    ) "ravnix-link-deliver sets more than PATH, and hides the user manager's environment"
    ++ check ((units m) ? ravnix-link-daemon == false) "the server runs the laptop's daemon"
    ++ check (m.services.openssh.settings.StreamLocalBindUnlink or false) "the server's sshd keeps a stale socket, so the forward fails after a dropped connection"

    # The laptop: the daemon of the graphical session, and nothing of the
    # server's.
    ++ check (named "xdg-open" h == [ ]) "the laptop's xdg-open is the link's"
    ++ check (named "notify-send" h == [ ]) "the laptop's notify-send is the link's"
    ++ check (homeNamed "xdg-open" h == [ ]) "the laptop's user profile has the link's xdg-open"
    ++ check (lib.length (homeNamed "ravnix-link" h) == 1) "the laptop has no ravnix-link"
    ++ check (daemon != null) "the laptop has no ravnix-link-daemon unit"
    ++ check (
      daemon != null && suffix " daemon" (execOf daemon)
      && infix "--xdg-open ${lib.getExe' pkgs.xdg-utils "xdg-open"}" (execOf daemon)
      && infix "--notify-send ${lib.getExe' pkgs.libnotify "notify-send"}" (execOf daemon)
    ) "ravnix-link-daemon does not run the daemon with xdg-utils' xdg-open and libnotify's notify-send"
    ++ check (
      daemon != null && infix "--systemd-run ${lib.getExe' pkgs.systemd "systemd-run"}" (execOf daemon)
    ) "ravnix-link-daemon does not start its programs in scopes of their own, so a restart of it ends them"
    ++ check (daemon != null && daemon.Install.WantedBy == [ "graphical-session.target" ]) "ravnix-link-daemon is not part of the graphical session"
    ++ check ((units h) ? ravnix-link-deliver == false) "the laptop runs the server's delivery"
    ++ check (!(h.services.openssh.settings.StreamLocalBindUnlink or false)) "the laptop's sshd is changed for the link"

    # One socket name, in the option and in the tool.
    ++ check (m.ravnix.link.socket == "ravnix-link.sock") "ravnix.link.socket is ${m.ravnix.link.socket}"
    ++ check (toolSocket == m.ravnix.link.socket) "the tool's socket ${toolSocket} is not ravnix.link.socket";
in
pkgs.runCommand "glue-link-shapes" { } (
  if failures == [ ] then
    ''
      touch $out
    ''
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
