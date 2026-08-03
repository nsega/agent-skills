# dual-model-debate Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the `dual-model-debate` skill: two models from two labs debate a question, and a neutral Claude synthesizes a recommended decision.

**Architecture:** Skill-orchestrated (a `SKILL.md` playbook the main Claude follows), with two thin bash helpers (`build_packet.sh`, `codex_turn.sh`) and a `references/protocol.md`. Claude's debater turns run in a subagent; the chair (main) context never argues. GPT turns run through `codex exec` read-only. State is a growing transcript file each codex turn receives on stdin.

**Tech Stack:** Bash (`set -euo pipefail`), `codex exec` (v0.146.0) for the second model, plain-bash test scripts with a `CODEX_FAKE` stub (no bats/shellcheck in this repo).

## Global Constraints

- **Layout:** the skill lives at `skills/dual-model-debate/` and mirrors `skills/dual-model-review/`'s shape (`SKILL.md`, `scripts/`, `references/`). Tests live in `skills/dual-model-debate/tests/`.
- **No `config/` dir.** codex hardening is done entirely with flags: `--ignore-user-config --skip-git-repo-check --ephemeral --sandbox read-only -C <scratch>`. This is a deliberate difference from the review skill (which needs `OPENCODE_CONFIG`).
- **codex facts (verified):** the flag is `--sandbox read-only` (`-s`); model via `-m` (default `gpt-5.6-sol`); reasoning effort via `-c model_reasoning_effort=<minimal|low|medium|high>`; the model's final message is captured with `-o <file>`; prompt is the arg, piped stdin is appended as a `<stdin>` block.
- **Every bash script:** starts with `#!/usr/bin/env bash` and `set -euo pipefail`; validates inputs and spends nothing on a bad path; lets codex's stderr flow to the caller; never edits the repo.
- **Test scripts are bash scripts too:** they also start with `set -euo pipefail` and are made executable (`chmod +x`). Under `set -e`, capture a command's exit code with `rc=0; cmd || rc=$?` (never a bare `cmd; rc=$?`, which `set -e` aborts before the capture). Leave the happy-path `p="$(cmd)"` assignments as-is (they exit 0).
- **Writing style (user rule):** no em-dashes anywhere (prose, comments, commit messages). Use commas, colons, parentheses, or `·`. En-dashes in numeric ranges and `→` are fine.
- **Commits:** Conventional Commits 1.0.0. Every commit message ends with these two trailer lines:
  ```
  Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01XErHevPA1KaGGVDDYJNqTj
  ```
- **Public repo:** no secrets in any file.

## File Structure

```
skills/dual-model-debate/
  SKILL.md                     # Task 4: playbook (loop, bias guards, brief template, governance)
  references/protocol.md       # Task 2: turn format, three roles, chair synthesis/escalation
  scripts/build_packet.sh      # Task 1: question + context files -> packet.md (prints path)
  scripts/codex_turn.sh        # Task 3: one read-only GPT turn -> appended to transcript
  tests/test_build_packet.sh   # Task 1
  tests/test_codex_turn.sh     # Task 3
  tests/test_docs.sh           # Task 4: assert required sections exist
  tests/test_integration.sh    # Task 5: end-to-end wiring in CODEX_FAKE mode
```

Dependency order: Task 1 (packet) is independent. Task 2 (protocol) must precede Task 3 (the turn script reads protocol.md on its real path). Task 4 (SKILL.md) depends on the scripts and protocol existing. Task 5 wires everything and registers the skill.

---

### Task 1: Packet builder

**Files:**
- Create: `skills/dual-model-debate/scripts/build_packet.sh`
- Test: `skills/dual-model-debate/tests/test_build_packet.sh`

**Interfaces:**
- Produces: `build_packet.sh "<question>" [context_file ...]` → prints the packet path on stdout; exit 2 on a missing question or a missing context file. Packet contains headings `## Question`, `## Framing (author fills before the debate)`, and `## Context` (or the literal `No context files attached.`).

- [ ] **Step 1: Create the skill directory and write the failing test**

