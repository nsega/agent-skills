# Dual-model review: example PR

**Reviewers:** claude (medium, author-aware) · gpt-6-luna (medium)
**Verdict:** request_changes

## ⚠️ Escalated to human (disagreements that matter)
None

## Consensus findings (both reviewers)
- **[F-001][high][correctness]** a.py:10: off by one (from C-001, R2-001). *Evidence:* `for i in range(n-1)`. *Fix:* use `range(n)`.

## Single-reviewer findings
- **[F-002][medium][maintainability][R2]** a.py:40: duplicated parser (from R2-002). *Fix:* reuse `parse_row`.

## Disposition
- must fix: F-001 · should fix: F-002

## Not adopted (reviewer #2 findings I dropped)
- [R2-003][b.py:5] long line: style only, below the bar.
