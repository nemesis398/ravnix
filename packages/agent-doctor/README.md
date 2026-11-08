# agent-doctor

Catches drift in the agent-instruction corpus: the vault's conventions and
role files, the Claude Code skills, and a machine-wide norms document. It
runs four checks (DUPLICATE: a canonical rule restated away from its home;
DEADPATH: a file the instructions cite that is not there; LINECOUNT: a prose
claim "FILE, N lines" that no longer matches; AGREEMENT, which watches
nothing since 2026-10-03) and exits 0 when it finds nothing, as the gate.
Python, standard library only, carried over from Fedora's `bin-agent-doctor`
(AGENTS.md, rule 4). The comments hold the reasons for each rule.

Installed on both hosts by `modules/common/scripts.nix`.

## Personal values

Nothing about where the corpus lives is built in.

| Value | How it is read |
| --- | --- |
| the vault | `VAULT_DIR`, else the skill value `vault.root` (`RAVNIX_SKILL_VALUES`, else `~/.config/ravnix/skill-values.json`); with neither, exit 2 (`--rules` needs none) |
| the skills | `AGENT_DOCTOR_SKILLS`, else `~/.claude/skills` |
| the norms document | `AGENT_DOCTOR_NORMS`, which the module sets from `ravnix.scripts.agentDoctor.normsFile` |

## Changes from the original

- the three fixed paths of the original (the vault, the config repository,
  the skills in it) are the three values above; the config repository's
  second lookup place for cited paths is gone with it;
- without a norms document the rules whose home it is are dropped and
  it is not part of the corpus, so the tool runs a reduced rule set (the
  vault rules and the prose rule) and does not claim coverage it lacks;
- comments that named the user say "the maintainer";
- the shebang is gone (the package adds one);
- flake8 ignores E501 (28 lines) and W503 (3 breaks before a binary operator,
  the style of the file; an ignore list replaces flake8's defaults, which
  ignore it).

## Left out

Nothing.

## Tests

`tests/agent-doctor.test.sh`, the check `bin-agent-doctor`: a fixture corpus.
Covers a clean one, DUPLICATE (with and without a pointer, inside a code
fence, in a role file where replication is deliberate), DEADPATH (a missing
path, the placeholders, a relative path, a path under the home directory),
LINECOUNT (a wrong claim, a right one, a file that does not exist), the
skills and norms variables, a file that is not UTF-8, three hundred roles,
the vault from the variable and from the skill values (a bad file counts as
none), `--rules`, `--quiet` and the exit codes.

## Findings not fixed

- The `LINECOUNT` expression is quadratic in the longest run of letters,
  spaces and dots in a line that has no `.md` in it: a line of 16 KB takes
  0.4 s, one of 160 KB about 40 s. A paragraph written on one line is as
  long as that only in an unusually large file.
- With no vault, `--rules` shows the homes of the vault rules under a
  placeholder directory.
- The reader of the skill values (`RAVNIX_SKILL_VALUES`, and for the vault
  `--vault`, then `VAULT_DIR`, then `vault.root`) is a copy of the one in the
  other tools that read them: `searx`, `vault-check`, `agent-doctor`,
  `claude-telemetry`, `ccna-deck` and `sap-deck`. They stay as carried over;
  one library for them belongs to the port, when the language is chosen,
  because a shared Python or Bash module would be discarded with it.
