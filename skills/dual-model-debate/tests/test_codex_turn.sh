#!/usr/bin/env bash
set -euo pipefail
# CODEX_FAKE stub keeps this free: no real codex call. Capture exit codes with
# `rc=0; cmd || rc=$?` under set -e.
# The developer's own overrides must not leak into the default assertions.
unset CODEX_MODEL CODEX_EFFORT
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

# 2b: the allowlist must match the real catalog (`codex debug models`): no model
# accepts "minimal" (the API 400s on it mid-turn), and the newest models accept
# max/ultra. Getting either end wrong is a silent downgrade or a bogus rejection.
rc=0; CODEX_EFFORT=minimal CODEX_FAKE="$canned" "$CT" "GPT" 0 opening "$pk" "$tr" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "CODEX_EFFORT=minimal is not a codex effort, should exit 2 (got $rc)"
for e in xhigh max ultra; do
  fresh="$(mktemp)"; : > "$fresh"
  rc=0; CODEX_EFFORT="$e" CODEX_FAKE="$canned" "$CT" "GPT" 0 opening "$pk" "$fresh" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 0 ] && ok || bad "CODEX_EFFORT=$e must be accepted (got $rc)"
done

# 3: empty packet -> exit 2
empty="$(mktemp)"; : > "$empty"
rc=0; CODEX_FAKE="$canned" "$CT" "GPT" 0 opening "$empty" "$tr" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "empty packet should exit 2 (got $rc)"

# 4: fake opening appended under the harness header
rc=0; CODEX_FAKE="$canned" "$CT" "GPT (codex)" 0 opening "$pk" "$tr" >/dev/null || rc=$?
[ "$rc" -eq 0 ] && ok || bad "fake turn should succeed (got $rc)"
grep -q "### GPT (codex) (round 0)" "$tr" && ok || bad "transcript missing turn header"
grep -q "sentinel_ABC" "$tr"                     && ok || bad "transcript missing turn body"

# 5: a second turn appends (transcript grows) with the new round header
before=$(wc -l < "$tr")
CODEX_FAKE="$canned" "$CT" "GPT (codex)" 1 rebuttal "$pk" "$tr" >/dev/null
after=$(wc -l < "$tr")
[ "$after" -gt "$before" ] && ok || bad "second turn should grow the transcript"
grep -q "(round 1)" "$tr"  && ok || bad "transcript missing round 1 header"

# 6: round 0 with a non-empty transcript -> exit 2 (blindness guard)
ne="$(mktemp)"; printf 'prior opening content\n' > "$ne"
rc=0; CODEX_FAKE="$canned" "$CT" "GPT" 0 opening "$pk" "$ne" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok || bad "round 0 with non-empty transcript should exit 2 (got $rc)"

# 7: model and effort defaults come from models.json, and the env vars win over
# it. A fake `codex` first on PATH records its argv and honours `-o FILE`.
work="$(mktemp -d)"
cat > "$work/codex" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$work/args"
cat > /dev/null
prev=""
for a in "\$@"; do
  [ "\$prev" = "-o" ] && cat "$canned" > "\$a"
  prev="\$a"
done
exit 0
EOF
chmod +x "$work/codex"
fresh="$(mktemp)"; : > "$fresh"
rc=0; PATH="$work:$PATH" DMD_OUT_DIR="$work" "$CT" "GPT" 0 opening "$pk" "$fresh" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok || bad "a turn through the fake codex should succeed (got $rc)"
grep -qx -- "gpt-6-luna" "$work/args" && ok || bad "codex model should default to gpt-6-luna"
grep -qx -- "model_reasoning_effort=medium" "$work/args" && ok || bad "codex effort should default to medium"
fresh="$(mktemp)"; : > "$fresh"
rc=0; PATH="$work:$PATH" DMD_OUT_DIR="$work" CODEX_MODEL=some-other-model CODEX_EFFORT=low \
  "$CT" "GPT" 0 opening "$pk" "$fresh" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok || bad "an overridden turn should succeed (got $rc)"
grep -qx -- "some-other-model" "$work/args" && ok || bad "CODEX_MODEL should win over models.json"
grep -qx -- "model_reasoning_effort=low" "$work/args" && ok || bad "CODEX_EFFORT should win over models.json"
rm -rf "$work"

echo "codex_turn: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
