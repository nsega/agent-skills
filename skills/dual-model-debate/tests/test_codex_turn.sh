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

# 6: round 0 with a non-empty transcript -> exit 2 (blindness guard)
ne="$(mktemp)"; printf 'prior opening content\n' > "$ne"
rc=0; CODEX_FAKE="$canned" "$CT" "GPT" 0 opening "$pk" "$ne" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "round 0 with non-empty transcript should exit 2 (got $rc)"

echo "codex_turn: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
