# The options of ravnix.scripts refuse what the shell or systemd would read as
# syntax, and accept the unusual values that are right. Most of them become
# session variables, which home-manager writes as export NAME="value" without
# escaping (the check common-scripts-config reads that profile script), so a
# double quote, a dollar sign, a backtick or a backslash would reach the shell
# as code; a colon would split a list in two. Paths below the vault are
# relative and stay below it.
{
  self,
  pkgs,
  lib,
  ...
}:
let
  eval = import ./helpers/eval.nix { inherit lib self; };
  template = ../../templates/default/me.nix;
  force = lib.mapAttrsRecursive (_: lib.mkForce);
  accepted =
    module:
    let
      e = eval [
        template
        (force module)
      ];
    in
    e.values.success && e.failed == [ ];

  scripts = attrs: { ravnix.scripts = attrs; };
  note = value: scripts { machineFacts.note = value; };
  roots = value: scripts { claudeTelemetry.conflictRoots = [ value ]; };
  dirs = value: scripts { claudeTelemetry.memoryDirs = [ value ]; };
  deck = attrs: scripts { ccnaDeck = attrs; };
  sap = attrs: scripts { sapDeck = attrs; };

  refused = {
    "a note path with a double quote" = note ''/srv/a"b.md'';
    "a note path with a dollar sign" = note "/srv/a$HOME.md";
    "a note path with a backtick" = note "/srv/a`id`.md";
    "a note path with a backslash" = note ''/srv/a\b.md'';
    "a relative note path" = note "notes/a.md";
    "a norms file with a command substitution" = scripts { agentDoctor.normsFile = "/srv/$(id).md"; };
    "a conflict root with a colon, which would be two roots" = roots "/srv/a:/srv/b";
    "a conflict root with a double quote" = roots ''/srv/"x"'';
    "a memory folder with a slash" = dirs "a/b";
    "a memory folder with a dollar sign" = dirs "$HOME";
    "a memory folder with a space" = dirs "a b";
    "a deck name with a double quote" = deck { deckName = ''My "deck"''; };
    "a deck name with a dollar sign" = deck { deckName = "$deck"; };
    "an empty deck name" = deck { deckName = ""; };
    # The deck name becomes a file name in the media folder.
    "a deck name with a slash" = deck { deckName = "a/b"; };
    "a deck name that climbs out of the media folder" = deck { deckName = "a/../../x"; };
    "a deck name of two dots" = deck { deckName = ".."; };
    "a deck name of one dot" = deck { deckName = "."; };
    "a deck name that starts with a dot, which would be a hidden file" = deck { deckName = ".deck"; };
    "a notes folder that is absolute" = deck { notesDir = "/srv/notes"; };
    "a notes folder that climbs out of the vault" = deck { notesDir = "../notes"; };
    "a media folder that climbs out in the middle" = deck { mediaDir = "a/../../b"; };
    "a notes folder with a dollar sign" = sap { notesDir = "Notes/$x"; };
    "an empty deck file" = sap { out = ""; };
    "a transactions base with a dollar sign" = sap { transactionsBase = "Notes/$x.base"; };
    "a transactions base that is absolute" = sap { transactionsBase = "/srv/Tx.base"; };
    "a transactions base that climbs out of the vault" = sap { transactionsBase = "../Tx.base"; };
    "an empty transactions base" = sap { transactionsBase = ""; };
    "a shortcuts note with a backtick" = sap { shortcutsNote = "Notes/`x`.md"; };
  };

  allowed = {
    "the template as it is" = { };
    "a note path with a percent sign, an apostrophe, a space and an umlaut" = note "/srv/100%/it's Küche.md";
    "a conflict root with a space" = roots "/srv/my notes";
    "a memory folder with a dot and an umlaut" = dirs "old.memory-Ü";
    "a deck name with a space, a percent sign and an umlaut" = deck { deckName = "Deck 100% für mich"; };
    "a notes folder two levels down, with a space" = deck { notesDir = "Notes/Card Deck"; };
    "a folder name that merely contains two dots" = deck { mediaDir = "a..b/c"; };
    "a deck name with a dot inside and a hyphen" = deck { deckName = "My CCNA v1.2 - 2026"; };
    "a deck name that ends in two dots" = deck { deckName = "Deck.."; };
    "a transactions base at the root of the vault" = sap { transactionsBase = "Transactions.base"; };
    "a transactions base with an en dash and a space" = sap { transactionsBase = "Notes/Tx – list.base"; };
    "a shortcuts note with an en dash, as vault notes are named" = sap { shortcutsNote = "Notes/Shortcuts – table.md"; };
    "every deck setting null" = deck {
      notesDir = null;
      mediaDir = null;
      deckName = null;
    };
    "every SAP setting null" = sap {
      notesDir = null;
      shortcutsNote = null;
      transactionsBase = null;
      out = null;
    };
  };

  failures =
    lib.mapAttrsToList (what: _: "accepted ${what}") (lib.filterAttrs (_: accepted) refused)
    ++ lib.mapAttrsToList (what: _: "refused ${what}") (lib.filterAttrs (_: m: !(accepted m)) allowed);
in
pkgs.runCommand "options-scripts" { } (
  if failures == [ ] then
    ''
      echo ${toString (lib.length (lib.attrNames refused))} refused values are refused, ${toString (lib.length (lib.attrNames allowed))} allowed values are allowed
      touch "$out"
    ''
  else
    ''
      printf '%s\n' ${lib.escapeShellArgs failures} >&2
      exit 1
    ''
)
