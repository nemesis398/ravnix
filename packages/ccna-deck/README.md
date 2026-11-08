# ccna-deck

Builds the CCNA Anki deck from the vault's own card notes
(`CCNA NN – Subject.md` in a folder of the vault): fact cards, term cards (both
directions) and cloze cards, as one `.apkg` that Anki imports. The note GUIDs
come from the card keys alone, so a re-import updates the cards and keeps
their review history. `--check` parses and validates and writes nothing.
`diagrams.py` (in `share/ccna-deck`, not a command) draws the SVG diagrams the
cards show. Python, carried over from Fedora's `bin-ccna-deck` (AGENTS.md,
rule 4). The comments hold the card syntax and the reasons.

Installed on both hosts by `modules/common/scripts.nix`.

## Packaging

The original ran under `uv run --script` and declared `genanki` as a PEP 723
dependency. Here `genanki` is nixpkgs' and the shebang is the Python that has
it, so nothing is fetched at run time. The three JetBrains Mono fonts
(`fonts/`, copies of the originals, byte for byte) and `diagrams.py` are the
package's data, in `$out/share/ccna-deck`, where the script looks for them.

To redraw the diagrams:

    python3 "$(dirname "$(readlink -f "$(type -P ccna-deck)")")/../share/ccna-deck/diagrams.py" VAULT/$CCNA_DECK_MEDIA_DIR

## Personal values

| Value | How it is read |
| --- | --- |
| the vault | `--vault`, else `VAULT_DIR`, else the skill value `vault.root` (`RAVNIX_SKILL_VALUES`, else `~/.config/ravnix/skill-values.json`); with none, the script says what to set |
| the folder of the card notes | `CCNA_DECK_NOTES_DIR`, from `ravnix.scripts.ccnaDeck.notesDir` |
| the folder of the diagrams and fonts the cards show | `CCNA_DECK_MEDIA_DIR`, from `ravnix.scripts.ccnaDeck.mediaDir` |
| the deck's name, which Anki matches decks by | `CCNA_DECK_NAME`, from `ravnix.scripts.ccnaDeck.deckName`; it is also the file name of the deck, so the option refuses a `/` and a leading `.` |

The two folders are below the vault. The deck is written to
`MEDIA_DIR/DECK_NAME.apkg`, or where `--out` says. Fedora defaulted to the
user's vault, folders and deck name. There is no default now: the options are
null in the template, and the script names the ones that are unset and stops.
The private flake sets them, so the public repository holds none of the user's
folders.

## Changes from the original

- the vault, the two folders and the deck name as above;
- the media are copied into a temporary directory before they are packed.
  A file in the Nix store has the modification time 1 (1970), which a zip cannot
  hold, and genanki writes with strict timestamps: the build stopped with
  "ZIP does not support timestamps before 1980". Found by the first test that
  built a deck on NixOS; the copy gets a current time and the names survive;
- comments that named the user are neutral;
- flake8 ignores E501 (lines past 79 characters, 46 of them) and W503 (15
  breaks before a binary operator; an ignore list replaces flake8's defaults,
  which ignore it). `diagrams.py` is data, not a command, and fails E501, E741
  and F841; it is checked to compile.

The deck's colors are hex colors in card templates and diagrams, in the
Catppuccin Mocha the deck was made in. They are a style exception
(docs/style.md, rule 9): the decks live in Anki, not in the desktop, and
cannot read the theme module without a rewrite of the generator, which stays as
it is until its port.

## Left out

Nothing.

## Tests

`tests/ccna-deck.test.sh`, the check `bin-ccna-deck`: fixture vaults, and the
`.apkg` is opened (it is a zip with a SQLite collection). The folders and the
name of the fixtures are ones the test invents, set through the variables, so
the test holds no layout of a real vault. Covers `--check` and a build (counts
per subject, the default place, `--out`, the media list
with the fonts and the diagram, GUIDs that survive a second build), the
Dropped section staying out, a colon inside a cloze gap, escaping of HTML and
the vault markup, and the vaults it must refuse or warn about: none, no
`Vault.md`, no notes, a bad file name, a key used twice, no `**Src:**`, a card
without Q and A, a missing diagram, a malformed key, an em dash, a stray
line, a note without a Cards section, four hundred cards, and the vault from
the skill values (a bad file counts as none), and each of the three variables
missing, alone and together.

## Findings not fixed

- The vault resolver (`--vault`, then `VAULT_DIR`, then the skill value
  `vault.root`) is a copy of the one in `vault-check`, `agent-doctor`,
  `claude-telemetry` and the other deck builder (`searx` reads the same file), and the media copy
  (`stage_media`) is a copy of the other deck's. They are kept as they were
  carried over; one library for them is for the port, when the language is
  chosen, because a shared Python module would be thrown away with it.

