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
  octet = "(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])";
  ipv4 = "${octet}[.]${octet}[.]${octet}[.]${octet}";
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

  # An SSH public key as one line of its .pub file: the type, the key, and
  # a comment if any, on one line. Nothing before the type, so a value
  # cannot carry options of its own (from=, command=) into an
  # authorized_keys line. A security key's types (sk-...) are keys too.
  sshPublicKey =
    types.strMatching "(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh[.]com|sk-ecdsa-sha2-nistp256@openssh[.]com) [A-Za-z0-9+/]+=*( [^\n]*)?"
    // {
      description = "SSH public key, one line of a .pub file";
    };

  # One machine's IPv4 or IPv6 address, as sshd compares it with where a
  # connection comes from. No name (a name is what the connecting side's DNS
  # says), no wildcard, no `!`, no list and no prefix length. The IPv6 half
  # checks only its characters and colons, so a malformed one such as `:::`
  # passes; sshd then matches it with nothing, and the rest of the from=
  # list still holds (OpenSSH 10.6, addr_match_list).
  ipAddress = types.strMatching "${ipv4}|${ipv6}" // {
    description = "IPv4 or IPv6 address, without a prefix length";
  };
}
