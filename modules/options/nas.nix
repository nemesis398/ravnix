# The NAS's SMB shares on the laptop, mounted on demand
# (modules/desktop/nas.nix): the server, the accounts and the Bitwarden items
# that hold their passwords, the shares and where each is mounted, and the
# links to them in the home. ravnix sets none of them, and none has a default
# that could pass for a real value; templates/default/me.nix lists them.
#
# A password is only ever named here, by its Bitwarden item; it reaches the
# credentials file at runtime, from the vault, and never the Nix store.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  ravnix = import ./types.nix { inherit lib; };
  cfg = config.ravnix.nas;

  account = types.submodule (
    { config, ... }:
    {
      options = {
        username = mkOption {
          # One line of the credentials file, so no newline, and no comma,
          # space or `=`, which no SMB account name needs.
          type = types.strMatching "[A-Za-z0-9_][A-Za-z0-9_.@-]*" // {
            description = "SMB user name (letters, digits, `_`, `.`, `@` and `-`)";
          };
          example = "alice";
          description = "The account's user on the NAS, as the credentials file names it.";
        };
        item = mkOption {
          type = types.strMatching "[^\n]+";
          example = "NAS - alice";
          description = "The name or id of the Bitwarden item whose password is the account's.";
        };
        itemUser = mkOption {
          type = types.nullOr (types.strMatching "[^\n]+");
          default = config.username;
          defaultText = lib.literalExpression "username";
          example = null;
          description = ''
            rbw's second argument to `rbw get`, the user of the item, which
            picks one of several items of the same name. The account's
            username by default; null asks by the item alone.
          '';
        };
      };
    }
  );

  share = types.submodule {
    options = {
      share = mkOption {
        type = types.strMatching "[A-Za-z0-9_$][A-Za-z0-9_.$-]*" // {
          description = "SMB share name (letters, digits, `_`, `.`, `$` and `-`)";
        };
        example = "media";
        description = "The share's name on the server, as `//SERVER/SHARE` names it.";
      };
      account = mkOption {
        type = types.str;
        example = "alice";
        description = "The name of the account in ravnix.nas.accounts the share is mounted as.";
      };
      mountPoint = mkOption {
        # An fstab field: no space, comma or anything else to escape.
        type = types.strMatching "(/[A-Za-z0-9_][A-Za-z0-9_.@-]*)+" // {
          description = "absolute path without a trailing slash (letters, digits, `_`, `.`, `@` and `-`)";
        };
        example = "/mnt/nas/media";
        description = "Where the share is mounted.";
      };
      readOnly = mkOption {
        type = types.bool;
        default = false;
        description = "Mount the share read-only (`ro`), whatever the account may do on the server.";
      };
    };
  };

  shares = if cfg == null then [ ] else cfg.shares;
  points = map (s: s.mountPoint) shares;
  twice = lib.unique (lib.filter (p: lib.count (x: x == p) points > 1) points);
  unknown = lib.filter (s: !(cfg.accounts ? ${s.account})) shares;
  # An account's name is part of a unit's and a file's name.
  badNames = lib.filter (n: builtins.match "[a-z0-9][a-z0-9-]*" n == null) (
    if cfg == null then [ ] else lib.attrNames cfg.accounts
  );
in
{
  options.ravnix.nas = mkOption {
    type = types.nullOr (
      types.submodule {
        options = {
          server = mkOption {
            type = ravnix.address;
            example = "nas.example.org";
            description = ''
              The NAS, by its address or name, as `//SERVER/SHARE` names it:
              where it serves SMB, which may be another interface than the
              address of the NAS in ravnix.hosts, where its services are
              reached, so it is not taken from there.
            '';
          };
          accounts = mkOption {
            type = types.attrsOf account;
            default = { };
            example = {
              alice = {
                username = "alice";
                item = "NAS - alice";
              };
            };
            description = ''
              The NAS's accounts the shares are mounted as, by a name of your
              choice (lowercase letters, digits and `-`). Each account has one
              credentials file, /run/ravnix/nas/NAME.cred, root's and mode
              600, which a unit writes from your vault when a share of it is
              mounted. The file has no domain line: an account of a
              standalone NAS needs none, and one of an Active Directory
              domain cannot be given yet.
            '';
          };
          shares = mkOption {
            type = types.listOf share;
            default = [ ];
            example = [
              {
                share = "media";
                account = "alice";
                mountPoint = "/mnt/nas/media";
              }
            ];
            description = "The shares, each mounted on first access and unmounted after 10 idle minutes.";
          };
          links = mkOption {
            type = types.attrsOf ravnix.absolutePath;
            default = { };
            example = {
              NAS = "/mnt/nas";
            };
            description = ''
              Links in the home, by their path below it, each to a directory
              of the mounts: `NAS = "/mnt/nas"` is ~/NAS.
            '';
          };
        };
      }
    );
    default = null;
    description = ''
      The NAS's SMB shares, mounted on demand on the laptop
      (modules/desktop/nas.nix); null mounts none.
    '';
  };

  config.assertions = [
    {
      assertion = twice == [ ];
      message = "ravnix.nas.shares mounts more than one share on ${toString twice}.";
    }
    {
      assertion = unknown == [ ];
      message = "ravnix.nas.shares names the account ${
        toString (lib.unique (map (s: s.account) unknown))
      }, which ravnix.nas.accounts does not have.";
    }
    {
      assertion = badNames == [ ];
      message = "ravnix.nas.accounts has the name ${toString badNames}, which is not lowercase letters, digits and `-`: it is part of a unit's name.";
    }
    {
      assertion =
        cfg == null
        || lib.all (n: builtins.match "[A-Za-z0-9_][A-Za-z0-9_.-]*(/[A-Za-z0-9_][A-Za-z0-9_.-]*)*" n != null) (
          lib.attrNames cfg.links
        );
      message = "ravnix.nas.links has a name that is not a relative path inside the home (letters, digits, `_`, `.` and `-`, no part starting with `.`).";
    }
  ];
}
