# The value types the option modules share, so one rule has one spelling.
# Not a module: each option file imports it with
#   ravnix = import ./types.nix { inherit lib; };
{ lib }:
let
  inherit (lib) types;

  # A DNS name, an ssh alias or an IPv4 address: no colon, and no leading
  # dash, which ssh and other tools would read as an option.
  name = "[A-Za-z0-9][A-Za-z0-9._-]*";
  # An IPv6 address: two colons at least.
  ipv6 = "[0-9A-Fa-f.]*:[0-9A-Fa-f.]*:[0-9A-Fa-f:.]*";
  user = "[A-Za-z0-9_][A-Za-z0-9_.-]*";
in
{
  # Where a host is reached: an IPv4 or IPv6 address or a DNS name, without
  # a scheme, a port or a prefix length (`ip` and `netbird status` print
  # one, `/16`; it does not belong here), because URLs and ssh targets are
  # built from it.
  address = types.strMatching "${name}|${ipv6}" // {
    description = "IP address or DNS name, without a port or prefix length";
  };

  # What ssh takes as its destination: `[user@]host`, where host is an
  # address or an ssh alias, or `ssh://[user@]host[:port]` when a port is
  # needed (an IPv6 address in brackets there). No spaces, so no options.
  sshTarget =
    types.strMatching "(${user}@)?(${name}|${ipv6})|ssh://(${user}@)?(${name}|[[]${ipv6}[]])(:[0-9]{1,5})?"
    // {
      description = "ssh destination, [user@]host or ssh://[user@]host[:port]";
    };

  mail = types.strMatching "[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+" // {
    description = "mail address";
  };

  url = types.strMatching "https?://[^[:space:]]+" // {
    description = "http or https URL";
  };

  # A path on the host as a string, for what tools read or write at runtime:
  # a Nix path would be copied into the store, read-only.
  absolutePath = types.strMatching "/.+" // {
    description = "absolute path, as a string";
  };
}