Create `skills/dual-model-debate/tests/test_build_packet.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
# Plain assertions; capture exit codes with `rc=0; cmd || rc=$?` under set -e.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BP="$HERE/../scripts/build_packet.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1" >&2; }

# 1: no question -> exit 2
rc=0; "$BP" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "no question should exit 2 (got $rc)"

# 2: question only -> packet has the question, framing, and the no-context note
p="$("$BP" "Should we adopt X?")"
[ -f "$p" ] && ok || bad "question-only should print a packet path"
grep -q "Should we adopt X?" "$p" && ok || bad "packet missing the question"
grep -q "## Framing" "$p"          && ok || bad "packet missing framing section"
grep -q "No context files attached." "$p" && ok || bad "packet should note no context"

# 3: question + context file -> includes basename header and contents
tmpc="$(mktemp)"; echo "SENTINEL_CONTENT_42" > "$tmpc"
p2="$("$BP" "Q?" "$tmpc")"
grep -q "### $(basename "$tmpc")" "$p2" && ok || bad "packet missing context basename"
grep -q "SENTINEL_CONTENT_42" "$p2"     && ok || bad "packet missing context contents"

# 4: nonexistent context file -> exit 2
rc=0; "$BP" "Q?" /no/such/file >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "missing context file should exit 2 (got $rc)"

echo "build_packet: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash skills/dual-model-debate/tests/test_build_packet.sh`
Expected: FAIL (the script does not exist yet, so the first assertion's `$BP` is not found).

- [ ] **Step 3: Write the packet builder**

Create `skills/dual-model-debate/scripts/build_packet.sh`:

```bash
#!/usr/bin/env bash
# Build a debate packet (single file) from a question + optional context files,
# and print its path on stdout. The mechanical assembly is done here; the author
# fills the framing (constraints / non-goals / what a good decision looks like)
# before the debate. Sibling to dual-model-review's gather_artifact.sh.
set -euo pipefail

QUESTION="${1:-}"
[ -n "$QUESTION" ] || { echo 'usage: build_packet.sh "<question>" [context_file ...]' >&2; exit 2; }
shift

# Validate context paths up front so a typo fails before we emit anything.
for f in "$@"; do
  [ -f "$f" ] || { echo "no such context file: $f" >&2; exit 2; }
done

OUT="$(mktemp /tmp/dual-model-debate-packet.XXXXXX.md)"
{
  echo "# Debate packet"
  echo
  echo "- generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "## Question"
  echo
  echo "$QUESTION"
  echo
  echo "## Framing (author fills before the debate)"
  echo
  echo "### Constraints"
  echo "<!-- fill: hard requirements the answer must respect -->"
  echo
  echo "### Non-goals"
  echo "<!-- fill: what is out of scope, to stop off-target arguments -->"
  echo
  echo "### What a good decision looks like"
  echo "<!-- fill: the bar the decision is judged against -->"
  echo
  echo "## Context"
  echo
  if [ "$#" -eq 0 ]; then
    echo "No context files attached."
  else
    for f in "$@"; do
      echo "### $(basename "$f")"
      echo '```'
      cat "$f"
      echo '```'
      echo
    done
  fi
} > "$OUT"

echo "$OUT"
```

Then make both executable: `chmod +x skills/dual-model-debate/scripts/build_packet.sh skills/dual-model-debate/tests/test_build_packet.sh`

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash skills/dual-model-debate/tests/test_build_packet.sh`
Expected: `build_packet: 8 passed, 0 failed` and exit 0.

- [ ] **Step 5: Commit**

```bash
git add skills/dual-model-debate/scripts/build_packet.sh skills/dual-model-debate/tests/test_build_packet.sh
git commit -m "feat(dual-model-debate): add debate packet builder

Assemble a packet from a question plus optional context files, with author
framing fields (constraints / non-goals / decision bar) left to fill.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01XErHevPA1KaGGVDDYJNqTj"
```

---

### Task 2: Debate protocol reference

**Files:**
- Create: `skills/dual-model-debate/references/protocol.md`

**Interfaces:**
- Produces: a reference doc with a `## Turn format` section (the four fields), a `## Roles` section naming exactly `Honest opening (round 0)`, `Rebuttal (rounds 1-2)`, and `Forced opposition`, a `## Debate discipline` section, and a `## Chair: synthesis and escalation` section. `codex_turn.sh` (Task 3) reads this file and maps its `<role kind>` argument to these role names; `test_docs.sh` (Task 4) asserts the section names are present, so the exact strings matter.

- [ ] **Step 1: Write the protocol reference**

Create `skills/dual-model-debate/references/protocol.md`:

````markdown
# Debate protocol

Shared by both debaters and the chair. The debaters argue; the chair (the main
Claude context) never argues, it decides.

## Turn format

Every debater turn is these four fields, in this order, and nothing else. The
harness adds the `### <role> (round N)` heading; do not write your own heading.

```markdown
**Position:** <one line: your recommended answer to the Question>
**Argument:** <your case; prose, may be several paragraphs; cite the packet>
**Concedes:** <points from the other debater you grant this turn, or "nothing yet">
**Still unresolved:** <the specific disagreements this turn does not settle>
```

## Roles

