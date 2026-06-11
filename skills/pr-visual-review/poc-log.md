# pr-visual-review — PoC Observation Log

Solo PoC log. Append one block per PR you run the skill on. Keep entries to ~2 min.
Free-text fields can be in any language; keep the checkboxes as-is so they tally easily.

The three signals that decide whether this is worth proposing to the team:
1. **Gating accuracy** — did it draw when it should, and skip when it should?
2. **Consistency** — does the node mapping match the real code (no fabricated edges)?
3. **Intent fit** — was the inferred intent right? (only scorable when the PR's intent is known)

---

## Rolling tally

Update as you go. This is the number you'll show the team.

| Signal | ✅ good | ⚠️ partial | ❌ bad | n |
|---|---|---|---|---|
| Gating decision | 0 | 0 | 0 | 0 |
| Consistency (mapping) | 0 | 0 | 0 | 0 |
| Intent fit | 0 | 0 | 0 | 0 |

Go/no-go gut check: aim for gating + consistency mostly ✅ before trusting intent-fit numbers.
A wrong diagram (❌ consistency) is the disqualifier — note those first.

---

## Entry template (copy per PR)

### PR: <repo>#<num> — <title>
- Date: YYYY-MM-DD
- Link:
- My read of the change type: [ flow | types/deps | branching | refactor | local fix | config/docs ]
- Skill decided: [ sequence | class | flowchart | before-after | NO DIAGRAM ]

**Gating** — was draw/skip the right call?
- [ ] ✅ right call
- [ ] ⚠️ borderline (defensible either way)
- [ ] ❌ false positive (drew noise on a trivial PR)
- [ ] ❌ false negative (missed a real structural change)
- Note:

**Consistency** — does the node→`file:function` mapping match reality?
- [ ] ✅ all correct
- [ ] ⚠️ minor (e.g. a label off, but no wrong relationships)
- [ ] ❌ fabricated/ wrong edge or node  ← highest-priority bug
- Inferred edges that were actually wrong:

**Intent fit** — was the inferred-intent block correct? (skip if intent unknown)
- [ ] ✅ matched
- [ ] ⚠️ partial
- [ ] ❌ wrong
- [ ] n/a (no known spec/intent to compare)
- Author/known intent vs. what the skill guessed:

**Usefulness** — did the diagram let you grasp the change faster than the raw diff?
- [ ] clearly | [ ] marginally | [ ] no
- One thing it surfaced (or missed):

**Skill fix this entry suggests** — concrete change to SKILL.md:
- e.g. "tighten gating: refactors with no flow change shouldn't get a sequence diagram"
- e.g. "inferred-intent wording too assertive; soften"

---

## Worked example (delete once you have real entries)

### PR: myapp#42 — add retry to payments API client
- Date: 2026-06-04
- My read of the change type: branching
- Skill decided: flowchart

**Gating**: ⚠️ borderline — only ~15 lines, but it added a retry/backoff branch, so a small flowchart was defensible.
**Consistency**: ✅ all correct — 3 nodes mapped cleanly to `payments/client.go`.
**Intent fit**: ✅ matched — "make payment calls resilient to transient 5xx". n/a spec, but obvious from code.
**Usefulness**: clearly — the flowchart made the "no rollback on final failure" gap jump out, which the diff buried.
**Skill fix**: none. Possibly add a size threshold note so tiny branch-only PRs still qualify (this one was a good catch).
