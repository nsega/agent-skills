---
name: dual-model-review
description: >-
  Run a two-model review of a pull request or a system-design document.
  Claude Code (Opus 5, high effort) is the main reviewer and synthesizer; a
  second, independent reviewer runs blind through another lab's model:
  GPT-5.6 Sol via the Codex CLI by default, or GLM-5.2 / Kimi K3 via opencode
  as alternates, for decorrelated blind spots. Use this whenever the user asks
  to "cross-review", wants a "second opinion" on a PR or design, says "review
  this with codex" / "with GPT" / "with GLM" / "with Kimi", "run the
  panel", or wants higher-confidence review of an architecture doc, RFC, or diff
  before merging or sign-off. Trigger even when they just paste a diff or design
  and ask "what did we miss?".
---

# dual-model-review

Two independent reviewers from two different labs, so their blind spots do not
line up. You are reviewer #1 **and** the synthesizer; reviewer #2 is a second
lab's model, blind. The value is in the **disagreements**: surface them, never
average them away.

Sibling skill, easy to confuse: `dual-model-debate` **decides an open question**
by having the two models argue it out. This one **reviews an artifact that
already exists** (a diff or a design doc) and merges findings. "Should we do
X?" is debate; "is this X any good?" is review.

| | reviewer #1 | reviewer #2 (default) | reviewer #2 (alt 1) | reviewer #2 (alt 2) |
|---|---|---|---|---|
| `--backend` | n/a | `codex` | `glm` | `kimi` |
| model | `claude-opus-5` | `gpt-5.6-sol` | `glm-5.2` | `kimi-k3` |
| effort | high | high (`CODEX_EFFORT`) | max (`ZEN_VARIANT`) | max (`ZEN_VARIANT`) |
| runs via | Claude Code | Codex CLI | opencode + OpenCode Zen | opencode + OpenCode Zen |
| lab | Anthropic | OpenAI | Z.ai (US-hosted) | Moonshot AI (US-hosted) |
| $/Mtok in-out | n/a | n/a | 1.4 / 4.4 | 3.0 / 15.0 |

`glm` and `kimi` are one code path with different default models, so `ZEN_MODEL`
overrides either and any other Zen model can be tried without touching the
script.

Reviewer #2 is pluggable *because only the CLI changes*: packet, rubric, schema,
prompt, and synthesis are identical across backends. One judgment call worth
knowing: two US frontier labs plausibly correlate more than two labs with very
different training mixes, so on a change where decorrelation matters most (novel
algorithm, unusual threat model) `--backend glm` or `--backend kimi` is the more
independent second opinion. Treat a unanimous clean pass as weak evidence either
way.

**Reliability, as of 2026-08:** prefer `kimi` over `glm` for the opencode arm.
GLM-5.2 via Zen has stalled repeatedly (one `low`-effort run on a 591-byte packet
ran 44 minutes and never returned; one `max`-effort run on a 75KB packet returned
empty after ~10 minutes), while `kimi` returned in under three minutes on the same
packet. Re-check before trusting this note; it is two observations, not a
benchmark.

