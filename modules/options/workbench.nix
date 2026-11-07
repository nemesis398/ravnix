# What the server's terminal programs need to know about you: your Nextcloud,
# your mail accounts and your calendar. Each is unset (null, or no account)
# until you set it, and the program that needs it is then installed without
# an account. Where a
# value is a password, the option holds only the name of the Bitwarden item
# that has it; rbw reads the password at the moment it is needed, and it is
# in neither flake nor store.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  ravnix = import ./types.nix { inherit lib; };

  item =
    what:
    mkOption {
      type = types.nonEmptyStr;
      example = "Nextcloud - app password";
      description = ''
        The name of the Bitwarden item whose password is ${what}. Only the
        name is here; rbw reads the password when it is needed, so the
        unit that needs it fails, and says so, while the vault is locked.
      '';
    };

  # A directory of the Nextcloud account: `/`, or a path that starts with `/`,
  # has no trailing `/`, and no `.` or `..` component.
  remoteFolder = types.strMatching "/|(/[^/[:cntrl:]]+)+" // {
    description = "folder of the Nextcloud account, `/` for all of it, otherwise `/name/name` without a trailing slash";
  };
  badComponent = f: lib.any (c: c == "." || c == "..") (lib.splitString "/" f);

  feed = types.submodule {
    options = {
      url = mkOption {
        type = ravnix.url;
        example = "https://calendar.example.org/class.ics";
        description = "The calendar feed, an iCalendar file that vdirsyncer reads over http or https.";
      };

      color = mkOption {
        type = types.nullOr types.nonEmptyStr;
        default = null;
        example = "light magenta";
        description = "The color khal draws the feed's events in, one of its color names such as `light magenta`; null keeps khal's own.";
      };
    };
  };
