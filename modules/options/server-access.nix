# How the laptop reaches the server, for the main terminal and the main
# connection (modules/glue/terminal.nix): an ssh key of its own, and the
# server's host key. The laptop's side of the key is a file on the laptop,
# the server's side its public half; neither is a secret that enters a
# flake. The address is the server's in NetBird (ravnix.server.netbirdAddress)
# and the account is yours, the same on both hosts. It is the mirror of
# ravnix.laptopAccess, which takes the other way.
{ lib, ... }:
let
  inherit (lib) mkOption types;

  # The private key's path, which goes into ssh_config in quotes, % written
  # as %%: so a space and a % are fine. Not a $, since ssh expands ${NAME} in
  # an IdentityFile and has no way to write it literally, and not a quote, a
  # backslash or a control character, which would end the value or the line,
  # and with it every ssh the user runs.
  keyPath = types.strMatching ''/[^"\\$[:cntrl:]]+'' // {
    description = ''absolute path, as a string, without $, ", \ or a control character'';
  };

  # One line of a .pub file. Not a security key's type (sk-ssh-ed25519@...):
  # the laptop connects again by itself after a drop, a suspend or a new
  # network, with nobody there to touch a key. Nothing may precede the type:
  # the server writes the options of the authorized_keys line itself.
  publicKey =
    types.strMatching "(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/]+=*( [^\n]*)?"
    // {
      description = "SSH public key, one line of a .pub file";
    };
in
{
  options.ravnix.serverAccess = {
    identityFile = mkOption {
      type = types.nullOr keyPath;
      default = null;
      example = "/home/alice/.ssh/ravnix-server";
      description = ''
        The private key the laptop logs in to the server with, for the main
        terminal and the main connection: a file on the laptop that only you
        can read, as an absolute path in a string (a Nix path would copy the
        key into the store). Make it with `ssh-keygen -t ed25519 -N "" -f
        <path>`: the laptop connects again by itself after every drop, with
        nobody there to type a passphrase. It is a key of its own, not the
        YubiKey's and not one Bitwarden's agent holds; with it set, the
        connection asks no agent. Null: ssh's own defaults, the agent of
        SSH_AUTH_SOCK (Bitwarden's) and ~/.ssh/id_*, which a reconnect after
        a suspend may find locked. A space or a % in the path is fine; a $,
        a double quote, a backslash or a control character is refused, since
        ssh_config could not hold it.
      '';
    };

    publicKey = mkOption {
      type = types.nullOr publicKey;
      default = null;
      example = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnlyNotARealKeyExampleOnlyNotARealKey ravnix-server@example.org";
      description = ''
        The public half of `identityFile` (the one line of its `.pub` file),
        which the server accepts for your account: for a shell, a command
        and the forwarding of sockets and ports, and not for an agent or a
        display. Null: the server adds no key for it, and your account
        takes the keys you give it in users.users.<name>.openssh.
      '';
    };

    hostKey = mkOption {
      type = types.nullOr publicKey;
      default = null;
      example = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnlyNotARealKeyExampleOnlyNotARealKey";
      description = ''
        The server's ssh host key, as the server's
        `/etc/ssh/ssh_host_ed25519_key.pub` has it. The laptop refuses any
        other.

        Null: the laptop checks the key against ~/.ssh/known_hosts, under
        the name `ravnix-server`, and reaches the server only once it is
        there. Until then the main key's window says "Host key verification
        failed" and the main connection forwards nothing, because the
        forwards hand the server your security key's agent; the laptop
        never takes the first key it is shown, and warns at every build
        while this is null. To put the key there once, by hand, run on the
        laptop

            ssh -o BatchMode=no -o StrictHostKeyChecking=ask ravnix-server true

        compare the fingerprint it shows with what
        `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` prints on the
        server, read on the server's own console and not over this
        connection, and answer yes only when they match. Then run
        `systemctl --user restart ravnix-connection`. Setting the key here
        does the same without that step, and on every laptop you build.
      '';
    };
  };
}
