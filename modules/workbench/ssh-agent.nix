# What the SSH agent means for the server. rbw's agent (modules/common/
# rbw.nix) runs here as on the laptop, because Claude Code runs here too.
# It serves every SSH key item of the vault to every process of the user
# while the vault is unlocked, and `rbw get --field private_key` prints any
# of them: no filter of ravnix's can narrow that.
#
# A known gap, accepted (the maintainer, 2026-11-08): the vault holds the
# Proxmox nodes' root keys, so while it is unlocked every agent on the
# server can log in to a node as root, unrestricted, wherever the network
# lets the server reach it, and root on the hypervisor is root on the
# server's own disk. The same goes for every other host, guest and account
# a vault key opens, and for the vault's touch-free keys for the git
# hosts: Task 5.4 keeps the listed git host names on the security key, but
# what gets past its blocks (an alias with that HostName, a trailing dot,
# an address, -o IdentityAgent=) reaches those keys here. Closing it would
# take a vault account for the server with fewer items, or a from= on each
# node's root keys that leaves out the server's addresses.
#
# The dedicated Proxmox update key (ravnix.server.proxmoxUpdate) is
# therefore no boundary on its own; it is the way the server's tools are
# meant to reach a node. ssh offers it to that node alone (IdentitiesOnly,
# its public half as the one IdentityFile), and the node takes it only
# with a forced command, `command="<update script>",restrict` in front of
# the key in its authorized_keys, so that key runs the script and nothing
# else. That line and the script are the node's own, set up by hand there;
# ravnix configures the server's side only.
#
# Every other host gets all of the agent's keys offered, in turn: a host
# whose key comes late refuses with "Too many authentication failures"
# (sshd's MaxAuthTries), and every server the server connects to sees every
# public key. Give such a host a block with IdentitiesOnly and its key's
# public half, as the private flake does for its aliases.
#
# The deploy login (hosts/server/deploy.nix): a deploy key is root's,
# limited by from= to ravnix.server.deployFrom, and on a security key,
# which rbw's agent cannot serve (it signs with Ed25519 and RSA keys only).
# This file asserts what the configuration shows: deployFrom names none of
# the server's own addresses, its NetBird address or a loopback address in
# any spelling (the IPv4-compatible and IPv4-mapped ones too), from which
# the agent's keys would come, and the Proxmox update key, which is in the
# vault, is no deploy key. It cannot see the
# server's LAN address, which no ravnix option holds: keep it out of
# deployFrom too.
{ config, lib, ... }:
let
  cfg = config.ravnix.server;
  user = config.ravnix.user.username;
  update = cfg.proxmoxUpdate;
  blob = line: lib.elemAt (lib.splitString " " line) 1;
  # A loopback address in any spelling sshd's from= would match: 127.0.0.0/8
  # and ::1, with or without zeros (0::1, 0:0:0:0:0:0:0:1, 0000:...:0001),
  # in the IPv4-compatible spelling (::0.0.0.1), and 127.0.0.0/8 mapped into
  # IPv6 (::ffff:127.0.0.1). Lowercased first.
  zeros = "(0{0,4}:){1,7}:?(0{0,4}:)*";
  loopback =
    a:
    let
      l = lib.toLower a;
    in
    lib.hasPrefix "127." l
    || builtins.match "${zeros}0{0,3}1" l != null
    || builtins.match "${zeros}0{1,3}[.]0{1,3}[.]0{1,3}[.]0{0,2}1" l != null
    || builtins.match "${zeros}ffff:127[.].*" l != null;
  # The NetBird address as itself or mapped into IPv6.
  netbird =
    a:
    let
      l = lib.toLower a;
      mapped = builtins.match "${zeros}ffff:(.*)" l;
    in
    l == lib.toLower cfg.netbirdAddress
    || (mapped != null && lib.last mapped == lib.toLower cfg.netbirdAddress);
  own = lib.filter (a: netbird a || loopback a) cfg.deployFrom;
in
{
  assertions = [
    {
      assertion = own == [ ];
      message = "ravnix.server.deployFrom names the server's own address (${toString own}). A deploy key would then open root from the server itself, where rbw's agent serves the vault's keys to every agent; deploy from the laptop's address only.";
    }
    {
      assertion = update == null || !lib.elem (blob update.publicKey) (map blob cfg.deployKeys);
      message = "ravnix.server.proxmoxUpdate's key is also in ravnix.server.deployKeys. The update key lives in the vault, whose keys rbw's agent serves on the server; a deploy key must not be one of them.";
    }
  ];

  home-manager.users.${user} = lib.mkIf (update != null) (
    { pkgs, ... }:
    {
      programs.ssh = {
        enable = true;
        enableDefaultConfig = lib.mkDefault false;
        matchBlocks.${update.alias} = {
          hostname = update.hostName;
          inherit (update) user;
          identitiesOnly = true;
          identityFile = [ "${pkgs.writeText "${update.alias}.pub" "${update.publicKey}\n"}" ];
          forwardAgent = false;
          extraOptions = {
            ClearAllForwardings = "yes";
            RequestTTY = "no";
            PermitLocalCommand = "no";
          };
        };
      };
    }
  );
}