### Honest opening (round 0)
Give your genuine recommended answer to the Question, argued from the packet
only. You have not seen the other debater. Take a real position; do not hedge to
a safe middle. If the packet is genuinely underspecified, say exactly what is
missing and answer under your stated assumption.

### Rebuttal (rounds 1-2)
Respond to the other debater's latest Position and Argument specifically. Grant
what is correct under Concedes. Advance the disagreement: add a new argument,
counter a specific claim, or narrow what is left. Do not restate a prior turn
without adding something. If you have nothing new, say so in one line under
Argument so the chair can stop.

### Forced opposition
Both debaters reached the same answer. Now argue, in good faith, the strongest
case AGAINST that consensus, even though you may believe it. Surface the best
reasons it could be wrong: the failure mode, the missed alternative, the
assumption that may not hold.

## Debate discipline

- Argue only from the packet and the transcript. Do not run tools or read files.
- Cite specifics from the Question, Framing, or Context, not vibes.
- Concede honestly; a debate that never concedes is not converging on truth.
- No fence-sitting unless the packet truly cannot support a call.

## Chair: synthesis and escalation

The chair reads the whole transcript fresh, having argued nothing.

1. **Stall check.** Stop rebuttals when a round adds no new substantive argument:
   no new claim, no new counter, no narrowing of what is unresolved. Two turns
   that only restate prior positions are a stall.
2. **Decide.** Pick the answer best supported by the debate, not the one argued
   most loudly. State the deciding rationale.
3. **Escalate, do not self-rule.** Send the decision to the human instead of
   deciding when ALL of these hold: the conflict is unresolved, it is a
   subjective / which-approach call, and the only remaining tiebreak is your own
   preference. Also escalate any unresolved conflict on an irreversible or
   high-stakes axis (security, data loss, migration, public API), regardless of
   subjectivity.
4. **Agreement is not verification.** When both debaters simply agreed without
   independently grounding the claim, label it "agreement, not verification" and
   do not treat it as proof.
````

- [ ] **Step 2: Verify the required section strings are present**

Run:
```bash
grep -q "## Turn format" skills/dual-model-debate/references/protocol.md && \
grep -q "Honest opening (round 0)" skills/dual-model-debate/references/protocol.md && \
grep -q "Rebuttal (rounds 1-2)" skills/dual-model-debate/references/protocol.md && \
grep -q "Forced opposition" skills/dual-model-debate/references/protocol.md && \
grep -q "## Chair: synthesis and escalation" skills/dual-model-debate/references/protocol.md && \
echo "protocol sections OK"
```
Expected: `protocol sections OK`

- [ ] **Step 3: Verify no em-dashes**

Run: `! grep -q "—" skills/dual-model-debate/references/protocol.md && echo "no em-dashes"`
Expected: `no em-dashes`

- [ ] **Step 4: Commit**

```bash
git add skills/dual-model-debate/references/protocol.md
git commit -m "feat(dual-model-debate): add debate protocol and turn instructions

Turn format (four fields), the three roles (honest opening, rebuttal, forced
opposition), debate discipline, and the chair's synthesis + escalation rules.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01XErHevPA1KaGGVDDYJNqTj"
```

---

### Task 3: Single codex turn runner

**Files:**
- Create: `skills/dual-model-debate/scripts/codex_turn.sh`
- Test: `skills/dual-model-debate/tests/test_codex_turn.sh`

