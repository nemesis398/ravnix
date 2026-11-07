# The user: who they are, as git, the account and the forges see them, and
# where their own checkout of ravnix lives.
{ lib, ... }:
let
  inherit (lib) mkOption types;
  ravnix = import ./types.nix { inherit lib; };
in
{
  options.ravnix.user = {
    name = mkOption {
      type = types.nonEmptyStr;
      example = "Alice Example";
      description = "Your full name, as git commits and the account's full name show it.";
    };

    email = mkOption {
      type = ravnix.mail;
      example = "alice@example.org";
      description = "Your mail address, as git commits show it.";
    };

    username = mkOption {
      # What useradd accepts, without the trailing $ of machine accounts.
      type = types.strMatching "[a-z_][a-z0-9_-]{0,31}";
      example = "alice";
      description = "The login name of your account, the same on both hosts.";
    };

    githubUser = mkOption {
      type = types.strMatching "[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?";
      example = "alice-example";
      description = "Your GitHub account name, for gh and the forge settings.";
    };

    signingKey = mkOption {
      type = types.strMatching "(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh[.]com|sk-ecdsa-sha2-nistp256@openssh[.]com) [A-Za-z0-9+/]+=*( [^\n]*)?";
      example = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleOnly alice@example.org";
      description = ''
        The SSH public key your commits are signed with, as one line of a
        `.pub` file. Without git's `key::` prefix, which ravnix adds where git
        needs it. The private half stays in your Bitwarden agent.
      '';
    };
  };

  options.ravnix.dev = {
    checkout = mkOption {
      type = types.nullOr ravnix.absolutePath;
      default = null;
      example = "/home/alice/src/ravnix";
      description = ''
        Your checkout of ravnix, if you work on it, as an absolute path in a
        string (a Nix path would copy the checkout into the store). Its git
        hooks get turned on there. Null when you do not work on ravnix.
      '';
    };

    denyList = mkOption {
      type = types.nullOr ravnix.absolutePath;
      default = null;
      example = "/home/alice/src/ravnix-private/deny-list.txt";
      description = ''
        The deny list the hooks of that checkout read: your personal values,
        one per line, which must never appear in ravnix. An absolute path in
        a string; the list stays in your private flake.
      '';
    };
  };
}
