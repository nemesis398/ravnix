# The personal values behind printing and the VPNs: the printers a user has,
# the NetBird management server, the NordVPN account's Bitwarden items and
# country, and the home VPN gateway. They are read by modules/desktop/
# printing.nix and vpn.nix and by the nord and vpn-home commands those build;
# ravnix itself sets none of them, and none has a default that could pass for
# a real value. templates/default/me.nix lists every option with a comment.
#
# A Bitwarden item is only ever named here, by its name or its id; rbw reads
# the secret at the moment a command needs it, and no value reaches a file or
# the Nix store.
{ lib, ... }:
let
  inherit (lib) mkOption types;
  ravnix = import ./types.nix { inherit lib; };

  # A CUPS device URI as `lpinfo -v` prints it: a scheme CUPS has a backend
  # for, then the rest with no white space (a space in a printer's name is
  # written %20 in the URI). `dnssd://` and `ipp://NAME._ipp._tcp.local/`
  # name a printer by its DNS-SD service, which survives a change of its
  # address. No `@` is allowed before the first `/` after the scheme, which is
  # where a user name and password would go: the URI lands in the Nix store and
  # in the journal, and neither is a place for a credential.
  printerUri =
    types.strMatching "(ipp|ipps|dnssd|socket|lpd|http|https|usb)://[^@/[:space:]]+(/[^[:space:]]*)?"
    // {
      description = "CUPS device URI without credentials (ipp://, ipps://, dnssd://, socket://, lpd://, http(s):// or usb://)";
    };

  # What the NetBird client takes as its management server: scheme, host and
  # an optional port, with no path.
  managementUrl =
    types.strMatching "https?://[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?/?"
    // {
      description = "http or https URL of a host, with an optional port and no path";
    };

  printer = types.submodule {
    options = {
      uri = mkOption {
        type = printerUri;
        example = "ipp://printer.example.org/ipp/print";
        description = ''
          Where CUPS reaches the printer: the URI `lpinfo -v` shows for it
          while it is on the network, or `lpstat -v` on a machine that has
          its queue. No user name or password: the URI is written into the
          Nix store and the journal.

          A DNS-SD URI (`dnssd://` or `ipp://NAME._ipp._tcp.local/`) should
          carry the printer's `?uuid=`, which `lpinfo -v` shows for a printer
          that announces one: CUPS then refuses an answer from another device.
          Without it, whatever answers that service name on the network the
          laptop is on gets a queue made from its attributes, and the queue
          keeps the driver it was made with. A printer announced by ipp-usb
          shows no uuid until it is plugged in; `avahi-browse -rt _ipp._tcp`
          then lists its `UUID=` in the TXT record.
        '';
      };

      model = mkOption {
        type = types.nonEmptyStr;
        default = "everywhere";
        example = "everywhere";
        description = ''
          The `lpadmin -m` argument that picks the driver. `everywhere` asks
          the printer itself (IPP Everywhere, also called driverless), which
          every printer from the last decade answers and needs no package;
          `lpinfo -m` lists the others.
        '';
      };
    };
  };

  nord = types.submodule {
    options = {
      countryId = mkOption {
        type = types.ints.positive;
        example = 81;
        description = ''
          Nord's id for the country the servers are chosen from (81 is
          Germany). The list is at
          `https://api.nordvpn.com/v1/servers/countries`.
        '';
      };

      tokenItem = mkOption {
        type = types.nonEmptyStr;
        example = "NordVPN - access token";
        description = ''
          The Bitwarden item, by name or id, that holds the access token
          `nord setup` uses once to fetch the account's WireGuard key. The
          token is made in the Nord account (NordVPN, Set up NordVPN
          manually, Access token), kept in this item for the few minutes
          the setup takes, and revoked after it.
        '';
      };

      keyItem = mkOption {
        type = types.nonEmptyStr;
        example = "NordVPN - NordLynx private key";
        description = ''
          The name `nord setup` gives the Bitwarden item that receives a
          copy of the WireGuard key, as the record outside this machine.
          NetworkManager holds the working copy.
        '';
      };
    };
  };

  home = types.submodule {
    options = {
      apiUrl = mkOption {
        type = ravnix.url;
        example = "http://gateway.example.org:8080";
        description = ''
          The switch of the VPN gateway at home that `vpn-home on|off|status`
          calls, with its port and no trailing slash.
        '';
      };

      tokenItem = mkOption {
        type = types.nonEmptyStr;
        example = "VPN gateway - switch token";
        description = ''
          The Bitwarden item, by name or id (an id is the safer one: renaming
          the item never breaks it), that holds the switch's bearer token.
        '';
      };
    };
  };
in
{
  options.ravnix.printing = {
    printers = mkOption {
      type = types.attrsOf printer;
      default = { };
      example = lib.literalExpression ''
        {
          office = { uri = "ipp://printer.example.org/ipp/print"; };
        }
      '';
      description = ''
        Your printers, by the name of the CUPS queue (letters, digits, `.`,
        `_` and `-`). Each queue is created once the printer can be reached,
        which is when a network comes up with it on, so a laptop that is
        away from home neither fails nor retries.
      '';
    };

    defaultPrinter = mkOption {
      type = types.nullOr types.nonEmptyStr;
      default = null;
      example = "office";
      description = "The name of the printer that prints when none is chosen: one of `printers`, or null for CUPS's own choice.";
    };
  };

  options.ravnix.vpn = {
    netbird.managementUrl = mkOption {
      type = managementUrl;
      example = "https://netbird.example.org";
      description = ''
        The NetBird management server the client enrolls with and talks to.
        For NetBird's cloud that is `https://api.netbird.io:443`; the port
        defaults to 443 for https and 80 for http.
      '';
    };

    nord = mkOption {
      type = types.nullOr nord;
      default = null;
      description = "Your NordVPN account, for the `nord` command; null leaves the command out.";
    };

    home = mkOption {
      type = types.nullOr home;
      default = null;
      description = "The VPN gateway at home, for the `vpn-home` command; null leaves the command out.";
    };
  };
}
