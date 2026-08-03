# dual-model-debate: design

- **Date:** 2026-08-02
- **Status:** approved design, pending implementation plan
- **Sibling skill:** `skills/dual-model-review` (blind two-model review). This skill
  reuses that skill's structure and hardening, but changes the *mode* from blind
  parallel review to a moderated **dialectic** that ends in a decision.

## Summary

A skill that runs a structured, multi-turn **debate** about a question between two
models from two different labs, then has a neutral Claude synthesize a recommended
decision. Claude (opus-tier, via Claude Code) is one debater; GPT (`gpt-5.6-sol`,
via `codex exec`) is the other. The value is in the friction: the skill is built so
an easy consensus still gets stress-tested, and so the judge cannot simply rule for
its own side.

## Goal

Given a question plus optional context, produce a **decision brief** (a recommended
verdict with the reasoning and the disagreements that matter) backed by a saved
round-by-round **transcript**.

## Non-goals

- Not a code review. That is `dual-model-review`. This skill decides a question.
- Not an autonomous agent loop. The debaters are read-only and argue from a packet;
  they do not edit the repo.
- Not a convergence engine. The models are not asked to reach agreement; Claude
  decides, and unresolved subjective conflicts are escalated to the human.
- Not unbounded. The round count has a hard ceiling.

## Design decisions (settled during brainstorming)

| Axis | Decision |
|---|---|
| Mode | Dialectic that ends in a recommended decision. |
| Stance | **Hybrid:** each model gives its honest independent read first (blind); if they converge on the same answer, a forced-opposition round fires before the decision. |
| Protocol | **Bounded, early-exit:** blind openings, then up to 2 rebuttal rounds, stopping early when a round adds no new substantive argument. Forced-opposition round only on convergence. |
| Judge bias | Claude's debater turns run in a **subagent**. The main (chair) Claude never argues a side; it reads the transcript fresh and decides. |
| Input | A question plus optional context files. |
| Deliverable | A decision brief plus a separate transcript file. |
| Name | `dual-model-debate`. |
| Turn format | Structured markdown (required headers), not strict JSON. |

## Architecture

Skill-orchestrated, with thin shell helpers, matching `dual-model-review`'s shape.
`SKILL.md` is the playbook; the main Claude context is the chair and drives the
loop; a subagent plays Claude's debater; small scripts do the mechanical work; the
running transcript is a growing file that each codex turn receives on stdin.

Rejected alternatives:

- **One scripted driver runs the whole loop** (shelling out to `claude -p` and
  `codex exec` with heuristic stall detection). Rejected: hardcoding "did the
  argument advance?" as a shell heuristic discards Claude's judgment, and nesting
  `claude -p` inside a Claude session is awkward and lower-nuance.
- **Workflow tool drives it.** Rejected for a shippable skill: a Workflow run is a
  one-off, not an installable `SKILL.md`, and codex is not a subagent type.

### Components

```
skills/dual-model-debate/
  SKILL.md                     # playbook: roles, protocol, bias guards, synthesis, output, governance
  scripts/build_packet.sh      # question + optional context files -> packet.md
  scripts/codex_turn.sh        # run ONE codex turn: read-only, packet + transcript on stdin
  references/protocol.md       # exact per-role turn instructions + chair synthesis/escalation rubric
```

- `build_packet.sh`: from a question string and optional context file paths, emit
  one `packet.md` with the restated question, the author framing (constraints,
  non-goals, "what a good decision looks like"), and the attached context. The
  script assembles the mechanical parts; the human fills the framing fields.
  Analogous to `dual-model-review`'s `gather_artifact.sh`.
- `codex_turn.sh`: run one codex turn via
  `codex exec -m "$CODEX_MODEL" -s read-only -C <scratch>`, with the turn
  instructions passed as the prompt argument and `packet + running transcript` on
  stdin; capture GPT's turn and append it to the transcript. Hardened the way
  `glm_review.sh` is: validate the model id and reasoning effort, verify inputs
  exist and are non-empty before spending, handle codex auth, capture codex's
  stderr for the caller, and never allow repo edits.

### Turn format (structured markdown)

Each turn is these four required fields, so the chair can parse turns and detect
stalls while arguments stay readable. The harness (the turn script) writes the
`### <role> (round N)` heading; the model emits only the fields:

