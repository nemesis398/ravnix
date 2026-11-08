# claude-telemetry

Read-only telemetry over Claude Code's transcripts. Three subcommands:
`extract` writes one row per session (counts, sizes and names, never prompt,
answer or tool text) to `<folder>/rows/<host>.jsonl`; `state` writes a few
settings and decisions to `<folder>/state/<host>.json`; `report` merges the
rows and states of every host and writes `reports/<date>.md`, `.json` and
`alerts.json`. Each file has exactly one writer, so two hosts never conflict.
Python, standard library only, carried over from Fedora's
`bin-claude-telemetry` (AGENTS.md, rule 4).

Installed on both hosts by `modules/common/scripts.nix`, which also writes
its systemd user units.

## The units

| Unit | When | Where |
| --- | --- | --- |
| `claude-telemetry-extract.timer` | daily: `extract`, then `state` | every host |
| `claude-telemetry-report.timer` | Monday 07:00, after a fresh `extract` | the host with `ravnix.scripts.claudeTelemetry.report = true` |

Both are `Persistent=true` (a host that slept through its slot runs once when
it wakes), and both services run at `Nice=19` with idle I/O. They are
home-manager user units (`systemd.user.services` and `timers`) and call the
packaged script by its store path. The values below reach them as
`Environment`, with `%` and `"` escaped for systemd. Fedora decided where the
report ran with `ConditionHost=`, which would have named a host; the option
replaces it, so the host is chosen by which configuration sets it.

## Personal values

| Value | How it is read |
| --- | --- |
| the telemetry folder | `CLAUDE_TELEMETRY_DIR` or `--dir`, else `<nextcloud.root>/claude-telemetry` from the skill values; with neither, a command that needs it stops and says what to set |
| the conflict roots | `CLAUDE_TELEMETRY_CONFLICT_ROOTS` (colon-separated), from `ravnix.scripts.claudeTelemetry.conflictRoots`, else the vault (`VAULT_DIR`, else `vault.root`), else none |
| the memory folders | `CLAUDE_TELEMETRY_MEMORY_DIRS` (names, colon-separated), from `ravnix.scripts.claudeTelemetry.memoryDirs`; a project's own memory folder always counts |

Fedora built in three folders to scan for conflicts and a memory store path;
none of that is in the script now.

## Changes from the original

The places it reads its folders from, as above, and the shebang. flake8
ignores E501 (157 lines), E127 (one continuation line), W503 and W504 (breaks
before and after binary operators: an ignore list replaces flake8's defaults,
which ignore both).

## Left out

Nothing is removed. Two defaults describe Fedora only and are inert here: the
claude routing shim's log (`--shim-log`, the shim was removed on 2026-10-03)
and the date routing started (`--routing-since`). With no log the shim
section of the report is empty.

## Tests

`tests/claude-telemetry.test.sh`, the check `bin-claude-telemetry`, from an
empty environment with only `python3` on the `PATH`: fixtures of transcripts,
settings and memory notes, and above all what the script never writes
(a marker string planted in every place that holds prompt or tool text must
appear in no file it wrote). The ai-memory skill's `lint.py` is not part of
ravnix, so the memory section runs against a stand-in
(`tests/fixtures/ai-memory/scripts/lint.py`). The same test checks the
generated units with `systemd-analyze verify`.

## Findings not fixed

- The report's memory section needs the ai-memory skill at
  `~/.claude/skills/ai-memory/scripts/lint.py`; without it that section
  says the lint is unavailable.
- The reader of the skill values (`RAVNIX_SKILL_VALUES`, and for the vault
  `--vault`, then `VAULT_DIR`, then `vault.root`) is a copy of the one in the
  other tools that read them: `searx`, `vault-check`, `agent-doctor`,
  `claude-telemetry`, `ccna-deck` and `sap-deck`. They stay as carried over;
  one library for them belongs to the port, when the language is chosen,
  because a shared Python or Bash module would be discarded with it.
