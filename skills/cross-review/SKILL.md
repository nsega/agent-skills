---
name: cross-review
description: >-
  Run a two-model cross-review of a pull request or a system-design document.
  Claude Code (Opus 4.8) is the main reviewer and synthesizer; a second,
  independent reviewer runs through opencode + GLM-5.2 (OpenCode Zen, paid key)
  for decorrelated blind spots. Use this whenever the user asks to "cross-review",
  wants a "second opinion" on a PR or design, says "review this with GLM",
  "run the panel", or wants higher-confidence review of an architecture doc,
  RFC, or diff before merging or sign-off. Trigger even when they just paste a
  diff or design and ask "what did we miss?".
---

# cross-review

Two independent reviewers, two different labs (Anthropic + Z.ai), so their blind
spots do not line up. You (Claude Code / Opus 4.8) are reviewer #1 **and** the
synthesizer. GLM-5.2 via opencode is reviewer #2, tilted toward dissent. The
value is in the **disagreements** — surface them, never average them away.

> **"Cross" means cross-lab, not reciprocal.** The two reviewers never see each
> other's findings; you synthesize both. You are therefore a disputant *and* the
> chair, which is a standing bias, not a detail. Step 4 exists to contain it.

## Topology

```
            ┌─ you (Opus, author-aware) ─► claude-findings.json ─┐
artifact ──►│                                                    ├─► SYNTHESIS ─► report
            └─ GLM-5.2 (opencode, blind) ─► glm-findings.json ───┘
```

Both reviewers review **blind**. You also synthesize, so enforce blindness
manually: **write your own findings to disk before reading GLM's.** Better:
spawn a **subagent** for your review so the synthesizing context never sees the
artifact's authoring intent. Note your self-review is *author-aware*, not fully
independent — when you and GLM conflict on **design/architecture**, weight GLM's
view up; on **correctness**, your author knowledge is an asset, do not discount it.

## Stakes first: lite vs full

Pick the tier before doing work (effort-routing):

- **lite** (daily PR): minimal packet, GLM one pass + your synthesis, `must fix`
  only, Claude self-check, brief summary. GLM at **High** effort.
- **full** (high-risk PR / system design): full packet, both review blind, full
  disposition + conflict isolation, delta-review, F-ID-tracked summary. GLM at **Max**.

## Step 1 — Identify the target

- **pr** — a diff. base ref (default `origin/main`), optional branch/range.
- **design** — a markdown design doc / RFC. A file path.

## Step 2 — Build the packet

```bash
scripts/gather_artifact.sh pr     origin/main --level full     # or --level minimal
scripts/gather_artifact.sh design docs/rfc.md  --level full --tests test.out
```

The script fills mechanical fields (changed files, diff/doc, test results). **You
fill the author fields** (background / purpose / non-goals / key decisions /
known worries / what to review)
before sending to reviewers — non-goals and known-worries cut the most off-target
findings. Even `minimal` keeps purpose + non-goals + diff + test results.

## Step 3 — Launch GLM, then review yourself

Kick off GLM first; **do not open `glm-findings.json` until step 4.**

```bash
scripts/glm_review.sh <packet> references/rubric.md \
  references/findings.schema.json /tmp/glm-findings.json
```

Then do your own review against `references/rubric.md` (read it + the schema now).
Emit `/tmp/claude-findings.json` per `references/findings.schema.json`,
`"reviewer": "claude-opus-4.8"`. **Each reviewer prefixes its finding ids**
(`C-001…` for you, `G-001…` for GLM). Honor the schema: Evidence is required for
critical/high and for correctness/security; critical/high also need a failure_case.
Every finding also needs a `recommendation` (`must_fix` / `should_fix` / `defer` /
`nit`) — that is your reviewer-hat call, and it is what makes the "reviewers
disagree" escalation triggers in Step 4 checkable. Commit to it here, before you
have seen GLM's, and do not revise it during synthesis; overruling it later is a
**disposition**, recorded as such.

## Step 4 — Synthesize (the actual work)

Read **both** `/tmp/claude-findings.json` and `/tmp/glm-findings.json` now, then
run the mechanical check before you reason about any of it:

```bash
scripts/check_disagreements.sh /tmp/claude-findings.json /tmp/glm-findings.json
```

It prints the pairs that trip the escalation triggers below. Treat its output as
the floor, not the ceiling: it matches on location, so it cannot see the cases in
4.1 where the same issue is described two different ways.

1. **Cluster + dedupe** the same issue across both reviewers; keep the clearest
   evidence + suggestion. Disagreement is only detectable when both reviewers'
   findings land on the **same** F-ID, so before you conclude there are no
   conflicts, scan for adjacent locations and overlapping issues that you filed
   separately and compare their recommendations. When the two reviewers' severities
   differ on a clustered finding, **record the higher one**.
2. **Reassign canonical ids** `F-001, F-002, …` to merged findings.
3. **Order** by `severity × confidence` (`high × high` first). Never filter on
   confidence — a `low confidence × high severity` item still reaches a human.
