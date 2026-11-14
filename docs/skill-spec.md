# Writing a skill as a small spec

A SKILL.md is a model spec for one job. This guide borrows the six components
that public model specs share (SAIF, "Emerging International Best Practices
for AI Model Specs", Nov 2026) and maps them onto a skill. Use the parts a
skill needs and skip the rest: most skills need three or four.

| Component | Where it goes in a SKILL.md | Write it as |
|---|---|---|
| Scope | frontmatter `description`, `## When to use` | when to trigger, and when not to |
| Goal | one or two lines under the H1 | what a good outcome is for the user |
| Constraints | `## Non-negotiables` or `## Governance & operating rules` | never-do rules, each with its reason |
| Principles | `## Core principles` or the workflow steps | how to make the judgment calls the steps leave open |
| Output style | `## Output` or a template block | the shape and tone of what the skill returns |
| Conflicts | `## When rules conflict` | which rule wins when two collide, and why |

## Rules for each part

- **Scope drives triggering.** The `description` is the only part Claude sees
  before it loads the skill, so name the phrasings that should trigger it and
  any near misses that should not.
- **Every constraint carries a reason, in one clause.** "Never route internal
  code through Z.ai's own API, since a sent packet cannot be recalled." A
  reason lets the model handle a case the rule did not name.
- **Add `## When rules conflict` only when two rules can actually collide.**
  List the winners in order, each with a one-clause reason, then one or two
  short examples of the ambiguous case. A skill with no collisions gets no
  section, so the file stays short.
- **Prefer an example over a longer rule** for an ambiguous case. One worked
  case sets a precedent that a paragraph of qualifiers does not.
- **Treat the order as holistic.** A higher rule usually wins, but the model
  still weighs the lower ones. Write "never" only for real hard limits.

## Existing priority lines worth copying

- `repo-deepwiki`: "Accuracy beats coverage; a smaller wiki that's all-correct wins."
- `pr-review`: "A green CI does not override a blocker finding."
- `pr-visual-review`: "A wrong diagram is worse than no diagram."

## Changing a skill

- **Say why in the commit body**, above all when a constraint is loosened or
  removed. Git history is the changelog.
- **Check per rule, not overall.** For a constraint or conflict rule, write
  down the one prompt that would break it and what the right output is. Where
  a skill has `tests/`, a zero-token test for that case is better still. A
  single "the skill worked" judgment hides which rule failed.
- **Keep it short.** A new section replaces words elsewhere where it can. The
  whole file is loaded on every trigger.
