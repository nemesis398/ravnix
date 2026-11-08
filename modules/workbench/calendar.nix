# The calendar on the server: vdirsyncer keeps a local copy of your calendars
# (and contacts), khal reads and edits it. This is Fedora's setup, with the
# password moved from a file to the vault.
#
#   - ravnix.calendar says where the account is. vdirsyncer finds every
#     calendar under the CalDAV URL and keeps each in a directory of
#     ~/.local/share/calendars (and the contacts of CardDAV in
#     ~/.local/share/contacts). The server wins a conflict.
#   - A feed (ravnix.calendar.feeds) is a calendar published as a file: it is
#     copied into ~/.local/share/calendars-readonly/<name>, outside the
#     directory above on purpose, because that one is written back to the
#     server and a feed would be uploaded as a second, writable calendar.
#   - The password is the vault item named by passwordItem, which vdirsyncer
#     asks rbw for on each run (`password.fetch`). It is in no file.
#
# The sync is a user unit that a timer starts every fifteen minutes, on the
# quarter hours, two minutes after boot, and once when the server was off at
# a quarter. Each run copies the feeds first, which need no password. Then it
# asks the vault and discovers, so a calendar made on the phone appears here
# by itself (`implicit = "create"` makes its directory without asking), syncs
# the colors and names, and then the events. With the vault locked the unit
# stops with a message and status 75 (./unlocked.nix) after the feeds, and the
# next run tries again. khal reads the account's calendars, so it works from
# the first run that found the vault unlocked; until then it reports that its
# default calendar does not exist.
#
# vdirsyncer takes only letters, digits and _ in the name of a pair or a
# storage, and a feed's name may have a dot and a dash as well (it is a
# directory and a khal calendar), so the pair is named with those spelled _.
# Two feeds that would end up under one name are refused by an assertion;
# that counts the pair and its two storages (feed_x_local, feed_x_remote), so
# a feed x-local beside a feed x is refused too.
#
# Style (docs/style.md, rule 9, an exception): khal draws with the terminal's
# 16 ANSI colors, which the terminal sets to Catppuccin Mocha; its dates and
# times are ISO unless the user sets programs.khal.locale.
{ config, lib, ... }:
let
  os = config;
  user = os.ravnix.user.username;
  calendar = os.ravnix.calendar;
  # A feed's name as vdirsyncer can have it in a section name, and the
  # sections the feed makes: its pair and the two storages of it.
  spelled = name: lib.replaceStrings [ "." "-" ] [ "_" "_" ] name;
  pairOf = name: "feed_${spelled name}";
  sectionsOf = name: [
    (pairOf name)
    "${pairOf name}_local"
    "${pairOf name}_remote"
  ];
  # The section names that two feeds would both make, with the feeds. In
  # vdirsyncer a pair and a storage cannot share a name either.
  clashes = lib.filterAttrs (_: names: lib.length names > 1) (
    lib.mapAttrs (_: lib.unique) (
      lib.zipAttrs (
        lib.concatMap (name: map (section: { ${section} = name; }) (sectionsOf name)) (
          lib.optionals (calendar != null) (lib.attrNames calendar.feeds)
        )
      )
    )
  );
