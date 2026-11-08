# What the workbench makes of a user who has set only some of its values. The
# server shape is evaluated, never built, with the template's me.nix and one
# value changed at a time:
#
#   - no Nextcloud, no calendar, no Remote Control directory: the unit that
#     needs the value is not there, and the other units still are;
#   - no mail accounts, no Matrix account: the program is installed without
#     an account and nothing breaks;
#   - several mail accounts: exactly one is primary, and each has its own
#     password item;
#   - what the units are made of: herdr and Remote Control run through the
#     user's profile and are kept by a switch, the sync units hold the name of
#     a vault item and never a password, and the Nextcloud password goes to
#     the client in its environment and not on its command line.
{
  self,
  inputs,
  pkgs,
  lib,
  ...
}:
let
  me = import ../../templates/default/me.nix;
  user = me.ravnix.user.username;

  host =
    module:
    inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        self.nixosModules.server
        ../../templates/default/me.nix
        {
          # Just enough of a host for its configuration to evaluate.
          boot.loader.grub.enable = false;
          fileSystems."/" = {
            device = "none";
            fsType = "tmpfs";
          };
          system.stateVersion = "26.05";
          warnings = lib.mkForce [ ];
          ravnix.editor.languages = lib.mkForce [ "nix" ];
        }
        module
      ];
    };

  hmOf = h: h.config.home-manager.users.${user};
  unitsOf =
    h: lib.attrNames (hmOf h).systemd.user.services ++ lib.attrNames (hmOf h).systemd.user.timers;
  failed = h: map (a: a.message) (lib.filter (a: !a.assertion) h.config.assertions);
  mail = account: {
    address = "${account}@example.org";
    imap.host = "imap.example.org";
    smtp.host = "smtp.example.org";
    passwordItem = "Mail - ${account}";
  };

  everything = host { };
  noNextcloud = host { ravnix.nextcloud = lib.mkForce null; };
  noCalendar = host { ravnix.calendar = lib.mkForce null; };
  noRemoteControl = host { ravnix.server.remoteControlDir = lib.mkForce null; };
  noMail = host { ravnix.mail = lib.mkForce { }; };
  noMatrix = host { ravnix.matrix.userId = lib.mkForce null; };
  nothing = host {
    ravnix = {
      nextcloud = lib.mkForce null;
      calendar = lib.mkForce null;
      server.remoteControlDir = lib.mkForce null;
      mail = lib.mkForce { };
      matrix.userId = lib.mkForce null;
    };
  };
  twoPrimary = host {
    ravnix.mail = lib.mkForce {
      a = mail "a" // {
        primary = true;
      };
      b = mail "b" // {
        primary = true;
      };
    };
  };
  nonePrimary = host {
    ravnix.mail = lib.mkForce {
      a = mail "a";
      b = mail "b";
    };
  };
  oneOfTwo = host {
    ravnix.mail = lib.mkForce {
      a = mail "a";
      b = mail "b" // {
        primary = true;
      };
    };
  };
  # vdirsyncer takes only letters, digits and _ in the name of a pair or a
  # storage; a feed's name may have a dot and a dash as well.
  feed = url: { inherit url; };
  dottedFeed = host {
    ravnix.calendar.feeds = lib.mkForce {
      "class-2.0" = feed "http://calendar.example.org/class.ics";
    };
  };
  alikeFeeds = host {
    ravnix.calendar.feeds = lib.mkForce {
      "a-b" = feed "http://calendar.example.org/a.ics";
      "a.b" = feed "http://calendar.example.org/b.ics";
    };
  };
  # A feed x makes the storages feed_x_local and feed_x_remote, and a feed
  # x-local makes the pair feed_x_local: one name for two things.
  suffixFeeds = host {
    ravnix.calendar.feeds = lib.mkForce {
      "x" = feed "http://calendar.example.org/x.ics";
      "x-local" = feed "http://calendar.example.org/y.ics";
    };
  };
  alone = host { ravnix.mail = lib.mkForce { only = mail "only"; }; };
  badName = host { ravnix.mail = lib.mkForce { "two words" = mail "x"; }; };
  starttls = host {
    ravnix.mail = lib.mkForce {
      main = lib.recursiveUpdate (mail "main") {
        smtp.port = 587;
        smtp.starttls = true;
      };
    };
  };

  has = h: unit: lib.elem unit (unitsOf h);
  aercAccounts = h: (hmOf h).home.file."${(hmOf h).xdg.configHome}/aerc/accounts.conf".text;
  vdirsyncerConfig = h: (hmOf h).xdg.configFile."vdirsyncer/config".text;
  service = h: name: (hmOf h).systemd.user.services.${name};
  timer = h: name: (hmOf h).systemd.user.timers.${name};
  # A unit entry that may be given once or repeated: home-manager keeps the
  # repeated ones as a list.
  one = v: if lib.isList v then lib.head v else v;
  exec = h: name: one (service h name).Service.ExecStart;
  script = name: exec everything name;

  closure = pkgs.closureInfo {
    rootPaths = [ everything.config.ravnix.workbench.nextcloudSync.package ];
  };
  laptopOnly = [
    "sway"
    "waybar"
    "fuzzel"
    "dunst"
    "kanshi"
    "greetd"
    "helium"
    "obsidian"
    "ghostty"
  ];

  failures = lib.flatten [
    # Complete: every unit is there.
    (map (u: lib.optional (!has everything u) "the template's host lacks the unit ${u}") [
      "herdr-server"
      "nextcloud-sync"
      "vdirsyncer"
      "claude-remote-control"
    ])
    (lib.optional (
      failed everything != [ ]
    ) "the template's server host fails: ${toString (failed everything)}")

    # Each missing value takes away its own unit and no other.
    (lib.optional (has noNextcloud "nextcloud-sync") "nextcloud-sync exists without ravnix.nextcloud")
    (lib.optional (!has noNextcloud "vdirsyncer") "vdirsyncer is gone without ravnix.nextcloud")
    (lib.optional (has noCalendar "vdirsyncer") "vdirsyncer exists without ravnix.calendar")
    (lib.optional (
      !(hmOf noCalendar).programs.khal.enable
    ) "khal is not installed without ravnix.calendar")
    (lib.optional (
      (hmOf noCalendar).accounts.calendar.accounts != { }
    ) "khal has an account without ravnix.calendar")
    (lib.optional (has noRemoteControl "claude-remote-control") "Remote Control exists without a directory")
    (lib.optional (
      !has noRemoteControl "herdr-server"
    ) "herdr is gone without a Remote Control directory")
    (lib.optional (
      (hmOf noMail).accounts.email.accounts != { }
    ) "aerc has an account without ravnix.mail")
    (lib.optional (!(hmOf noMail).programs.aerc.enable) "aerc is not installed without ravnix.mail")
    (lib.optional (
      (hmOf noMatrix).programs.iamb.settings != { }
    ) "iamb has a profile without ravnix.matrix.userId")
    (lib.optional (
      !(hmOf noMatrix).programs.iamb.enable
    ) "iamb is not installed without ravnix.matrix.userId")
    (lib.optional (
      failed nothing != [ ]
    ) "a host with none of the optional values fails: ${toString (failed nothing)}")
    (lib.optional
      (
        # A bare server runs herdr's server, the glue's ravnix-link-deliver,
        # which delivers queued requests to the laptop from boot (Task 5.3),
        # and rbw's agent and its 12-hour lock (modules/common/rbw.nix): none
        # of them is an optional value's, and any other unit is one of theirs.
        lib.filter (
          u:
          !lib.elem u [
            "herdr-server"
            "ravnix-link-deliver"
            "rbw-agent"
            "rbw-relock"
          ]
        ) (unitsOf nothing) != [ ]
      )
      "a host with none of the optional values has units besides herdr, the link and rbw's: ${toString (unitsOf nothing)}"
    )

    # Mail accounts.
    (lib.optional (
      !lib.any (lib.hasInfix "exactly one needs primary") (failed twoPrimary)
    ) "two primary accounts are accepted")
    (lib.optional (
      !lib.any (lib.hasInfix "exactly one needs primary") (failed nonePrimary)
    ) "several accounts and none primary are accepted")
    (lib.optional (
      failed oneOfTwo != [ ]
    ) "one primary of two is refused: ${toString (failed oneOfTwo)}")
    (lib.optional (failed alone != [ ]) "a single account is refused: ${toString (failed alone)}")
    (lib.optional (
      !(hmOf alone).accounts.email.accounts.only.primary
    ) "the only account is not primary, which home-manager demands of one")
    (lib.optional (
      !lib.any (lib.hasInfix "two words") (failed badName)
    ) "an account name with a space is accepted")
    (lib.optional (
      !lib.all (lib.hasInfix "Mail - ") [ (aercAccounts oneOfTwo) ]
    ) "aerc does not read the passwords of the accounts from the vault")
    (lib.optional (
      !(
        lib.hasInfix "Mail - a" (aercAccounts oneOfTwo) && lib.hasInfix "Mail - b" (aercAccounts oneOfTwo)
      )
    ) "the accounts do not each name their own vault item")
    (lib.optional (
      !(
        lib.hasInfix "outgoing = smtp+plain://" (aercAccounts starttls)
        && lib.hasInfix ":587" (aercAccounts starttls)
      )
    ) "STARTTLS on 587 is not smtp://...:587 in aerc: ${aercAccounts starttls}")
    (lib.optional (
      !(lib.hasInfix "outgoing = smtps+plain://" (aercAccounts everything))
    ) "TLS from the start is not smtps:// in aerc: ${aercAccounts everything}")
    (lib.optional (
      !(lib.hasInfix "source = imaps://" (aercAccounts everything))
    ) "IMAP is not over TLS from the start in aerc")

    # The units.
    (lib.optional (
      (service everything "herdr-server").Unit.X-SwitchMethod != "keep-old"
    ) "a switch can restart herdr's server")
    (lib.optional (
      !lib.hasPrefix "/etc/profiles/per-user/${user}/bin/herdr " (exec everything "herdr-server")
    ) "herdr's server does not run through the user's profile")
    (lib.optional (
      !lib.hasPrefix "/etc/profiles/per-user/${user}/bin/claude " (
        exec everything "claude-remote-control"
      )
    ) "Remote Control does not run through the user's profile")
    (lib.optional (
      !(lib.elem "ANTHROPIC_API_KEY" (
        lib.toList (service everything "claude-remote-control").Service.UnsetEnvironment
      ))
    ) "Remote Control keeps ANTHROPIC_API_KEY")
    (lib.optional (
      !(lib.hasInfix "--spawn worktree" (exec everything "claude-remote-control"))
    ) "Remote Control does not spawn worktrees")
    (lib.optional (
      (service everything "claude-remote-control").Unit.ConditionPathExists != [
        "%h/.claude/.credentials.json"
        "${me.ravnix.server.remoteControlDir}/.git"
      ]
    ) "Remote Control starts without its login and its repository")
    # That Claude Code ran its first run is read from ~/.claude.json by an
    # ExecCondition= helper (a skip it makes is clean, and Restart=always
    # does not restart it), not from the file merely existing.
    (lib.optional (
      !(service everything "claude-remote-control").Service ? ExecCondition
    ) "Remote Control does not check that Claude Code finished its first run")
    (lib.optional (
      (service everything "nextcloud-sync").Unit.X-SwitchMethod != "keep-old"
    ) "a switch can start a Nextcloud sync")
    (lib.optional (
      (service everything "vdirsyncer").Unit.X-SwitchMethod != "keep-old"
    ) "a switch can start a calendar sync")
    # The schedule on a server. The VM test gives these timers a time they do
    # not reach, so this is where the real one is held.
    (lib.optional (
      (timer everything "nextcloud-sync").Timer.OnCalendar != "*:0/5"
    ) "the Nextcloud sync does not run every five minutes")
    (lib.optional (
      (timer everything "vdirsyncer").Timer.OnCalendar != "*:0/15"
    ) "the calendar sync does not run every quarter hour")
    (lib.concatMap
      (
        name:
        lib.optional (
          (timer everything name).Timer.OnBootSec != "2min"
          || (timer everything name).Timer.Persistent != true
        ) "the timer ${name} does not run two minutes after boot, or does not catch up a missed run"
      )
      [
        "nextcloud-sync"
        "vdirsyncer"
      ]
    )

    # The vdirsyncer configuration: the vault, never a password.
    (lib.optional (
      !lib.hasInfix "password.fetch = [\"command\"," (vdirsyncerConfig everything)
    ) "vdirsyncer does not fetch its password by command")
    (lib.optional (
      !lib.hasInfix "\"${me.ravnix.calendar.passwordItem}\"" (vdirsyncerConfig everything)
    ) "vdirsyncer does not name the vault item")
    (lib.optional (lib.hasInfix "password =" (vdirsyncerConfig everything)) "vdirsyncer has a literal password")
    (lib.optional (
      !lib.hasInfix "[pair feed_class]" (vdirsyncerConfig everything)
    ) "a feed has no pair")
    (lib.optional (
      !lib.hasInfix "collections = null" (vdirsyncerConfig everything)
    ) "a feed is discovered like an account")
    (lib.optional (
      !lib.hasInfix "[pair feed_class_2_0]" (vdirsyncerConfig dottedFeed)
    ) "a feed named class-2.0 has no pair that vdirsyncer accepts: ${vdirsyncerConfig dottedFeed}")
    (lib.optional (lib.any
      (l: lib.hasPrefix "[" l && builtins.match "\\[(general|(pair|storage) [A-Za-z0-9_]+)]" l == null)
      (lib.splitString "\n" (vdirsyncerConfig dottedFeed))
    ) "a section of vdirsyncer's config has a name with a character vdirsyncer refuses")
    (lib.optional (
      !lib.any (lib.hasInfix "the same name in vdirsyncer") (failed alikeFeeds)
    ) "two feeds that vdirsyncer would see under one name are accepted")
    (lib.optional (
      !lib.any (lib.hasInfix "feed_x_local") (failed suffixFeeds)
    ) "a feed x-local beside x, whose pair and storage share a name, is accepted")
    (lib.optional (
      failed dottedFeed != [ ]
    ) "a feed with a dot and a dash in its name is refused: ${toString (failed dottedFeed)}")
    (lib.optional (lib.hasInfix "contacts" (
      vdirsyncerConfig (host {
        ravnix.calendar.carddavUrl = lib.mkForce null;
      })
    )) "contacts are synced without a CardDAV URL")
    (lib.optional (
      !lib.hasInfix "contacts_remote" (vdirsyncerConfig everything)
    ) "contacts are not synced with a CardDAV URL")
  ];
