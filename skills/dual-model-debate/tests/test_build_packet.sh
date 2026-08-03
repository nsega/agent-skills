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

# 5: DMD_OUT_DIR set -> packet lands in that dir (created if missing)
outdir="$(mktemp -d)/nested"   # nested = not pre-created, so we also test mkdir -p
p3="$(DMD_OUT_DIR="$outdir" "$BP" "Q?")"
case "$p3" in "$outdir"/*) ok ;; *) bad "packet not under DMD_OUT_DIR (got $p3)" ;; esac
[ -f "$p3" ] && ok || bad "packet under DMD_OUT_DIR should exist"

# 6: no DMD_OUT_DIR -> default /tmp
p4="$("$BP" "Q?")"
case "$p4" in /tmp/*) ok ;; *) bad "default packet should be under /tmp (got $p4)" ;; esac

# 7: a context file that itself contains a ``` fence gets a longer wrapping fence
fcx="$(mktemp)"; printf 'before\n```\ninside\n```\nafter FENCE_SENTINEL\n' > "$fcx"
p5="$("$BP" "Q?" "$fcx")"
grep -q "FENCE_SENTINEL" "$p5"  && ok || bad "packet dropped fenced context content"
grep -qE '^`{4,}' "$p5"         && ok || bad 'packet should wrap a backtick-fenced file in a >=4 backtick fence'

echo "build_packet: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
