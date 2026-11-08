# The server shape, muninn: how the laptop's main terminal reaches it, the
# repository Claude Code's Remote Control works from, and who may deploy to
# it as root.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  ravnix = import ./types.nix { inherit lib; };
in
{
  options.ravnix.server = {
    sshTarget = mkOption {
      type = ravnix.sshTarget;
      example = "alice@muninn.example.org";
      description = ''
        How huginn reaches muninn over ssh: `[user@]host` (host an address or
        an ssh alias) or `ssh://[user@]host[:port]`. The main terminal key
        opens herdr there.
      '';
    };

    remoteControlDir = mkOption {
      type = types.nullOr ravnix.absolutePath;
      default = null;
      example = "/home/alice/src/project";
      description = ''
        The git repository that Claude Code's Remote Control works from on
        muninn: each session you start from the phone gets a worktree of it.
        An absolute path in a string. Null leaves Remote Control off.
      '';
    };

    netbirdAddress = mkOption {
      type = ravnix.address;
      example = "198.51.100.20";
      description = ''
        muninn's address in your NetBird network, which reaches it from
        anywhere the laptop roams. The bare address, without the `/16` that
        `netbird status` prints after it.
      '';
    };

    deployKeys = mkOption {
      type = types.listOf ravnix.sshPublicKey;
      default = [ ];
      example = [ "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tExampleOnly deploy@laptop" ];
      description = ''
        The public keys that may log in to muninn as root over ssh, to
        deploy (`nixos-rebuild switch --target-host root@muninn`), each as
        one line of its .pub file, without options: ravnix puts
        `from=` (the addresses of deployFrom) and `restrict` in front of
        each. Keys of root's own, never one the account logs in or signs
        with, and never one an agent on muninn holds: a key on a security
        key made with its PIN (`ssh-keygen -t ed25519-sk -O
        verify-required`), which takes a touch and the PIN for each login,
        or a key that stays on the deploying machine. A security key's line
        gets `verify-required` too, so one made without the flag does not
        log in. Empty, root takes no key at all.
      '';
    };

    deployFrom = mkOption {
      type = types.listOf ravnix.ipAddress;
      default = [ ];
      example = [ "198.51.100.10" ];
      description = ''
        The addresses a deploy may come from, as muninn sees them: the
        deploying machine's address in your NetBird network, or on muninn's
        own network. Each a bare IPv4 or IPv6 address, no name and no
        network. A deploy key works from these addresses alone, so it is
        no good from muninn itself or through a hop over another host.
        Needed as soon as deployKeys holds a key.
      '';
    };

    proxmoxUpdate = mkOption {
      type = types.nullOr (
        types.submodule {
          options = {
            alias = mkOption {
              type = types.strMatching "[A-Za-z0-9][A-Za-z0-9._-]*";
              default = "proxmox-update";
              description = "The ssh alias on muninn, `ssh <alias>`, that runs the update.";
            };
            hostName = mkOption {
              type = ravnix.address;
              example = "192.0.2.40";
              description = "The Proxmox node the update runs on.";
            };
            user = mkOption {
              type = types.strMatching "[a-z_][a-z0-9_-]*";
              default = "root";
              description = "The node's user whose authorized_keys holds the key with its forced command.";
            };
            publicKey = mkOption {
              type = ravnix.sshPublicKey;
              example = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnly update@muninn";
              description = ''
                The public half of the dedicated key, one line of its .pub
                file. The private half is an SSH key item of your vault,
                which rbw's agent serves while it is unlocked.
              '';
            };
          };
        }
      );
      default = null;
      description = ''
        The one way from muninn to a Proxmox node: a dedicated key, which
        muninn's ssh offers to that node alone (`ssh <alias>`, and no other
        key of the agent). The node takes it only with a forced command,
        `command="<the update script>",restrict <key>` in that user's
        authorized_keys, so the key runs the script and nothing else. That
        line, and the script, are the node's: ravnix does not configure
        the node. Null: no such block.
      '';
    };
  };

  config.assertions = [
    {
      assertion = config.ravnix.server.deployKeys == [ ] || config.ravnix.server.deployFrom != [ ];
      message = "ravnix.server.deployKeys holds a key, but ravnix.server.deployFrom names no address to deploy from, so the key would open root from nowhere. Add the deploying machine's address to ravnix.server.deployFrom.";
    }
  ];
}
