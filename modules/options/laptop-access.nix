# How the server reaches the laptop over NetBird, to run a command there
# (`ravnix-laptop`, modules/glue/laptop-access.nix): an ssh key of its own,
# and the laptop's host key. The server's side of the key is a file on the
# server and the laptop's side is its public half; neither is a secret that
# enters a flake. Every value is null until you set it, and the laptop and
# the server then do nothing about it.
{ lib, ... }:
let
  inherit (lib) mkOption types;
  ravnix = import ./types.nix { inherit lib; };

  # One line of a .pub file: an ssh-ed25519, ssh-rsa or ecdsa key and its
  # comment. A key that needs hardware (sk-ssh-ed25519@openssh.com) is not one:
  # this key is for a command that runs unattended, and it never touches the
  # YubiKey. Nothing may precede the type: the module writes the options of
  # the authorized_keys line itself (`restrict,from=...`), and an option such
  # as `command=` in front of the key would be a second set, or a way to run
  # something else.
  publicKey =
    types.strMatching "(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/]+=*( [^\n]*)?"
    // {
      description = "SSH public key, one line of a .pub file";
    };
in
{
  options.ravnix.laptopAccess = {
    identityFile = mkOption {
      type = types.nullOr ravnix.absolutePath;
      default = null;
      example = "/home/alice/.ssh/ravnix-laptop";
      description = ''
        The private key that `ravnix-laptop` logs in to the laptop with, a
        file on the server that only you can read, as an absolute path in a
        string (a Nix path would copy the key into the store). Make it with
        `ssh-keygen -t ed25519 -N "" -f <path>`: the command runs without
        anyone to type a passphrase, and it never asks for one. It is a key of
        its own, not the YubiKey's and not the one Bitwarden's agent holds for
        the git hosts; the command ignores every agent and every file in
        `~/.ssh/config`. Null: the server has no `ravnix-laptop`.
      '';
    };

    publicKey = mkOption {
      type = types.nullOr publicKey;
      default = null;
      example = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnlyNotARealKeyExampleOnlyNotARealKey ravnix-laptop@example.org";
      description = ''
        The public half of `identityFile` (the one line of its `.pub` file),
        which the laptop accepts for your account. It is accepted only from
        the server's NetBird address (`ravnix.server.netbirdAddress`), and
        only for commands: no forwarding of ports, agents or displays. Null:
        the laptop runs no sshd for it.
      '';
    };

    hostKey = mkOption {
      type = types.nullOr publicKey;
      default = null;
      example = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnlyNotARealKeyExampleOnlyNotARealKey";
      description = ''
        The laptop's ssh host key, as the laptop's
        `/etc/ssh/ssh_host_ed25519_key.pub` has it. `ravnix-laptop` refuses
        any other key. Null: it trusts the first key the laptop shows and
        remembers it (in `$XDG_STATE_HOME/ravnix-laptop/known_hosts`), then
        refuses a different one; set the key to avoid that first trust.
      '';
    };
  };
}