**Interfaces:**
- Consumes: `references/protocol.md` from Task 2 (read on the real codex path, relative to the script's parent dir).
- Produces: `codex_turn.sh <ROLE_LABEL> <ROUND> <ROLE_KIND> <PACKET> <TRANSCRIPT>` where `ROLE_KIND` is `opening|rebuttal|forced`. It appends `### <ROLE_LABEL> (round <ROUND>)` plus a blank line plus the model message to `TRANSCRIPT` (creating it if absent) and prints the transcript path. Honors env `CODEX_MODEL` (default `gpt-5.6-sol`), `CODEX_EFFORT` (default `high`), `CODEX_FAKE` (a file path whose contents replace the codex call). Exit 2 on a bad `ROLE_KIND`, bad `CODEX_EFFORT`, missing/empty packet, or a `CODEX_FAKE` file that does not exist.

- [ ] **Step 1: Write the failing test**

Create `skills/dual-model-debate/tests/test_codex_turn.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
# CODEX_FAKE stub keeps this free: no real codex call. Capture exit codes with
# `rc=0; cmd || rc=$?` under set -e.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CT="$HERE/../scripts/codex_turn.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1" >&2; }

pk="$(mktemp)"; echo "# packet" > "$pk"
canned="$(mktemp)"; printf '**Position:** Yes\n**Argument:** Because sentinel_ABC.\n**Concedes:** nothing yet\n**Still unresolved:** cost\n' > "$canned"
tr="$(mktemp)"; : > "$tr"   # empty transcript (round 0)

# 1: bad role kind -> exit 2
rc=0; CODEX_FAKE="$canned" "$CT" "GPT" 0 bogus "$pk" "$tr" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "bad role kind should exit 2 (got $rc)"

# 2: bad effort -> exit 2
rc=0; CODEX_EFFORT=bogus CODEX_FAKE="$canned" "$CT" "GPT" 0 opening "$pk" "$tr" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "bad effort should exit 2 (got $rc)"

# 3: empty packet -> exit 2
empty="$(mktemp)"; : > "$empty"
rc=0; CODEX_FAKE="$canned" "$CT" "GPT" 0 opening "$empty" "$tr" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "empty packet should exit 2 (got $rc)"

# 4: fake opening appended under the harness header
rc=0; CODEX_FAKE="$canned" "$CT" "GPT (gpt-5.6-sol)" 0 opening "$pk" "$tr" >/dev/null || rc=$?
[ "$rc" -eq 0 ] && ok || bad "fake turn should succeed (got $rc)"
grep -q "### GPT (gpt-5.6-sol) (round 0)" "$tr" && ok || bad "transcript missing turn header"
grep -q "sentinel_ABC" "$tr"                     && ok || bad "transcript missing turn body"

# 5: a second turn appends (transcript grows) with the new round header
before=$(wc -l < "$tr")
CODEX_FAKE="$canned" "$CT" "GPT (gpt-5.6-sol)" 1 rebuttal "$pk" "$tr" >/dev/null
after=$(wc -l < "$tr")
[ "$after" -gt "$before" ] && ok || bad "second turn should grow the transcript"
grep -q "(round 1)" "$tr"  && ok || bad "transcript missing round 1 header"

echo "codex_turn: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `bash skills/dual-model-debate/tests/test_codex_turn.sh`
Expected: FAIL (the script does not exist yet).

- [ ] **Step 3: Write the turn runner**

Create `skills/dual-model-debate/scripts/codex_turn.sh`:

```bash
#!/usr/bin/env bash
# Run ONE debate turn and append it to the transcript.
#
# Usage:
#   codex_turn.sh <ROLE_LABEL> <ROUND> <ROLE_KIND> <PACKET> <TRANSCRIPT>
#     ROLE_KIND: opening | rebuttal | forced
#
# The model argues from the piped packet + current transcript only, in the
# four-field format from references/protocol.md. Its final message is captured
# via `codex exec -o` (no stdout scraping) and appended under a
# "### <ROLE_LABEL> (round <ROUND>)" header.
#
# codex runs --ignore-user-config (so the caller's notify hooks, plugins, and
# personality do not perturb a reproducible turn; auth still resolves from
# CODEX_HOME), --sandbox read-only in a throwaway -C dir (so it cannot edit or
# usefully crawl the repo), and --ephemeral (no session files on disk).
#
# Env:
#   CODEX_MODEL   default gpt-5.6-sol
#   CODEX_EFFORT  default high            (minimal|low|medium|high)
#   CODEX_FAKE    if set to a file path, use its contents as the model message
#                 instead of calling codex (free dry runs and tests).
set -euo pipefail

ROLE="${1:?need role label}"
ROUND="${2:?need round number}"
KIND="${3:?need role kind: opening|rebuttal|forced}"
PACKET="${4:?need packet path}"
TRANSCRIPT="${5:?need transcript path}"

case "$KIND" in opening|rebuttal|forced) ;; *) echo "bad role kind: '$KIND' (want opening|rebuttal|forced)" >&2; exit 2 ;; esac

CODEX_MODEL="${CODEX_MODEL:-gpt-5.6-sol}"
CODEX_EFFORT="${CODEX_EFFORT:-high}"
case "$CODEX_EFFORT" in minimal|low|medium|high) ;; *) echo "bad CODEX_EFFORT: '$CODEX_EFFORT' (want minimal|low|medium|high)" >&2; exit 2 ;; esac

[ -f "$PACKET" ] || { echo "no such packet: $PACKET" >&2; exit 2; }
[ -s "$PACKET" ] || { echo "packet is empty: $PACKET" >&2; exit 2; }
touch "$TRANSCRIPT"   # may not exist on round 0

MSG=""
if [ -n "${CODEX_FAKE:-}" ]; then
  [ -f "$CODEX_FAKE" ] || { echo "CODEX_FAKE set but no such file: $CODEX_FAKE" >&2; exit 2; }
  MSG="$(cat "$CODEX_FAKE")"
