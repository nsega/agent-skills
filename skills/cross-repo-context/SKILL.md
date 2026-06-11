---
name: cross-repo-context
description: >
  Enables Claude to work across multiple sibling repositories as if they were a monorepo,
  by reading files from ../other-repo paths and combining knowledge from both sides.
  Use this skill whenever the user references a sibling repo, mentions a "../" path to
  another repository, wants to share context between two separate repos, says things like
  "the other repo", "the public repo", "the OSS repo", "the upstream repo", or wants to
  apply internal knowledge/strategy from the current repo to work done in an adjacent repo.
  Also trigger when the user wants to generate code, docs, or copy that depends on context
  from more than one repository root.
---

# Cross-Repo Context Skill

Enables compound, monorepo-like workflows across separate Git repositories by combining
knowledge from the **home repo** (where CLAUDE.md lives) and one or more **sibling repos**
(adjacent directories reachable via `../`).

## When to Use

- You're in a private/internal repo and need to work on a public OSS repo
- You maintain a fork and want the upstream context without merging repos
- You have strategy docs, design docs, or marketing copy in repo A that inform code in repo B
- Third-party repos you can reference but not commit to
- Any situation where "if only this were a monorepo" comes to mind

---

## Step 1 — Discover the Sibling Repo

Before doing any work, map what exists in the sibling repo:

```bash
# List all files (respects .gitignore by default)
rg --files ../other-repo

# If the path is a symlink or contains symlinks, add --follow (-L)
# Without this flag, rg silently skips symlinked directories
rg --files --follow ../other-repo

# If you need to ignore .gitignore (e.g., for build artifacts analysis)
rg --files --no-ignore --follow ../other-repo

# Filter to specific file types
rg --files --follow --glob "*.go" ../other-repo
rg --files --follow --glob "*.ts" ../other-repo

# Quick directory tree overview (find follows symlinks by default)
find ../other-repo -type f -not -path '*/.git/*' | head -60
```

> **Symlink note:** `rg` does **not** follow symlinks by default — it silently returns
> no results without `--follow`. `find`, `cat`, and Claude's file-read tools are
> symlink-transparent and need no special flags.
>
> If you have nested symlinks, guard against infinite loops:
> ```bash
> rg --files --follow --max-depth 10 ../other-repo
> ```

Use the output to build a mental map before reading individual files.

---

## Step 2 — Load Relevant Cross-Repo Context

Read files from the sibling repo the same way you'd read local files. Combine with
home-repo knowledge to reason about both sides simultaneously.

**Typical context-loading patterns:**

```bash
# Read the sibling repo's entrypoint / README
cat ../other-repo/README.md

# Read specific source files
cat ../other-repo/cmd/main.go
cat ../other-repo/src/index.ts

# Search for a symbol or pattern across the sibling repo
rg "FunctionName" --follow ../other-repo --type go
rg "TODO|FIXME|HACK" --follow ../other-repo -l

# Diff the sibling repo against current state (if it's a fork)
git -C ../other-repo log --oneline -20
git -C ../other-repo diff HEAD~5
```

---

## Step 3 — Apply Home-Repo Knowledge to Sibling Repo Work

This is the core value: use knowledge that **cannot exist in the sibling repo** to guide
work done there.

Examples of what lives only in the home repo:
- Architecture Decision Records (ADRs) explaining *why* something was built a certain way
- Internal naming conventions, style guides, brand voice
- Business logic or strategy that must not be committed to a public OSS repo
- Test patterns, scaffolding templates, CI/CD knowledge

**Workflow:**

1. Read the relevant home-repo context (docs, ADRs, CLAUDE.md notes, etc.)
2. Read the sibling-repo files that need to change
3. Produce changes that reflect both sources of truth — write to `../other-repo/...` paths

---

## Step 4 — Write Changes Back to the Sibling Repo

All standard file operations work on sibling paths:

```bash
# Apply a patch
patch -d ../other-repo -p1 < my.patch

# Direct file write (via Claude tool)
# Just reference ../other-repo/path/to/file as the target path

# Run tests in the sibling repo
cd ../other-repo && go test ./... && cd -
make -C ../other-repo test
```

---

## Compound Context Patterns

### Pattern A: Private strategy → OSS implementation
Home repo has `docs/strategy/roadmap.md`. OSS repo needs a new feature.
Claude reads the roadmap, understands the intent, writes the feature without leaking
internal naming or rationale into the public commit.

### Pattern B: Reference-only upstream
You depend on a third-party library at `../upstream`. You cannot commit there.
Claude reads upstream internals to understand behavior, then writes adapter code
in the home repo that correctly wraps it.

### Pattern C: Shared type contracts
Two services in separate repos must agree on an API schema.
Claude reads both, identifies drift, proposes changes to the editable side.

### Pattern D: Documentation bridge
Internal design doc in home repo → public-facing docs in OSS repo.
Claude translates internal knowledge into appropriate public language.

---

## Multi-Sibling Setup (3+ repos)

For more than one sibling repo, define them explicitly in CLAUDE.md:

```markdown
## Sibling Repositories
- `../api-server`   — Go backend, read/write
- `../web-client`   — TypeScript frontend, read/write
- `../upstream-sdk` — Third-party SDK, read-only reference
```

Then load all relevant repos at the start of each session:

```bash
for repo in ../api-server ../web-client ../upstream-sdk; do
  echo "=== $repo ===" && rg --files --follow $repo | head -20
done
```

---

## Tips

- **Add sibling repo paths to CLAUDE.md** in the home repo so every session auto-loads
  the relationship map. E.g.: `Sibling repos: ../public-sdk (OSS, read/write), ../vendor-lib (read-only)`
- **Never commit home-repo secrets or internal notes into the sibling repo** — Claude will
  follow this if you state it as a constraint in CLAUDE.md
- **Use `rg --files --follow`** not bare `rg --files` — ripgrep silently skips symlinked
  directories without `--follow`. Add `--max-depth 10` if you have nested symlinks to
  avoid infinite loops. `find` and `cat` are symlink-transparent by default.
- **Use `rg --files` not `find`** — ripgrep respects `.gitignore` and is dramatically faster
  on large repos
- **Anchor relative paths from the home repo root**, not from a subdirectory, to keep
  paths stable regardless of which subdirectory Claude is currently operating in
