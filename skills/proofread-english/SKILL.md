---
name: proofread-english
description: >-
  Proofread an English draft (email, Slack message, PR description, commit
  message, design doc, LinkedIn post) and return the corrected text ready to
  paste, plus a short list of the fixes with a one-line reason each, so the
  writer learns from them. Fixes grammar, spelling, punctuation, word choice
  and naturalness while keeping the writer's meaning, voice and register, and
  enforces the writer's house style: no em dashes, no `It's not X, it's Y`
  contrast construction, no semicolons unless strictly necessary. Two modes:
  light (errors only) and polish (also more natural phrasing, the default).
  Use when the user pastes English and asks to "proofread", "check my
  English", "fix the grammar", "does this sound natural?", "polish this",
  "make this sound native", or in Japanese "校正して", "英語をチェックして",
  "添削して", "自然な英語にして", even with no other words beside the draft.
  NOT for: translating Japanese or another language into English from
  scratch, proofreading Japanese, reviewing code, or writing a new draft
  from bullet points (draft it first, then proofread).
---

# Proofread English

A good outcome: the user pastes the corrected text as is, with nothing they
have to undo, and the fix list teaches them one or two things they will get
right next time.

## When to use

- The user gives an English draft and asks for it to be checked, corrected,
  polished or made more natural, in English or Japanese.
- The user pastes an English draft with no instruction at all, right after
  saying they want help with their English.
- The user asks "is this correct?" or "does this sound OK?" about one
  sentence. Treat the sentence as a tiny draft.

Near misses that should not trigger it:

- "How do I say X in English?" from a Japanese idea. That is translation,
  not proofreading.
- A request to write a reply or a post from notes. Write it, keeping the
  style rules below, and offer to proofread only if they ask.
- Code review, or a comment that only questions the technical content.

## Pick the mode and the register first

**Mode.** Default to **polish**. Switch to **light** when the user says
"errors only", "just typos", "grammar only", "最低限", "間違いだけ", or when
the draft is a quotation, a legal or contractual text, or a message where
their exact wording matters.

| Mode | Changes |
|---|---|
| light | spelling, grammar, punctuation, agreement, articles, prepositions, tense, a word that is plainly wrong, and the style rules below |
| polish | everything in light, plus unnatural phrasing, word choice, word order, wordiness, flow between sentences, and a clearer opening line |

Polish still edits like a careful native colleague, not a ghostwriter. Keep
the user's sentences where they already work. Never make the text longer to
make it sound fancier.

**Register.** Infer it from the text and anything the user said, then keep
it. `references/registers.md` has the details for each one.

| Register | Keep |
|---|---|
| Slack or chat | short, casual, contractions, lowercase starts if the user writes that way, no greeting or sign-off added |
| Email | a greeting line and a sign-off if the draft has them, polite but direct, point in the first sentence |
| PR description, commit, issue | plain and factual, imperative commit subjects, Markdown structure, code and identifiers untouched |
| Design doc or report | precise, consistent terms, headings kept, no chattiness |
| LinkedIn or social | warm and personal, short paragraphs, no hype words the user did not use |

## Non-negotiables

- **No em dashes.** Remove every em dash, and never swap in an en dash, a
  spaced hyphen or a double hyphen as a substitute, since the user's rule is
  about the dash as punctuation, not about one character. Rewrite with a
  comma, a colon, parentheses or two sentences.
- **No `It's not X, it's Y` contrast construction**, including its variants
  (`This isn't about X. It's about Y.`, `X is not A, it is B`,
  `It's not just X, it's Y`), since the user finds the pattern formulaic.
  State the positive claim directly, and keep the contrast only as a short
  trailing phrase when it carries information
  (`It's not a config issue, it's a race.` becomes
  `The cause is a race, not the config.`).
- **Semicolons only when strictly necessary**, for example between list
  items that contain commas. Otherwise split the sentence or use a comma and
  a conjunction, since the user avoids semicolons in prose.
- **Keep the meaning.** Never add a claim, a promise, a number, an apology
  or a softener the user did not write, since they will send the text as
  their own.
- **Leave untouched:** code blocks, inline code, commands, identifiers,
  URLs, file paths, product and people's names, numbers, and text quoted from
  someone else, since a "fix" there breaks something or misquotes someone.
  Spelling in an identifier is never a typo to fix.
- **Keep the format:** Markdown, line breaks, lists and @mentions stay where
  the user put them, so the text pastes back cleanly.

## When rules conflict

1. Meaning over polish, since a natural sentence that says something else is
   a wrong sentence.
2. The user's style rules over what a native writer would usually do, since
   the rules are the user's choice. A native writer might reach for an em
   dash here. This user does not.
3. Register over polish, since a Slack message that reads like a formal
   email sounds wrong to its reader.
4. Quoted text and code over the style rules, since they are not the user's
   prose. An em dash inside a quotation from someone else stays, and the fix
   list says so in one line.

Example: a Slack draft says `cant make standup`, then an em dash, then
`stuck on the deploy`. The right output is `Can't make standup, I'm stuck on the deploy.` or, if the user
writes in lowercase, `can't make standup, stuck on the deploy`. It is not
`Unfortunately, I won't be able to attend today's standup meeting.`

## The loop

1. **Read the whole draft once** before changing anything, so a fix in one
   sentence fits the rest.
2. **Pick the mode and the register.** Ask nothing unless the meaning of a
   sentence is truly unclear. Then make the most likely reading, and flag it
   in the fix list (`check: I read "it" as the migration`).
3. **Edit.** Fix the errors, then (polish only) the phrasing. Apply the
   non-negotiables last, over the whole text, including sentences you did not
   otherwise touch.
4. **Check the style rules mechanically** when a shell is available:
   `python3 scripts/check_style.py corrected.txt` (path relative to this
   skill's folder), or pipe the text on stdin. Fix every error it reports.
   For each semicolon warning, keep the semicolon only if it is strictly
   necessary. The checker skips fenced code, inline code and `>` quote lines.
   If no shell is available, reread the text once for each rule instead.
5. **Write the output** in the shape below.

## Output

Write the explanations in the language the user asked in (Japanese if they
asked in Japanese). The corrected text always stays in English.

1. **The corrected text** in one fenced block (`text`, or `markdown` when
   the draft uses Markdown), so it copies cleanly. Use four backticks when
   the draft itself contains a fenced block.
2. **Fixes**, as a numbered list, most instructive first. Each line is the
   original fragment, an arrow, the fixed fragment, a colon, and one short
   reason: `` `I am agree` → `I agree`: "agree" is a verb, so no "am". ``
   Group repeats into one line (`3 missing articles: "the API", "a test",
   "the team"`). Keep the list to about ten lines, and add one line with the
   count of minor fixes left out (`plus 4 small punctuation fixes`).
3. **One pattern to watch**, only when the same kind of mistake shows up two
   or more times: one sentence on the rule behind it.

When the draft needs no change, say so in one line and do not return the
text. When the only change is a style rule, the fix list still names it.

`references/registers.md` has a worked example for each register, with the
before, the after and the fix list.
