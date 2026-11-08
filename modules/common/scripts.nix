# The scripts that both hosts need, as home-manager installs them: the Claude
# Code tools (claude-artifacts, claude-bg, claude-telemetry, agent-doctor), the
# vault and search tools (vault-check, searx) and the tools that build and
# fetch (ccna-deck and sap-deck, which build Anki decks from the vault, and
# dl-video). They come from packages/NAME (README.md in each), which this
# module reads as pkgs.ravnix.NAME. The scripts that need the desktop are
# installed by modules/desktop/scripts.nix. modules/common/default.nix imports
# this file, beside the other home-manager files of the common module.
#
# What a script needs of the user is a value from ravnix.claude.skillValues
# (the SearXNG URL, the vault, the Nextcloud root), which the script reads from
# the skill values file at run time, or an option of ravnix.scripts, which this
# module turns into what the script reads:
#
#   - vault-check's baseline, written to ~/.config/ravnix/vault-check.baseline;
#   - the secret table of claude-bg (ravnix.shell.secretEnv), written to
#     ~/.config/ravnix/secret-env: NAME=item lines, never a value;
#   - agent-doctor's norms document, the folders of the Anki deck builders and
#     claude-telemetry's conflict roots and memory folders, as session
#     variables (their types refuse the characters a shell would read as
#     syntax); the telemetry ones, and the place of the skill values, also as
#     the Environment of the units;
#   - claude-telemetry's systemd user units, which need the telemetry folder,
#     <nextcloud.root>/claude-telemetry of the skill values, and are not
#     installed without it: the daily extract on every host that has one, and
#     the weekly report where ravnix.scripts.claudeTelemetry.report is on.
#
# claude-artifacts and claude-bg carry with-secret-env (packages/with-secret-env),
# which reads the secret table written here; it is not installed for the user.
#
# pkgs.ravnix comes from the overlay that nixosModules.common applies. A
# home-manager configuration that has no overlay (homeModules.common used on
# its own, as the tests of the common module do) gets the same packages from
# the same overlay here, so this module never needs one to be added.
#
# Style exception (docs/style.md, rule 9): ccna-deck and sap-deck write Anki
# card templates in Catppuccin Mocha with hex colors, square and flat, in the
# Python they were carried over in. The colors are the deck's own and cannot
# come from the theme module without rewriting the generators, which stay as
# they are until their port (AGENTS.md, rule 4). The decks live in Anki, not in
# the desktop, and scripts/check-style.sh does not judge packages/.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ravnix.scripts;

  ravnixPackages = import ../../lib/ravnix-packages.nix { inherit lib; } {
    packagesDir = ../../packages;
    toolsDir = ../../tools;
  };
  ravnix = pkgs.ravnix or (pkgs.extend ravnixPackages.overlay).ravnix;

  scripts = [
    "agent-doctor"
    "ccna-deck"
    "claude-artifacts"
    "claude-bg"
    "claude-telemetry"
    "dl-video"
    "sap-deck"
    "searx"
    "vault-check"
  ];

  telemetry = cfg.claudeTelemetry;
  exe = lib.getExe ravnix.claude-telemetry;

  # The units need the folder the telemetry goes to, which is read from the
  # skill values; without it `extract` has nowhere to write and would fail
  # every day, so there is no unit.
  hasFolder = (config.ravnix.claude.skillValues.nextcloud.root or null) != null;
  # Where claude-skills.nix writes them.
  skillValuesFile = "${config.xdg.configHome}/ravnix/skill-values.json";

  set = name: value: lib.optionalAttrs (value != null) { ${name} = value; };

  # What the units read: the telemetry folders, and where the skill values are
  # (a unit has no session variables, and a config home that is not the
  # default would otherwise not be found).
  telemetryVariables =
    { RAVNIX_SKILL_VALUES = skillValuesFile; }
    // lib.optionalAttrs (telemetry.conflictRoots != [ ]) {
      CLAUDE_TELEMETRY_CONFLICT_ROOTS = lib.concatStringsSep ":" telemetry.conflictRoots;
    }
    // lib.optionalAttrs (telemetry.memoryDirs != [ ]) {
      CLAUDE_TELEMETRY_MEMORY_DIRS = lib.concatStringsSep ":" telemetry.memoryDirs;
    };

  # Variables the scripts read, set only where the user gave a value. The
  # skill values' own variable is set by claude-skills.nix.
  variables =
    removeAttrs telemetryVariables [ "RAVNIX_SKILL_VALUES" ]
    // set "AGENT_DOCTOR_NORMS" cfg.agentDoctor.normsFile
    // set "CCNA_DECK_NOTES_DIR" cfg.ccnaDeck.notesDir
    // set "CCNA_DECK_MEDIA_DIR" cfg.ccnaDeck.mediaDir
    // set "CCNA_DECK_NAME" cfg.ccnaDeck.deckName
    // set "SAP_DECK_DIR" cfg.sapDeck.notesDir
    // set "SAP_DECK_SHORTCUTS" cfg.sapDeck.shortcutsNote
    // set "SAP_DECK_BASE" cfg.sapDeck.transactionsBase
    // set "SAP_DECK_OUT" cfg.sapDeck.out;

  # A unit's Environment entry: quoted, with systemd's own escapes for the
  # characters it reads in a value.
  quoted =
    name: value:
    ''"${name}=${lib.replaceStrings [ "\\" ''"'' "%" ] [ "\\\\" ''\"'' "%%" ] value}"'';
  environment = lib.mapAttrsToList quoted telemetryVariables;

  # Nice 19 and idle I/O: a pass over the transcripts must never be what makes
  # an interactive session wait.
  lowPriority = {
    Type = "oneshot";
    Nice = 19;
    IOSchedulingClass = "idle";
    Environment = environment;
  };
in
{
  config = {
    home.packages = map (name: ravnix.${name}) scripts;

    home.sessionVariables = variables;

    xdg.configFile = {
      "ravnix/secret-env".text =
        "# Written by ravnix from ravnix.shell.secretEnv: NAME=item, the item being the\n"
        + "# name or id of the Bitwarden item. with-secret-env reads each with rbw get; no value is here.\n"
        + lib.concatStrings (lib.mapAttrsToList (name: item: "${name}=${item}\n") config.ravnix.shell.secretEnv);
      "ravnix/vault-check.baseline" = lib.mkIf (cfg.vaultCheck.baseline != "") {
        text = cfg.vaultCheck.baseline;
      };
    };

    # The daily rows: every host that runs Claude Code and has a telemetry
    # folder. Persistent, because the job is read-only and idempotent, so the
    # one late run after a host slept through its slot is harmless, and
    # without it a laptop that is closed at midnight would rarely run at all.
    systemd.user.services.claude-telemetry-extract = lib.mkIf hasFolder {
      Unit.Description = "Claude Code telemetry: this machine's transcript rows and state";
      Service = lowPriority // {
        ExecStart = [
          "${exe} extract"
          "${exe} state"
        ];
      };
    };
    systemd.user.timers.claude-telemetry-extract = lib.mkIf hasFolder {
      Unit.Description = "Daily Claude Code telemetry rows, on every machine that runs Claude Code";
      Timer = {
        OnCalendar = "daily";
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };

    # The weekly report: one writer, so one host, where the option is on.
    systemd.user.services.claude-telemetry-report = lib.mkIf (hasFolder && telemetry.report) {
      Unit = {
        Description = "Weekly Claude Code telemetry report";
        # Refresh this machine's rows first. Wants, not Requires: a failed
        # extract still leaves last week's rows to report on.
        Wants = [ "claude-telemetry-extract.service" ];
        After = [ "claude-telemetry-extract.service" ];
      };
      Service = lowPriority // {
        ExecStart = "${exe} report";
      };
    };
    systemd.user.timers.claude-telemetry-report = lib.mkIf (hasFolder && telemetry.report) {
      Unit.Description = "Weekly Claude Code telemetry report";
      Timer = {
        OnCalendar = "Mon *-*-* 07:00:00";
        Persistent = true;
      };
      Install.WantedBy = [ "timers.target" ];
    };
  };
}
