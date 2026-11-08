# The personal values of the bin-* scripts (packages/NAME, installed by
# modules/common/scripts.nix and modules/desktop/scripts.nix). Where a value
# already has an option, the script reads that one: the SearXNG URL, the vault
# and the Nextcloud root are ravnix.claude.skillValues (web.searxngUrl,
# vault.root, nextcloud.root), which the scripts read from the skill values
# file at run time. What is left is here, and none of it has a default that
# could pass for a real value: a value that is not set switches its part off,
# and the script says which setting it wants.
{ lib, ... }:
let
  inherit (lib) mkOption types;

  # Most of these become session variables, and home-manager writes those as
  # export NAME="value" and escapes nothing: a double quote, a dollar sign, a
  # backtick or a backslash in a value would reach the shell as syntax. They
  # are refused here, and the colon too where the variable is a colon-separated
  # list. A percent sign, an apostrophe, a space and an umlaut are fine.
  bad = "\"$`\\\\";
  plain = extra: "[^${bad}${extra}]";
  absolute =
    extra: description: types.strMatching "/${plain extra}+" // { inherit description; };
  absolutePath = absolute "" "absolute path, as a string, without \" $ ` or \\";
  listedPath = absolute ":" "absolute path, as a string, without \" $ ` \\ or :";
  # A path below the vault, which the script joins to it: relative, no ..
  vaultPath =
    description:
    types.addCheck (types.strMatching "${plain "/"}${plain ""}*" // { inherit description; }) (
      path: !(lib.elem ".." (lib.splitString "/" path))
    );
  vaultFolder = vaultPath "path below the vault, without .. \" $ ` or \\";
