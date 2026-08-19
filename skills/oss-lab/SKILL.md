---
name: oss-lab
description: >
  Autonomous Issue Scout loop for Kubernetes OSS contributions. Scans
  target repos hourly on weekdays, applies zero-token hard filters, then
  scores surviving issues against a weighted OKR-alignment rubric and
  routes them to a task manager or a holding queue. Designed to run
  all day within Claude Max rate limits by never invoking Claude when
  there is nothing new to score.
---

# oss-lab: Issue Scout Loop

## What this skill does

Every weekday hour (09:00–18:00), a launchd job runs one iteration:

1. **Fetch (bash, zero tokens)** — `gh api` pulls new open issues from
   the target repos, filters out assigned / stale / excluded-label
   issues with jq, and deduplicates against `seen.json`.
2. **Guard** — if nothing survives, exit before Claude starts.
3. **Score (Claude, the only paid step)** — surviving issues are scored
   0–10 on four weighted axes (see Rubric).
4. **Route (bash)** — high scores become tasks, mid scores go to a
   re-evaluation queue, low scores are recorded and dropped.
5. **Commit state** — `seen.json` and `last_run` advance so the next
   window resumes cleanly even after a rate-limit stop.

## Etiquette by design

This tool automates *attention*, not *contribution*. The constraints
below are deliberate, not incidental:

- **Read-only upstream.** The loop only reads public issue feeds. It
  never comments, never `/assign`s, and never opens PRs. Nothing here
  writes to the target repos.
- **Respects existing claims.** Issues with an assignee are
  hard-filtered before scoring; work someone else has claimed is never
  surfaced.
- **No hoarding.** The WIP cap (3 active tasks) exists so the loop
  never queues up more claimed work than will actually be delivered.
- **Depth over breadth.** The consistency axis anchors scoring to one
  SIG, one code area, and reviewers who already know the contributor:
  sustained work in one corner of the project, not drive-by issue
  farming across repos.
- **A human does the work.** Routing an issue to the task manager is
  where automation stops. Reading the issue, joining the discussion,
  and writing the fix are manual and human-owned.

## Rubric

| Axis | Weight | Measures |
|---|---|---|
| okr_alignment | 0.3 | Mergeable code/test contribution to a target repo |
| consistency | 0.3 | Continuity with existing contribution line (same SIG, code area, reviewers) |
| impact | 0.2 | Post-merge reach; test infra and flaky-test fixes rank high |
| feasibility | 0.2 | Scoped effort and expected review round-trips |

Routing: weighted ≥ 7.0 → task manager · 5.0–6.9 → queue · < 5.0 → drop.

Flow controls:
- **WIP cap** — at most 3 active tasks; overflow demotes to queue.
- **Release-cycle correction** — around code freeze, feature work is
  penalized and stabilization work is boosted (static config, updated
  quarterly in prompt.md).
- **Queue decay** — queued issues are re-scored weekly; two consecutive
  sub-threshold scores drop the issue. The hourly runner triggers
  `run-reeval.sh` once the `last_reeval` stamp is 6+ days old, so a
  slept-through Monday self-heals on the next weekday run. The pass is
  best-effort (a failure never costs the scout iteration) and retries
  hourly until it succeeds. Run `run-reeval.sh` directly for an ad-hoc
  pass; a successful manual pass counts toward the weekly cadence.

## Rubric governance

The consistency anchors (SIG, open PRs, code areas) and the release
phase live as static blocks in `prompt.md` and are reviewed monthly and
quarterly respectively. Weight changes require a calibration note:
compare routed tasks against actual outcomes (started / merged /
abandoned) and record the adjustment rationale below.

### Calibration log

- 2026-08: initial weights (0.3 / 0.3 / 0.2 / 0.2), thresholds 7.0 / 5.0.

## Configuration

Secrets and state never live in this repo:

```
$OSS_LAB_STATE_DIR (default ~/.local/share/oss-lab)
├── env        # GITHUB_TOKEN, TODOIST_TOKEN, TODOIST_PROJECT_ID
├── seen.json
├── queue.json
├── last_run
└── last_reeval
```

In the reference setup, `OSS_LAB_STATE_DIR` points at a clone of the
private `oss-lab-state` repo: after each iteration that changes
`seen.json` or `queue.json`, the runner commits them
(`scout: <date> <n> scored, <m> queued`, or
`reeval: <date> <n> rescored, <m> dropped` after the weekly pass) and
pushes, best-effort. A failed push never fails the iteration. `env`,
`last_run(.pending)`, `last_reeval`, and logs stay untracked there.

Install: `make install-oss-lab`. It symlinks the skill into the
personal Claude identity, copies the plist with the repo path rewritten
to the current checkout (a verbatim copy would point launchd at a path
that may not exist), and runs `launchctl load -w` only if the job is
not already loaded. The shipped plist points `OSS_LAB_STATE_DIR` at the
reference setup (`~/dev/oss-lab-state`, a clone of the private state
repo) and logs to `~/Library/Logs/oss-scout.log`. Verify
`CLAUDE_CONFIG_DIR` resolves to the intended personal account before
first run (the runner enforces this).
