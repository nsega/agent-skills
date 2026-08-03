#!/usr/bin/env bash
# Plain assertions; no `set -e` so we can inspect exit codes.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BP="$HERE/../scripts/build_packet.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1" >&2; }

# 1: no question -> exit 2
"$BP" >/dev/null 2>&1; rc=$?
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
"$BP" "Q?" /no/such/file >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] && ok || bad "missing context file should exit 2 (got $rc)"

echo "build_packet: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