4. **Isolate conflicts, but escalate only the ones that matter.** Send to the
   human a conflict when ANY of:
   - **either** reviewer rated it high+ and the two reviewers' `recommendation`
     values differ (a GLM finding with **no** `recommendation` counts as
     differing — fail toward escalation, never toward silence);
   - it touches security / data loss / migration / public API;
   - you are about to disposition `reject` on a finding the other reviewer
     recommended `must_fix`;
   - you are about to disposition `reject` or `defer` on a finding **you**
     recommended `must_fix` in `/tmp/claude-findings.json`. Overruling your own
     pre-GLM call is the one conflict with no second reviewer to catch it;
   - low confidence but high severity;
   - **you are downgrading a GLM finding it rated high+ to `defer` or `reject`.**
     You are the disputant here, so that call is not yours to make privately.
   Lower-risk conflicts: make a provisional call yourself and just note it in the
   summary. Do not inflate verdicts to look thorough.

   Three rules bind you specifically, because you are also the chair:
   - **Tie-break toward escalation.** If it is arguable whether a conflict clears
     the bar, it clears the bar. A spurious escalation costs one line; a
     suppressed blocker costs the incident.
   - **No self-resolution on design.** On a design/architecture conflict, if
     author knowledge is your only ground for your side, you may not settle it:
     either GLM's read stands, or it goes to the human. Author knowledge settles
     **correctness** conflicts, not taste or structure. Design conflicts you can
     settle on grounds visible in the artifact itself still follow the normal
     escalation bar above.
     **Do not launder a design conflict into a correctness one.** You assign the
     category at synthesis, so it is the one lever that could void this rule:
     for a GLM-raised finding use **GLM's** original category, and if it is
     arguable whether a conflict is correctness or design, treat it as design.
   - **Account for every dropped GLM finding.** Any GLM finding you do not adopt
     ("not adopted" = it never received an F-ID; a GLM finding that got an F-ID
     and was then rejected belongs under Disposition with its reject reason)
     gets listed under "Not adopted" with a reason, even below the escalation
     bar. Silent drops are the failure mode this whole topology exists to
     prevent. **In lite one grouped line suffices** (`Not adopted: G-002, G-005
     — below must-fix bar`); itemized per-finding reasons are required in full.
5. **Disposition** each finding: `must fix` / `should fix` / `defer` / `reject`.
   `reject` requires a reason. This turns the review into a design decision, not
   an AI vote.

   A **recommendation** is a reviewer's call on its own finding (`must_fix` /
   `should_fix` / `defer` / `nit`, schema-enforced); a **disposition** is yours as
   chair, over the merged finding. They are different vocabularies on purpose. Fill
   the `Claude rec` and `GLM rec` cells of the report **verbatim from the two JSON
   files**, never from memory: your own recommendation was committed in Step 3
   before you saw GLM's, and that ordering is the only thing making the first
   trigger meaningful. If your view has since changed, that is a disposition and
   is recorded as one; it does not rewrite what you recommended.

## Step 5 — Fix and delta-review

After fixing the `must fix` items:

- **default**: you self-check the fix diff against the `must fix` F-IDs.
- **high-risk** (security / data loss / migration / public API): run a GLM
  **delta-review** — pass only the fix diff + the F-IDs it should resolve, and
  ask GLM two things: (a) is each listed finding actually resolved, (b) did the
  fix introduce a regression. Do not re-send the whole artifact.
- **major design change**: run the delta-review in a **fresh GLM session** to
  restore independence.

```bash
git diff > /tmp/fix.diff
# wrap /tmp/fix.diff + "verify F-001,F-004 resolved; check for regressions" as the bundle
scripts/glm_review.sh /tmp/fix-bundle.md references/rubric.md \
  references/findings.schema.json /tmp/glm-delta.json
```

## Output — ALWAYS use this exact template

```markdown
# Cross-review: <target>  (<lite|full>)

**Reviewers:** Claude Opus 4.8 (author-aware) · GLM-5.2 (via OpenCode Zen)
**Verdict:** <approve | approve_with_nits | request_changes | block>

## ⚠️ Escalated to human (high-risk conflicts)
- [F-00x][<location>] Claude rec: <must_fix|should_fix|defer|nit> · GLM rec: <same enum, or "not raised"> · my disposition: <must fix|should fix|defer|reject> — <why it matters>

## Consensus findings (both reviewers)
- **[F-00x][severity][category]** <location> — <issue>. *Evidence:* <…>. *Fix:* <…>

## Single-reviewer findings
- **[F-00x][severity][category][C|G]** <location> — <issue>. *Fix:* <…>

## Disposition
- must fix: F-001, F-004 · should fix: F-006 · defer: F-002 · reject: F-007 (<reason>)

## Not adopted (GLM findings I dropped)
- [G-00x][<location>] <finding> — <why not adopted>

## After fix
- F-001 fixed · F-004 fixed · delta-review: <clean | findings>

## Residual risk / for the human
- ...
```

Keep every heading. If a section is empty, write "None" — its presence proves it
was checked, not skipped.

## Governance & operating rules (do not skip)

- **Read-only reviewers.** They analyze; they do not edit the repo.
- **Zen, US-hosted, paid tier only.** GLM-5.2 = `opencode/glm-5.2` (zero-retention).
  **Never** route internal code through Z.ai's own API. Confirm the Zen workspace
  has all free / data-collecting tiers disabled and `small_model` pinned (see `config/`).
- **Entity-List determination on file.** Z.ai is on the US BIS Entity List; this
  skill assumes your organization's compliance has approved MIT-licensed GLM
  weights via a US host for internal artifacts. If that lapses, swap reviewer #2
  to a non-listed lab
  (Gemini/Vertex, GPT-5.5/Azure) — topology unchanged.

## Files

- `scripts/gather_artifact.sh` — build the packet (`--level full|minimal`, `--tests`).
- `scripts/glm_review.sh` — run reviewer #2, capture JSON findings.
- `scripts/check_disagreements.sh` — list the pairs that trip the Step 4 triggers
  (location-matched; the floor, not the ceiling).
- `tests/run_tests.sh` — offline regression tests for the contract + the checker.
- `references/rubric.md` — severity/category source of truth + lenses (read before reviewing).
- `references/findings.schema.json` — findings contract (Evidence/Failure-case rules, ids).
- `config/opencode.zen.json` — hardened opencode config (Zen + GLM-5.2 Max).
- `cross-review-playbook.md` — the method/rationale (human-facing).