in
pkgs.runCommand "workbench-optional" { } (''
  status=0
  fail() {
    echo "$*" >&2
    status=1
  }
  # What the sync scripts do with the password: they read it from the
  # vault into a variable and hand it over in the environment of the one
  # command. Never an argument, never a trace of the commands.
  nc=${script "nextcloud-sync"}
  grep -q 'NC_PASSWORD=\$password' "$nc" || fail "the Nextcloud password does not go in NC_PASSWORD"
  grep -q -e '--non-interactive' "$nc" || fail "nextcloudcmd is not run non-interactively"
  ! grep -q -E -e '--password|--apppassword|-p +"?\$password|://[^ ]*\$password' "$nc" ||
    fail "the Nextcloud password is an argument"
  ! grep -q -e 'set -x' -e 'xtrace' -e 'set -o verbose' "$nc" || fail "the Nextcloud sync traces its commands"
  ! grep -q -E 'export +(NC_)?PASSWORD' "$nc" || fail "the Nextcloud sync exports the password to every command"
  grep -q 'exit 75' "$nc" || fail "the Nextcloud sync does not stop on a locked vault"
  # Hidden files are part of the copy (the desktop client on the laptop syncs
  # them, and the vault holds .obsidian, .claude and .agents): -h on every
  # run of the client, with the exclusion of .git still given.
  [ "$(grep -c -F -e ' -h ' "$nc")" = ${toString (lib.length me.ravnix.nextcloud.folders)} ] ||
    fail "nextcloudcmd is not given -h for every folder, so hidden files stay out of the copy"
  [ "$(grep -c -F -e '--exclude-anchored' "$nc")" = ${toString (lib.length me.ravnix.nextcloud.folders)} ] ||
    fail "nextcloudcmd is not given the exclusion of .git for every folder"
  vs=${script "vdirsyncer"}
  grep -q 'exit 75' "$vs" || fail "the calendar sync does not stop on a locked vault"
  grep -q 'vdirsyncer discover' "$vs" || fail "the calendar sync does not discover"
  ! grep -q -e 'set -x' -e 'xtrace' "$vs" || fail "the calendar sync traces its commands"
  # A feed is a file on the web that needs no password: it is copied before
  # the vault is asked, so it does not wait for an unlock. The account's
  # pairs are named, so the feed is not synced a second time after the guard.
  at() { grep -n -F -e "$2" "$1" | head -n 1 | cut -d: -f1 || true; }
  guard=$(at "$vs" 'exit 75')
  feedMkdir=$(at "$vs" 'mkdir -p -- /home/')
  feedDiscover=$(at "$vs" 'vdirsyncer discover feed_class')
  feedSync=$(at "$vs" 'vdirsyncer sync feed_class')
  accountDiscover=$(at "$vs" 'vdirsyncer discover calendars')
  accountSync=$(at "$vs" 'vdirsyncer sync calendars')
  if [ -z "$guard" ] || [ -z "$feedMkdir" ] || [ -z "$feedDiscover" ] || [ -z "$feedSync" ] || [ -z "$accountDiscover" ] || [ -z "$accountSync" ]; then
    fail "the calendar sync lacks a step (guard '$guard', feed directory '$feedMkdir', feed discover '$feedDiscover', feed sync '$feedSync', account discover '$accountDiscover', account sync '$accountSync')"
  else
    [ "$feedMkdir" -lt "$feedDiscover" ] && [ "$feedDiscover" -lt "$feedSync" ] && [ "$feedSync" -lt "$guard" ] ||
      fail "the feed is not set up and copied, in that order, before the vault guard"
    [ "$guard" -lt "$accountDiscover" ] && [ "$accountDiscover" -lt "$accountSync" ] ||
      fail "the account is synced before the vault guard"
    # Making the feed's directory is inside the feed's failure guard: where
    # it fails, the feed is counted as failed and the account still syncs.
    [ "$(sed -n "$((feedMkdir - 1))p" "$vs")" = "if ! {" ] ||
      fail "the feed's directory is made outside the guard that keeps a feed from stopping the account sync"
  fi
  ! grep -q -E '^vdirsyncer (discover|metasync|sync)$' "$vs" ||
    fail "the calendar sync runs vdirsyncer for every pair, feeds again after the guard"
  # The helper that decides whether Remote Control may start: exit 0 only for
  # a ~/.claude.json that says Claude Code finished its first run and trusts
  # the working folder. Anything else is a skip, exit 1, never 255 (a
  # failure, which Restart=always retries every half minute). A file that
  # holds only mcpServers, as other parts of ravnix make it, proves nothing,
  # and neither does a first run without the folder: `claude remote-control`
  # refuses an untrusted folder, and the unit would be retried forever.
  ready=${one (service everything "claude-remote-control").Service.ExecCondition}
  grep -q 'hasCompletedOnboarding' "$ready" || fail "Remote Control does not look for hasCompletedOnboarding"
  grep -q 'hasTrustDialogAccepted' "$ready" || fail "Remote Control does not look for hasTrustDialogAccepted"
  home=$(mktemp -d)
  ready_case() {
    want=$1 content=$2 label=$3
    rm -f "$home/.claude.json"
    if [ "$content" != MISSING ]; then printf '%s' "$content" >"$home/.claude.json"; fi
    got=0
    HOME=$home "$ready" >/dev/null 2>&1 || got=$?
    [ "$got" = "$want" ] || fail "the Remote Control condition gives $got, not $want, for $label"
  }
  dir=${lib.escapeShellArg me.ravnix.server.remoteControlDir}
  trusted='{"hasTrustDialogAccepted":true}'
  ready_case 1 MISSING "no ~/.claude.json"
  ready_case 1 "" "an empty file"
  ready_case 1 '{}' "an empty object"
  ready_case 1 '{"mcpServers":{}}' "only an empty mcpServers"
  ready_case 1 '{"mcpServers":{"x":{"type":"http","url":"https://example.org/mcp"}},"numStartups":2}' "mcpServers and a startup count"
  ready_case 1 '{"hasCompletedOnboarding":false}' "onboarding not completed"
  ready_case 1 '{"hasCompletedOnboarding":"true"}' "onboarding as a string"
  ready_case 1 'not json' "a file that is not JSON"
  ready_case 1 '[]' "a JSON array"
  ready_case 1 '"hasCompletedOnboarding"' "a JSON string"
  # Onboarding done is not enough: the folder has to be trusted, as Claude
  # Code keys it, by the path of the repository.
  ready_case 1 '{"hasCompletedOnboarding":true}' "completed onboarding and no projects"
  ready_case 1 '{"hasCompletedOnboarding":true,"projects":{}}' "completed onboarding and an empty projects"
  ready_case 1 '{"hasCompletedOnboarding":true,"projects":{"/home/else/other":'"$trusted"'}}' "completed onboarding and another folder trusted"
  ready_case 1 '{"hasCompletedOnboarding":true,"projects":{"'"$dir"'":{"allowedTools":[]}}}' "completed onboarding and the folder known but not trusted"
  ready_case 1 '{"hasCompletedOnboarding":true,"projects":{"'"$dir"'":{"hasTrustDialogAccepted":false}}}' "completed onboarding and the folder explicitly not trusted"
  ready_case 1 '{"hasCompletedOnboarding":true,"projects":{"'"$dir"'":{"hasTrustDialogAccepted":"true"}}}' "trust as a string"
  ready_case 1 '{"hasCompletedOnboarding":true,"projects":"'"$dir"'"}' "projects that is no object"
  # Claude Code 2.1.319 honors a folder above the working one only up to the
  # git root, and the unit's directory is a git root (its .git is a
  # condition), so trust on a parent of it does not count.
  ready_case 1 '{"hasCompletedOnboarding":true,"projects":{"'"$(dirname "$dir")"'":'"$trusted"'}}' "completed onboarding and trust on a parent of the repository"
  ready_case 1 '{"projects":{"'"$dir"'":'"$trusted"'}}' "trust without onboarding"
  ready_case 0 '{"hasCompletedOnboarding":true,"projects":{"'"$dir"'":'"$trusted"'}}' "completed onboarding and the folder trusted"
  ready_case 0 '{"mcpServers":{},"hasCompletedOnboarding":true,"numStartups":9,"projects":{"/x":{},"'"$dir"'":{"allowedTools":[],"hasTrustDialogAccepted":true}}}' "completed onboarding and trust among other keys"
  rm -rf "$home"
  rc=${one (service everything "claude-remote-control").Service.ExecStartPre}
  grep -q 'remoteDialogSeen' "$rc" || fail "Remote Control does not answer its consent prompt"
  grep -q 'is not JSON' "$rc" || fail "Remote Control does not refuse a ~/.claude.json that is not JSON"
  # The Nextcloud client the module installs by default is a Qt program; it
  # brings Qt and some KDE libraries, and none of the laptop's programs.
  for name in $(sed 's|^/nix/store/[a-z0-9]*-||' ${closure}/store-paths); do
    case "$name" in
      ${lib.concatStringsSep "|" (map (n: "${n}-[0-9]*") laptopOnly)})
        fail "the Nextcloud client's closure holds $name" ;;
    esac
  done
  ${lib.optionalString (failures != [ ]) ''
    printf '%s\n' ${lib.escapeShellArgs failures} >&2
    status=1
  ''}
  [ "$status" = 0 ]
  touch "$out"
'')
