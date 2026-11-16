# skrá, the web interface for CUPS, as the user's own units: a socket on
# 127.0.0.1:7631, a service that the first request starts, the configuration,
# and a launcher that opens the page in a window of its own. The program is
# packages/skra; the units are dist/skra.socket and dist/skra.service of its
# repository, with the binary from the store instead of ~/.local/bin.
#
# Nothing runs while the page is closed: only the socket is wanted, and the
# service has no [Install] section. The service exits after skrá's idle_exit
# (five minutes by default, and only when systemd started it) and the socket
# starts it again. MemoryMax=100M, Restart=on-failure and NoNewPrivileges are
# the units' own. Under socket activation skrá refuses a socket that is not
# TCP on 127.0.0.1, and the module never names another address.
#
# ~/.config/skra/config.json holds what NixOS knows and nothing else:
#
#   declared_queues     the queues of ravnix.printing.printers, which
#                       ravnix-printers.service makes (printing.nix) and which
#                       come back after a rebuild; skrá shows them read-only
#                       and refuses to remove or re-address them
#   cupsd_conf_managed  NixOS writes /etc/cups/cupsd.conf, so skrá's switch for
#                       debug logging, which edits that file, is off
#
# listen, cups_socket, user, state_dir and idle_exit stay at skrá's defaults:
# the socket unit decides the address, CUPS is at /run/cups/cups.sock, and the
# user and the state directory come from the user manager's environment.
#
# The rights it needs, and where they come from on this system:
#   - CUPS admin over /run/cups/cups.sock. skrá sends `Authorization: PeerCred
#     USER`; NixOS writes `SystemGroup root wheel lpadmin` into
#     cups-files.conf (nixos/modules/services/printing/cupsd.nix), and the
#     account is in wheel (modules/common/nixos.nix). The unit needs nothing
#     added.
#   - The CUPS log is `journalctl -u cups.service`. systemd gives the system
#     journal's read ACL to wheel and adm, so the same group is enough;
#     tests/desktop/skra.nix reads it as the user in a VM.
#
# Launcher: `skra` opens the page in a Helium app window like the web apps
# (webapps.nix), by gtk-launch or the launcher menu. It is no webapp-NAME entry
# because that set is the sites the user chooses (tests/desktop/webapps.nix).
# Opening the page is the first request, which starts the service.
#
# Style exception (docs/style.md, rule 9): the page follows the style's shape,
# with square corners, JetBrainsMono Nerd Font and no animation, but its
# Catppuccin Mocha palette and mauve accent are hard-coded in the program's
# stylesheet. ravnix.theme's flavor and accent do not reach it, and cannot
# without a patch to the program or a theme setting upstream.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ravnix.printing;
  package = pkgs.ravnix.skra;
  appId = import ../../lib/webapp-app-id.nix { inherit lib; };
  url = "http://127.0.0.1:7631/";
in
{
  config = lib.mkIf cfg.skra.enable {
    environment.systemPackages = [
      (pkgs.makeDesktopItem {
        name = "skra";
        desktopName = "skrá";
        genericName = "Printing";
        comment = "Printers, ink levels, the queue and the CUPS log";
        exec = "helium --app=${url}";
        icon = "printer";
        terminal = false;
        startupNotify = true;
        startupWMClass = appId url;
        categories = [
          "Office"
          "Settings"
        ];
        keywords = [
          "skra"
          "skrá"
          "print"
          "printer"
          "drucker"
          "drucken"
          "cups"
          "ink"
          "tinte"
        ];
      })
    ];

    home-manager.sharedModules = [
      {
        xdg.configFile."skra/config.json".text = builtins.toJSON {
          declared_queues = lib.attrNames cfg.printers;
          cupsd_conf_managed = true;
        };

        systemd.user.sockets.skra = {
          Unit.Description = "skrá print service socket";
          Socket.ListenStream = "127.0.0.1:7631";
          Install.WantedBy = [ "sockets.target" ];
        };

        systemd.user.services.skra = {
          Unit = {
            Description = "skrá print service";
            Requires = [ "skra.socket" ];
            After = [ "skra.socket" ];
          };
          # No Install: the first request to the socket starts it.
          Service = {
            Type = "simple";
            ExecStart = lib.getExe package;
            # Idle it stays under 50 MB; saving a page as PNG or JPEG holds the
            # decoded page and a copy. Both are the limits of dist/ as pushed.
            MemoryMax = "100M";
            Restart = "on-failure";
            NoNewPrivileges = true;
          };
        };
      }
    ];
  };
}