Both reviewers review **blind** (neither sees the other's findings). You also
synthesize, so you are a disputant *and* the chair. Two habits contain that bias:
write your own findings before you open reviewer #2's, and when you and it
conflict on **design/architecture**, weight its read up (you know the authoring
intent, so you are not neutral there); on **correctness**, your knowledge is an
asset.

## Step 1: Build the packet

```bash
scripts/gather_artifact.sh pr     origin/main --level full   # or --level minimal
scripts/gather_artifact.sh design docs/rfc.md  --level full --tests test.out
```

Use `--level minimal` for a routine PR (keeps purpose, non-goals, diff, and test
results); use `--level full` for a high-risk PR or a system design (adds
background, key decisions, known worries, and a review focus).

The script fills the mechanical fields (changed files, diff/doc, test results).
**You fill the author fields** (background / purpose / non-goals / key decisions
/ known worries / what to review) before sending it to the reviewers. Non-goals
and known-worries cut the most off-target findings.

## Step 2: Review it yourself, then run reviewer #2

Do your own review first and **write it to `/tmp/claude-findings.json` before you
run reviewer #2**, so its output cannot anchor yours. Review against
`references/rubric.md` at **high reasoning effort** and emit findings per
`references/findings.schema.json` with `"reviewer": "claude-opus-5"` and `C-###`
ids. (Better: run your review in a subagent, so the synthesizing context never
saw the authoring intent.)

Then run reviewer #2:

```bash
# default: GPT-5.6 Sol via codex, high effort
scripts/second_review.sh <packet> references/rubric.md \
  references/findings.schema.json /tmp/r2-findings.json

# alternate: GLM-5.2 via opencode, max effort
scripts/second_review.sh <packet> references/rubric.md \
  references/findings.schema.json /tmp/r2-findings.json --backend glm

# alternate: Kimi K3 via opencode, max effort
scripts/second_review.sh <packet> references/rubric.md \
  references/findings.schema.json /tmp/r2-findings.json --backend kimi
```

Prereqs: `codex` on PATH and logged in (`codex login`), or `opencode` plus an
OpenCode Zen key for `--backend glm|kimi`; and `python3` with `jsonschema`, without
which the run **fails closed** rather than accepting unchecked findings.

**No call timeout is built in**, and a Zen backend can stall for tens of minutes
(see the reliability note above). Bound it yourself when that matters:

```bash
timeout  900 scripts/second_review.sh ... --backend kimi   # GNU coreutils
gtimeout 900 scripts/second_review.sh ... --backend kimi   # macOS + brew coreutils
```

`timeout` is GNU coreutils and **macOS ships neither name** until you
`brew install coreutils`, so check before relying on it. Exit 124 means it
stalled; nothing is written to `OUT_JSON`, which is cleared before the call, so a
timed-out run cannot leave stale findings behind.

Reviewer #2 runs blind, and its output is schema-validated (a finding missing
required Evidence / failure_case / recommendation is rejected, not silently
accepted). It writes `R2-###` ids and stamps the actual model in `reviewer`, so
the merged report still records which lab said what.

Override per run with `CODEX_MODEL` / `CODEX_EFFORT`
(`low|medium|high|xhigh|max|ultra`; `max`/`ultra` need a model that supports
them, e.g. `gpt-5.6-sol`) or `ZEN_MODEL` / `ZEN_VARIANT` (`minimal|low|high|max`);
a bad value exits 2 before anything is spent, since neither CLI reliably rejects
one itself.

> A single pass is a **noisy** detector: two passes over the same packet can
> share few findings. Treat a clean pass as weak evidence, and for a high-stakes
> review run `second_review.sh` two or three times into different files, or once
> per backend, and union the findings yourself. That is the whole reliability
> story; there is no aggregation script to run.

## Step 3: Synthesize (the actual work)

Read both findings files now and merge them into one report:

1. **Cluster + dedupe.** Same issue from both reviewers becomes one finding
   (renumber to `F-###`); keep the clearest evidence and suggestion. When the two
   disagree on severity for a merged finding, record the **higher** one.
2. **Escalate the conflicts that matter to the human.** Surface a disagreement
   (do not quietly split the difference) when ANY of:
   - you and reviewer #2 differ on a **high-severity** finding (one says fix, one shrugs);
   - it touches security / data loss / migration / public API, regardless of severity;
   - low confidence but high severity;
   - you are about to reject or defer a finding the other reviewer called `must_fix`.

   On design/architecture conflicts where your only ground is author knowledge,
   reviewer #2's read stands or it goes to the human, since you are not a neutral
   judge there. Lower-risk conflicts: make a provisional call and note it in the
   summary.
3. **Never silently drop a reviewer #2 finding.** If you do not adopt one, say so
   and why (a one-line "not adopted: R2-002, below the bar" is enough). Silent
   drops are the exact failure this two-reviewer setup exists to prevent.
4. **Disposition, do not vote.** Give each finding `must fix` / `should fix` /
   `defer` / `reject`; `reject` needs a reason. This makes the review a design
   decision, not an AI tally.

**After the fix.** Self-checking the fix diff against the must-fix findings is
enough for routine changes. For a high-risk change (security / data loss /
migration / public API), re-run `second_review.sh` on **just the fix diff** (wrap
it as a small bundle asking whether each finding is resolved and whether the fix
regressed anything); do not re-send the whole artifact.

## Output: use this template

