# vault-check

The deterministic health check of the Obsidian vault: broken links, orphans,
frontmatter, duplicates, unresolved links against a baseline, the ai-memory
lint. Exit 0 is the gate. Bash, carried over from Fedora's `bin-vault-check`
(AGENTS.md, rule 4). The vault skills call it on both hosts.

Installed on both hosts by `modules/common/scripts.nix`.

## Personal values

| Value | How it is read |
| --- | --- |
| the vault | `VAULT_DIR`, else the skill value `vault.root` (`RAVNIX_SKILL_VALUES`, else `~/.config/ravnix/skill-values.json`); with neither, exit 2 |
| the baseline | `VAULT_CHECK_BASELINE`, else `~/.config/ravnix/vault-check.baseline`, which the module writes from `ravnix.scripts.vaultCheck.baseline` |

The baseline is what travels with the tool in Fedora (a file next to the
script, found through the stow symlink). Here it is the user's own option.
Empty writes no file, and the script then warns that it is missing. The
file lands in the world-readable Nix store, so it holds note names only.

## Changes from the original

- the vault and the baseline are resolved as above; the user's vault path and
  the stow-symlink lookup are gone;
- comments that named the user are neutral.

shellcheck passes without a change; `bashOptions = [ ]` because the script
sets `set -uo pipefail` itself.

## Left out

Nothing. The Obsidian CLI (`obsidian`) belongs to the desktop application and
is looked up on the `PATH`; without it the checks that need it are skipped
with an INFO line, as in Fedora. The ai-memory lint is the skill's
(`~/.claude/skills/ai-memory/scripts/lint.py`, or `AI_MEMORY_LINT`); the skill
is not part of ravnix, and without it the script warns that `AI/` went
unchecked.

## Tests

`tests/vault-check.test.sh`, the check `bin-vault-check`: the Obsidian CLI
and `date` are stand-ins in front of the script's own tools
(`tests/bin/helpers/stub-first.nix`), and the lint is a stand-in
(`tests/fixtures/lint.py`). Covers the unresolved-link check and its baseline
(accepted links, the week rules, the reference count), the run of the
memory lint (missing, crashing, reporting), the exemption of `AI/specs` and
`AI/plans` from the link checks, vault and baseline resolution, and a start
with an empty environment.

## Findings not fixed

- The reader of the skill values (`RAVNIX_SKILL_VALUES`, and for the vault
  `--vault`, then `VAULT_DIR`, then `vault.root`) is a copy of the one in the
  other tools that read them: `searx`, `vault-check`, `agent-doctor`,
  `claude-telemetry`, `ccna-deck` and `sap-deck`. They stay as carried over;
  one library for them belongs to the port, when the language is chosen,
  because a shared Python or Bash module would be discarded with it.
