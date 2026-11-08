# searx

Web search through a self-hosted SearXNG, printed as a numbered list that
holds the title, the address and a short snippet. Bash, carried over from
Fedora's `bin-searx` (AGENTS.md, rule 4: it stays as it is until its port).
Exit 2 tells the web-route hook that SearXNG did not answer, so that the
caller falls back to another search.

Installed on both hosts by `modules/common/scripts.nix`.

## Personal values

| Value | How it is read |
| --- | --- |
| the SearXNG URL | `SEARXNG_URL`, else the skill value `web.searxngUrl` of `ravnix.claude.skillValues`, read at run time from `RAVNIX_SKILL_VALUES` or `~/.config/ravnix/skill-values.json` |

Fedora's script had the user's own address as its default. There is none
now: with neither value the script prints a message that names both and exits
2. The `jq` read tolerates a missing file, invalid JSON and a value of the
wrong type, and treats each as "not set".

## Changes from the original

- the built-in default URL is gone (see above);
- the comments that named the user and a policy date are neutral;
- the pointer to the tests names this package.

shellcheck passes at build time without a change. `bashOptions = [ ]`,
because the script sets its own `set -uo pipefail` and errexit would change
what it does.

## Tests

`tests/searx.test.sh`, the check `bin-searx`: a fake SearXNG on the loopback
(no network). Covers the output format, the arguments and the encoding of
a query, redirects, the removal of bidi and zero-width characters, the cut of a
snippet at a word, the exit codes (no results, HTTP 403, nothing listening, a
timeout, malformed JSON), the "down" marker the web-route hook reads and an
unwritable state directory, URL resolution from the variable and from the
skill values, and a start with an empty `PATH` and no home.

## Findings not fixed

- The reader of the skill values (`RAVNIX_SKILL_VALUES`, and for the vault
  `--vault`, then `VAULT_DIR`, then `vault.root`) is a copy of the one in the
  other tools that read them: `searx`, `vault-check`, `agent-doctor`,
  `claude-telemetry`, `ccna-deck` and `sap-deck`. They stay as carried over;
  one library for them belongs to the port, when the language is chosen,
  because a shared Python or Bash module would be discarded with it.
