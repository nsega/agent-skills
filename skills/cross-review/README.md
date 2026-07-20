# cross-review (Claude Code skill)

Two-model cross-review for PRs and system-design docs. Claude Code (Opus 4.8) is
the main reviewer + synthesizer; GLM-5.2 via OpenCode Zen is an independent
second reviewer. Different labs → decorrelated blind spots → higher-confidence
review. The output foregrounds **disagreements** for human adjudication.

## Prerequisites

- **Claude Code** (Opus 4.8, max reasoning effort) — the runtime that reads the skill.
- **opencode** CLI on PATH, authenticated to **OpenCode Zen** (paid):
  `opencode auth login` → select OpenCode Zen → paste your Zen API key
  (or `/connect` in the TUI). Add billing/credits.
- **python3** with **jsonschema** (`pip install jsonschema`). The GLM reviewer's
  output is hard-validated against `findings.schema.json` (the Evidence /
  failure_case / recommendation rules are enforced — a violating finding is
  rejected, not silently accepted). Without jsonschema the review **aborts**: an
  unvalidated run looks green while producing findings that the synthesis step's
  escalation triggers cannot read.

## Install

Drop the folder where Claude Code discovers skills, e.g.:

```bash
cp -r cross-review ~/.claude/skills/cross-review
# or symlink it from your agent-skills repo (dotfiles-style), e.g.
# ln -s ~/src/agent-skills/cross-review ~/.claude/skills/cross-review
```

Make scripts executable:

```bash
chmod +x cross-review/scripts/*.sh cross-review/tests/run_tests.sh
```

Verify the install (offline, no API key, no cost):

```bash
cross-review/tests/run_tests.sh
```

## Use

In Claude Code, just ask — the skill triggers on cross-review intent:

- "Cross-review PR #133906 against main."
- "Get a second opinion on docs/rfc-routecause.md before I send it for sign-off."
- "What did we miss in this diff?" (paste/point at the diff)

Or drive the sub-reviewer directly:

```bash
B=$(scripts/gather_artifact.sh pr origin/main)
scripts/glm_review.sh "$B" references/rubric.md references/findings.schema.json /tmp/glm.json
scripts/check_disagreements.sh /tmp/claude.json /tmp/glm.json   # exits 1 if any pair escalates
```

## Governance (already assumed in place)

- **Zen paid + US-hosted only.** GLM-5.2 runs as `opencode/glm-5.2` (zero-retention).
  Never use Z.ai's own API for internal code.
- **Disable free / data-collecting tiers at the Zen workspace level** (admin →
  model access). `config/opencode.zen.json` repeats the do-not-use list as
  defense-in-depth and pins `small_model` to a paid zero-retention model.
- **Entity-List determination on file.** This skill assumes your organization's
  compliance has approved MIT-licensed GLM weights via a US host for internal
  artifacts. If that changes, swap reviewer #2 (Gemini/Vertex, GPT-5.5/Azure) —
  topology unchanged.

## Verify before first internal run

A couple of opencode keys move between releases — confirm against current docs:

- `provider.opencode.models["glm-5.2"].options` — exact **reasoning-effort** key
  (this config uses `reasoningEffort: "max"`).
- `permission` / `share` value spellings.

These were not end-to-end tested in the environment that generated this skill
(no opencode auth / network there); the shell and JSON are syntax-validated.
