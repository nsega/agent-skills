---
name: dual-model-debate
description: >-
  Run a moderated dialectic between two models from two labs to decide a
  question. Claude (opus, via Claude Code) and GPT (gpt-5.6-sol, via codex)
  each argue their honest read, exchange rebuttals, and a neutral Claude
  synthesizes a recommended decision that surfaces the disagreements that
  matter. Use whenever the user wants the two models to "debate", "hash out",
  "argue both sides", get a "dialectic" or a decision on a design question or
  tradeoff, or wants a stress-tested second opinion before committing to a
  direction. Sibling to dual-model-review (which reviews a diff); this one
  decides an open question.
---

# dual-model-debate

Two debaters from two labs argue a question; a neutral Claude decides. Claude is
one debater AND the chair, so the debater turns run in a **subagent** and the
chair context never argues a side. The value is friction that survives scrutiny:
if the two agree, that agreement is stress-tested before it is trusted.

Read `references/protocol.md` first. It defines the turn format, the three roles
(honest opening / rebuttal / forced opposition), and the chair's synthesis and
escalation rules.

## Step 1: Build the packet

```bash
PKT="$(scripts/build_packet.sh "Should we adopt X for Y?" docs/rfc.md notes.md)"
```

The script assembles the packet and prints its path (captured here as `$PKT`,
reused in Steps 2-3). **You fill the framing**
(constraints, non-goals, what a good decision looks like) in the packet before
the debate. Non-goals and constraints cut the most off-target arguments. Any
file the debate needs must be attached here, because the debaters see only the
packet.

## Step 2: Round 0, blind openings

Openings must be blind: neither debater sees the other's opening. Working files
and the saved transcript go in `${DMD_OUT_DIR:-/tmp}`: set `DMD_OUT_DIR` to use a
dedicated directory, or leave it unset for `/tmp` (the same directory
`build_packet.sh` writes the packet to).

1. Dispatch a **subagent** to write Claude's opening from the packet only, using
   the "Honest opening (round 0)" role in `references/protocol.md`, returning
   only the four fields. Do NOT write Claude's argument in this (chair) context.
   Save it to the transcript as a block:

   ```
   ### Claude (opus) (round 0)

   <the four fields the subagent returned>
   ```

   For example: `printf '### Claude (opus) (round 0)\n\n%s\n\n' "$CLAUDE_OPENING" > "${DMD_OUT_DIR:-/tmp}/dmd-transcript.md"`
2. Produce GPT's opening against a FRESH empty transcript so it cannot see
   Claude's:

   ```bash
   D="${DMD_OUT_DIR:-/tmp}"; : > "$D/dmd-gpt.md"
   scripts/codex_turn.sh "GPT (gpt-5.6-sol)" 0 opening "$PKT" "$D/dmd-gpt.md"
   ```
3. Append GPT's opening to the transcript:
   `D="${DMD_OUT_DIR:-/tmp}"; cat "$D/dmd-gpt.md" >> "$D/dmd-transcript.md"`

## Step 3: Exchange or stress-test

Read both openings as the chair.

- **If they disagree:** run up to 2 rebuttal rounds. Each round, first dispatch
  the subagent for Claude's rebuttal (give it the packet AND
  `${DMD_OUT_DIR:-/tmp}/dmd-transcript.md` so far, matching what GPT sees via
  stdin; it appends its block), then run GPT's:

  ```bash
  scripts/codex_turn.sh "GPT (gpt-5.6-sol)" 1 rebuttal "$PKT" "${DMD_OUT_DIR:-/tmp}/dmd-transcript.md"
  ```

  Stop early the moment a round adds no new substantive argument (the chair's
  stall check in the protocol). This caps GPT at 3 paid calls. Use round 2 for the second rebuttal.
- **If they converge** on the same answer: run ONE forced-opposition round.
  Assign codex the contrarian job, so the chair Claude never argues against a
  conclusion it is about to judge:

  ```bash
  scripts/codex_turn.sh "GPT (devil's advocate)" 1 forced "$PKT" "${DMD_OUT_DIR:-/tmp}/dmd-transcript.md"
  ```

## Step 4: Synthesize the decision

As the chair, read the whole transcript and write the brief with the template
below. Save the working transcript under a descriptive name in the same output
directory and link that path, for example:
`D="${DMD_OUT_DIR:-/tmp}"; cp "$D/dmd-transcript.md" "$D/dual-model-debate-<slug>-transcript.md"`.
Apply the escalation rule: on an unresolved subjective call where your only
tiebreak is your own preference, escalate to the human rather than ruling for
Claude's side.