in
{
  options.ravnix = {
    nextcloud = mkOption {
      default = null;
      description = ''
        Your Nextcloud, whose files muninn keeps a copy of. The sync runs
        without a window (`nextcloudcmd`), every few minutes, as your user.
        Null: no sync is set up.
      '';
      type = types.nullOr (
        types.submodule {
          options = {
            url = mkOption {
              type = ravnix.url;
              example = "https://cloud.example.org";
              description = "The address of the Nextcloud: the base URL only, without `/remote.php` or `/dav`.";
            };

            user = mkOption {
              type = types.nonEmptyStr;
              example = "alice";
              description = "The login name of the Nextcloud account.";
            };

            passwordItem = item "an app password of that account (Settings, Security, Create new app password)";

            folders = mkOption {
              type = types.nonEmptyListOf remoteFolder;
              example = [
                "/Documents"
                "/Notes"
              ];
              description = ''
                The folders to keep a copy of, as paths in the account. Each
                is copied to the same path under `localRoot`. `/` is the
                whole account.
              '';
            };

            localRoot = mkOption {
              type = types.nullOr ravnix.absolutePath;
              default = null;
              example = "/home/alice/Nextcloud";
              description = "Where the copies live, as an absolute path in a string; null is `Nextcloud` in your home directory.";
            };
          };
        }
      );
    };

    mail = mkOption {
      default = { };
      description = ''
        Your mail accounts, read and written in aerc, by a name of your choice
        (letters, digits, `_` and `-`). Each server must speak IMAP with TLS
        from the start (port 993 unless you say otherwise) and SMTP either with
        TLS from the start (465) or with STARTTLS (587). Several accounts that
        share a server are several entries. With none, aerc is installed
        without an account.
      '';
      type = types.attrsOf (
        types.submodule {
          options = {
            address = mkOption {
              type = ravnix.mail;
              example = "alice@example.org";
              description = "The address mail is sent from.";
            };

            primary = mkOption {
              type = types.bool;
              default = false;
              description = "Whether this is the account aerc opens first. One account is primary; with a single account it is that one.";
            };

            login = mkOption {
              type = types.nullOr types.nonEmptyStr;
              default = null;
              example = "alice";
              description = "The login name of the mail servers; null is the address.";
            };

            imap = {
              host = mkOption {
                type = ravnix.address;
                example = "imap.example.org";
                description = "The IMAP server.";
              };
              port = mkOption {
                type = types.ints.between 1 65535;
                default = 993;
                description = "Its port, with TLS from the start.";
              };
            };

            smtp = {
              host = mkOption {
                type = ravnix.address;
                example = "smtp.example.org";
                description = "The SMTP server.";
              };
              port = mkOption {
                type = types.ints.between 1 65535;
                default = 465;
                description = "Its port.";
              };
              starttls = mkOption {
                type = types.bool;
                default = false;
                description = "Whether the connection starts in the clear and is upgraded with STARTTLS (port 587), instead of TLS from the start (port 465).";
              };
            };

            passwordItem = item "the password (or app password) of the mail account";
          };
        }
      );
    };

    calendar = mkOption {
      default = null;
      description = ''
        Your calendar and contacts, kept in a local copy by vdirsyncer and
        read in khal. Null: khal and vdirsyncer are installed without an
        account.
      '';
      type = types.nullOr (
        types.submodule {
          options = {
            caldavUrl = mkOption {
              type = ravnix.url;
              example = "https://cloud.example.org/remote.php/dav/";
              description = "The CalDAV server, or its root: vdirsyncer finds every calendar of the account under it. For Nextcloud it is `<url>/remote.php/dav/`.";
            };

            carddavUrl = mkOption {
              type = types.nullOr ravnix.url;
              default = null;
              example = "https://cloud.example.org/remote.php/dav/";
              description = "The CardDAV server, the same way; null keeps no contacts.";
            };

            user = mkOption {
              type = types.nonEmptyStr;
              example = "alice";
              description = "The login name of the account.";
            };

            passwordItem = item "an app password of that account";

            defaultCalendar = mkOption {
              type = types.nullOr types.nonEmptyStr;
              default = null;
              example = "personal";
              description = "The calendar khal puts a new event in, by its name on the server; null leaves it to khal.";
            };

            feeds = mkOption {
              type = types.attrsOf feed;
              default = { };
              example = {
                class = {
                  url = "https://calendar.example.org/class.ics";
                  color = "light magenta";
                };
              };
              description = ''
                Calendars that are published as a file and that you only read,
                by a name of your choice (letters, digits, `.`, `_` and `-`).
                khal shows them, and vdirsyncer never writes to them or to
                their server.
              '';
            };
          };
        }
      );
    };
  };

  # A name becomes a directory and a section of khal's configuration.
  config.assertions =
    lib.optionals (config.ravnix.nextcloud != null) [
      {
        # nextcloudcmd refuses a URL with these in it, and says so only when
        # it runs.
        assertion =
          let
            url = lib.toLower config.ravnix.nextcloud.url;
          in
          !(lib.hasInfix "/dav" url || lib.hasInfix "/webdav" url || lib.hasInfix "/remote.php" url);
        message = "ravnix.nextcloud.url is \"${config.ravnix.nextcloud.url}\", which has /dav, /webdav or /remote.php in it; give the base address of the Nextcloud only.";
      }
    ]
    ++ lib.optionals (config.ravnix.nextcloud != null) (
      map (f: {
        assertion = !badComponent f;
        message = "ravnix.nextcloud.folders has \"${f}\", which has a . or .. component; name the folder itself.";
      }) config.ravnix.nextcloud.folders
    )
    ++ map (name: {
      assertion = builtins.match "[A-Za-z0-9][A-Za-z0-9_-]*" name != null;
      message = "ravnix.mail has the account \"${name}\", which is not letters, digits, `_` and `-` (not starting with a symbol).";
    }) (lib.attrNames config.ravnix.mail)
    ++ lib.optional (config.ravnix.mail != { }) {
      assertion =
        let
          primaries = lib.filter (a: a.primary) (lib.attrValues config.ravnix.mail);
        in
        if lib.length (lib.attrNames config.ravnix.mail) == 1 then
          lib.length primaries <= 1
        else
          lib.length primaries == 1;
      message = "ravnix.mail has several accounts, so exactly one needs primary = true (it is the account aerc opens first).";
    }
    ++ lib.optionals (config.ravnix.calendar != null) (
      map (name: {
        assertion = builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" name != null;
        message = "ravnix.calendar.feeds has the name \"${name}\", which is not letters, digits, `.`, `_` and `-` (not starting with a symbol).";
      }) (lib.attrNames config.ravnix.calendar.feeds)
    );
}
