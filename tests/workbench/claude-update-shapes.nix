# The Claude Code update's units as each shape makes them, evaluated and never
# built (tests/workbench/claude-update.nix runs them): the server bumps and
# rolls, the laptop follows, rolls nothing and retries hourly while a follow
# waits for the vault, a host without the private
# flake's source has no update, a container has none either, and a remote
# without a token, an update without a remote, and one in a container are
# refused by name.
{
  self,
  inputs,
  lib,
  pkgs,
  ...
}:
let
  me = import ../../templates/default/me.nix;
  user = me.ravnix.user.username;
  remote = "https://git.example.org/${user}/private.git";
  flake = "/nix/store/00000000000000000000000000000000-source";

  base = {
    boot.loader.grub.enable = false;
    fileSystems."/" = {
      device = "none";
      fsType = "tmpfs";
    };
    system.stateVersion = "26.05";
    warnings = lib.mkForce [ ];
    ravnix.editor.languages = lib.mkForce [ "nix" ];
  };
  token = {
    ravnix.secrets.gitTokens = lib.mkForce [
      {
        url = remote;
        username = user;
        item = "Forge - API token (private)";
      }
    ];
  };
  update = {
    ravnix.claudeUpdate = { inherit flake remote; };
  };

  server =
    modules:
    inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        self.nixosModules.server
        ../../templates/default/me.nix
        base
      ]
      ++ modules;
    };
  # The laptop's end, on the common module alone: the laptop shape imports
  # the same file.
  laptop =
    modules:
    inputs.nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        self.nixosModules.common
        (import ../../modules/workbench/claude-update.nix { inherit self; })
        ../../templates/default/me.nix
        base
        { ravnix.shape = "laptop"; }
      ]
      ++ modules;
    };

  failed = h: map (a: a.message) (lib.filter (a: !a.assertion) h.config.assertions);
  hm = h: h.config.home-manager.users.${user}.systemd.user.services;
  root = h: h.config.systemd.services.ravnix-claude-update;
  exec = h: (root h).serviceConfig.ExecStart;
  # home-manager keeps ExecStart as a list.
  userExec = h: name: lib.concatStringsSep "\n" (lib.toList (hm h).${name}.Service.ExecStart);

  muninn = server [
    token
    update
  ];
  huginn = laptop [
    token
    update
  ];
  noFlake = server [ token ];
  noToken = server [ update ];
  noRemote = server [
    token
    { ravnix.claudeUpdate.flake = flake; }
  ];
  container = server [
    token
    update
    { boot.isContainer = true; }
  ];
  containerForced = server [
    token
    update
    {
      boot.isContainer = true;
      ravnix.claudeUpdate.enable = true;
    }
  ];

  # The words name store paths; only their text is compared.
  has =
    s: word:
    lib.hasInfix (builtins.unsafeDiscardStringContext word) (builtins.unsafeDiscardStringContext s);
  checks = [
    [
      (failed muninn == [ ])
      "the server with its update fails: ${toString (failed muninn)}"
    ]
    [
      (has (exec muninn) "claude-roll update --mode bump --flake ${flake} --host nixos --user ${user}")
      "the server's update does not bump the deployed flake: ${exec muninn}"
    ]
    [
      (has (exec muninn) "--override 'ravnix=${self}'")
      "the server's update does not build with the ravnix it runs: ${exec muninn}"
    ]
    [
      (has (exec muninn) "--candidate /home/${user}/.local/state/ravnix/claude-update/candidate.lock")
      "root does not read the candidate where prepare leaves it: ${exec muninn}"
    ]
    [
      ((root muninn).restartIfChanged == false)
      "a switch would restart the update that runs it"
    ]
    [
      (
        muninn.config.systemd.timers.ravnix-claude-update.timerConfig == {
          OnCalendar = [
            "06:00"
            "18:00"
          ];
          Persistent = true;
        }
      )
      "the timer is not 06:00 and 18:00, Persistent"
    ]
    [
      (lib.all (u: (hm muninn) ? ${u}) [
        "ravnix-claude-update-prepare"
        "ravnix-claude-update-finish"
        "claude-roll"
        "claude-remote-control-roll"
      ])
      "the server lacks a user unit of the update: ${toString (lib.attrNames (hm muninn))}"
    ]
    [
      (has (userExec muninn "ravnix-claude-update-finish") "--roll-unit claude-roll.service --roll-unit claude-remote-control-roll.service")
      "the server's finish does not start the roll"
    ]
    [
      (has (userExec muninn "ravnix-claude-update-prepare") "--mode bump --remote ${remote} --branch main")
      "the server's prepare does not bump the remote: ${userExec muninn "ravnix-claude-update-prepare"}"
    ]
    [
      (has (userExec muninn "claude-roll") "--state /home/${user}/.local/state/ravnix --herdr /etc/profiles/per-user/${user}/bin/herdr")
      "the roll does not read the hooks' state or the profile's herdr: ${userExec muninn "claude-roll"}"
    ]
    [
      (failed huginn == [ ])
      "the laptop with its update fails: ${toString (failed huginn)}"
    ]
    [
      (has (exec huginn) "--mode follow")
      "the laptop does not follow: ${exec huginn}"
    ]
    [
      (!(hm huginn) ? claude-roll && !(hm huginn) ? claude-remote-control-roll)
      "the laptop rolls sessions it does not run"
    ]
    [
      (!has (userExec huginn "ravnix-claude-update-finish") "--roll-unit")
      "the laptop's finish starts a roll"
    ]
    [
      (
        huginn.config.systemd.timers ? ravnix-claude-update-retry
        && huginn.config.systemd.timers.ravnix-claude-update-retry.timerConfig.OnCalendar == "hourly"
      )
      "the laptop has no hourly retry for a follow that waits"
    ]
    [
      (
        (huginn.config.systemd.services.ravnix-claude-update-retry.unitConfig.ConditionPathExists or null)
        == "/var/lib/ravnix-claude-update/pending"
      )
      "the laptop's retry does not wait for the pending marker"
    ]
    [
      (has (huginn.config.systemd.services.ravnix-claude-update-retry.serviceConfig.ExecStart or ""
      ) "systemctl start --no-block ravnix-claude-update.service")
      "the laptop's retry does not start the update"
    ]
    [
      (
        !muninn.config.systemd.timers ? ravnix-claude-update-retry
        && !muninn.config.systemd.services ? ravnix-claude-update-retry
      )
      "the server has a retry, which only the laptop's follow needs"
    ]
    [
      (has (lib.concatStringsSep " " (hm huginn).ravnix-claude-update-prepare.Service.Environment) "-rbw-")
      "the laptop's prepare cannot ask rbw whether the vault is locked"
    ]
    [
      (
        !noFlake.config.systemd.services ? ravnix-claude-update
        && !(hm noFlake) ? ravnix-claude-update-prepare
      )
      "a host without the private flake's source has an update"
    ]
    [
      (lib.any (lib.hasInfix "has no token in ravnix.secrets.gitTokens") (failed noToken))
      "a remote without a token is taken"
    ]
    [
      (lib.any (lib.hasInfix "needs ravnix.claudeUpdate.remote") (failed noRemote))
      "an update without a remote is taken"
    ]
    [
      (!container.config.systemd.services ? ravnix-claude-update)
      "a container has the update"
    ]
    [
      (lib.any (lib.hasInfix "updates by image swap only") (failed containerForced))
      "an update forced on in a container is taken"
    ]
  ];
  failures = map (c: lib.elemAt c 1) (lib.filter (c: !(lib.elemAt c 0)) checks);
in
pkgs.runCommand "workbench-claude-update-shapes" { } ''
  ${lib.optionalString (failures != [ ]) ''
    printf '%s\n' ${lib.escapeShellArgs failures} >&2
    exit 1
  ''}
  touch $out
''