else
  command -v codex >/dev/null || { echo "codex not found on PATH" >&2; exit 127; }
  SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  PROTOCOL="$SKILL_DIR/references/protocol.md"
  [ -f "$PROTOCOL" ] || { echo "protocol not found: $PROTOCOL" >&2; exit 2; }
  case "$KIND" in
    opening)  DIRECTIVE="Use the 'Honest opening (round 0)' role. You have not seen the other debater." ;;
    rebuttal) DIRECTIVE="Use the 'Rebuttal' role. Respond specifically to the other debater's latest turn in the transcript." ;;
    forced)   DIRECTIVE="Use the 'Forced opposition' role. Both debaters agreed; argue the strongest good-faith case AGAINST that consensus." ;;
  esac
  PROTOCOL_TXT="$(cat "$PROTOCOL")"
  FULL_PROMPT="You are playing: $ROLE, round $ROUND.
$DIRECTIVE
Respond ONLY in the four-field markdown turn format (Position / Argument /
Concedes / Still unresolved). Do NOT print a heading; the harness adds it.
Argue only from the <stdin> block (the packet and the transcript so far); do not
run tools or read files.

## PROTOCOL
$PROTOCOL_TXT"

  SCRATCH="$(mktemp -d /tmp/dual-model-debate-scratch.XXXXXX)"
  OUTMSG="$(mktemp /tmp/dual-model-debate-turn.XXXXXX.txt)"
  echo "codex turn: $ROLE round $ROUND ($KIND), model=$CODEX_MODEL effort=$CODEX_EFFORT" >&2
  # stdin = packet + transcript so far; final message captured via -o.
  if ! cat "$PACKET" "$TRANSCRIPT" | codex exec \
        --ignore-user-config --skip-git-repo-check --ephemeral \
        --sandbox read-only -C "$SCRATCH" \
        -m "$CODEX_MODEL" -c model_reasoning_effort="$CODEX_EFFORT" \
        -o "$OUTMSG" "$FULL_PROMPT" >/dev/null; then
    echo "codex exec failed (its stderr is above)" >&2
    rm -rf "$SCRATCH" "$OUTMSG"
    exit 1
  fi
  MSG="$(cat "$OUTMSG")"
  rm -rf "$SCRATCH" "$OUTMSG"
fi

[ -n "$MSG" ] || { echo "empty turn from $ROLE (round $ROUND)" >&2; exit 1; }

{
  echo "### $ROLE (round $ROUND)"
  echo
  echo "$MSG"
  echo
} >> "$TRANSCRIPT"

echo "$TRANSCRIPT"
```

Then make both executable: `chmod +x skills/dual-model-debate/scripts/codex_turn.sh skills/dual-model-debate/tests/test_codex_turn.sh`

- [ ] **Step 4: Run the test to verify it passes**

Run: `bash skills/dual-model-debate/tests/test_codex_turn.sh`
Expected: `codex_turn: 8 passed, 0 failed` and exit 0.

- [ ] **Step 5: Commit**

```bash
git add skills/dual-model-debate/scripts/codex_turn.sh skills/dual-model-debate/tests/test_codex_turn.sh
git commit -m "feat(dual-model-debate): add single codex turn runner

Run one read-only, packet-only GPT turn via codex exec and append it to the
transcript. CODEX_FAKE stub replays a canned turn for free dry runs and tests.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01XErHevPA1KaGGVDDYJNqTj"
```

---

### Task 4: SKILL.md playbook

**Files:**
- Create: `skills/dual-model-debate/SKILL.md`
- Test: `skills/dual-model-debate/tests/test_docs.sh`

**Interfaces:**
- Consumes: `build_packet.sh`, `codex_turn.sh`, and `references/protocol.md` from Tasks 1-3 (referenced by name in the playbook).
- Produces: the front-facing skill. `test_docs.sh` asserts the playbook names its four steps and the governance section, so those heading strings matter.

- [ ] **Step 1: Write the failing docs test**

Create `skills/dual-model-debate/tests/test_docs.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="$HERE/../SKILL.md"
PROTO="$HERE/../references/protocol.md"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1" >&2; }

[ -f "$SKILL" ] && ok || bad "SKILL.md missing"
grep -q "name: dual-model-debate" "$SKILL"             && ok || bad "frontmatter name wrong"
grep -q "## Step 1: Build the packet" "$SKILL"          && ok || bad "missing Step 1"
grep -q "## Step 2: Round 0, blind openings" "$SKILL"   && ok || bad "missing Step 2"
grep -q "## Step 3: Exchange or stress-test" "$SKILL"    && ok || bad "missing Step 3"
grep -q "## Step 4: Synthesize the decision" "$SKILL"    && ok || bad "missing Step 4"
grep -q "## Governance & operating rules" "$SKILL"       && ok || bad "missing governance"
grep -q "build_packet.sh" "$SKILL"                       && ok || bad "does not reference build_packet.sh"
grep -q "codex_turn.sh" "$SKILL"                         && ok || bad "does not reference codex_turn.sh"
grep -q "references/protocol.md" "$SKILL"                && ok || bad "does not reference protocol.md"
# no em-dashes in either doc
! grep -q "—" "$SKILL" && ok || bad "SKILL.md contains an em-dash"
! grep -q "—" "$PROTO" && ok || bad "protocol.md contains an em-dash"