in
{
  assertions = [
    {
      assertion = clashes == { };
      message = "ravnix.calendar.feeds has names that are the same name in vdirsyncer (it takes only letters, digits and _, so . and - count as _, and a feed makes feed_<name>, feed_<name>_local and feed_<name>_remote): ${
        lib.concatStringsSep "; " (
          lib.mapAttrsToList (
            section: names: "${lib.concatStringsSep " and " names} both make ${section}"
          ) clashes
        )
      }.";
    }
  ];

  home-manager.users.${user} =
    { config, pkgs, ... }:
    let
      rbw = lib.getExe' config.programs.rbw.package "rbw";
      data = config.xdg.dataHome;
      calendars = "${data}/calendars";
      readonly = "${data}/calendars-readonly";
      contacts = "${data}/contacts";

      # vdirsyncer reads its values as JSON.
      js = builtins.toJSON;
      section = kind: name: values: ''
        [${kind} ${name}]
        ${lib.concatStringsSep "\n" (lib.mapAttrsToList (k: v: "${k} = ${js v}") values)}
      '';

      remote = type: url: {
        inherit type url;
        username = calendar.user;
        # A dotted key of vdirsyncer's own format, not a table.
        "password.fetch" = [
          "command"
          rbw
          "get"
          "--"
          calendar.passwordItem
        ];
      };
      # a is the copy here and b the server, as on Fedora: "b wins".
      pair =
        name: extra:
        section "pair" name (
          {
            a = "${name}_local";
            b = "${name}_remote";
            conflict_resolution = "b wins";
          }
          // extra
        );
      storage = section "storage";
      both = [
        "from a"
        "from b"
      ];

      feedNames = lib.attrNames calendar.feeds;
      accountPairs = lib.concatStringsSep " " (
        [ "calendars" ] ++ lib.optional (calendar.carddavUrl != null) "contacts"
      );
      vdirsyncerConfig = lib.concatStringsSep "\n" (
        [
          ''
            [general]
            status_path = ${js "${data}/vdirsyncer/status/"}
          ''
          (pair "calendars" {
            collections = both;
            metadata = [
              "color"
              "displayname"
            ];
            implicit = "create";
          })
          (storage "calendars_local" {
            type = "filesystem";
            path = "${calendars}/";
            fileext = ".ics";
          })
          (storage "calendars_remote" (remote "caldav" calendar.caldavUrl))
        ]
        ++ lib.optionals (calendar.carddavUrl != null) [
          (pair "contacts" {
            collections = both;
            metadata = [ "displayname" ];
            implicit = "create";
          })
          (storage "contacts_local" {
            type = "filesystem";
            path = "${contacts}/";
            fileext = ".vcf";
          })
          (storage "contacts_remote" (remote "carddav" calendar.carddavUrl))
        ]
        ++ lib.concatMap (name: [
          (pair (pairOf name) { collections = null; })
          (storage "${pairOf name}_local" {
            type = "filesystem";
            path = "${readonly}/${name}/";
            fileext = ".ics";
          })
          (storage "${pairOf name}_remote" {
            type = "http";
            inherit (calendar.feeds.${name}) url;
          })
        ]) feedNames
      );

      sync = pkgs.writeShellApplication {
        name = "ravnix-calendar-sync";
        runtimeInputs = [ pkgs.vdirsyncer ];
        text = ''
          ${lib.optionalString (feedNames != [ ]) ''
            # A feed that cannot be fetched does not keep the account from
            # syncing; the unit fails at the end if one could not.
            feeds=0
            ${lib.concatMapStrings (name: ''
              if ! { vdirsyncer discover ${pairOf name} && vdirsyncer sync ${pairOf name}; }; then
                feeds=1
              fi
            '') feedNames}
          ''}
          ${import ./unlocked.nix {
            inherit rbw;
            what = "the calendar's password";
          }}
          vdirsyncer discover ${accountPairs}
          vdirsyncer metasync ${accountPairs}
          vdirsyncer sync ${accountPairs}
          ${lib.optionalString (feedNames != [ ]) ''exit "$feeds"''}
        '';
      };
    in
    {
      home.packages = [ pkgs.vdirsyncer ];

      programs.khal = {
        enable = true;
        locale = {
          dateformat = lib.mkDefault "%Y-%m-%d";
          timeformat = lib.mkDefault "%H:%M";
          datetimeformat = lib.mkDefault "%Y-%m-%d %H:%M";
          longdateformat = lib.mkDefault "%d %B %Y";
          longdatetimeformat = lib.mkDefault "%d %B %Y %H:%M";
          firstweekday = lib.mkDefault 0;
          weeknumbers = lib.mkDefault "right";
        };
        settings = {
          default = {
            highlight_event_days = true;
          }
          // lib.optionalAttrs (calendar != null && calendar.defaultCalendar != null) {
            default_calendar = calendar.defaultCalendar;
          };
          keybindings.save = "ctrl s";
        };
      };
    }
    // lib.optionalAttrs (calendar != null) {
      accounts.calendar = {
        basePath = calendars;
        accounts = {
          # Every calendar vdirsyncer finds is a directory of its own.
          main = {
            local = {
              type = "filesystem";
              path = calendars;
              fileExt = ".ics";
            };
            khal = {
              enable = true;
              type = "discover";
            };
          };
        }
        // lib.mapAttrs' (
          name: feed:
          lib.nameValuePair "feed-${name}" {
            local = {
              type = "filesystem";
              path = "${readonly}/${name}";
              fileExt = ".ics";
            };
            khal = {
              enable = true;
              readOnly = true;
              inherit (feed) color;
            };
          }
        ) calendar.feeds;
      };

      xdg.configFile."vdirsyncer/config".text = vdirsyncerConfig;

      systemd.user.services.vdirsyncer = {
        Unit = {
          Description = "vdirsyncer: copy the calendars and contacts of the account";
          # A switch must not start a sync by restarting the unit.
          X-SwitchMethod = "keep-old";
        };
        Service = {
          Type = "oneshot";
          ExecStart = lib.getExe sync;
        };
      };
      systemd.user.timers.vdirsyncer = {
        Unit.Description = "vdirsyncer: copy the calendars and contacts every quarter of an hour";
        Timer = {
          # On the quarter hours, not a monotonic interval: Persistent= only
          # works with a calendar time, and runs one sync at resume or boot
          # for a quarter that was missed.
          OnCalendar = "*:0/15";
          OnBootSec = "2min";
          Persistent = true;
        };
        Install.WantedBy = [ "timers.target" ];
      };
    };
}
