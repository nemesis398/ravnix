# English

American spelling: `organize`, `behavior`, `color`, `center`, `license` as both
noun and verb, `analyze`. That is what the vault already uses.

## Dashes

`—` never appears. Neither does a spaced ` – ` as a sentence interrupter, which
is the British habit and is not the convention here. Restructure instead, and
the restructure is usually an improvement, because the dash was hiding a
decision the sentence had not made.

```
bad     The container starts in under a second — fast enough for us.
good    The container starts in under a second, which is fast enough for us.
good    The container starts in under a second. Fast enough for us.
```

The en dash survives for ranges and for paired opposites: `2020–2024`,
`pages 341–356`, `the Berlin–Munich route`.

Hyphenate compound modifiers before a noun, not after it, and never after an
`-ly` adverb.

```
a well-documented setup          the setup is well documented
a self-hosted server             the server is self hosted
a fully managed service          (no hyphen after "fully")
```

## Commas

**The comma splice is the one to watch.** Two complete sentences joined by a
comma need a semicolon, a period, or a conjunction.

```
bad     The backup ran, it finished in ten minutes.
good    The backup ran. It finished in ten minutes.
good    The backup ran, and it finished in ten minutes.
```

Use the serial comma and use it consistently: `analytics, error tracking, and
backups`.

No comma before a restrictive `that`. A comma before `which` only when the
clause is genuinely parenthetical.

## German interference

This is the section worth rereading even when the English looks fine, because
these errors survive proofreading. They are real English words in real
sentences, so nothing underlines them, and LanguageTool passes most of them
without comment.

### False friends

| Written | Means in English | Intended |
|---|---|---|
| eventually | in the end | eventuell → possibly, maybe |
| actual, actually | real, in fact | aktuell → current, currently |
| become | turn into | bekommen → get, receive |
| sensible | reasonable | sensibel → sensitive |
| brave | courageous | brav → well-behaved |
| gift | present | Gift → poison |
| also | in addition | German *also* → so, therefore |
| chef | cook | Chef → boss, manager |
| handy | convenient | Handy → mobile phone |
| control | to steer | kontrollieren → to check |
| realize | to notice | realisieren → to implement |
| concept | abstract notion | Konzept → design, plan |
| protocol | formal procedure | Protokoll → log, minutes |
| provision | supply | Provision → commission |
| term | period, word | Termin → appointment, deadline |
| overseen | supervised | übersehen → overlooked |
| spend | to pay out | spenden → to donate |
| engagement | commitment to marry | Engagement → involvement |
| meaning | sense | Meinung → opinion |
| study | to learn | Studium → degree |

### Uncountables that get a plural

`information`, `software`, `hardware`, `advice`, `research`, `feedback`,
`training`, `knowledge`, `equipment`, `evidence`, `staff`, `progress`.

```
bad     I sent you some informations and two advices.
good    I sent you some information and two pieces of advice.
```

### Tense and preposition

- **Duration takes `for`, not `since`.** `I have had it for two years`, not
  `since two years`. `since` only marks a starting point: `since 2024`.
- **A deadline takes `by`, not `until`.** `Send it by Friday` means the
  deadline. `until Friday` means the activity continues up to then.
- **A finished past event takes the simple past.** `I saw him yesterday`, not
  `I have seen him yesterday`. German merges these two tenses and English does
  not.
- `at the moment`, not `in the moment`.
- `discuss the issue`, not `discuss about it`.
- `explain it to me`, not `explain me it`.
- `answer the question`, not `answer to the question`.
- `depends on`, not `depends of`.
- `most people`, not `the most people`.

### Habits that read as translated

`respectively` is almost never the right word for `beziehungsweise`. Usually
the answer is `or`. `resp.` is not English at all.

Nouns stay lowercase mid-sentence, however wrong that feels.

## Machine-shaped English

Structural, so a word filter will not fix them. The full reasoning is in
SKILL.md; this is the checklist.

**Antithesis padding.** `It's not just X, it's Y`. `This isn't about A, it's
about B`. It sounds like insight and carries none. State the thing.

**Throat-clearing.** `It's worth noting that`, `It's important to understand`,
`In today's landscape`, `When it comes to`. Delete the opener, keep the fact.

**Announcing instead of saying.** `Let's dive into the numbers` followed by the
numbers. Cut the first half.

**The paragraph that restates itself.** A closing sentence that summarises what
was just said, and a `## Conclusion` on a note that is eight lines long.

**Uniform bullets.** Every item the same length and the same grammatical shape.
Real observations are uneven, so even bullets read as generated.

**Empty intensifiers.** `seamless`, `robust`, `powerful`, `comprehensive`,
`crucial`, `vital`, `leverage`, `delve`, `game-changer`, `unlock`. If a
sentence still works with the word deleted, delete it.

**Paired adjectives.** `fast and efficient`, `robust and scalable`, `powerful
and flexible`. Two vague words are not more precise than one.

**The rule of three every time.** Real lists are sometimes two things and
sometimes five.

**Uniform sentence length.** The strongest tell of the lot. Break it
deliberately.

## Numbers and dates in English

| | |
|---|---|
| Thousands | `5,000` |
| Decimal | `3.5` |
| Percent | `40%`, no space |
| Date | `July 27, 2026` or ISO `2026-07-27` |
| Time | `2:30 p.m.` or `14:30` |
| Ranges | `10–40%`, en dash without spaces |

German formats leaking into English prose (`27.07.2026`, `5.000`, `3,5`,
`40 %`) are the mirror image of the interference errors above, and just as
visible to the reader.
