---
name: dual-model-review
description: >-
  Run a two-model review of a pull request or a system-design document.
  Claude Code is the main reviewer and synthesizer; a second, independent
  reviewer runs through opencode + GLM-5.2 (OpenCode Zen, paid key) for
  decorrelated blind spots. Use this whenever the user asks to "cross-review",
  wants a "second opinion" on a PR or design, says "review this with GLM",
  "run the panel", or wants higher-confidence review of an architecture doc,
  RFC, or diff before merging or sign-off. Trigger even when they just paste a
  diff or design and ask "what did we miss?".
---

# dual-model-review

Two independent reviewers from two different labs (Anthropic + Z.ai), so their
blind spots do not line up. You are reviewer #1 **and** the synthesizer; GLM-5.2
via opencode is reviewer #2, blind. The value is in the **disagreements**:
surface them, never average them away.

Both reviewers review **blind** (neither sees the other's findings). You also
synthesize, so you are a disputant *and* the chair. Two habits contain that bias:
write your own findings before you open GLM's, and when you and GLM conflict on
**design/architecture**, weight GLM's read up (you know the authoring intent, so
you are not neutral there); on **correctness**, your knowledge is an asset.

## Step 1: Build the packet

```bash
scripts/gather_artifact.sh pr     origin/main --level full   # or --level minimal
scripts/gather_artifact.sh design docs/rfc.md  --level full --tests test.out
```

The script fills the mechanical fields (changed files, diff/doc, test results).
**You fill the author fields** (background / purpose / non-goals / key decisions
/ known worries / what to review) before sending it to the reviewers. Non-goals
and known-worries cut the most off-target findings.

## Step 2: Review it yourself, then run GLM

Do your own review first and **write it to `/tmp/claude-findings.json` before you
run GLM**, so GLM's output cannot anchor yours. Review against
`references/rubric.md` and emit findings per `references/findings.schema.json`
with `"reviewer": "claude-opus-4.8"` and `C-###` ids. (Better: run your review in
a subagent, so the synthesizing context never saw the authoring intent.)

Then run reviewer #2:

```bash
scripts/glm_review.sh <packet> references/rubric.md \
  references/findings.schema.json /tmp/glm-findings.json
```

GLM reviews blind, at max effort, and its output is schema-validated (a finding
missing required Evidence / failure_case / recommendation is rejected, not
silently accepted). It writes `/tmp/glm-findings.json` with `G-###` ids.

> A single GLM pass is a **noisy** detector: two passes over the same packet can
> share few findings. Treat a clean pass as weak evidence, and for a high-stakes
> review run `glm_review.sh` two or three times into different files and union
> the findings yourself. That is the whole reliability story; there is no
> aggregation script to run.

## Step 3: Synthesize (the actual work)

Read both findings files now and merge them into one report:

1. **Cluster + dedupe.** Same issue from both reviewers becomes one finding
   (renumber to `F-###`); keep the clearest evidence and suggestion. When the two
   disagree on severity for a merged finding, record the **higher** one.
2. **Escalate real disagreements to the human.** Where you and GLM genuinely
   differ on a **high-severity** finding, one says fix it and the other shrugs,
   surface that conflict; do not quietly split the difference. On
   design/architecture conflicts where your only ground is author knowledge,
   GLM's read stands or it goes to the human, since you are not a neutral judge
   there.
3. **Never silently drop a GLM finding.** If you do not adopt one, say so and why
   (a one-line "not adopted: G-002, below the bar" is enough). Silent drops are
   the exact failure this two-reviewer setup exists to prevent.
4. **Disposition, do not vote.** Give each finding `must fix` / `should fix` /
   `defer` / `reject`; `reject` needs a reason. This makes the review a design
   decision, not an AI tally.

## Output: use this template

```markdown
# Cross-review: <target>

**Reviewers:** Claude (author-aware) · GLM-5.2 (via OpenCode Zen)
**Verdict:** <approve | approve_with_nits | request_changes | block>

## ⚠️ Escalated to human (disagreements that matter)
- [F-00x][<location>] Claude: <call> · GLM: <call> · why: <why it matters>

## Consensus findings (both reviewers)
- **[F-00x][severity][category]** <location>: <issue>. *Evidence:* <…>. *Fix:* <…>

## Single-reviewer findings
- **[F-00x][severity][category][C|G]** <location>: <issue>. *Fix:* <…>

## Disposition
- must fix: F-001, F-004 · should fix: F-006 · defer: F-002 · reject: F-007 (<reason>)

## Not adopted (GLM findings I dropped)
- [G-00x][<location>] <finding>: <why not adopted>

## Residual risk / for the human
- ...
```

Keep every heading. If a section is empty, write "None": its presence proves it
was checked, not skipped.

## Governance & operating rules

- **Read-only reviewers.** They analyze; they do not edit the repo.
- **Zen, US-hosted, paid tier only.** GLM-5.2 = `opencode/glm-5.2` (zero-retention).
  **Never** route internal code through Z.ai's own API. The hardened
  `config/opencode.zen.json` disables file/exec tools (so GLM reviews only the
  piped packet, staying blind) and pins a paid, zero-retention `small_model`.
- **Entity-List note.** Z.ai is on the US BIS Entity List; this skill assumes
  your org's compliance has approved MIT-licensed GLM weights via a US host for
  internal artifacts. If that lapses, swap reviewer #2 to a non-listed lab
  (Gemini/Vertex, GPT-5.x/Azure); the flow is unchanged.

## Files

- `scripts/gather_artifact.sh`: build the review packet (`--level full|minimal`, `--tests`).
- `scripts/glm_review.sh`: run reviewer #2 (one blind, schema-validated GLM pass).
- `references/rubric.md`: severity/category source of truth + review lenses.
- `references/findings.schema.json`: the per-reviewer findings contract.
- `config/opencode.zen.json`: hardened opencode config (Zen, tools off, paid model).