echo "docs: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

Then make it executable: `chmod +x skills/dual-model-debate/tests/test_docs.sh`

- [ ] **Step 2: Run the docs test to verify it fails**

Run: `bash skills/dual-model-debate/tests/test_docs.sh`
Expected: FAIL (`SKILL.md missing`).

- [ ] **Step 3: Write SKILL.md**

Create `skills/dual-model-debate/SKILL.md`:

````markdown
---
name: dual-model-debate
description: >-
  Run a moderated dialectic between two models from two labs to decide a
  question. Claude (opus, via Claude Code) and GPT (gpt-5.6-sol, via codex)
  each argue their honest read, exchange rebuttals, and a neutral Claude
  synthesizes a recommended decision that surfaces the disagreements that
  matter. Use whenever the user wants the two models to "debate", "hash out",
  "argue both sides", get a "dialectic" or a decision on a design question or
  tradeoff, or wants a stress-tested second opinion before committing to a
  direction. Sibling to dual-model-review (which reviews a diff); this one
  decides an open question.
---

# dual-model-debate

Two debaters from two labs argue a question; a neutral Claude decides. Claude is
one debater AND the chair, so the debater turns run in a **subagent** and the
chair context never argues a side. The value is friction that survives scrutiny:
if the two agree, that agreement is stress-tested before it is trusted.

Read `references/protocol.md` first. It defines the turn format, the three roles
(honest opening / rebuttal / forced opposition), and the chair's synthesis and
escalation rules.

## Step 1: Build the packet

```bash
scripts/build_packet.sh "Should we adopt X for Y?" docs/rfc.md notes.md
```

The script assembles the packet and prints its path. **You fill the framing**
(constraints, non-goals, what a good decision looks like) in the packet before
the debate. Non-goals and constraints cut the most off-target arguments. Any
file the debate needs must be attached here, because the debaters see only the
packet.

## Step 2: Round 0, blind openings

Openings must be blind: neither debater sees the other's opening.

1. Dispatch a **subagent** to write Claude's opening from the packet only, using
   the "Honest opening (round 0)" role in `references/protocol.md`, returning
   only the four fields. Do NOT write Claude's argument in this (chair) context.
   Save it to the transcript as a block:

   ```
   ### Claude (opus) (round 0)

   <the four fields the subagent returned>
   ```

   For example: `printf '### Claude (opus) (round 0)\n\n%s\n\n' "$CLAUDE_OPENING" > /tmp/dmd-transcript.md`
2. Produce GPT's opening against a FRESH empty transcript so it cannot see
   Claude's:

   ```bash
   : > /tmp/dmd-gpt.md
   scripts/codex_turn.sh "GPT (gpt-5.6-sol)" 0 opening <packet> /tmp/dmd-gpt.md
   ```
3. Append GPT's opening to the transcript: `cat /tmp/dmd-gpt.md >> /tmp/dmd-transcript.md`

## Step 3: Exchange or stress-test

Read both openings as the chair.

- **If they disagree:** run up to 2 rebuttal rounds. Each round, first dispatch
  the subagent for Claude's rebuttal (it reads `/tmp/dmd-transcript.md` so far
  and appends its block), then run GPT's:

  ```bash
  scripts/codex_turn.sh "GPT (gpt-5.6-sol)" 1 rebuttal <packet> /tmp/dmd-transcript.md
  ```

  Stop early the moment a round adds no new substantive argument (the chair's
  stall check in the protocol). This caps GPT at 3 paid calls.
- **If they converge** on the same answer: run ONE forced-opposition round.
  Assign codex the contrarian job, so the chair Claude never argues against a
  conclusion it is about to judge:

  ```bash
  scripts/codex_turn.sh "GPT (devil's advocate)" 1 forced <packet> /tmp/dmd-transcript.md
  ```

## Step 4: Synthesize the decision

As the chair, read the whole transcript and write the brief with the template
below. Save the transcript file and link it. Apply the escalation rule: on an
unresolved subjective call where your only tiebreak is your own preference,
escalate to the human rather than ruling for Claude's side.

