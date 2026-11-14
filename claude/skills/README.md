# Claude Code skills

The skills ravnix installs for Claude Code, one directory each. They came over
from an earlier setup; their scripts were Python there and stay Python
(AGENTS.md, rule 4), behind their tests.

| Skill | Does |
| --- | --- |
| `handoff` | writes and resumes a session handoff on a Plane board; its hooks show the board at session start and advise when to compact |
| `journal` | writes a session's noteworthy work into a session note in the notes vault; its Stop hook reminds once |
| `ai-memory` | writes and reviews the memory notes of the vault; its hooks inject them |
| `prose` | the house style for German and English prose, with a checker that runs LanguageTool |
| `conventional-commits` | commit messages in Conventional Commits 1.0.0, in the shape of the repository's history |
| `simplify-changes` | the strict, behavior-preserving simplification pass |
| `conscience` | a sparring partner against folklore code, speculative abstraction and unexamined convenience |
| `laptop` | how to change the laptop, huginn: which repository, how to build and switch, what never to touch |

## How a skill gets its values

A skill holds no personal value. Each one it needs is a key of
`ravnix.claude.skillValues`, set in the private flake (`claude/README.md`
says how), and reaches the skill two ways:

- **The Markdown is rendered when the home is built.** A skill's text names
  a value as `{{KEY}}`, and `lib/claude-skills.nix` puts the value in. It
  has to be in the text itself: Claude Code reads a skill's description to
  decide whether to load it, before any script could look anything up.
  Three names are ravnix's own: `{{ravnix.python}}` (the python3 the scripts
  run with), `{{ravnix.skillDir}}` and `{{ravnix.skillsDir}}`.
- **The scripts read `skill-values.json`** at run time, through
  `scripts/skill_values.py` (one module, the same in every skill).

**A key that is not set stops the skill.** The rendered `SKILL.md` then
opens with an instruction to stop and one line per key, "set `KEY` in your
ravnix skill values", and a script that needs the key exits 2 with the same
sentence. A hook whose key is missing stays quiet.

| Key | Type | Used by | What it is |
| --- | --- | --- | --- |
| `user.name` | string | every skill but `conscience` | how the skills name the user: "when Alice says handoff" |
| `vault.root` | string, an absolute path | `journal`, `ai-memory` (and `session-preflight`, `claude/README.md`) | the notes vault (Obsidian) |
| `journal.protectedSection` | string, a heading line | `journal` | the section of the daily note that is the user's alone: the skill never writes there, and puts its Capture section above it |
| `journal.languageRule` | string, Markdown | `journal` | which language a session note is written in, by subject |
| `memory.domains` | object, a list of keywords per domain | `ai-memory`, `journal` | the domain vocabulary of the notes; without it the lint checks no domain and no digest is injected |
| `handoff.workspaces` | object | `handoff` | the Plane board layout: workspaces, their projects and the directories each project is the default for |
| `plane.mcpUrl` | string, a URL | `handoff` | Plane's MCP gateway; `PLANE_MCP_URL` wins over it |
| `prose.languageRule` | string, Markdown | `prose` | which language a text is written in, and when to address the reader as `Sie` |
| `prose.languagetool.item` | string | `prose` | the Bitwarden item of a LanguageTool Premium account (key in its password, account in its username), read with rbw; without it the checker uses the free tier |
| `laptop.model` | string | `laptop` | the laptop's model and GPUs, as the description should match them |
| `laptop.checkout` | string, an absolute path | `laptop` | the ravnix checkout the laptop is built from (`ravnix.dev.checkout`) |
| `laptop.privateFlake` | string, an absolute path | `laptop` | the private flake |
| `laptop.note` | string, an absolute path | `laptop` | the machine's note, which `machine-facts --write` keeps |

`handoff.workspaces` looks like this:

```nix
handoff.workspaces = {
  home = {
    default = true;   # the workspace `claim` takes without --workspace
    projects.NOTES = {
      id = "00000000-0000-0000-0000-000000000000";
      name = "Notes";
      dirs = [ "/home/alice/Notes" ];
    };
  };
};
```

Two values are no skill value. The Plane token is the environment's
`PLANE_API_TOKEN`, which `ravnix.shell.secretEnv` reads from Bitwarden when
Claude Code starts. The prose skill's accepted words are the user's list,
`~/.config/prose/dictionary.txt`, which ravnix-dict keeps
(`ravnix.dictionary.paths.prose`); the `dictionary.txt` beside the skill holds
no words and is read only when that file does not exist.

`vault.commitVia` and `vault.repositoryHere` are set by ravnix itself, by the
host's shape (`modules/glue/vault.nix`). The vault skills commit with
`vault-commit MESSAGE PATH...`, never with `git commit`, and name the files.