```markdown
# Decision: <slug, 9 words max, names the DECISION not the question>

> Decision at issue: <the fork compressed to the options actually on the table, 45 words max>

## Decision record

| Field | Entry |
| --- | --- |
| Decision | <exactly one verdict, 15 words max> |
| Form | <where it lives / what shape it takes> |
| Not built | <what is explicitly excluded this cycle> |
| Cost | <build cost, then steady-state running cost> |
| Kill switch | <how it gets turned off, or n/a> |
| Confidence | <LEVEL on X, LEVEL on Y (CF ids)> |
| Do today | <the single most time-sensitive action> |
| Open escalations | <n (E ids), or None> |
| Decided / next review | <YYYY-MM-DD / YYYY-MM-DD (C id)> |

## Confidence

| id | Claim | Level | Basis |
| --- | --- | --- | --- |
| CF1 | <one proposition, never two> | FIRM | <20 words max> |

## Do next

- [ ] <action doable today without reopening this note> (→ E<n> if blocked on a call below)

## Escalated to you

| id | The call | Claude | GPT | Why the chair refused | Due |
| --- | --- | --- | --- | --- | --- |
| E1 | <the choice> | <call> | <call> | <why it is yours, not the chair's> | <date> |

## Build ledger

**In scope:** <bulleted, one item per line>
**Not in scope:** <the scope armor; what a later reader must not assume was included>
**Envelope:** <home, sessions, recurring cost, arming rule, carve-outs; 40 words max>

## Checkpoints and kill criteria

| id | Date | Measured | Target | Result |
| --- | --- | --- | --- | --- |
| C1 | <YYYY-MM-DD> | <the quantity> | <the number> | PENDING |

| id | Kill criterion | Evaluated at | Action if hit |
| --- | --- | --- | --- |
| K1 | <observable condition> | <C id> | <the tear-out action> |

**Retarget rule:** <what changes if the target is missed but the approach still holds>

## Disagreement ledger

| id | Topic | Claude's strongest | GPT's strongest | Outcome | Ruled by |
| --- | --- | --- | --- | --- | --- |
| D1 | <topic> | <point> | <point> | CONVERGED | both |

> Strongest dissent (D<n>): <the best losing argument, preserved verbatim, 40 words max>

## Agreed, and how well grounded

| id | Point | Grounding |
| --- | --- | --- |
| G1 | <point> | ASSUMED |

## Why this decision

1. <claim the decision rests on, ending in the ids that support it> (CF1, D2)

## What would flip this

| id | Trigger | How you would notice | Flips to |
| --- | --- | --- | --- |
| F1 | <condition> | <the observation> | <the other option, or a retarget> |

## Provenance and assumptions

| id | Assumption | Grounding |
| --- | --- | --- |
| A1 | Both debaters are language models reading one packet; convergence is inference, not measurement | VERIFIED |

**Question as asked:** <verbatim, the only place it appears in full>

## Appendix

- AP1 <the only place a fenced block, JSON, schema, or shell command may appear>
- AM1 <chair amendments, referenced by id from the Disagreement ledger>

## Transcript and legend

- <path to the saved transcript>
- **Level:** FIRM / MODERATE / WEAK · **Outcome:** RESOLVED→CLAUDE / RESOLVED→GPT / CONVERGED / AMENDED / ESCALATED→E<n> / UNRESOLVED · **Grounding:** VERIFIED / ASSUMED / EXTRAPOLATED · **Result:** PENDING / MET / MISSED / RETARGETED
```

Keep every heading; an empty section says "None." so its presence proves it was
checked, not skipped. `## Appendix` is the one section to omit when empty.

**Five rules that keep the brief scannable.** The failure mode this shape exists
to prevent is a chair pouring six different things into one prose paragraph.

1. **Cap the top, and never put the question in it.** The H1 is 9 words max and
   names the decision. The `Decision` row is 15 words max and holds exactly one
   verdict. H1 through Confidence is 150 words max in total. The verbatim
   question appears only in Provenance.
2. **One claim per field.** Every cell and checkbox asserts exactly one thing. A
   cell needing "and" or "but" to join two propositions is malformed: split it
   into two rows. Confidence gets one row per proposition, so "firm on X but
   moderate on Y" can never merge into a single hedge.
3. **Outcomes are tokens, not sentences.** Every Level, Outcome, Grounding, and
   Result cell holds exactly one uppercase token from the legend, alone, with no
   trailing explanation. If no token fits, the row is wrong. Never write prose
   like "resolved by convergence" in a token cell.
4. **Columns carry attribution.** Who said what is expressed by column position
   only. Never pack topic, Claude's call, GPT's call, and the resolution into one
   bullet joined by a separator.
5. **Every heading renders and every cut is visible.** When a cap binds, the last
   row reads `... and <n> more in the transcript`. Nuance that will not fit a
   cell goes in a short prose block under that table, never back into the top.

The reader returns to this brief at a checkpoint, so `Checkpoints and kill
criteria` owns every date and number: no dated target may live anywhere else,
and the `Result` column is left PENDING for the human to fill in later.

## Governance & operating rules

- **Read-only, packet-only debaters.** codex runs `--sandbox read-only`,
  `--skip-git-repo-check`, and `--ephemeral` in a throwaway `-C` dir with
  `--ignore-user-config`, so it argues from the piped packet, not by editing the
  repo or firing your codex notify hooks and plugins. `--skip-git-repo-check`
  only lets codex run in the non-repo scratch dir; it does not weaken the sandbox.
  Note: `--sandbox read-only` prevents writes/edits, not reads, and "do not read
  files" is a prompt instruction, not a hard boundary, so treat only what you put
  in the packet as exposed to the model (and to OpenAI). The subagent is likewise
  told to argue from the packet only.
- **Bounded cost.** GPT turns are the only paid calls: at most 3 per run (an
  opening plus up to 2 rebuttals, or an opening plus one forced round). Effort
  prints to stderr.
- **Data to OpenAI.** The packet is sent to OpenAI via codex. Do not route
  secrets through it.
- **Parameters.** `CODEX_MODEL` (default `gpt-5.6-sol`), `CODEX_EFFORT` (default
  `high`; low|medium|high|xhigh|max|ultra, where max/ultra need a model that
  supports them, e.g. `gpt-5.6-sol`). Set `CODEX_FAKE=<file>` to replay a canned
  turn instead of calling codex, for a free dry run. `DMD_OUT_DIR` sets the
  directory for the packet and the saved transcript (created if missing; default
  `/tmp`).

## Files

- `scripts/build_packet.sh`: assemble the debate packet (question + context).
- `scripts/codex_turn.sh`: run one blind, read-only GPT turn; append to transcript.
- `references/protocol.md`: turn format, the three roles, chair synthesis/escalation.
