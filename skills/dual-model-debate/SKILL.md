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
scripts/build_packet.sh "Should we adopt X for Y?" docs/rfc.md notes.md
```

The script assembles the packet and prints its path. **You fill the framing**
(constraints, non-goals, what a good decision looks like) in the packet before
the debate. Non-goals and constraints cut the most off-target arguments. Any
file the debate needs must be attached here, because the debaters see only the
packet.

## Step 2: Round 0, blind openings

Openings must be blind: neither debater sees the other's opening.

1. Dispatch a **subagent** to write Claude's opening from the packet only, using
   the "Honest opening (round 0)" role in `references/protocol.md`, returning
   only the four fields. Do NOT write Claude's argument in this (chair) context.
   Save it to the transcript as a block:

   ```
   ### Claude (opus) (round 0)

   <the four fields the subagent returned>
   ```

   For example: `printf '### Claude (opus) (round 0)\n\n%s\n\n' "$CLAUDE_OPENING" > /tmp/dmd-transcript.md`
2. Produce GPT's opening against a FRESH empty transcript so it cannot see
   Claude's:

   ```bash
   : > /tmp/dmd-gpt.md
   scripts/codex_turn.sh "GPT (gpt-5.6-sol)" 0 opening <packet> /tmp/dmd-gpt.md
   ```
3. Append GPT's opening to the transcript: `cat /tmp/dmd-gpt.md >> /tmp/dmd-transcript.md`

## Step 3: Exchange or stress-test

Read both openings as the chair.

- **If they disagree:** run up to 2 rebuttal rounds. Each round, first dispatch
  the subagent for Claude's rebuttal (it reads `/tmp/dmd-transcript.md` so far
  and appends its block), then run GPT's:

  ```bash
  scripts/codex_turn.sh "GPT (gpt-5.6-sol)" 1 rebuttal <packet> /tmp/dmd-transcript.md
  ```

  Stop early the moment a round adds no new substantive argument (the chair's
  stall check in the protocol). This caps GPT at 3 paid calls. Use round 2 for the second rebuttal.
- **If they converge** on the same answer: run ONE forced-opposition round.
  Assign codex the contrarian job, so the chair Claude never argues against a
  conclusion it is about to judge:

  ```bash
  scripts/codex_turn.sh "GPT (devil's advocate)" 1 forced <packet> /tmp/dmd-transcript.md
  ```

## Step 4: Synthesize the decision

As the chair, read the whole transcript and write the brief with the template
below. Save the transcript file and link it. Apply the escalation rule: on an
unresolved subjective call where your only tiebreak is your own preference,
escalate to the human rather than ruling for Claude's side.

```markdown
# Dual-model debate: <question>

**Debaters:** Claude (opus, via Claude Code) · GPT (gpt-5.6-sol, via codex)
**Recommended decision:** <verdict>
**Confidence:** <how firm, and why>

## ⚠️ Escalated to human (unresolved, subjective)
- <disagreement> · Claude: <call> · GPT: <call> · why it needs you: <...>

## Key disagreements (each side's strongest argument)
- <topic> · Claude: <strongest point> · GPT: <strongest point> · resolved: <...>

## Genuine agreement
- <point> (mark "agreement, not verification" where neither side grounded it)

## Deciding rationale
- <why the decision follows from the debate>

## What would change this decision
- <the evidence or condition that would flip it>

## Transcript
- <path to the saved transcript>
```

Keep every heading; an empty section says "None" so its presence proves it was
checked, not skipped.

## Governance & operating rules

- **Read-only, packet-only debaters.** codex runs `--sandbox read-only` in a
  throwaway `-C` dir with `--ignore-user-config`, so it argues from the piped
  packet, not by crawling the repo or firing your codex notify hooks and
  plugins. The subagent is likewise told to argue from the packet only.
- **Bounded cost.** GPT turns are the only paid calls: at most 3 per run (an
  opening plus up to 2 rebuttals, or an opening plus one forced round). Effort
  prints to stderr.
- **Data to OpenAI.** The packet is sent to OpenAI via codex. Do not route
  secrets through it.
- **Parameters.** `CODEX_MODEL` (default `gpt-5.6-sol`), `CODEX_EFFORT` (default
  `high`; minimal|low|medium|high). Set `CODEX_FAKE=<file>` to replay a canned
  turn instead of calling codex, for a free dry run.

## Files

- `scripts/build_packet.sh`: assemble the debate packet (question + context).
- `scripts/codex_turn.sh`: run one blind, read-only GPT turn; append to transcript.
- `references/protocol.md`: turn format, the three roles, chair synthesis/escalation.
