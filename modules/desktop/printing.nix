# Printing and scanning on huginn, as the Fedora laptop has them: CUPS with
# driverless (IPP Everywhere) queues for the printers of ravnix.printing, found
# and resolved through avahi, a USB printer through ipp-usb, and scanning
# through the printer with sane-airscan (eSCL and WSD) in a native scan app.
#
# What Fedora does and this keeps:
#   - cups-browsed is off. It adds a queue for whatever a network announces,
#     which is how a laptop in a hotel ends up with a printer it never chose.
#   - CUPS listens on localhost only, shares nothing and opens no port.
#   - The only port open for this is mDNS (5353/udp), which avahi needs to
#     find a printer or a scanner; Fedora's public zone has it open too.
#
# The queues. NixOS's hardware.printers.ensurePrinters would make them in
# cups.service's postStart, and `lpadmin -m everywhere` asks the printer, so
# on a laptop that is away from home that start fails, and so does printing
# anywhere. ravnix-printers.service does it apart from CUPS instead, and
# tries again whenever a network comes up (NetworkManager's dispatcher), so
# the queue appears when the printer can be reached, and a printer that is not
# there costs a log line and nothing else.
#
# The scan app is simple-scan: the smallest closure of the candidates in
# nixpkgs (1.0 GiB; Skanpage is 2.3 GiB and Skanlite 1.8 GiB, both with KDE
# frameworks), GTK like the rest of the desktop's GTK apps, multi-page PDF
# output, and it talks to any SANE backend, airscan included.
#
# Style exception (docs/style.md, rule 9): simple-scan is a libadwaita
# application, which draws its own corners and header bar; the GTK theme
# (modules/theme/gtk-qt.nix) colors and fonts it but cannot square it. A Qt
# scan app would follow the Fusion style, and costs more than twice the disk
# for it. Task 3.7 judges it against a screenshot.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ravnix.printing;
  queues = lib.attrNames cfg.printers;

  # CUPS queue names: printable, no space, `#` or `/`. Narrower here, so that
  # the name is safe in every command line and file name it reaches.
  validName = name: builtins.match "[A-Za-z0-9._-]+" name != null;

  # One call per queue, in the order of the names. Arguments are shell words.
  ensureCalls = lib.concatMapStringsSep "\n" (
    name:
    let
      printer = cfg.printers.${name};
    in
    "ensure ${lib.escapeShellArg name} ${lib.escapeShellArg printer.uri} ${lib.escapeShellArg printer.model}"
  ) queues;

  systemctl = "${config.systemd.package}/bin/systemctl";
in
{
  config = lib.mkMerge [
    {
      services.printing = {
        enable = true;
        # Off as on Fedora, see above. It defaults to on with avahi.
        browsed.enable = false;
      };

      services.avahi = {
        enable = true;
        # Resolves the `.local` names a queue's URI may hold (an ipp-usb
        # printer, a DNS-SD printer). openFirewall stays at its default, which
        # opens 5353/udp for mDNS.
        nssmdns4 = true;
      };

      # A USB printer or scanner that speaks IPP everywhere appears as a
      # network printer on localhost, advertised through avahi. This also
      # turns on printing and SANE, which this module does anyway.
      services.ipp-usb.enable = true;

      hardware.sane = {
        enable = true;
        extraBackends = [ pkgs.sane-airscan ];
        # sane-backends has an eSCL backend of its own, and with sane-airscan
        # beside it every network scanner is listed twice in the scan app.
        disabledDefaultBackends = [ "escl" ];
      };

      environment.systemPackages = [ pkgs.simple-scan ];

      # The dispatcher below is how the queues are made once a printer can be
      # reached; vpn.nix turns NetworkManager on for the same reason.
      networking.networkmanager.enable = lib.mkDefault true;

      assertions = [
        {
          assertion = lib.all validName queues;
          message = "ravnix.printing.printers: ${
            lib.concatStringsSep ", " (lib.filter (n: !validName n) queues)
          } is not a queue name; use letters, digits, `.`, `_` and `-`.";
        }
        {
          assertion = cfg.defaultPrinter == null || cfg.printers ? ${cfg.defaultPrinter};
          message = "ravnix.printing.defaultPrinter is \"${toString cfg.defaultPrinter}\", which is none of ravnix.printing.printers (${lib.concatStringsSep ", " queues}).";
        }
      ];

      # avahi and the resolver share port 5353; two answerers make a lookup
      # flaky. Fedora's resolved does not answer mDNS either.
      services.resolved.settings.Resolve.MulticastDNS = lib.mkDefault false;
    }

    (lib.mkIf (cfg.printers != { }) {
      systemd.services.ravnix-printers = {
        description = "Create the CUPS queues of ravnix.printing.printers that are missing";
        # CUPS is socket activated: the socket is what this needs, and the
        # first lpadmin starts the daemon. avahi resolves dnssd:// URIs.
        after = [
          "cups.socket"
          "cups.service"
          "avahi-daemon.service"
          "ipp-usb.service"
        ];
        wants = [ "avahi-daemon.service" ];
        wantedBy = [ "multi-user.target" ];
        path = [
          config.services.printing.package
          pkgs.coreutils
          pkgs.gnused
        ];
        serviceConfig = {
          Type = "oneshot";
          # lpadmin waits for a printer that does not answer; it gives up
          # itself, and this is the limit for all queues.
          TimeoutStartSec = 300;
        };
        script = ''
          # One queue: made when missing, pointed at its URI when it exists
          # with another. A printer that cannot be reached is a line in the
          # journal, not a failed unit: away from home that is the normal case,
          # and a failed unit would show in every list of failures.
          ensure() {
            local name=$1 uri=$2 model=$3 have
            if lpstat -p "$name" >/dev/null 2>&1; then
              have=$(lpstat -v "$name" | sed -n "s|^device for $name: ||p")
              if [ "$have" != "$uri" ]; then
                lpadmin -p "$name" -v "$uri" ||
                  echo "ravnix-printers: could not point $name at $uri" >&2
              fi
            else
              lpadmin -p "$name" -E -v "$uri" -m "$model" ||
                echo "ravnix-printers: could not create $name at $uri (is the printer on?); it is tried again when a network comes up" >&2
            fi
          }

          ${ensureCalls}

          ${lib.optionalString (cfg.defaultPrinter != null) ''
            # A default that does not exist yet is set by the next run.
            if lpstat -p ${lib.escapeShellArg cfg.defaultPrinter} >/dev/null 2>&1; then
              lpadmin -d ${lib.escapeShellArg cfg.defaultPrinter}
            fi
          ''}
          exit 0
        '';
      };

      # A network came up: the printer may be on it. The dispatcher does not
      # wait for the unit, and a unit that is running is left alone.
      networking.networkmanager.dispatcherScripts = [
        {
          type = "basic";
          source = pkgs.writeShellScript "ravnix-printers" ''
            if [ "''${2:-}" = up ]; then
              ${systemctl} start --no-block ravnix-printers.service || true
            fi
            exit 0
          '';
        }
      ];
    })
  ];
}
