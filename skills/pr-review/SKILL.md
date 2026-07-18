---
name: pr-review
description: Perform a thorough, verification-based pull request review that produces a merge verdict with evidence. Use proactively whenever asked to evaluate, review, assess, or check a pull request, PR, or diff. Distinguishes from pr-visual-review (which generates structural diagrams) by focusing on correctness, completeness, and scoped actionable findings rather than visualization. Every finding must be verified before it is stated; ship a concrete scoped action or omit it. Never output hedges like possibly, might be, or could be without the check that resolves it.
---

# PR Review

## Core principle

A review that surfaces suspicions without resolving them is worse than no review: it hands the
reviewer unverified homework disguised as findings. Every item in the output MUST be backed by a
concrete check (a grep, a lockfile count, a CI status fetch) and MUST end with a scoped action
(drop this line, keep that file) or be omitted entirely. Verification over hedging. Verdicts over
candidates.

## Required checks

Run all of these. If a section does not apply (e.g. no dependency removed), state "N/A" with one
line of why. Do not silently skip sections.

### 1. Diff inventory

- List every file changed with +/-. Classify each as: source, lockfile, config, CI, docs,
  vendored/generated.
- Identify the change type (feat / fix / refactor / chore / removal).
- State the PR's stated motivation (from the PR body) and whether the diff matches it.

### 2. Stale-config sweep

Check ALL of these for references to the deleted path, package, workflow, or task. Do not rely on
a single grep; enumerate the files:

- `.idea/*` (IDE module configs)
- `.vscode/*` (workspace settings)
- `.gitignore`
- `Makefile`, `makefile`
- `.github/dependabot.yml`
- every file under `.github/workflows/`
- `README.md` and any architecture/tree docs
- task-runner configs at the root and per package (`justfile`, `dodo.py`, npm scripts): task
  discovery may reference the deleted package
- `.editorconfig`
- the package manifest of every package (`pyproject.toml`, `package.json`, `Cargo.toml`), not
  just the affected one
- deployment manifests, if the repo deploys services (helm `values.yaml`, kustomize overlays,
  compose files)
- `AGENTS.md`, `CLAUDE.md`, or any agent instruction files

Report any file that still references the deleted entity with `file:line` and the stale content.

### 3. Code-usage verification (for removals)

- grep the whole repo for imports / references to the removed symbol (e.g. `import somelib`,
  `from somelib_wrapper`).
- If zero hits: state "confirmed unused" with the grep command and hit count as evidence.
- If hits exist: list each as a blocker with `file:line`.

### 4. Channel / registry orphan audit (for dependency removals)

For each channel or registry declared in the affected service's manifest:

1. Count how many packages in THAT service's lockfile (`pixi.lock`, `poetry.lock`,
   `package-lock.json`, ...) are still
   fetched from the channel. Show the count with the grep command used.
2. If the count is zero, recommend dropping the channel entry from that service's
   manifest with the exact line number.
3. Check sibling services' manifests for the same channel. Scope the recommendation
   explicitly: "drop from this file at line N, keep in that file at line M".
4. Never say "safe to leave" without naming the concrete future break (e.g. "redundant repodata
   fetch on every solve; breaks if channel is later retired") or confirming another consumer
   exists with evidence.

### 5. Transitive-dependency audit (for dependency removals)

1. List every transitive dependency removed from the lockfile (packages that disappeared that
   were not direct deps in the manifest).
2. For each remaining direct dep in the affected manifest that was likely only there to
   satisfy the removed package, verify by checking whether any other direct dep or code path
   still needs it (grep for imports, check other deps' requirements).
3. State keep/drop with evidence. Do not list candidates; deliver verdicts. If verification is
   inconclusive, say "needs human check" rather than "possibly unused".

### 6. Lockfile hygiene

- Confirm the lockfile was regenerated, not hand-edited (look for consistent formatting, platform
  sections, and that all removed deps are absent).
- Confirm deps removed in the manifest are absent from the lockfile on EVERY platform or
  lock section the lockfile tracks (e.g. linux-64, osx-arm64, win-64).
- Flag any platform where a removed dep still appears.

### 7. CI status

- Report pass/fail/skip for every check via `gh pr checks`.
- Flag any skipped check and state whether the skip is expected for this change type.
- A green CI does not override a blocker finding; CI validates execution, not correctness of
  the removal scope.

## Output format

Verdict on one line: Approve, Request changes, or Block.

Group findings by severity:

- Blockers: must be resolved before merge. Each with file:line, verification evidence, required action.
- Recommended actions: each with file:line, verification evidence, and the exact edit to make.
- Nits: each with file:line and description.

Rules:
- No summary table unless asked.
- Every Recommended action must name the file, the line, and the exact edit.
- Do not explain what the PR does beyond one line.
- If there are no blockers and no recommended actions, say so explicitly rather than leaving the
  section empty.