```markdown
**Position:** <one-line stance / recommended answer>
**Argument:** <the case, prose, may be multiple paragraphs>
**Concedes:** <points from the other side this turn grants, or "nothing yet">
**Still unresolved:** <the specific open disagreements this turn does not settle>
```

(Strict JSON envelope, as in the review skill's schema, is the alternative; markdown
was chosen because a debate turn is prose and JSON string-cramming is lossy.)

## Data flow (one run)

1. Claude fills the packet framing and runs `build_packet.sh` -> `packet.md`.
2. **Round 0, blind openings.** The subagent-Claude writes its honest opening from
   the packet only; `codex_turn.sh` produces GPT's honest opening. Neither sees the
   other: each opening is given only the packet. Both are appended to the transcript.
3. **Chair reads both openings.**
   - *If they disagree materially* -> up to 2 rebuttal rounds. Each round: the
     subagent responds to GPT's latest turn; codex responds to Claude's latest turn;
     both are appended. The chair stops early the moment a round adds no new
     substantive argument.
   - *If they converge on the same answer* -> one **forced-opposition** round: codex
     is assigned to steelman the strongest case *against* the consensus. Giving GPT
     the contrarian job keeps Claude from arguing against a conclusion it is about to
     judge. The chair then weighs that case.
4. **Synthesis (neutral chair).** The main Claude reads the whole transcript and
   emits the decision brief, and saves the transcript to a file.

## Bias guards

The subagent split exists for these guarantees:

- The chair Claude **never generates a debater turn**, so at synthesis it genuinely
  has not argued a side.
- When both sides simply agreed, the brief labels it **"agreement, not
  verification"** and never treats consensus as proof.
- On any unresolved **subjective / which-approach** conflict where the chair's only
  ground would be its own preference, it **escalates to the human** rather than
  ruling for Claude's side.

## Output: decision brief template

```markdown
# Dual-model debate: <question>

**Debaters:** Claude (opus, via Claude Code) · GPT (gpt-5.6-sol, via codex)
**Recommended decision:** <verdict>
**Confidence:** <how firm, and why>

## ⚠️ Escalated to human (unresolved, subjective)
- <disagreement> · Claude: <call> · GPT: <call> · why it needs you: <...>

## Key disagreements (each side's strongest argument)
- <topic> · Claude: <strongest point> · GPT: <strongest point> · how it resolved: <...>

## Genuine agreement
- <point> (mark "agreement, not verification" where neither side independently grounded it)

## Deciding rationale
- <why the recommended decision follows from the debate>

## What would change this decision
- <the evidence or condition that would flip it>

## Transcript
- <path to the saved round-by-round transcript>
```

Every heading is kept. An empty section says "None" so its presence proves the step
was checked, not skipped (same discipline as `dual-model-review`).

## Governance, security, cost

- **Read-only, packet-only debaters.** codex runs with `-s read-only` and is
  confined to a scratch `-C` directory, so it argues from the packet rather than by
  crawling the repo. This keeps it symmetric with the subagent, which is likewise
  instructed to argue from the packet. Relevant files belong *in* the packet.
- **Bounded cost.** Only GPT turns are codex calls (Claude's turns run in the
  subagent), so the ceiling is 3 codex calls per run: the opening plus up to 2
  rebuttals on the disagree path, or the opening plus one forced-opposition round on
  the converge path. Each call's effort is printed to stderr so the human sees what
  was spent.
- **Data handling.** The packet is sent to OpenAI via codex. Do not route secrets
  through it. (No Entity-List concern as with GLM/Z.ai, but the same "don't send
  internal secrets to a third-party model" rule applies.)
- **Parameters.** `CODEX_MODEL` defaults to `gpt-5.6-sol`; reasoning effort
  validated like `ZEN_VARIANT` in the review skill; the debater Claude runs
  opus-tier (the session's Claude / opus-5).

## Testing

- `CODEX_FAKE` env makes `codex_turn.sh` echo canned output, so the full loop can be
  exercised without paying.
- A sample `packet.md` fixture.
- shellcheck on the scripts.

## Follow-ups (out of scope for this spec)

- `README.md`'s skills table still lists the old `cross-review` name and should be
  updated to `dual-model-review` and gain a `dual-model-debate` row once this ships.
