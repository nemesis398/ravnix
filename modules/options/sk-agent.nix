# The security key for git (modules/glue/sk-agent.nix): the key handles the
# laptop's own agent holds, and the git hosts that ssh on the server reaches
# with them, through that agent. A handle is the file `ssh-keygen -t
# ed25519-sk` writes: it holds no secret, only the reference the security
# key needs, so it is useless without the key itself, and every signature
# takes a touch on it. Nothing here is a secret; the handles stay files on
# the laptop, and only their paths and public halves are written here.
{ lib, ... }:
let
  inherit (lib) mkOption types;
  ravnix = import ./types.nix { inherit lib; };

  # One line of a .pub file. A security key's types are the ones meant here;
  # the others are accepted so that a test can stand a plain key in for one,
  # and the module warns about each (the server could use it without a
  # touch).
  publicKey =
    types.strMatching "(sk-ssh-ed25519@openssh[.]com|sk-ecdsa-sha2-nistp256@openssh[.]com|ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/]+=*( [^\n]*)?"
    // {
      description = "SSH public key, one line of a .pub file";
    };
in
{
  options.ravnix.skAgent = {
    socket = mkOption {
      type = types.str;
      default = "sk-agent.sock";
      readOnly = true;
      description = ''
        The agent's socket, as a name in `$XDG_RUNTIME_DIR`, the same on both
        hosts: on the laptop the agent listens on
        `$XDG_RUNTIME_DIR/sk-agent.sock` (mode 600), and the main connection
        forwards it to the server, where it is `$XDG_RUNTIME_DIR/sk-agent.sock`
        of the same user (an ssh `RemoteForward` of the server's path to the
        laptop's, which reads this value). The server's sshd replaces a socket
        that a dropped connection left behind (`StreamLocalBindUnlink`).
      '';
    };

    keys = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            handle = mkOption {
              type = ravnix.absolutePath;
              example = "/home/alice/.ssh/keys/github-sk";
              description = ''
                The key handle on the laptop, as an absolute path in a string
                (a Nix path would copy it into the store): the file without
                `.pub` that `ssh-keygen -t ed25519-sk` wrote. Without a
                passphrase, since the agent loads it with nobody to type one.
              '';
            };
            publicKey = mkOption {
              type = publicKey;
              example = "sk-ssh-ed25519@openssh.com AAAAGnNrLXNzaC1lZDI1NTE5QG9wZW5zc2guY29tExampleOnlyNotARealKey alice@example.org";
              description = ''
                The handle's public half, the one line of its `.pub` file. The
                laptop's agent loads the handle only if its public half is this
                one, and ssh on the server offers the git hosts this key and no
                other that the agent may hold.
              '';
            };
          };
        }
      );
      default = [ ];
      description = ''
        The security key's handles. The laptop runs an agent of their own on
        `ravnix.skAgent.socket`, apart from Bitwarden's and from any other,
        that holds these and nothing else. Empty: the laptop runs no such
        agent.
      '';
    };

    hosts = mkOption {
      type = types.listOf ravnix.address;
      default = [ ];
      example = [
        "github.com"
        "git.example.org"
      ];
      description = ''
        The git hosts that ssh on the server reaches with the security key,
        as git's remotes name them (`git@HOST:...`, `ssh://git@HOST:PORT/...`).
        For these, ssh uses the laptop's agent through the forwarded socket
        and no other agent, Bitwarden's included, and offers the keys of
        `ravnix.skAgent.keys` alone; while the laptop is not connected it
        stops at once with a message that says so. Empty: the server leaves
        ssh as it is.
      '';
    };
  };
}
