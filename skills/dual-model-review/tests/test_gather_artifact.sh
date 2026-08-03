#!/usr/bin/env bash
set -euo pipefail
# Plain assertions; capture exit codes with `rc=0; cmd || rc=$?` under set -e.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GA="$HERE/../scripts/gather_artifact.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1" >&2; }

# 1: bad --level -> exit 2
rc=0; "$GA" pr --level bogus >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "bad --level should exit 2 (got $rc)"

# 2: unknown mode -> exit 2
rc=0; "$GA" bogusmode >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "unknown mode should exit 2 (got $rc)"

# 3: design mode packet has the document body and the framing sections
doc="$(mktemp)"; printf '# My design\nDETAIL_SENTINEL\n' > "$doc"
p="$("$GA" design "$doc")"
[ -f "$p" ] && ok || bad "design mode should print a packet path"
grep -q "DETAIL_SENTINEL" "$p" && ok || bad "packet missing the document body"
grep -q "## Purpose" "$p"      && ok || bad "packet missing framing"

# 4: a --tests file that itself contains a ``` fence gets a length-safe fence
tf="$(mktemp)"; printf 'PASS 3/3\n```\nboom fence\n```\nTESTS_SENTINEL\n' > "$tf"
p2="$("$GA" design "$doc" --tests "$tf")"
grep -q "TESTS_SENTINEL" "$p2" && ok || bad "packet dropped fenced test content"
grep -qE '^`{4,}' "$p2"        && ok || bad 'tests block should use a >=4 backtick fence when content has a fence'

echo "gather_artifact: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