```markdown
# Dual-model review: <target>

**Reviewers:** Claude Opus 5, high effort (author-aware) · <reviewer #2 model, e.g. GPT-5.6 Sol via Codex>
**Verdict:** <approve | approve_with_nits | request_changes | block>

## ⚠️ Escalated to human (disagreements that matter)
- [F-00x][<location>] Claude: <call> · <r2 model>: <call> · why: <why it matters>

## Consensus findings (both reviewers)
- **[F-00x][severity][category]** <location>: <issue>. *Evidence:* <…>. *Fix:* <…>

## Single-reviewer findings
- **[F-00x][severity][category][C|R2]** <location>: <issue>. *Fix:* <…>

## Disposition
- must fix: F-001, F-004 · should fix: F-006 · defer: F-002 · reject: F-007 (<reason>)

## Not adopted (reviewer #2 findings I dropped)
- [R2-00x][<location>] <finding>: <why not adopted>

## Residual risk / for the human
- ...
```

Keep every heading. If a section is empty, write "None": its presence proves it
was checked, not skipped.

## Governance & operating rules

- **Read-only reviewers.** They analyze; they do not edit the repo. Both backends
  are hardened so reviewer #2 answers from the **packet it was handed alone**:
  with file tools available, a reviewer goes and reads the working tree
  (including changes it was meant to be blind to) instead of reviewing the diff
  it was handed. The transport differs by arm and is not interchangeable: codex
  takes the packet on stdin via the `-` placeholder, opencode takes it in the
  argv message under an explicit `## ARTIFACT TO REVIEW` header.
  - codex: `features.shell_tool=false` and `-C` pointed at an empty scratch dir,
    the working root is where codex discovers `AGENTS.md`, project config, and
    repo context, so an empty one is what keeps it blind. Plus
    `--ignore-user-config` (your notify hooks, plugins, personality, and any
    `web_search = "live"` stay out of a review; auth still resolves from
    `CODEX_HOME`) and `--ephemeral` (no session file on disk).
    **`--sandbox read-only` blocks writes, not reads**: it is not the thing
    keeping reviewer #2 blind, and only what you put in the bundle should be
    treated as exposed.
  - opencode: `config/opencode.zen.json` disables the file/exec tools and pins a
    paid, zero-retention `small_model`.
- **Retention is yours to confirm.** Check your Codex plan's data-retention and
  training terms before routing internal code through the default backend. The
  script deliberately does **not** relocate `CODEX_HOME` to ship a hardened
  `config.toml`: `auth.json` lives there too, so a fresh `CODEX_HOME` means "not
  logged in". Hardening rides on `--ignore-user-config` plus `-c` overrides
  instead, which is also the highest-precedence config layer.
- **glm backend: Zen, US-hosted, paid tier only.** GLM-5.2 = `opencode/glm-5.2`
  (zero-retention). **Never** route internal code through Z.ai's own API. Z.ai is
  also on the US BIS Entity List; that backend assumes your org's compliance has
  approved MIT-licensed GLM weights via a US host for internal artifacts.
- **kimi backend: same posture, same caveat.** Kimi K3 = `opencode/kimi-k3`,
  also a China-based lab (Moonshot AI) reached through the US-hosted,
  zero-retention Zen tier. **Never** route internal code through Moonshot's own
  API. Confirm your org's compliance position covers this lab specifically: it
  is a separate decision from the GLM one, not covered by it.
- **Swapping in another Zen model** is a one-line default in the `glm|kimi` arm
  (or just `ZEN_MODEL=`). A different **CLI** (Gemini/Vertex, an Azure-hosted
  model) is a new `case` arm: prompt, rubric, schema, and synthesis are already
  backend-agnostic.

## Files

- `scripts/gather_artifact.sh`: build the review packet (`--level full|minimal`, `--tests`).
- `scripts/second_review.sh`: run reviewer #2 (`--backend codex|glm|kimi`, one blind, schema-validated pass).
- `references/rubric.md`: severity/category source of truth + review lenses.
- `references/findings.schema.json`: the per-reviewer findings contract.
- `config/opencode.zen.json`: hardened opencode config (Zen, tools off, paid model), shared by `--backend glm` and `--backend kimi`.
- `tests/`: `bash tests/test_*.sh`; no test spends a paid call (fake CLI shims).
