# Multi-pass reviewer #2 for cross-review

**Status:** approved design, pre-implementation
**Date:** 2026-07-20
**Skill:** `skills/cross-review`

## Problem

Reviewer #2 (GLM-5.2 via opencode) is a single call, and that single call is
unreliable in two distinct ways, both found by running the skill on its own
commits:

1. **No output.** On a repo-shaped packet GLM sometimes spends its whole run
   without emitting findings JSON (once because a prose brace broke extraction,
   once because it explored the working tree with tools until its budget ran
   out). Both have been patched, but the underlying exposure remains: one call,
   one point of failure.
2. **High variance.** Two passes over one identical packet at the same effort
   shared **zero** findings. Every real defect this session was caught by a
   single pass, often by only one of the two reviewers. A lone GLM pass is
   therefore a weak detector: a clean pass is weak evidence of "no problems".

Raising reasoning effort does not help (measured: `high` vs `max` made no
reliable difference; run-to-run variance dominated). The durable fix is more
passes, not more effort per pass.

## Goal

Run reviewer #2 as **N independent passes** and **union** their findings, so
coverage improves and a single failed or unlucky pass no longer sinks the
review. Attach an agreement score to each finding so the synthesizer can rank by
it.

### Non-goals

- **Not a vote gate.** Findings are never dropped for appearing in only one pass.
  The variance data shows real findings rarely recur, so a "must appear in ≥K
  passes" filter would suppress genuine bugs (every real find this session was a
  singleton). Recurrence ranks findings; it never removes them.
- **Not multi-pass for Claude.** Reviewer #1 stays a single author-aware pass and
  remains the synthesizer. The variance and reliability problems are GLM's.
- **No semantic cross-pass matching.** Clustering is by normalized location only,
  the same approximation `check_disagreements.sh` already uses. Documented as the
  floor, not the ceiling.
- **No configurable vote threshold.** There is no threshold: nothing is dropped.

## Design

### Confidence model: recall-then-adjudicate

Union every finding across passes. Never drop a singleton. Each finding carries
`pass_count` = how many passes raised it, out of `passes_total` = how many passes
produced valid output. Confidence is a **score and a sort key**, not a filter.
High-recurrence findings float to the top; `pass_count = 1` findings sort last
but still reach the synthesizer and remain fully eligible for Step 4 escalation.

### Components

`glm_review.sh` is unchanged: one pass, one JSON file, already hardened
(tool-less, input-validated, robust extraction). Two new files wrap it.

**`scripts/glm_review_passes.sh <packet> <rubric> <schema> <out_json> [N]`**
- Same first four arguments as `glm_review.sh`, so it is a drop-in replacement:
  it produces the final aggregated `<out_json>` the synthesizer reads. It owns
  the intermediate directory and the aggregator call; callers never see pass
  files.
- Default `N = 3`; overridable by the 5th positional arg or `GLM_PASSES` env.
- Creates a private temp dir (`mktemp -d`), calls `glm_review.sh` N times into
  `<tmp>/pass-<i>.json`, each a fresh opencode session so passes stay
  independent, then calls `aggregate_passes.py <tmp> <schema> <out_json>`.
- Each pass gets its own stderr log (`<tmp>/pass-<i>.err`), fixing the earlier
  shared-`/tmp/glm-err.log` clobber under concurrency. Passes run **serially**
  (opencode contends on a shared session DB when run concurrently, observed as
  `database is locked`).
- Bounded retries per pass: if a pass yields no valid JSON, retry up to
  `GLM_PASS_RETRIES` (default 1) more times. If it still fails, skip it.
- Exit 3 if **zero** passes succeed (never emit an empty review silently).
- Print a one-line summary to stderr: `reviewer #2: <M>/<N> passes succeeded`.

**`scripts/aggregate_passes.py <passes_dir> <schema> <out_json>`**
- Invoked by the wrapper, but a standalone script so it can be tested offline
  against fixture pass files without any opencode call.
- Reads every `pass-*.json` in `out_dir` that is schema-valid.
- Unions all findings; clusters by normalized location using the same `norm()`
  rule as `check_disagreements.sh` (lowercase, strip line numbers and
  parentheticals). A shared helper avoids two copies drifting.
- For each cluster, emit one finding: keep the **highest-severity** instance
  (ties → the one with the longest evidence), and set:
  - `pass_count` = number of passes in the cluster,
  - `id` = the kept instance's id (e.g. `G-002`).
- Document-level `passes_total` = number of passes that produced valid output.
- Sort findings by `pass_count` desc, then severity (critical→low).
- Write `<out_json>` in the per-pass schema plus the two new fields. Validate the
  result against the schema before writing; exit non-zero on validation failure.

### Schema change (`references/findings.schema.json`)

- Add optional `pass_count` (integer, minimum 1) to each finding. Optional so the
  single-pass path and all existing fixtures stay valid, and so `glm_review.sh`
  never has to emit it.
- Add optional `passes_total` (integer, minimum 1) at the document level.
- The aggregator is the only writer of both fields.

### Data flow

```
packet → glm_review_passes.sh   (owns everything in this box)
           ├─ glm_review.sh → <tmp>/pass-1.json   (retry on no-JSON)
           ├─ glm_review.sh → <tmp>/pass-2.json
           ├─ glm_review.sh → <tmp>/pass-3.json
           └─ aggregate_passes.py <tmp> …
         → /tmp/glm-findings.json
           (union, pass_count per finding, passes_total, sorted)
         → synthesizer reads it exactly as it reads a single GLM file today
```

The synthesis side changes minimally: it still opens one `glm-findings.json`. The
Step-4 report gains an agreement annotation per GLM finding, e.g. `GLM 3/3` vs
`GLM 1/3`.

### SKILL.md / playbook updates

- Step 3: reviewer #2 is now `glm_review_passes.sh` (N passes). The synthesizer
  still reads a single aggregated `glm-findings.json`.
- Step 4: `pass_count / passes_total` is a ranking and confidence signal. State
  explicitly that it is **not** a gate: a high-severity `pass_count = 1` finding
  escalates exactly as today.
- Playbook: note the recall-then-adjudicate rationale and the zero-overlap datum
  that motivates never dropping singletons.

### Error handling

| condition | behavior |
|---|---|
| one pass yields no JSON | retry up to `GLM_PASS_RETRIES`, then skip; `passes_total` counts successes only |
| a pass file is schema-invalid | excluded from aggregation, logged; not fatal |
| zero passes succeed | `glm_review_passes.sh` exits 3, no output written |
| concurrent runs | serial by default; per-pass err logs prevent clobber |

`passes_total` always reflects actual successes, so `pass_count / passes_total`
never overstates agreement.

### Testing (offline, no API key)

Add to `tests/run_tests.sh`:
- Three fixture pass files: one finding in all three, one in two, two distinct
  singletons.
- Assert: union has 4 findings; `pass_count` is 3 / 2 / 1 / 1; `passes_total` = 3;
  both singletons present; ordering is `pass_count` desc then severity.
- Degraded case: remove one pass file, assert `passes_total` = 2, no crash, and
  aggregation still validates.
- Aggregator output validates against `findings.schema.json` (including the new
  optional fields).
- The shared `norm()` helper is exercised so it cannot drift from
  `check_disagreements.sh`.

## Decisions locked

- Scope: reviewer #2 (GLM) only.
- Default `N = 3`, override via arg or `GLM_PASSES`.
- Union with recurrence score; never drop singletons.
- Cluster by normalized location (approximate, documented).
- Passes run serially; per-pass err logs.
- New optional schema fields, aggregator-only.
