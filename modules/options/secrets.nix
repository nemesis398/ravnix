# Where the secrets come from. Secrets live in neither flake: rbw reads them
# from your Bitwarden at runtime. These options say only which server, which
# account, and which item goes where.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  ravnix = import ./types.nix { inherit lib; };
  tokens = config.ravnix.secrets.gitTokens;
  urls = map (t: t.url) tokens;
  twice = lib.unique (lib.filter (u: lib.count (x: x == u) urls > 1) urls);
in
{
  options.ravnix.secrets = {
    rbwBaseUrl = mkOption {
      type = ravnix.url;
      example = "https://vault.example.org";
      description = "The Bitwarden or Vaultwarden server rbw logs in to (`rbw config set base_url`).";
    };

    rbwEmail = mkOption {
      type = ravnix.mail;
      example = "alice@example.org";
      description = "The account rbw logs in as (`rbw config set email`).";
    };

    gitTokens = mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            url = mkOption {
              # https, a host (and port) without a user, and a path.
              type = types.strMatching "https://[A-Za-z0-9.-]+(:[0-9]+)?/[^[:space:]@]*[^[:space:]@/]" // {
                description = "https URL of a repository, without a user";
              };
              example = "https://git.example.org/alice/private.git";
              description = ''
                The remote, exactly as git is given it: the token goes to
                this URL alone, and not to another path on the same host.
              '';
            };
            username = mkOption {
              type = types.strMatching "[A-Za-z0-9_.-]+";
              example = "alice";
              description = "The forge's user the token belongs to: git sends the token as its password.";
            };
            item = mkOption {
              type = types.strMatching "[^\n]+";
              example = "Forge - API token (private, write)";
              description = "The name or id of the Bitwarden item whose password is the token.";
            };
          };
        }
      );
      default = [ ];
      example = [
        {
          url = "https://git.example.org/alice/private.git";
          username = "alice";
          item = "Forge - API token (private, write)";
        }
      ];
      description = ''
        HTTPS tokens for git, each for one remote: when git asks for that
        remote's credentials, a helper reads the item with rbw (only while
        the vault is unlocked; it never prompts) and hands git the user and
        the token, and no other helper of git's sees them. Per host: set it
        in the host's own module, so that only the host that pushes gets
        the write token.
      '';
    };
  };

  config.assertions = [
    {
      assertion = twice == [ ];
      message = "ravnix.secrets.gitTokens has more than one token for ${toString twice}; give each remote one.";
    }
  ];
}
