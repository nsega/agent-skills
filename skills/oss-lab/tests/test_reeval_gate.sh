#!/usr/bin/env bash
# Mocked end-to-end tests for the weekly reeval gate in run-scout.sh: fake
# `claude`, `gh`, and `curl` on PATH, a throwaway state dir (not a git repo,
# so state sync is a no-op), and a fetch that returns nothing so the scout
# takes its "no new issues" early exit after the gate has run. No paid
# calls, no network.
# shellcheck disable=SC2015,SC1091
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
RS="$HERE/../scripts/run-scout.sh"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MOCKBIN="$WORK/bin"; build_mockbin "$MOCKBIN"

QA='{"issue":"kubernetes/kubernetes#111","weighted_total":5.6,"route":"queue"}'

new_state() {  # $1: case name; sets STATE, MOCK_LOG, MOCK_CLAUDE_OUT
  STATE="$WORK/$1/state"; MOCK_LOG="$WORK/$1/log"; mkdir -p "$MOCK_LOG"
  build_state "$STATE"
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
      MOCK_WIP="${MOCK_WIP:-3}" \
      MOCK_GH_LOGIN=nsega \
      "$RS"
}

# 1: no stamp -> reeval runs, scout still completes its no-new-issues exit
new_state g1
rc=0; out="$(run_scout 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "no stamp: scout should exit 0 (got $rc)"
echo "$out" | grep -q "no new issues" && ok || bad "no stamp: scout should still take the empty-fetch exit"
# The scout exits before its own paid call when the fetch is empty, so any
# claude invocation here is the weekly pass.
[ -e "$MOCK_LOG/claude_args" ] && ok || bad "no stamp: reeval should invoke claude"
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

# 6: revalidation runs even on a quiet hour, i.e. before the fetch guard.
# Freeing a slot held by work someone else took must not wait for the next
# issue to appear.
new_state g6
date +%s > "$STATE/last_reeval"   # keep reeval out of the way
echo '[{"id":"z1","content":"Contribute: k8s/k8s#9 (score 7.5)","labels":["oss-lab"]}]' > "$WORK/g6/tasks.json"
echo '{"k8s/k8s#9": {"state":"closed","assignees":[]}}' > "$WORK/g6/issues.json"
rc=0; out="$(env PATH="$MOCKBIN:$PATH" OSS_LAB_STATE_DIR="$STATE" \
  CLAUDE_CONFIG_DIR="$HOME/.claude" MOCK_LOG="$MOCK_LOG" \
  MOCK_CLAUDE_OUT="$MOCK_CLAUDE_OUT" MOCK_GH_LOGIN=nsega \
  MOCK_TASKS_JSON="$WORK/g6/tasks.json" MOCK_ISSUES_JSON="$WORK/g6/issues.json" \
  "$RS" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "quiet hour: scout should exit 0 (got $rc)"
echo "$out" | grep -q "no new issues" && ok || bad "quiet hour: should still take the empty-fetch exit"
grep -q "z1" "$MOCK_LOG/todoist_closed" 2>/dev/null && ok || bad "quiet hour: revalidation should still free the stale slot"

# 7: task revalidation runs BEFORE the weekly pass, so the promotion budget
# is computed from live work. The reeval reads the WIP count to size its
# budget; if a dead task still occupies a cap slot at that moment the budget
# is short (or zero) for a whole week, since the stamp advances either way.
# This is the same "revalidate before you decide" rule the queue prune
# follows, one layer up.
new_state g7
rm -f "$STATE/last_reeval"        # no stamp: the weekly pass is due
echo '[{"id":"d1","content":"Contribute: k8s/k8s#4 (score 7.5)","labels":["oss-lab"]}]' > "$WORK/g7/tasks.json"
echo '{"k8s/k8s#4": {"state":"closed","assignees":[]}}' > "$WORK/g7/issues.json"
rc=0; env PATH="$MOCKBIN:$PATH" OSS_LAB_STATE_DIR="$STATE" \
  CLAUDE_CONFIG_DIR="$HOME/.claude" MOCK_LOG="$MOCK_LOG" \
  MOCK_CLAUDE_OUT="$MOCK_CLAUDE_OUT" MOCK_GH_LOGIN=nsega MOCK_WIP=3 \
  MOCK_TASKS_JSON="$WORK/g7/tasks.json" MOCK_ISSUES_JSON="$WORK/g7/issues.json" \
  "$RS" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok || bad "ordering: scout should exit 0 (got $rc)"
grep -q "d1" "$MOCK_LOG/todoist_closed" 2>/dev/null \
  && ok || bad "ordering: the dead task should be closed"
[ -e "$MOCK_LOG/claude_args" ] && ok || bad "ordering: the weekly pass should still run"
# The sequence log is appended by the mocks in call order.
[ "$(grep -n -m1 close "$MOCK_LOG/sequence" | cut -d: -f1)" -lt \
  "$(grep -n -m1 claude "$MOCK_LOG/sequence" | cut -d: -f1)" ] \
  && ok || bad "ordering: the task must be freed BEFORE the paid pass sizes its budget (sequence: $(tr '\n' ' ' < "$MOCK_LOG/sequence"))"

summary reeval_gate