in
{
  options.ravnix.scripts = {
    vaultCheck.baseline = mkOption {
      type = types.lines;
      default = "";
      example = ''
        notes 120
        unresolved Planned Note
      '';
      description = ''
        The baseline of `vault-check`: what it accepts on purpose, and the
        reference it compares the vault against. One line per entry, a key and
        its value after the first white space, `#` for comments:
        `unresolved LINK` accepts a link that no note answers, `notes N` is the
        reference count of notes (a warning when the live count falls more
        than 10 % below it). It is written to
        `~/.config/ravnix/vault-check.baseline`, where `vault-check` looks.
        Empty writes no file, and `vault-check` then warns that the baseline
        is missing. The file sits in the world-readable Nix store, so it
        holds note names only, never a secret.
      '';
    };

    machineFacts.note = mkOption {
      type = types.nullOr absolutePath;
      default = null;
      example = "/home/alice/Notes/Laptop.md";
      description = ''
        The note that `machine-facts --write`, `--check` and `--diff` work on:
        an absolute path in a string, to a note that holds the two marker lines
        `<!-- machine-facts:begin -->` and `<!-- machine-facts:end -->`. It is
        exported as `MACHINE_NOTE`. Null leaves it unset, and those three
        modes then say so; `machine-facts` alone prints the block and needs no
        note.
      '';
    };

    agentDoctor.normsFile = mkOption {
      type = types.nullOr absolutePath;
      default = null;
      example = "/home/alice/src/config/docs/working-norms.md";
      description = ''
        The document that holds your machine-wide working norms, as an absolute
        path in a string. `agent-doctor` treats it as the home of the rules it
        watches that are stated there, and reads it as part of the corpus. It is
        exported as `AGENT_DOCTOR_NORMS`. Null leaves it unset, and the rules
        homed in that document are then not watched.
      '';
    };

    ccnaDeck = {
      notesDir = mkOption {
        type = types.nullOr vaultFolder;
        default = null;
        example = "Notes/Cards";
        description = ''
          The folder of your vault that holds the CCNA card notes
          (`CCNA NN – Subject.md`), as a path below the vault. Exported as
          `CCNA_DECK_NOTES_DIR`. `ccna-deck` builds nothing without it and says
          so.
        '';
      };
      mediaDir = mkOption {
        type = types.nullOr vaultFolder;
        default = null;
        example = "attachments/cards";
        description = ''
          The folder of your vault that holds the diagrams the cards show, as a
          path below the vault. The deck file is written there, named after the
          deck. Exported as `CCNA_DECK_MEDIA_DIR`.
        '';
      };
      deckName = mkOption {
        # The name is also the file name of the deck, `<mediaDir>/<name>.apkg`,
        # so it holds no slash and does not start with a dot (which would hide
        # the file, and ".." would climb out of the folder).
        type = types.nullOr (
          types.strMatching "[^${bad}/.][^${bad}/]*"
          // {
            description = "deck name that is also a file name, without / or a leading dot, and without \" $ ` or \\";
          }
        );
        default = null;
        example = "My CCNA";
        description = ''
          The name of the top deck in Anki. Anki matches decks by name, so a
          change creates a second deck. The deck file is named after it, so it
          holds no `/` and does not start with a dot. Exported as
          `CCNA_DECK_NAME`.
        '';
      };
    };

    sapDeck = {
      notesDir = mkOption {
        type = types.nullOr vaultFolder;
        default = null;
        example = "Notes/Transactions";
        description = ''
          The folder of your vault that holds the transaction notes
          (`type: transaktion`), as a path below the vault. Exported as
          `SAP_DECK_DIR`. `sap-deck` builds nothing without it and says so.
        '';
      };
      shortcutsNote = mkOption {
        type = types.nullOr vaultFolder;
        default = null;
        example = "Notes/Transactions/Shortcut table.md";
        description = ''
          The note whose tables hold the shortcuts, one subdeck per H2, as a
          path below the vault. Exported as `SAP_DECK_SHORTCUTS`. Null leaves
          out the shortcut cards.
        '';
      };
      transactionsBase = mkOption {
        type = types.nullOr vaultFolder;
        default = null;
        example = "Notes/Transactions/Transactions.base";
        description = ''
          The Obsidian base of your vault that lists the transaction notes, as
          a path below the vault. `sap-deck` names it in the warning for a
          transaction without a `description`, which a base cannot show from
          the note's body. Exported as `SAP_DECK_BASE`. Null makes the warning
          say "the base that lists the transactions".
        '';
      };
      out = mkOption {
        type = types.nullOr vaultFolder;
        default = null;
        example = "Decks/transactions.apkg";
        description = ''
          The deck file `sap-deck` writes, as a path below the vault. Exported
          as `SAP_DECK_OUT`; `--out` takes its place.
        '';
      };
    };

    claudeTelemetry = {
      report = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether this host writes the weekly report of `claude-telemetry`
          (Monday 07:00). The daily rows and state run on every host; the report
          merges every host's rows and has one writer, so enable it on one host
          only, usually the laptop. The template sets it with `lib.mkDefault`,
          so a host module can turn it on with a plain
          `ravnix.scripts.claudeTelemetry.report = true;` and the other hosts
          keep the default. Both the daily rows and the report need the
          telemetry folder, which is `<nextcloud.root>/claude-telemetry` of
          the skill values: without `nextcloud.root` no unit is installed.
        '';
      };

      conflictRoots = mkOption {
        type = types.listOf listedPath;
        default = [ ];
        example = [ "/home/alice/Nextcloud/Notes" ];
        description = ''
          The folders the weekly report scans for Nextcloud conflict files, as
          absolute paths in strings. Exported as
          `CLAUDE_TELEMETRY_CONFLICT_ROOTS`. Empty scans the vault
          (`vault.root` of the skill values), and nothing if that is not set.
        '';
      };

      memoryDirs = mkOption {
        type = types.listOf (types.strMatching "[^/:[:space:]${bad}]+");
        default = [ ];
        example = [ "old-memory" ];
        description = ''
          Names of the folders (a name, no slash) that your Claude Code memory
          store is in or was in, so that `claude-telemetry` counts writes to
          notes there. A project's own memory folder is always counted. Exported
          as `CLAUDE_TELEMETRY_MEMORY_DIRS`.
        '';
      };
    };
  };
}