```markdown
# Dual-model debate: <question>

**Debaters:** Claude (opus, via Claude Code) · GPT (gpt-5.6-sol, via codex)
**Recommended decision:** <verdict>
**Confidence:** <how firm, and why>

## ⚠️ Escalated to human (unresolved, subjective)
- <disagreement> · Claude: <call> · GPT: <call> · why it needs you: <...>

## Key disagreements (each side's strongest argument)
- <topic> · Claude: <strongest point> · GPT: <strongest point> · resolved: <...>

## Genuine agreement
- <point> (mark "agreement, not verification" where neither side grounded it)

## Deciding rationale
- <why the decision follows from the debate>

## What would change this decision
- <the evidence or condition that would flip it>

## Transcript
- <path to the saved transcript>
```

Keep every heading; an empty section says "None" so its presence proves it was
checked, not skipped.

## Governance & operating rules

- **Read-only, packet-only debaters.** codex runs `--sandbox read-only` in a
  throwaway `-C` dir with `--ignore-user-config`, so it argues from the piped
  packet, not by crawling the repo or firing your codex notify hooks and
  plugins. The subagent is likewise told to argue from the packet only.
- **Bounded cost.** GPT turns are the only paid calls: at most 3 per run (an
  opening plus up to 2 rebuttals, or an opening plus one forced round). Effort
  prints to stderr.
- **Data to OpenAI.** The packet is sent to OpenAI via codex. Do not route
  secrets through it.
- **Parameters.** `CODEX_MODEL` (default `gpt-5.6-sol`), `CODEX_EFFORT` (default
  `high`; minimal|low|medium|high). Set `CODEX_FAKE=<file>` to replay a canned
  turn instead of calling codex, for a free dry run.

## Files

- `scripts/build_packet.sh`: assemble the debate packet (question + context).
- `scripts/codex_turn.sh`: run one blind, read-only GPT turn; append to transcript.
- `references/protocol.md`: turn format, the three roles, chair synthesis/escalation.
````

Note: the `## ⚠️ Escalated to human` heading contains an emoji, not an em-dash. The `test_docs.sh` em-dash check looks for the `—` character specifically, so the emoji is fine.

- [ ] **Step 4: Run the docs test to verify it passes**

Run: `bash skills/dual-model-debate/tests/test_docs.sh`
Expected: `docs: 12 passed, 0 failed` and exit 0.

- [ ] **Step 5: Commit**

```bash
git add skills/dual-model-debate/SKILL.md skills/dual-model-debate/tests/test_docs.sh
git commit -m "feat(dual-model-debate): add SKILL.md playbook

The four-step loop (packet, blind openings, exchange-or-stress-test,
synthesize), the subagent bias guard, the decision-brief template, and
governance. Docs test asserts the required sections and no em-dashes.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01XErHevPA1KaGGVDDYJNqTj"
```

---

### Task 5: Integration smoke test and skill registration

**Files:**
- Create: `skills/dual-model-debate/tests/test_integration.sh`
- Modify: `README.md` (skills table)

**Interfaces:**
- Consumes: `build_packet.sh` and `codex_turn.sh` wired together in `CODEX_FAKE` mode.
- Produces: a runnable end-to-end check (no paid calls) and a README row so the skill is discoverable.

- [ ] **Step 1: Write the failing integration test**

Create `skills/dual-model-debate/tests/test_integration.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail
# End-to-end wiring in fake mode: build a packet, seed a Claude opening block,
# run a GPT opening via the runner (CODEX_FAKE), assert the transcript carries
# both. No paid calls.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BP="$HERE/../scripts/build_packet.sh"
CT="$HERE/../scripts/codex_turn.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1" >&2; }

pkt="$("$BP" "Should we use approach A or B?")"
[ -s "$pkt" ] && ok || bad "packet not built"

tr="$(mktemp)"
printf '### Claude (opus) (round 0)\n\n**Position:** B\n**Argument:** B_scales.\n**Concedes:** nothing yet\n**Still unresolved:** cost\n\n' > "$tr"

gpt_open="$(mktemp)"; printf '**Position:** A\n**Argument:** A_is_simpler.\n**Concedes:** nothing yet\n**Still unresolved:** scale\n' > "$gpt_open"
CODEX_FAKE="$gpt_open" "$CT" "GPT (gpt-5.6-sol)" 0 opening "$pkt" "$tr" >/dev/null

grep -q "B_scales" "$tr"     && ok || bad "transcript missing Claude opening"
grep -q "A_is_simpler" "$tr" && ok || bad "transcript missing GPT opening"
grep -q "### Claude (opus) (round 0)" "$tr"      && ok || bad "missing Claude header"
grep -q "### GPT (gpt-5.6-sol) (round 0)" "$tr"  && ok || bad "missing GPT header"

echo "integration: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
```

