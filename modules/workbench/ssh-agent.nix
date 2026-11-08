# What the SSH agent means for the server. rbw's agent (modules/common/
# rbw.nix) runs here as on the laptop, because Claude Code runs here too,
# and it serves every SSH key of the vault to every process of the user
# while the vault is unlocked: the server's agents can log in wherever the
# vault's keys open. Two things follow, and this file holds them.
#
# The Proxmox nodes are reached through one key alone
# (ravnix.server.proxmoxUpdate): a dedicated key, which ssh offers to that
# node and to no other host, and no other key to that node
# (IdentitiesOnly, its public half as the one IdentityFile). The node takes
# it only with a forced command, `command="<update script>",restrict` in
# front of the key in its authorized_keys, so that whatever holds the key
# on the server runs the update script and nothing else: no shell, no
# forwarding, no terminal. That line and the script are the node's own,
# set up by hand there; ravnix configures muninn's side only.
#
# No key the agent serves opens the server's own root. A deploy key is
# root's (hosts/server/deploy.nix), limited by from= to the addresses of
# ravnix.server.deployFrom. The vault holds keys the configuration cannot
# see, so this file asserts what it can: deployFrom names none of the
# server's own addresses (its NetBird address, a loopback address), from
# which the agent's keys would come, and the Proxmox update key, which is
# in the vault, is no deploy key. Keep deploy keys out of the vault: on a
# security key, as the deploy login wants them, they are not in it.
{ config, lib, ... }:
let
  cfg = config.ravnix.server;
  user = config.ravnix.user.username;
  update = cfg.proxmoxUpdate;
  blob = line: lib.elemAt (lib.splitString " " line) 1;
  loopback = a: lib.hasPrefix "127." a || a == "::1" || lib.toLower a == "0:0:0:0:0:0:0:1";
  own = lib.filter (a: a == cfg.netbirdAddress || loopback a) cfg.deployFrom;
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
