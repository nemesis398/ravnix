# Claude Code, always current: the update timer on both hosts (the design's
# "Timer"), and after it the roll of the sessions on the server. The steps
# are claude-roll's (tools/claude-roll/update.odin, README.md "The update");
# this module wires them into units.
#
# At 06:00 and 18:00 (Persistent, so a host that was off or asleep runs it
# when it is back), root's ravnix-claude-update.service runs
# `claude-roll update`:
#
#   server  asks downloads.claude.ai for the latest version and stops when
#           the host runs it. Otherwise the user's
#           ravnix-claude-update-prepare.service fetches the private flake
#           over HTTPS and runs `nix flake update claude-code` on it; root
#           takes only the claude-code nodes of that lock into a copy of the
#           flake the host was deployed from, builds it, checks the download
#           with claude-code-verify against Anthropic's manifest, and
#           switches. The user's ravnix-claude-update-finish.service then
#           commits the lock, signed, onto the branch it fetched, pushes it
#           with the write token, and starts the roll: claude-roll.service
#           (the herdr panes) and claude-remote-control-roll.service
#           (Remote Control, restarted once it holds no phone session).
#   laptop  the user's prepare fetches the private flake with the read token;
#           if its lock moved the claude-code input, that is only the sign
#           to follow: root runs `nix flake update claude-code` itself, on a
#           copy of the flake the host was deployed from, and builds,
#           verifies and switches what that gives, the same way; finish says
#           so, and says when the server's lock named another revision. It
#           pushes nothing. While the user's side cannot run (the vault is
#           locked, or no user manager runs), the run ends with 75 and tells
#           nobody, and ravnix-claude-update-retry.timer starts it again
#           every hour until it gets through.
#
# Who does what, and why (decided for Task 6.1 from the spec and the modules
# already there):
#   - Root switches; the account never can (hosts/server/deploy.nix: no sudo
#     and no trusted Nix user, because every agent runs as the account). So
#     root must not build what the account wrote either: it builds the flake
#     the host was deployed from (ravnix.claudeUpdate.flake, the private
#     flake's own `self`, a store path), and of the new lock it takes the
#     claude-code nodes only, and only a new revision of the same repository
#     (another owner, URL, input or node shape is refused), and only a
#     version newer than the running one.
#   - That still leaves the revision. GitHub serves a commit of any fork
#     under the upstream's own URL, and claude-code-verify checks the
#     download the revision's own package names, which a fork can point at
#     Anthropic's genuine binary while it installs something else. So on
#     the server, whose account is the one that bumps, a compromised account
#     can still have root build and install such a revision. The accepted
#     cut: ravnix takes only the input's package, which runs as that same
#     account, so it gains nothing it did not have. The laptop's user is
#     another matter (and in wheel), so the laptop does not trust the
#     server's lock for the revision: root there asks the input's own
#     repository for the head of its branch, and the pushed lock only says
#     when to.
#   - The tokens and the signing key are the user's, from the user's vault
#     through rbw (modules/common/tokens.nix, modules/common/rbw.nix): the
#     prepare and finish steps run as user units, where git finds the token
#     helper and rbw's SSH agent, and root never reads the vault.
#   - The private flake is fetched into a bare repository of the update's own
#     ($XDG_STATE_HOME/ravnix/claude-update/flake.git), and the commit is
#     made there without a working tree: no checkout of the user's is
#     touched, and none can be dirty.
#   - The ravnix the host runs (this flake's own source) is passed to the
#     build with --override-input, so a host deployed against a local
#     checkout of ravnix keeps it, instead of falling back to the ravnix
#     revision in the private lock.
#   - The switch is root's own unit's: restartIfChanged is off, as for
#     system.autoUpgrade, so the switch it runs does not stop it.
#   - The OCI container form updates by image swap only, so the timer is
#     off where boot.isContainer is set.
#
# What the private flake sets, in each host's modules:
#
#   { ravnix.claudeUpdate = {
#       flake = self;                 # the private flake's own source
#       remote = "https://git.example.org/alice/private.git";
#     }; }
#
# and a token for that remote in ravnix.secrets.gitTokens: the write token
# on the server, a read-only one on the laptop. On the laptop a follow needs
# the user's manager to run (a login, or linger) and the vault to be
# unlocked: the token for the private remote comes from it. A run at 06:00,
# or the catch-up at boot before anyone logged in, finds neither; it waits
# quietly for the hourly retry, which runs only while
# /var/lib/ravnix-claude-update/pending says a follow waits.
{ self }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config.ravnix.claudeUpdate;
  user = config.ravnix.user.username;
  account = config.users.users.${user};
  home = config.home-manager.users.${user};
  server = config.ravnix.shape == "server";
  mode = if server then "bump" else "follow";
  tool = "${pkgs.ravnix.claude-roll}/bin/claude-roll";
  profile = "/etc/profiles/per-user/${user}/bin";
  userState = "${home.xdg.stateHome}/ravnix/claude-update";
  rootState = "/var/lib/ravnix-claude-update";
  rollUnits = [
    "claude-roll.service"
    "claude-remote-control-roll.service"
  ];
  tokenUrls = map (t: t.url) config.ravnix.secrets.gitTokens;

  # What the user's steps need on PATH: git with ssh-keygen for the
  # signature, Nix for the bump, systemctl to start the roll, rbw to ask
  # whether the vault is unlocked.
  userPath = lib.makeBinPath [
    pkgs.git
    pkgs.openssh
    config.nix.package
    pkgs.coreutils
    config.systemd.package
    home.programs.rbw.package
  ];
  userEnv = [
    "PATH=${userPath}:${profile}:/run/current-system/sw/bin"
  ];
  common = [
    "--mode"
    mode
    "--remote"
    cfg.remote
    "--branch"
    cfg.branch
    "--state"
    userState
    "--ravnix-notify"
    cfg.notify
  ];
