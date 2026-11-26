# Dual-model review: example PR

**Reviewers:** claude (medium, author-aware) · gpt-6-luna (medium)
**Verdict:** request_changes

## ⚠️ Escalated to human (disagreements that matter)
None

## Consensus findings (both reviewers)
- **[F-001][high][correctness]** a.py:10: off by one (from C-001, R2-001). *Evidence:* `for i in range(n-1)`. *Fix:* use `range(n)`.

## Single-reviewer findings
None

## Disposition
- must fix: F-001 · defer: R2-002

## Not adopted (reviewer #2 findings I dropped)
None

## Residual risk / for the human
- None
