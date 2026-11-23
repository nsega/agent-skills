# Registers and worked examples

Read the section for the draft's register before editing. Each one says what
to keep, what to fix first, and shows a before, an after and a fix list. In
the "before" texts, a double hyphen (`--`) stands in for an em dash, so this
file stays free of the character it bans.

## Slack or chat

Keep: the length, the casual tone, contractions, emoji, @mentions, and
lowercase sentence starts if the user writes that way. Do not add a greeting,
a sign-off, "please" or "thanks" the user did not write.

Fix first: missing subjects that make a line ambiguous, wrong tense, and
article errors. A dropped subject that reads naturally in chat
(`looking into it`) stays.

Before:

```text
@Ken I checked the logs -- the job is failed because of OOM. I will increase memory limit and rerun it, it's not a code bug, it's a sizing issue.
```

After (polish):

```text
@Ken I checked the logs. The job failed because it ran out of memory (OOM), so it's a sizing issue rather than a code bug. I'll raise the memory limit and rerun it.
```

Fixes:

1. `--` → `.`: em dash removed, two sentences read faster in chat.
2. `is failed` → `failed`: "fail" is not used in the passive here.
3. `it's not a code bug, it's a sizing issue` → `it's a sizing issue rather than a code bug`: states the cause directly.
4. `increase memory limit` → `raise the memory limit`: the limit is a specific one, so "the".
5. `I will` → `I'll`: contraction fits the chat register.

## Email

Keep: the greeting line and the sign-off if the draft has them (do not add
them if it does not), the user's level of formality, and every name and
date.

Fix first: put the point or the ask in the first sentence when it is buried,
remove stacked politeness (`I would be grateful if you could kindly`), and
fix the article and preposition errors that read as non-native.

Before:

```text
Hi Sarah,

Thank you for your reply. I wanted to ask about the contract renewal. Regarding to the rent, could you please let me know if there is any possibility to keep the current price; we have been here for 3 years.

Best,
Naoki
```

After (polish):

```text
Hi Sarah,

Thank you for your reply. Could we keep the rent at the current price for the renewal? We have lived here for three years.

Best,
Naoki
```

Fixes:

1. `Regarding to` → (removed): the phrase is "regarding" or "with regard to", and the question no longer needs it.
2. `could you please let me know if there is any possibility to keep` → `Could we keep`: the direct question is clearer and still polite.
3. `;` → `?` and a new sentence: semicolon removed, and the ask now ends as a question.
4. `have been here for 3 years` → `have lived here for three years`: "lived" says what "been here" means, and small numbers are spelled out in prose.
5. `I wanted to ask about the contract renewal.` → merged into the question: the ask now comes first.

## PR description, commit message, issue

Keep: Markdown headings, lists and checkboxes, code blocks and inline code
exactly as written, the repository's template sections, and the imperative
mood in a commit subject (`Fix`, `Add`, never `Fixed` or `Adds`).

Fix first: tense consistency (present tense for what the change does), vague
words (`some`, `stuff`), and long sentences that hide the change. Never fix
the spelling of an identifier, a flag or a file name.

Before:

```markdown
This PR fixes the bug that `ClusterQueue` was not reconcile when the
`spec.cohort` is changed -- now we requeue it. Also added some test.
```

After (polish):

```markdown
This PR fixes a bug where a `ClusterQueue` was not reconciled when its
`spec.cohort` changed. The controller now requeues it. It also adds unit
tests for the cohort change.
```

Fixes:

1. `was not reconcile` → `was not reconciled`: passive voice needs the past participle.
2. `the bug that` → `a bug where`: "where" introduces the situation the bug happens in.
3. `--` → `.`: em dash removed, the second idea gets its own sentence.
4. `Also added some test.` → `It also adds unit tests for the cohort change.`: present tense like the rest, plural "tests", and a concrete scope. Check: I assumed these are unit tests.

## Design doc or report

Keep: headings, numbered lists, defined terms, and the user's term for each
concept. Use one term per concept throughout. If the draft uses both
"workload" and "job" for the same thing, keep the first one and list the
change.

Fix first: undefined pronouns (`this`, `it`) at the start of a paragraph,
hedges that hide a decision, and sentences over about 30 words.

## LinkedIn or social

Keep: the first person, the user's warmth, short paragraphs, hashtags and
mentions. Do not add hype words (`thrilled`, `game-changer`, `delighted to
announce`) the user did not write.

Fix first: the opening line, since it is the only line most readers see.
Check that it says what happened in plain words.

## Output in Japanese

When the user asked in Japanese, the fix list is in Japanese and the
corrected text stays in English.

```text
I'll share the slides after the meeting.
```

修正点:

1. `I will share slides after meeting` → `I'll share the slides after the meeting`: 特定のスライドと会議を指しているので、どちらにも "the" が必要です。