in
{
  _file = ./claude-update.nix;
  key = "ravnix/modules/workbench/claude-update.nix";

  options.ravnix.claudeUpdate = {
    enable = mkOption {
      type = types.bool;
      default = cfg.flake != null && !config.boot.isContainer;
      defaultText = lib.literalExpression "config.ravnix.claudeUpdate.flake != null && !config.boot.isContainer";
      description = ''
        The twice-daily Claude Code update. On by itself once `flake` is
        set, except in a container, which updates by image swap only.
      '';
    };

    flake = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = lib.literalExpression "self";
      description = ''
        The private flake the host is deployed from, as a store path: set it
        to the private flake's own `self` in each host's modules. Root
        builds the update from this copy, never from a checkout the account
        can write.
      '';
    };

    host = mkOption {
      type = types.strMatching "[A-Za-z0-9_-]+";
      default = config.networking.hostName;
      defaultText = lib.literalExpression "config.networking.hostName";
      description = "The host's name under the private flake's nixosConfigurations.";
    };

    remote = mkOption {
      type = types.nullOr (
        types.strMatching "https://[a-z0-9.-]+(:[0-9]+)?/[^[:space:]@]*[^[:space:]@/]"
      );
      default = null;
      example = "https://git.example.org/alice/private.git";
      description = ''
        The private flake's HTTPS remote, exactly as in
        ravnix.secrets.gitTokens, whose token for it git uses: the write
        token on the server, which pushes the lock, a read-only one on the
        laptop, which fetches it.
      '';
    };

    branch = mkOption {
      type = types.strMatching "[A-Za-z0-9_./-]+";
      default = "main";
      description = "The private flake's branch the update fetches and pushes.";
    };

    input = mkOption {
      type = types.strMatching "[A-Za-z0-9_-]+";
      default = "claude-code";
      description = "The private flake's input that holds Claude Code, the only one the update moves.";
    };

    times = mkOption {
      type = types.listOf types.str;
      default = [
        "06:00"
        "18:00"
      ];
      description = ''
        When the timer runs (systemd calendar events). It is Persistent: a
        run missed while the host was off or asleep happens when it is back.
      '';
    };

    releases = mkOption {
      type = types.strMatching "https://[^[:space:]]+";
      default = "https://downloads.claude.ai/claude-code-releases";
      description = "Where Anthropic's releases are: `latest`, and each version's manifest.json.";
    };

    rollDeadline = mkOption {
      type = types.strMatching "([0-9]+h)?([0-9]+m)?([0-9]+s)?";
      default = "3h";
      description = ''
        How long the roll waits for a working session, and Remote Control
        for its phone sessions to end, before leaving them on the old
        version until the next update.
      '';
    };

    runningVersion = mkOption {
      type = types.str;
      default = home.programs.claude-code.package.version;
      defaultText = lib.literalExpression "the version of the user's programs.claude-code.package";
      internal = true;
      description = "The Claude Code version this system runs.";
    };

    overrideInputs = mkOption {
      type = types.attrsOf types.str;
      default = {
        ravnix = "${self}";
      };
      defaultText = lib.literalExpression ''{ ravnix = "''${self}"; }'';
      internal = true;
      description = ''
        Inputs of the private flake built as the running system was built:
        by default the ravnix it came from. An input the private flake does
        not have is left out.
      '';
    };

    notify = mkOption {
      type = types.str;
      default = "${pkgs.ravnix.ravnix-notify}/bin/ravnix-notify";
      defaultText = lib.literalExpression ''"''${pkgs.ravnix.ravnix-notify}/bin/ravnix-notify"'';
      internal = true;
      description = "The ravnix-notify the update's user steps tell the user with (a test puts a stand-in here).";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.flake != null;
        message = "ravnix.claudeUpdate.enable is set without ravnix.claudeUpdate.flake; set it to the private flake's `self`.";
      }
      {
        assertion = cfg.remote != null;
        message = "ravnix.claudeUpdate needs ravnix.claudeUpdate.remote, the private flake's HTTPS remote.";
      }
      {
        assertion = cfg.remote == null || lib.elem cfg.remote tokenUrls;
        message = "ravnix.claudeUpdate.remote ${toString cfg.remote} has no token in ravnix.secrets.gitTokens, so the update can neither fetch nor push it; add one (the write token on the server, a read-only one on the laptop).";
      }
      {
        assertion = config.ravnix.shape != null;
        message = "ravnix.claudeUpdate runs on a host with a shape (ravnix.shape): the server bumps, the laptop follows.";
      }
      {
        assertion = !config.boot.isContainer;
        message = "ravnix.claudeUpdate is on in a container, which updates by image swap only (hosts/server/oci.nix); turn it off.";
      }
    ];

    systemd.services.ravnix-claude-update = {
      description = "Claude Code update: bump or follow, build, verify, switch";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      # As system.autoUpgrade: the switch this unit runs must not stop it.
      restartIfChanged = false;
      unitConfig.X-StopOnRemoval = false;
      path = [
        config.nix.package
        pkgs.coreutils
        pkgs.curl
        pkgs.git
        pkgs.util-linux
        config.systemd.package
        pkgs.ravnix.claude-code-verify
      ];
      environment = config.nix.envVars // {
        HOME = "/root";
      };
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "ravnix-claude-update";
        StateDirectoryMode = "0755";
        ExecStart = lib.escapeShellArgs (
          [
            tool
            "update"
            "--mode"
            mode
            "--flake"
            "${cfg.flake}"
            "--host"
            cfg.host
            "--user"
            user
            "--group"
            account.group
            "--running"
            cfg.runningVersion
            "--candidate"
            "${userState}/candidate.lock"
            "--input"
            cfg.input
            "--releases"
            cfg.releases
            "--state"
            rootState
          ]
          ++ lib.concatLists (
            lib.mapAttrsToList (n: p: [
              "--override"
              "${n}=${p}"
            ]) cfg.overrideInputs
          )
        );
      };
    };

    systemd.timers.ravnix-claude-update = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = cfg.times;
        Persistent = true;
      };
    };

    # The laptop's follow, again, while it waits: claude-roll writes the
    # marker when a run ends with 75 (the vault locked, no user manager,
    # upstream or the manifest out of reach) and removes it when a run gets
    # through.
    systemd.services.ravnix-claude-update-retry = lib.mkIf (!server) {
      description = "Claude Code update: try the follow again while it waits";
      unitConfig.ConditionPathExists = "${rootState}/pending";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${config.systemd.package}/bin/systemctl start --no-block ravnix-claude-update.service";
      };
    };
    systemd.timers.ravnix-claude-update-retry = lib.mkIf (!server) {
      wantedBy = [ "timers.target" ];
      timerConfig.OnCalendar = "hourly";
    };

    home-manager.users.${user} = {
      systemd.user.services = {
        ravnix-claude-update-prepare = {
          Unit.Description = "Claude Code update, the user's side: fetch the private flake${lib.optionalString server " and bump its claude-code input"}";
          Service = {
            Type = "oneshot";
            Environment = userEnv;
            ExecStart = lib.escapeShellArgs (
              [
                tool
                "update-prepare"
                "--input"
                cfg.input
                "--host"
                cfg.host
              ]
              ++ common
            );
          };
        };
        ravnix-claude-update-finish = {
          Unit.Description = "Claude Code update, the user's side: ${lib.optionalString server "commit and push the lock, roll the sessions, and "}tell the user";
          Service = {
            Type = "oneshot";
            Environment = userEnv;
            ExecStart = lib.escapeShellArgs (
              [
                tool
                "update-finish"
                "--result"
                "${rootState}/result.json"
              ]
              ++ common
              ++ lib.optionals server (
                lib.concatMap (u: [
                  "--roll-unit"
                  u
                ]) rollUnits
              )
            );
          };
        };
      }
      // lib.optionalAttrs server {
        # The roll: the herdr panes onto the installed Claude Code. It reads
        # the hooks' records in the same state directory the hooks write.
        claude-roll = {
          Unit.Description = "Roll the Claude Code sessions in herdr's panes onto the installed version";
          Service = {
            Type = "oneshot";
            Environment = userEnv;
            TimeoutStartSec = "infinity";
            ExecStart = lib.escapeShellArgs [
              tool
              "--deadline"
              cfg.rollDeadline
              "--state"
              "${home.xdg.stateHome}/ravnix"
              "--herdr"
              "${profile}/herdr"
              "--ravnix-notify"
              cfg.notify
            ];
          };
        };
        # Remote Control is no herdr pane: restarted on its own, once it
        # holds no session from the phone (tools/claude-roll/README.md).
        claude-remote-control-roll = {
          Unit.Description = "Restart Claude Code's Remote Control onto the installed version once no session is open";
          Service = {
            Type = "oneshot";
            Environment = userEnv;
            TimeoutStartSec = "infinity";
            ExecStart = lib.escapeShellArgs [
              tool
              "remote-control"
              "--deadline"
              cfg.rollDeadline
              "--ravnix-notify"
              cfg.notify
            ];
          };
        };
      };
    };
  };
}
