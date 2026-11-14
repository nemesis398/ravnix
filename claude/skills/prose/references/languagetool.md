# LanguageTool

The second pass in `scripts/check.py`. It exists because it fails
independently: it catches comma placement and agreement inside long German
sentences, which is exactly the class of error a language model is worst at
spotting in its own output.

## Backend chain

The script tries these in order and uses the first that answers, so it keeps
working whatever the account allows on a given day.

1. **Self-hosted**, if `LANGUAGETOOL_SERVER` is set and reachable. No text
   leaves the machine and there are no rate limits. It runs the open source
   rules only, so the premium rules are not available this way.
2. **Premium cloud**, if `LANGUAGETOOL_USERNAME` and `LANGUAGETOOL_API_KEY` are
   both set. `https://api.languagetoolplus.com`.
3. **Free cloud**, always available. `https://api.languagetool.org`, no
   account.
4. **hunspell**, if nothing above answers. English spelling only, and the
   output says so rather than implying a grammar check happened.

`--selftest` prints which one answers and what tier it actually gives.

## Credentials

The API key is a secret and is never kept in a file: not in either
repository of ravnix and not on the disk. Two sources, reported by
`--selftest`, the environment first:

1. **Environment variables.** `LANGUAGETOOL_API_KEY` and
   `LANGUAGETOOL_USERNAME`, for a shell that already holds them; on a ravnix
   host `ravnix.shell.secretEnv` can put them into Claude Code's environment
   from the same vault. `LANGUAGETOOL_SERVER` names a self-hosted server.
2. **Bitwarden via `rbw`**, the item that the skill value
   `prose.languagetool.item` names (by name or id): the key in its password
   field, the account in its username field. It probes `rbw unlocked` first
   and skips itself when the vault is locked, so an unattended run never
   blocks on a pinentry prompt. `--unlock` allows the prompt when wanted.
   Without the value the checker says to set it and goes on with the free
   tier.

The key must never go into the notes vault or any other synced tree, because
those sync to other devices.

LanguageTool documents the API as a separate plan from the consumer Premium
subscription, and their own help pages point Premium holders at support for a
private-use key. **In practice the key from the account settings authenticates
against `api.languagetoolplus.com` directly**, verified 2026-07-27: the probe
comes back without a `premiumHint`, which is the field that actually proves
premium rules ran. No support request was needed. If that ever changes the
chain simply falls through to the free tier.

## Limits

| | Free | Premium |
|---|---|---|
| Requests per minute | 20 | 80 |
| Characters per minute | 75,000 | 300,000 |
| Characters per request | 20,000 | 60,000 |

The script chunks at 18,000 characters, under the lower ceiling, so the same
code path works on either tier.

A long document therefore spans several requests and can brush the per-minute
limit. Transient failures, 429 and the 5xx family, are retried twice with a
backoff. If a chunk still fails it becomes an `LT-CHUNK-FAILED` **error**
naming the line range that went unchecked, and the run exits non-zero.

That severity is deliberate. This was caught in practice: one run of this very
file reported 1 warning where every other run reported 40, because a chunk had
quietly dropped. A verification tool that reports fewer problems when it is
partly broken is worse than one that refuses to answer.

## Self-hosting

Worth doing for anything confidential, since nothing then leaves the network.

```bash
docker run -d --name languagetool -p 8081:8010 \
  -e langtool_languageModel=/ngrams \
  -v /path/to/ngrams:/ngrams \
  erikvl87/languagetool
```

Then set `LANGUAGETOOL_SERVER=http://localhost:8081`. The n-gram data is
optional and improves confusion-pair detection, which is the part that catches
`das` against `dass`.

## Filtering

`LT_DISABLED_RULES` in the script turns off rules that argue with this skill's
own policy, chiefly `DASH_RULE`, which suggests em dashes, and the rules that
fire constantly on note-shaped markdown such as bullets that legitimately start
lowercase and carry no full stop.

Three more filters exist specifically because of what premium returns. All
three were measured on real notes, not guessed at.

**`LT_RECOMMENDATION_*` is dropped entirely.** Premium injects adverts for the
browser plugin and the login as if they were matches. Showing those beside real
errors is how a checker loses its credibility.

**`QB_NEW_*` is demoted to a warning.** These QuillBot-derived premium rules
declare `issueType=grammar` or `misspelling`, so at face value they arrive as
errors, and this skill says to fix every error. On one real note that would
have forced 23 wrong edits: capitalising `restic`, lowercasing Hetzner's actual
product name "Storage Box", and turning a statement into a question. They are
still worth reading, so they stay, as warnings. After the demotion that same
note reports 0 errors and 15 warnings.

**Casing complaints go through the dictionary, case-insensitively.** A term
listed in `IGNORE_WORDS` or the personal dictionary keeps whatever casing it
was written with, which is what stops `restic` becoming `Restic`.

Premium also reads a markdown table row as running prose and suggests
rewriting `| 3 copies | Live data |` into `3 copies: live`, which would corrupt
the table. Suggestion-class rules are therefore dropped on table rows.

Spelling complaints are filtered against `IGNORE_WORDS` in the script plus
the user's dictionary, `~/.config/prose/dictionary.txt`, one word per line,
which is the place to add terms as they come up rather than editing the
script. On a ravnix host ravnix-dict keeps that file in step with the other
tools' dictionaries. The list that ships beside the skill is read only when
that file does not exist.

Anything LanguageTool flags inside masked regions is dropped, because a
spelling error inside a command name or a wikilink target cannot be fixed
without breaking the thing it names.

## Two findings worth keeping written down

Both were established empirically against the live API, and both silently
corrupt results if assumed the other way.

**Offsets are UTF-16 code units, not codepoints.** LanguageTool runs on the
JVM. Every emoji before a finding shifts its reported position by one, and the
error accumulates down the document. In a vault where headings are labelled
with emoji this is not a corner case, it is every file. The script converts
with `utf16_prefix` and `utf16_to_codepoint`.

**`interpretAs` does not shift offsets.** When the `data` parameter is used,
markup counts toward offsets at its full original length and the `interpretAs`
replacement contributes nothing. So offsets are simply positions in the
original document, once the UTF-16 conversion above is applied. No plaintext
mapping layer is needed, and building one produces wrong answers.

One more, smaller: `software.premium` in the response is `true` even on the
free endpoint, because it describes the build rather than the request. The
field that actually tells you is `premiumHint`, which is present exactly when
premium rules were **not** applied.

## Mixed-language documents

The script splits the document into paragraphs, detects the language of each,
merges neighbours that agree, and sends each stretch under its own language
code. Sending a mixed file as one language means the English paragraphs get
German grammar rules and no English spellcheck at all, which looks like a clean
result and is not one.
