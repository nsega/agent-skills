---
name: friction-log
description: Maintain a personal friction log in the user's Obsidian vault — a list of things >15 min that they'd happily delegate to an agent. Use when the user wants to add an entry ("log friction: X", "add to friction log"), review the open list ("show friction log", "weekly friction review"), or graduate items out ("shipped: X", "drop: X"). The log lives at one fixed path in the user's vault.
---

# Friction Log

Maintains a single living markdown file that captures recurring friction the user might delegate to an agent. The log is reviewed weekly and items graduate to either "Shipped" (an agent now handles it) or "Dropped" (turned out not to be agent-shaped).

## File location

The log lives at a single fixed path, defined in the user's **global CLAUDE.md** (`~/.claude/CLAUDE.md`) on a line of the form:

```
Friction log path: /absolute/path/to/vault/.../friction-log.md
```

Resolve the path from there. If no such line exists, ask the user once for the absolute path to their `friction-log.md` and tell them to add it to their global CLAUDE.md in that form.

The configured path is the **only** location. Do not create the file anywhere else. Always quote the path (it may contain spaces, e.g. under iCloud Drive).

## File shape

```markdown
---
tags: [agents, friction]
updated: YYYY-MM-DD
---

# Friction log

Things >15 min that I'd happily delegate. Append freely. Review weekly.

## Open
- YYYY-MM-DD — <one-line description, lowercase, no trailing period>

## Shipped → agent
- YYYY-MM-DD — <description> → <repo or link>

## Dropped (not agent-shaped)
- YYYY-MM-DD — <description>. <one-line reason>
```

The three section headings are fixed: `## Open`, `## Shipped → agent`, `## Dropped (not agent-shaped)`. Don't rename them, don't add subsections, don't reorder.

## Operations

For every operation: read the file first (use `Read`), then `Edit` it, then update the `updated:` frontmatter field to today's date. If the file doesn't exist, bootstrap it from the template above.

### 1. Add entry → Open

Trigger phrases: "log friction", "add to friction log", "frictionlog: X".

- Date = today (always confirm with `date +%Y-%m-%d` if unsure; never guess).
- Compress to one line. If the user gives a paragraph, summarize and confirm with them before writing.
- Append to the bottom of `## Open`. Don't sort.
- Echo the appended line back to the user so they can verify.

### 2. Show / review

Trigger phrases: "show friction log", "what's in the friction log", "weekly friction review".

- Read the file and print the `## Open` section verbatim.
- If the user said "weekly review", also compute and print the stats block below, then ask one question — *"Anything here that's recurred 3+ weeks and has the lowest blast radius? That's your next agent."* Don't score or rank for them; the prompt is the value.

**Stats block (weekly review only):**

Parse the leading `YYYY-MM-DD` from each `- ` line in each section. "This week" means the date is within the last 7 days from today (use `date +%Y-%m-%d` for today). Print:

```
Open: <N>   (aged >2w: <K>)
This week: +<captured> captured, <shipped> shipped, <dropped> dropped
Lifetime: <total_shipped> shipped, <total_dropped> dropped
```

Then list the aged-Open items (capture date >14 days ago) under a `Aged (>2w):` heading — these are the ones that have proven recurrence. They're the automation candidates. Limit to 5; if more, say so.

Do not write the stats into the markdown file. Git history on the vault is the time series — printing to the chat is enough.

For time-trend questions ("how did last week compare?"), use `git log -p` on the file from inside the vault directory (derive the vault root from the configured friction log path — it's the enclosing git repository):

```bash
cd "<vault root>" && git log --since="2 weeks ago" -p "<friction-log.md path relative to vault root>"
```

Diff the Open sections across commits to see what was captured/shipped/dropped between reviews.

### 3. Graduate Open → Shipped

Trigger phrases: "shipped: X", "X is done", "move X to shipped".

- Find the matching line in `## Open` (fuzzy match on the description; if ambiguous, ask which one).
- Move it under `## Shipped → agent`, append ` → <link>` if the user gave a repo/URL.
- Update its date to today (graduation date is more useful than capture date here).

### 4. Graduate Open → Dropped

Trigger phrases: "drop: X", "not agent-shaped", "X isn't worth automating".

- Find the matching line, move under `## Dropped (not agent-shaped)`.
- Require a one-line reason. If the user didn't give one, ask: *"What made this not agent-shaped?"* The reason is the lesson — don't skip it.

## Rules

1. **One line per entry.** If the user can't compress it, push back: *"What's the one-line version?"* Long entries mean the friction isn't understood yet.
2. **Move, don't delete.** Shipped and Dropped are archives — never `rm` lines. The Dropped pile teaches as much as the Shipped pile.
3. **Don't reorganize.** Resist the urge to sort by date, group by theme, or split files. The flat list is the feature.
4. **Don't suggest entries.** This is a personal capture log; the user adds, you record.
5. **Use Read + Edit, not Bash.** No `sed`, no `echo >>`. The file lives in iCloud Drive — partial writes can corrupt sync.

## Bootstrap (first run)

If the file doesn't exist, write it with this exact content (substituting today's date):

```markdown
---
tags: [agents, friction]
updated: YYYY-MM-DD
---

# Friction log

Things >15 min that I'd happily delegate. Append freely. Review weekly.

## Open

## Shipped → agent

## Dropped (not agent-shaped)
```

Then proceed with whatever operation the user originally asked for.
