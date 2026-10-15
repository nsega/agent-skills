---
name: pr-review-report
description: >-
  Run a PR review in a background subagent and save the result as a Markdown
  report, so the main session keeps working and receives only a short
  completion notice. The main session first reads the PR and writes a review
  brief (change type, hypotheses to verify, required checks) tailored to that
  PR, then hands it to a read-only reviewer. Use this when the user wants a
  review saved to a file, wants to keep working while a PR is reviewed, wants
  to compare review runs (models, effort levels, tools), or invokes
  /pr-review-report. For an inline merge verdict in the conversation, use
  pr-review instead.
argument-hint: <PR number> [--effort <level>] [extra focus]
---

# pr-review-report

Sibling skills, easy to confuse:

- `pr-review` reviews inline and answers in the conversation. This skill
  shares its verification discipline and output vocabulary (Blockers,
  Recommended actions, Nits) but runs the review in a background subagent and
  writes the report to a file.
- `pr-visual-review` explains structure with diagrams.
- `dual-model-review` adds a second lab's model for decorrelated findings.

The split of work is deliberate. The main session decides **how** this PR
should be reviewed (the brief). The subagent does the review with a clean
context: it sees the brief and the code, never the main conversation.

## Arguments

`$ARGUMENTS`: the first token is the PR number. Everything else is optional
extra focus from the user.

If the arguments contain `--effort <level>`, take `<level>` as the review
effort and remove both tokens before reading the extra focus. `<level>` must be
one of `low`, `medium`, `high`, `xhigh`, `max`. If it is not, tell the user and
stop.

## 1. Fetch the PR

```bash
gh pr view <PR> --json number,title,body,baseRefOid,headRefOid,files,additions,deletions,closingIssuesReferences
git fetch origin pull/<PR>/head
git fetch origin <baseRefOid>
```

Fetch only to make both SHAs available locally. Never check out the PR branch:
the user's working tree must stay as it is.

For each issue in `closingIssuesReferences`, read it with `gh issue view`.

## 2. Write the review brief

Read only these inputs, so the full diff stays in the reviewer's context:

1. `git diff --numstat <baseRefOid>...<headRefOid>`
2. the PR description and linked issues
3. `git diff <baseRefOid>...<headRefOid> -- <path>` for the 3 files with the
   most changed lines, skipping tests, lockfiles, and generated files

If the numstat shows more than about 1,500 changed lines outside lockfiles,
skip input 3. Launch an Explore subagent with `model: sonnet` instead. Give it
the PR number, both SHAs, any extra focus from the user, and the field
definitions from CHANGE_TYPE to SEVERITY_NOTES below, and ask it to return only
those fields. Wait for its result, then continue to step 3.

Write the brief with these fields:

- **REQUIREMENTS**: what the PR and its linked issues say it must do, 5 to 10
  lines. Record claims as claims. Do not adopt the author's framing as fact.
- **CHANGE_TYPE**: one or more of feat, fix, refactor, removal, deps, infra,
  docs, test.
- **HYPOTHESES**: 3 to 5 concrete things to verify, each tied to a path. Build
  them from the diff. When the PR description claims a behavior, turn that
  claim into a hypothesis. Good: "`retry.ts`: the new retry loop re-sends a
  non-idempotent POST". Bad: "check error handling".
- **REQUIRED_CHECKS**: checks that must run for this change type. For example:
  - removal or deps: the stale-config sweep, code-usage verification, and
    lockfile hygiene sections of `pr-review`
  - infra (Terraform, CDKTF, Kubernetes manifests): broadened IAM or RBAC,
    resources that would be destroyed or replaced, state impact
  - concurrency changes: goroutine or promise leaks, cancellation and context
    propagation
  - any change: `gh pr checks <PR>` status
- **DEPRIORITIZE**: generated files, vendored code, mechanical lockfile churn,
  mechanical renames, or "None".
- **SEVERITY_NOTES**: facts for judging impact. Does the changed code run on a
  production path or only in internal tooling? Do other services share it? Who
  sees a failure (users, on-call alerting, developers)? Describe the situation
  only. Leave severity levels to the reviewer, because main has seen only part
  of the diff.

Put any extra focus from the user at the top of HYPOTHESES.

## 3. Launch the reviewer

Pick the output path in the reviewed repository:
`reviews/pr-<PR>-<first 7 chars of headRefOid>.md`. If that file already
exists (for example, a rerun with another model), append `-2`, `-3`, and so on.
Create `reviews/` if needed. If `reviews/` is not in the repository's
`.gitignore`, mention that once in your final report rather than editing
`.gitignore` yourself.

Read `references/reviewer-prompt.md` in this skill's folder, fill every
double-brace placeholder, and launch a general-purpose subagent **in the background**
with the filled prompt as its only input. Do not add the main conversation.

- If `--effort` was given, set the subagent's `effort` parameter to that level.
  Otherwise leave it unset so the review runs at the session's effort.
- Leave `model` unset so the review runs on the session's model. To compare
  models, the user switches the session model and reruns.

Then tell the user only: "Started the review of PR #<PR>." and end the turn.
Do not wait for the result.

## 4. Report on completion

When the completion notice arrives, the subagent's reply is three lines (path,
verdict, counts). Report them to the user. If there are Blockers, add their
one-line headings from the report file. Do not paste the report body.

If the subagent's reply does not follow the three-line format, or the report
file is missing, say so plainly and show what the subagent returned.
