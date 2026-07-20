# Review rubric

Both reviewers use this. Review against every relevant lens; skip lenses that do
not apply rather than inventing findings.

## Severity (single source of truth — used by schema, SKILL.md, playbook)

- **critical** — must not merge / must not ship as designed. Correctness break,
  data loss, security hole, or a design flaw that does not survive load.
- **high** — should fix before merge/sign-off; meaningful risk, or debt with a
  plausible near-term operational or maintenance cost. Not "someday this hurts" —
  "as-is, this bites soon."
- **medium** — worth fixing; not gating.
- **low** — optional; include only when style/clarity creates real maintenance
  risk, or when the user explicitly asks for nits.

## Category values (must match findings.schema.json `category` enum)

`correctness · security · testing · performance · failure_modes · observability ·
maintainability · design · operability · other`

## Common lenses (PRs and designs)

- **correctness** — does it do the stated thing? logic errors, off-by-one, wrong
  defaults, races, bad error handling.
- **security** — authz/authn, input validation, secrets, injection, SSRF, unsafe
  deserialization, dependency risk.
- **failure_modes** — partial failure, timeout, retry storms, poison input. Blast
  radius? graceful degradation?
- **performance** — hot paths, N+1, unbounded work/memory, large-context timeouts.
- **observability** — can you tell when it breaks? logs/metrics/traces, useful errors.
- **testing** — is the risky part covered? meaningful tests vs theater?

## PR-specific lenses

- **scope** — one thing? unrelated changes sneaking in?
- **backward compatibility** — API/schema/flag changes safe for existing callers?
- **migration safety** — reversible? safe to roll out and roll back? ordering?
- **coverage of the change** — new/changed branches tested?

## System-design-specific lenses

- **scalability** — holds at 10x load/data? first bottleneck?
- **data model & consistency** — concurrency correctness; idempotency; delivery
  semantics; schema evolution.
- **operability & cost** — on-call burden, deploy/runbook complexity, $ at scale.
- **threat model** — trust boundaries, data residency, multi-tenant isolation.
- **alternatives considered** — chosen approach justified vs simpler ones? what was
  rejected and why?

## Lens → category mapping

Several lenses above are not category enum values. Map each finding to the closest
category so reviewers stop defaulting to `other`. Guidance, not a straitjacket —
pick the better-fitting category when one applies.

```
scope                   -> maintainability / design
backward compatibility  -> correctness / design
migration safety        -> failure_modes / operability
coverage of the change  -> testing
scalability             -> performance / design
data model & consistency-> correctness / design
operability & cost      -> operability
threat model            -> security
alternatives considered -> design
```

Use `other` only when no listed category fits, and say why.

## Output discipline

- Findings first, severity-ordered. Do not summarize first.
- Cite a concrete `location`. Format:
  - PR: `path/to/file.ext:line` when possible; otherwise `path/to/file.ext` + hunk/function.
  - Design: section heading, diagram/table name, or quoted requirement ID.

  Avoid coarse locations like `design doc` or `the diff`.
- `suggestion` must be concrete enough that the author can act on it. Avoid vague
  advice like "handle errors better."
- **Evidence is mandatory for:**
  - all critical/high findings;
  - all correctness/security findings, regardless of severity.

  Evidence is the diff line, spec clause, or observed behavior that proves the
  finding — it reduces hallucinations. For critical/high also give a `failure_case`.
- Mark unverified concerns `speculative: true` and set `confidence` honestly. If
  evidence is unavailable but the concern is important, still raise it as
  speculative and state what would verify or falsify it.
- Suppress style-only comments unless they create real maintenance risk.
- **No findings is a valid result.** If there are none, say "No findings" and
  instead list residual risk, unverified assumptions, and tests not run. Do not
  invent low-severity findings to fill the report.