Then make it executable: `chmod +x skills/dual-model-debate/tests/test_integration.sh`

- [ ] **Step 2: Run it to verify it passes**

Run: `bash skills/dual-model-debate/tests/test_integration.sh`
Expected: `integration: 5 passed, 0 failed` and exit 0. (The scripts already exist from Tasks 1 and 3, so this passes on first run; it is a wiring regression guard, not a red-to-green unit.)

- [ ] **Step 3: Run the whole suite once**

Run:
```bash
for t in skills/dual-model-debate/tests/*.sh; do echo "== $t"; bash "$t" || exit 1; done
```
Expected: every file prints `... passed, 0 failed` and the loop exits 0.

- [ ] **Step 4: Register the skill in the README**

In `README.md`, the skills table currently has a stale `cross-review` row (the skill was renamed to `dual-model-review`). Update that row and add the new one. Replace:

```
| `cross-review` | Two-model cross-review of a PR or design doc (Claude + GLM-5.2 via OpenCode Zen), disagreements surfaced for the human |
```

with:

```
| `dual-model-debate` | Two-model dialectic that decides a question (Claude + GPT via codex), disagreements surfaced, decision synthesized |
| `dual-model-review` | Two-model review of a PR or design doc (Claude + GLM-5.2 via OpenCode Zen), disagreements surfaced for the human |
```

- [ ] **Step 5: Link the skill into the Claude skills dirs**

Run: `make install`
Expected: the install output lists `dual-model-debate` among the linked skills (no error).

- [ ] **Step 6: Commit**

```bash
git add skills/dual-model-debate/tests/test_integration.sh README.md
git commit -m "feat(dual-model-debate): add integration smoke test and register skill

End-to-end wiring check in CODEX_FAKE mode, plus a README row. Corrects the
stale cross-review row to dual-model-review while updating the table.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01XErHevPA1KaGGVDDYJNqTj"
```

- [ ] **Step 7 (manual, optional, costs one paid codex call): one real turn**

Once the fake-mode suite is green, verify the real codex path once:

```bash
pkt="$(skills/dual-model-debate/scripts/build_packet.sh "Is a single global mutex acceptable for a request counter under low load?")"
: > /tmp/dmd-real.md
CODEX_EFFORT=low skills/dual-model-debate/scripts/codex_turn.sh "GPT (gpt-5.6-sol)" 0 opening "$pkt" /tmp/dmd-real.md
sed -n '1,40p' /tmp/dmd-real.md
```
Expected: a `### GPT (gpt-5.6-sol) (round 0)` block whose body has the four fields (Position / Argument / Concedes / Still unresolved). This confirms the codex flags, auth, and `-o` capture work end to end. Do not commit `/tmp` output.

---

## Self-Review

**1. Spec coverage.** Every spec section maps to a task:
- Mode / stance / protocol / deliverable → Task 4 (SKILL.md loop) + Task 2 (protocol roles).
- Judge bias (subagent debater, neutral chair) → Task 4 Steps 2-4 (subagent for Claude turns; chair never argues).
- Input (question + context files) → Task 1 (build_packet.sh).
- Turn format (four fields, harness owns header) → Task 2 (protocol) + Task 3 (codex_turn.sh header).
- Data flow (blind openings, converge/disagree branch, forced round) → Task 4 Steps 2-3.
- Bias guards / output template → Task 4 Steps 3-4.
- Governance (read-only, packet-only, --ignore-user-config, cost ceiling, data-to-OpenAI, params) → Task 3 (flags) + Task 4 (governance section).
- Testing (CODEX_FAKE, packet fixture, no bats) → Tasks 1, 3, 5 tests. (The fixture is created inline in each test via `mktemp`, not a committed file, which is simpler and avoids a stale fixture.)
- Follow-up: README stale-name fix → Task 5 Step 4.

**2. Placeholder scan.** No "TBD"/"TODO"/"handle errors"/"similar to Task N": every script and test is written out in full.

**3. Type consistency.** The `codex_turn.sh` signature `<ROLE_LABEL> <ROUND> <ROLE_KIND> <PACKET> <TRANSCRIPT>` with `ROLE_KIND ∈ {opening,rebuttal,forced}` is used identically in the tests (Task 3), the integration test (Task 5), and the SKILL.md call sites (Task 4). The header string `### <ROLE_LABEL> (round <ROUND>)` written by the script matches every `grep` assertion. Protocol role names (`Honest opening (round 0)`, `Rebuttal (rounds 1-2)`, `Forced opposition`) match the directives the script maps to and the `test_docs.sh` assertions.
