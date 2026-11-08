# sap-deck

Builds the SAP Anki deck from the vault's own SAP notes: one card pair per
row of the shortcut tables in one note of the vault (a subdeck per H2), and one
per note with `type: transaktion` in one folder. Two note types, two card templates
each, so a fact is asked in both directions. The GUID comes from the shortcut
or the transaction code alone, so fixing a description updates the card and
keeps its review history. Python, carried over from Fedora's `bin-sap-deck`
(AGENTS.md, rule 4). The note types are frozen (a changed field list forks
Anki's note type); the header of the script says why.

Installed on both hosts by `modules/common/scripts.nix`.

## Packaging

The original ran under `uv run --script` with `genanki` as a PEP 723
dependency. Here `genanki` is nixpkgs' and the shebang is the Python that has
it; nothing is fetched at run time. The two JetBrains Mono fonts (`fonts/`,
byte for byte copies) are the package's data, in `$out/share/sap-deck`.

## Personal values

| Value | How it is read |
| --- | --- |
| the vault | `--vault`, else `VAULT_DIR`, else the skill value `vault.root` (`RAVNIX_SKILL_VALUES`, else `~/.config/ravnix/skill-values.json`); with none, the script says what to set |
| the folder of the transaction notes | `SAP_DECK_DIR`, from `ravnix.scripts.sapDeck.notesDir` |
| the note with the shortcut tables | `SAP_DECK_SHORTCUTS`, from `ravnix.scripts.sapDeck.shortcutsNote`; unset, there are no shortcut cards and no warning |
| the base that lists the transactions | `SAP_DECK_BASE`, from `ravnix.scripts.sapDeck.transactionsBase`; only named in the warning for a transaction without a `description` (a base shows frontmatter and cannot see a note's body); unset, the warning says "the base that lists the transactions" |
| the file the deck is written to | `SAP_DECK_OUT`, from `ravnix.scripts.sapDeck.out`, or `--out` |

All four are paths below the vault. Fedora built the user's layout in; there
is no default now. The options are null in the template, and the script names
the folder or the output that is unset and stops. The private flake sets them.

## Changes from the original

- the vault, the folder, the shortcuts note, the base and the output as above (Fedora
  defaulted to the user's layout);
- the media are copied into a temporary directory before they are packed, as
  in `ccna-deck`: a file of the Nix store has the modification time 1 (1970),
  which a zip cannot hold;
- flake8 ignores E501 (36 lines past 79 characters), E306 (one nested
  definition without a blank line before it) and W503 (13 breaks before a
  binary operator; an ignore list replaces flake8's defaults, which ignore it).

The deck's colors are hex colors in card templates, in Catppuccin Mocha. They
are a style exception (docs/style.md, rule 9), for the reason given in the
README of `ccna-deck`.

## Left out

Nothing.

## Tests

`tests/sap-deck.test.sh`, the check `bin-sap-deck`: fixture vaults, and the
`.apkg` is opened. The folders and file names of the fixtures are ones the test
invents, set through the variables. Covers a build (counts, subdecks in the order of the note,
an alternative key as two fields, wikilinks and HTML in cells, the code taken
from the file name, the first Stolperstein as the warning, both YAML list
forms, the deck's tags and media), GUIDs that survive a second build and an
edited description, `--out`, the base named in the warning (and no file of the vault named when it is unset), a vault from the variable and from the skill
values, and what it refuses or warns about: no vault, no `Vault.md`, nothing
to build, a transaction without an alias or a description, a key over 24
characters, empty cells, underscores in identifiers, five hundred shortcuts,
and each variable missing.

## Findings not fixed

- A shortcut written with backticks in the table keeps them on the card
  (`` `Strg + s` `` shows the backticks): only the action and detail cells go
  through the text cleaner, not the key. Write the key without backticks.
- A wikilink with an alias inside a table cell (`[[A|B]]`) is split at the
  `|`, as Markdown reads it; Obsidian wants `\|` there and the script does not
  unescape it.

- The vault resolver (`--vault`, then `VAULT_DIR`, then the skill value
  `vault.root`) is a copy of the one in `vault-check`, `agent-doctor`,
  `claude-telemetry` and the other deck builder (`searx` reads the same file), and the media copy
  (`stage_media`) is a copy of the other deck's. They are kept as they were
  carried over; one library for them is for the port, when the language is
  chosen, because a shared Python module would be thrown away with it.