### The vault's layout

The skills keep their notes in fixed places of the vault, as `vault-check`
expects them: `AI/memory/`, `AI/archive/` and `AI/sessions/`, the daily notes
in `daily-notes/` with the name format of Obsidian's daily-notes setting
`dddd, DD. MMM Y ([W]W)`, and the daily note's template at
`templates/Daily Note.md`. A vault laid out otherwise needs those changed in
the scripts.

## How they are installed

`homeModules.claude-skills` (`modules/common/claude-skills.nix`) renders all
of them into one tree in the store and links each directory at
`~/.claude/skills/NAME`. It is one tree because `journal` imports
`ai-memory`'s note reader from beside itself.

`ravnix.claude.skills` adds skills beside ravnix's own, by name: a skill of
the private flake's, or one pinned from upstream as a flake input. A name of
ravnix's set there replaces ravnix's skill; `null` leaves it out. The module
merges ravnix's skills under it, so a definition at any priority, the
`lib.mkDefault` the NixOS module forwards included, adds to them instead of
replacing all of them.

The hooks of three skills join ravnix's other hooks
(`ravnix.claude.hookEntries`), each a wrapper at `~/.claude/ravnix/hooks/NAME`
that runs the adapter of the installed skill and ends 0 whatever happens:

| Event | Hook | Timeout | Skill |
| --- | --- | --- | --- |
| SessionStart | `handoff-sessionstart` | 30 s | `handoff`: the board of the directory's project, and the newest handoff after a compaction |
| Stop | `handoff-stop` | 30 s | `handoff`: the compaction advice to the user, from 200k tokens |
| PreCompact | `handoff-precompact` | 30 s | `handoff`: re-arms the advice |
| Stop | `journal-stop` | 30 s | `journal`: one reminder when files changed and no session note was written |
| SessionStart | `ai-memory-sessionstart` | 5 s | `ai-memory`: the pinned memory lines |
| UserPromptSubmit | `ai-memory-userpromptsubmit` | 5 s | `ai-memory`: the notes a prompt points at |
| PostToolUseFailure | `ai-memory-posttoolfailure` | 5 s | `ai-memory`: the notes whose symptom is in the error |

A skill left out leaves its hooks out. Each kill switch of the earlier setup
still works: `HANDOFF_DISABLED=1`, `JOURNAL_DISABLED=1`, `AI_MEMORY_DISABLED=1`.

## Tests

The check `claude-skills` (`tests/claude/skills.nix`) runs each skill's
Python suite in the sandbox (`handoff`, `journal`, `ai-memory`, and `prose`'s
`test_values.py` and fixture run), and checks that every copy of
`skill_values.py` is handoff's, that every key a skill names or a script reads
is a row of the table above and every row is used, and that no skill ships a
word list, a board layout or a domain list of its own. The check
`claude-skills-render` (`tests/claude/skills-render.nix`) builds a home: the
skills linked and rendered, the stop lines for every missing key, the hooks
wired, a skill replaced and one left out.

## Changes from the earlier setup

- The values: the board layout (`projects.json`), the domain list
  (`domains.json`), the vault's path, the Plane gateway's address, the
  LanguageTool item and the user's name were in the files; they are keys now.
- `muratori-conscience` is `conscience`, and `fedora`, the manual of a
  Fedora laptop, is `laptop`, rewritten for huginn: NixOS, built from two
  flakes, nothing configured by hand.
- `prose` reads its LanguageTool key from rbw alone (and the environment),
  never from a file: the keyring and the plaintext credentials file are gone,
  and with them `--store-key`.
- `journal` and the handoff advisor count `vault-commit` as a commit, and
  every script also counts when run by the store path of its python3, as the
  rendered skills run them.
- Left out: `ai-memory`'s `migrate.py` (a one-time move of an older memory
  store, done), and `handoff`'s `DESIGN.md` and `PLAN.md` (the history of the
  file-based design that the board replaced).

## Known gaps

- `journal` imports `ai-memory`'s `notes.py` from beside itself. A
  `ravnix.claude.skills.ai-memory` of the user's own, or `null`, takes that
  away, and `session_note.py` then fails to import.
- A project's own Plane hooks may import `handoff_state.py` by its absolute
  path, `~/.claude/skills/handoff/scripts/handoff_state.py`. That path holds
  on a ravnix host; a different `configDir` moves it.
- The vault's layout above is fixed in the scripts, as it is in `vault-check`.
- The rendered text is as current as the last switch: a value changed in the
  private flake reaches a skill's Markdown at the next switch, and its
  scripts at once.
