# What modules/common/scripts.nix and modules/desktop/scripts.nix turn the
# options of ravnix.scripts into, on an evaluated host (no VM; the closure of
# the scripts themselves is the check common-scripts): the files the scripts
# read at run time, the session variables (evaluated, and as the shell reads
# them from the profile script, since home-manager escapes nothing there), the
# systemd user units of claude-telemetry (only where there is a telemetry
# folder, the report only where its option is on, a value that systemd would
# read as a specifier escaped), and the desktop's MACHINE_NOTE.
{
  self,
  inputs,
  pkgs,
  lib,
  system,
  ...
}:
let
  hostModules = import ../flake/helpers/host-modules.nix { inherit lib; };
  user = (import ../../templates/default/me.nix).ravnix.user.username;

  host =
    modules:
    (inputs.nixpkgs.lib.nixosSystem {
      inherit system;
      modules = hostModules ++ modules;
    }).config;
  homeOf = config: config.home-manager.users.${user};

  # The template sets every option to its empty value: this is what a host that
  # has not configured the scripts gets.
  bare = host [ self.nixosModules.common ];
  # A host that has: values with the characters that are right and need care
  # (a percent sign and an apostrophe, which systemd and the shell read), and
  # a telemetry folder.
  set = [
    {
      ravnix.shell.secretEnv = {
        FIRST_TOKEN = "First - API token";
        SECOND_TOKEN = "00000000-0000-0000-0000-000000000000";
      };
      ravnix.claude.skillValues.nextcloud.root = "/srv/cloud";
      ravnix.scripts = {
        vaultCheck.baseline = lib.mkForce ''
          # accepted on purpose
          notes 120
          unresolved Planned Note
        '';
        machineFacts.note = lib.mkForce "/srv/notes/Laptop.md";
        agentDoctor.normsFile = lib.mkForce "/srv/config/working-norms.md";
        # A plain definition: the template's is a mkDefault, so a host module
        # turns the report on without a mkForce.
        claudeTelemetry = {
          report = true;
          conflictRoots = lib.mkForce [
            "/srv/notes"
            "/srv/100%/it's here"
          ];
          memoryDirs = lib.mkForce [
            "old-memory"
            "memory"
          ];
        };
        ccnaDeck = {
          notesDir = lib.mkForce "Notes/Cards";
          mediaDir = lib.mkForce "Media/cards";
          deckName = lib.mkForce "Deck of 100%";
        };
        sapDeck = {
          notesDir = lib.mkForce "Notes/Tx";
          shortcutsNote = lib.mkForce "Notes/Tx/Shortcut table.md";
          transactionsBase = lib.mkForce "Notes/Tx/List of 100%.base";
          out = lib.mkForce "Out/deck.apkg";
        };
      };
    }
  ];
  common = host ([ self.nixosModules.common ] ++ set);
  desktop = host (
    [
      self.nixosModules.common
      self.nixosModules.desktop
    ]
    ++ set
  );
  desktopBare = host [
    self.nixosModules.common
    self.nixosModules.desktop
  ];
  # A host with a folder but no report: the template's default.
  folderOnly = host [
    self.nixosModules.common
    { ravnix.claude.skillValues.nextcloud.root = "/srv/cloud"; }
  ];

  files = config: (homeOf config).xdg.configFile;
  vars = config: (homeOf config).home.sessionVariables;
  units = config: (homeOf config).systemd.user;
  hasFile = config: name: (files config) ? ${name} && (files config).${name}.enable;
  environmentOf = config: unit: (units config).services.${unit}.Service.Environment;

  skillValues = "/home/${user}/.config/ravnix/skill-values.json";

  expectations = [
    {
      what = "a host with nothing set writes a secret table that is only comments";
      ok =
        let
          lines = lib.splitString "\n" (files bare)."ravnix/secret-env".text;
        in
        lib.all (l: l == "" || lib.hasPrefix "#" l) lines;
    }
    {
      what = "the secret table is NAME=item lines, with the item and never a value";
      ok =
        let
          t = (files common)."ravnix/secret-env".text;
        in
        lib.hasInfix "FIRST_TOKEN=First - API token\n" t
        && lib.hasInfix "SECOND_TOKEN=00000000-0000-0000-0000-000000000000\n" t;
    }
    {
      what = "no baseline file without a baseline";
      ok = !(hasFile bare "ravnix/vault-check.baseline");
    }
    {
      what = "the baseline is written as it was given";
      ok =
        (files common)."ravnix/vault-check.baseline".text
        == "# accepted on purpose\nnotes 120\nunresolved Planned Note\n";
    }
    {
      what = "no script variable is set without a value";
      ok = !(lib.any (n: (vars bare) ? ${n}) [
        "AGENT_DOCTOR_NORMS"
        "CLAUDE_TELEMETRY_CONFLICT_ROOTS"
        "CLAUDE_TELEMETRY_MEMORY_DIRS"
        "CCNA_DECK_NOTES_DIR"
        "CCNA_DECK_MEDIA_DIR"
        "CCNA_DECK_NAME"
        "SAP_DECK_DIR"
        "SAP_DECK_SHORTCUTS"
        "SAP_DECK_BASE"
        "SAP_DECK_OUT"
        "MACHINE_NOTE"
      ]);
    }
    {
      what = "the norms file, the conflict roots and the memory folders become session variables";
      ok =
        (vars common).AGENT_DOCTOR_NORMS == "/srv/config/working-norms.md"
        && (vars common).CLAUDE_TELEMETRY_CONFLICT_ROOTS == "/srv/notes:/srv/100%/it's here"
        && (vars common).CLAUDE_TELEMETRY_MEMORY_DIRS == "old-memory:memory";
    }
    {
      what = "the folders and the name of the deck builders become session variables";
      ok =
        (vars common).CCNA_DECK_NOTES_DIR == "Notes/Cards"
        && (vars common).CCNA_DECK_MEDIA_DIR == "Media/cards"
        && (vars common).CCNA_DECK_NAME == "Deck of 100%"
        && (vars common).SAP_DECK_DIR == "Notes/Tx"
        && (vars common).SAP_DECK_SHORTCUTS == "Notes/Tx/Shortcut table.md"
        && (vars common).SAP_DECK_BASE == "Notes/Tx/List of 100%.base"
        && (vars common).SAP_DECK_OUT == "Out/deck.apkg";
    }
    {
      what = "the common module leaves the desktop's note variable unset";
      ok = !((vars common) ? MACHINE_NOTE);
    }
    {
      what = "the desktop sets MACHINE_NOTE from the option, and not without one";
      ok = (vars desktop).MACHINE_NOTE == "/srv/notes/Laptop.md" && !((vars desktopBare) ? MACHINE_NOTE);
    }
    {
      what = "without a telemetry folder (no nextcloud.root in the skill values) there is no telemetry unit, so none fails every day";
      ok =
        !((units bare).services ? claude-telemetry-extract)
        && !((units bare).timers ? claude-telemetry-extract)
        && !((units bare).services ? claude-telemetry-report)
        && !((units bare).timers ? claude-telemetry-report);
    }
    {
      what = "with a folder the daily extract runs, with the extract and the state as its two commands";
      ok =
        (units folderOnly).timers ? claude-telemetry-extract
        && (units folderOnly).timers.claude-telemetry-extract.Timer.OnCalendar == "daily"
        && (units folderOnly).timers.claude-telemetry-extract.Timer.Persistent
        && lib.length (units folderOnly).services.claude-telemetry-extract.Service.ExecStart == 2
        && lib.hasSuffix " extract" (
          lib.elemAt (units folderOnly).services.claude-telemetry-extract.Service.ExecStart 0
        )
        && lib.hasSuffix " state" (
          lib.elemAt (units folderOnly).services.claude-telemetry-extract.Service.ExecStart 1
        );
    }
    {
      what = "the weekly report is only where the option is on, and the template's default leaves it off";
      ok =
        !((units folderOnly).timers ? claude-telemetry-report)
        && !((units folderOnly).services ? claude-telemetry-report)
        && (units common).timers.claude-telemetry-report.Timer.OnCalendar == "Mon *-*-* 07:00:00"
        && (units common).services.claude-telemetry-report.Service.ExecStart != null
        && (units common).services.claude-telemetry-report.Unit.Wants == [ "claude-telemetry-extract.service" ];
    }
    {
      what = "the report needs the folder as well: on with no nextcloud.root there is still no unit";
      ok =
        let
          c = host [
            self.nixosModules.common
            { ravnix.scripts.claudeTelemetry.report = true; }
          ];
        in
        !((units c).services ? claude-telemetry-report) && !((units c).timers ? claude-telemetry-report);
    }
    {
      what = "the units run at the lowest priority";
      ok =
        (units common).services.claude-telemetry-extract.Service.Nice == 19
        && (units common).services.claude-telemetry-extract.Service.IOSchedulingClass == "idle";
    }
    {
      what = "the units get the telemetry values and the place of the skill values in their Environment, quoted, with a specifier escaped";
      ok =
        environmentOf common "claude-telemetry-extract" == environmentOf common "claude-telemetry-report"
        && lib.elem ''"CLAUDE_TELEMETRY_CONFLICT_ROOTS=/srv/notes:/srv/100%%/it's here"'' (
          environmentOf common "claude-telemetry-extract"
        )
        && lib.elem ''"CLAUDE_TELEMETRY_MEMORY_DIRS=old-memory:memory"'' (
          environmentOf common "claude-telemetry-extract"
        )
        && lib.elem ''"RAVNIX_SKILL_VALUES=${skillValues}"'' (environmentOf common "claude-telemetry-extract");
    }
    {
      what = "the units get nothing they do not read: no norms file, no deck folder";
      ok = lib.all (e: !(lib.hasPrefix ''"AGENT_DOCTOR'' e) && !(lib.hasPrefix ''"CCNA'' e) && !(lib.hasPrefix ''"SAP'' e)) (
        environmentOf common "claude-telemetry-extract"
      );
    }
    {
      what = "a host with a folder and no values gives the units the place of the skill values only";
      ok = environmentOf folderOnly "claude-telemetry-extract" == [ ''"RAVNIX_SKILL_VALUES=${skillValues}"'' ];
    }
  ];

  # The session variables as a shell reads them: home-manager writes
  # export NAME="value" into a profile script, and escapes nothing.
  shellExpected = {
    AGENT_DOCTOR_NORMS = (vars common).AGENT_DOCTOR_NORMS;
    CLAUDE_TELEMETRY_CONFLICT_ROOTS = (vars common).CLAUDE_TELEMETRY_CONFLICT_ROOTS;
    CLAUDE_TELEMETRY_MEMORY_DIRS = (vars common).CLAUDE_TELEMETRY_MEMORY_DIRS;
    CCNA_DECK_NAME = (vars common).CCNA_DECK_NAME;
    CCNA_DECK_NOTES_DIR = (vars common).CCNA_DECK_NOTES_DIR;
    SAP_DECK_SHORTCUTS = (vars common).SAP_DECK_SHORTCUTS;
    SAP_DECK_BASE = (vars common).SAP_DECK_BASE;
    MACHINE_NOTE = (vars desktop).MACHINE_NOTE;
  };

  profileOf = config: "${(homeOf config).home.sessionVariablesPackage}/etc/profile.d/hm-session-vars.sh";

  failed = map (e: e.what) (lib.filter (e: !e.ok) expectations);
in
pkgs.runCommand "common-scripts-config" { nativeBuildInputs = [ pkgs.bash ]; } (
  if failed != [ ] then
    ''
      printf 'not so: %s\n' ${lib.escapeShellArgs failed} >&2
      exit 1
    ''
  else
    ''
      status=0

      # The profile scripts of the common host and of the desktop host, sourced
      # by a shell with nothing else in its environment: what a login shell gets.
      shell_value() {
        env -i HOME=/home/${user} ${pkgs.bash}/bin/bash -c '. "$1"; printf %s "''${!2-<unset>}"' _ "$1" "$2"
      }
      test -f ${profileOf common}
      ${lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: value: ''
          got=$(shell_value ${profileOf (if name == "MACHINE_NOTE" then desktop else common)} ${name})
          if [ "$got" != ${lib.escapeShellArg value} ]; then
            echo "the shell reads ${name} as [$got], not as [${value}]" >&2
            status=1
          fi
        '') shellExpected
      )}

      [ "$status" = 0 ]
      echo ${toString (lib.length expectations)} expectations hold
      touch "$out"
    ''
)
