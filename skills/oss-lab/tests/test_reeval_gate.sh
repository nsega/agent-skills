#!/usr/bin/env bash
# `X && ok || bad` is the house test idiom; ok never fails.
# shellcheck disable=SC2015
set -euo pipefail
# Mocked end-to-end tests for the weekly reeval gate in run-scout.sh: fake
# `claude` and `gh` on PATH, a throwaway state dir (not a git repo, so state
# sync is a no-op), and a fetch that returns nothing so the scout takes its
# "no new issues" early exit after the gate has run. No paid calls, no network.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RS="$HERE/../scripts/run-scout.sh"
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1" >&2; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

MOCKBIN="$WORK/bin"; mkdir -p "$MOCKBIN"
cat > "$MOCKBIN/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$MOCK_LOG/claude_args"
cat > "$MOCK_LOG/claude_stdin"
cat "$MOCK_CLAUDE_OUT"
EOF
chmod +x "$MOCKBIN/claude"
cat > "$MOCKBIN/gh" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$MOCKBIN/gh"

QA='{"issue":"kubernetes/kubernetes#111","weighted_total":5.6,"route":"queue"}'

new_state() {  # $1: case name; sets STATE, MOCK_LOG, MOCK_CLAUDE_OUT
  STATE="$WORK/$1/state"; MOCK_LOG="$WORK/$1/log"
  mkdir -p "$STATE" "$MOCK_LOG"
  printf 'TODOIST_TOKEN=x\nTODOIST_PROJECT_ID=y\n' > "$STATE/env"
  echo '[]' > "$STATE/seen.json"
  printf '[%s]\n' "$QA" > "$STATE/queue.json"
  MOCK_CLAUDE_OUT="$WORK/$1/claude_out"
  printf '%s\n' \
    '{"issue":"kubernetes/kubernetes#111","weighted_total":6.0,"route":"queue","reeval_count":1}' \
    > "$MOCK_CLAUDE_OUT"
}

run_scout() {
  env PATH="$MOCKBIN:$PATH" \
      OSS_LAB_STATE_DIR="$STATE" \
      CLAUDE_CONFIG_DIR="$HOME/.claude" \
      MOCK_LOG="$MOCK_LOG" \
      MOCK_CLAUDE_OUT="$MOCK_CLAUDE_OUT" \
      "$RS"
}

# 1: no stamp -> reeval runs, scout still completes its no-new-issues exit
new_state g1
rc=0; out="$(run_scout 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "no stamp: scout should exit 0 (got $rc)"
echo "$out" | grep -q "no new issues" && ok || bad "no stamp: scout should still take the empty-fetch exit"
grep -q "REEVAL=1" "$MOCK_LOG/claude_args" 2>/dev/null && ok || bad "no stamp: reeval should invoke claude with REEVAL=1"
grep -qE '^[0-9]+$' "$STATE/last_reeval" && ok || bad "no stamp: reeval should write the stamp"

# 2: fresh stamp -> reeval skipped
new_state g2
date +%s > "$STATE/last_reeval"
rc=0; run_scout >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok || bad "fresh stamp: scout should exit 0 (got $rc)"
[ ! -e "$MOCK_LOG/claude_args" ] && ok || bad "fresh stamp: reeval must not run"

# 3: stamp 7 days old -> reeval runs
new_state g3
echo "$(( $(date +%s) - 7 * 86400 ))" > "$STATE/last_reeval"
rc=0; run_scout >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok || bad "old stamp: scout should exit 0 (got $rc)"
[ -e "$MOCK_LOG/claude_args" ] && ok || bad "old stamp: reeval should run"

# 4: garbage stamp -> treated as never run, reeval runs, no crash
new_state g4
echo "not-a-number" > "$STATE/last_reeval"
rc=0; run_scout >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok || bad "garbage stamp: scout should exit 0 (got $rc)"
[ -e "$MOCK_LOG/claude_args" ] && ok || bad "garbage stamp: reeval should run"

# 5: reeval failure -> scout warns but completes; stamp not advanced
new_state g5
printf 'no json here\n' > "$MOCK_CLAUDE_OUT"
rc=0; err="$(run_scout 2>&1 >/dev/null)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "reeval failure: scout should still exit 0 (got $rc)"
echo "$err" | grep -q "reeval pass failed" && ok || bad "reeval failure: scout should warn"
[ ! -e "$STATE/last_reeval" ] && ok || bad "reeval failure: stamp must not advance"

echo "reeval_gate: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
