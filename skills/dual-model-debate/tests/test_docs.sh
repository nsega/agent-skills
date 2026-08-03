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
