#!/usr/bin/env bash
# Mocked end-to-end tests for run-reeval.sh: fake `claude`, `gh`, and `curl`
# on PATH, each case in a throwaway state dir (a git repo with a local bare
# remote, so the sync path is exercised for real). Promotion behaviour lives
# in test_claims_and_promotion.sh; this suite covers the re-scoring pass
# itself. No paid calls, no network.
# shellcheck disable=SC2015,SC1091
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
RR="$HERE/../scripts/run-reeval.sh"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MOCKBIN="$WORK/bin"; build_mockbin "$MOCKBIN"

# Two queued issues: A scored 5.6 last time, B already sub-threshold once.
QA='{"issue":"kubernetes/kubernetes#111","weighted_total":5.6,"rationale_consistency":"anchor overlap","route":"queue"}'
QB='{"issue":"kubernetes-sigs/kueue#222","weighted_total":4.4,"rationale_consistency":"weak","route":"queue","reeval_count":1}'

new_state() {  # $1: case name; sets STATE, REMOTE, MOCK_LOG; queue = [QA, QB]
  STATE="$WORK/$1/state"; MOCK_LOG="$WORK/$1/log"; mkdir -p "$MOCK_LOG"
  build_state "$STATE" --git
  REMOTE="$STATE.remote.git"
  printf '[%s,%s]\n' "$QA" "$QB" > "$STATE/queue.json"
  git -C "$STATE" commit --quiet -am seed
}

run_rr() {
  env PATH="$MOCKBIN:$PATH" \
      OSS_LAB_STATE_DIR="$STATE" \
      CLAUDE_CONFIG_DIR="${TEST_CONFIG_DIR:-$HOME/.claude}" \
      MOCK_LOG="$MOCK_LOG" \
      MOCK_CLAUDE_OUT="${MOCK_CLAUDE_OUT:-/dev/null}" \
      MOCK_WIP="${MOCK_WIP:-3}" \
      MOCK_GH_LOGIN=nsega \
      OSS_LAB_WIP_CAP="${OSS_LAB_WIP_CAP:-4}" \
      "$RR"
}

# 1: empty queue -> exit 0, claude never invoked, stamp advanced
new_state t1
echo '[]' > "$STATE/queue.json"
rc=0; out="$(run_rr 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "empty queue should exit 0 (got $rc)"
echo "$out" | grep -q "claude not invoked" && ok || bad "empty queue should report claude not invoked"
[ ! -e "$MOCK_LOG/claude_args" ] && ok || bad "empty queue must not invoke claude"
grep -qE '^[0-9]+$' "$STATE/last_reeval" && ok || bad "empty queue should still advance the stamp"

# 2: happy path -> A survives rescored, B drops after a second sub-threshold
new_state t2
MOCK_CLAUDE_OUT="$WORK/t2/claude_out"
printf '%s\n' \
  '{"issue":"kubernetes/kubernetes#111","weighted_total":6.1,"rationale_consistency":"r","route":"queue","reeval_count":1}' \
  '{"issue":"kubernetes-sigs/kueue#222","weighted_total":4.2,"rationale_consistency":"r","route":"drop","reeval_count":2}' \
  > "$MOCK_CLAUDE_OUT"
rc=0; run_rr >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok || bad "happy path should exit 0 (got $rc)"
jq -e 'length == 1' "$STATE/queue.json" >/dev/null && ok || bad "dropped issue should leave the queue"
jq -e '.[0].issue == "kubernetes/kubernetes#111" and .[0].weighted_total == 6.1 and .[0].reeval_count == 1' \
  "$STATE/queue.json" >/dev/null && ok || bad "survivor should carry the rescored fields"
grep -qE '^[0-9]+$' "$STATE/last_reeval" && ok || bad "happy path should advance the stamp"
grep -q "REEVAL=1" "$MOCK_LOG/claude_args" && ok || bad "claude prompt should carry REEVAL=1"
grep -q "okr_alignment" "$MOCK_LOG/claude_args" && ok || bad "claude prompt should carry the rubric"
grep -q "WIP_COUNT=3" "$MOCK_LOG/claude_args" && ok || bad "claude prompt should carry WIP_COUNT"
# 4 is neither the shipped default nor WIP_COUNT, so this only passes if
# the runner really forwards the configured cap.
grep -q "WIP_CAP=4" "$MOCK_LOG/claude_args" && ok || bad "claude prompt should carry WIP_CAP"
grep -qx -- "--tools" "$MOCK_LOG/claude_args" && ok || bad "claude should run with --tools"
# The scorer must hold NO tools: it reads text that originated in untrusted
# public issues, so any tool is an exfiltration path for the state repo env.
[ -z "$(grep -A1 -x -- "--tools" "$MOCK_LOG/claude_args" | tail -1)" ] \
  && ok || bad "--tools must be empty so every tool is disabled"
grep -qx -- "--allowedTools" "$MOCK_LOG/claude_args" \
  && bad "claude must not be granted tools via --allowedTools" || ok
[ "$(wc -l < "$MOCK_LOG/claude_stdin" | tr -d ' ')" -eq 2 ] && ok || bad "claude stdin should carry both queue items as JSONL"
grep -q "kubernetes/kubernetes#111" "$MOCK_LOG/claude_stdin" && ok || bad "claude stdin missing queue item A"
git -C "$STATE" log -1 --pretty=%s | grep -q "^reeval: .* 2 rescored, 0 promoted, 1 dropped$" \
  && ok || bad "state commit message wrong (got: $(git -C "$STATE" log -1 --pretty=%s))"
[ "$(git -C "$STATE" show --name-only --pretty=format: HEAD | grep -v '^$')" = "queue.json" ] \
  && ok || bad "state commit should touch only queue.json"
[ "$(git -C "$REMOTE" log -1 --pretty=%s)" = "$(git -C "$STATE" log -1 --pretty=%s)" ] \
  && ok || bad "state commit should be pushed to the remote"

# 3: unparseable claude output -> exit 1, queue untouched, stamp NOT advanced
new_state t3
MOCK_CLAUDE_OUT="$WORK/t3/claude_out"
printf 'I could not score these issues today.\n' > "$MOCK_CLAUDE_OUT"
cp "$STATE/queue.json" "$WORK/t3/queue.before"
rc=0; err="$(run_rr 2>&1 >/dev/null)" || rc=$?
[ "$rc" -eq 1 ] && ok || bad "garbage output should exit 1 (got $rc)"
cmp -s "$STATE/queue.json" "$WORK/t3/queue.before" && ok || bad "garbage output must leave the queue untouched"
[ ! -e "$STATE/last_reeval" ] && ok || bad "garbage output must not advance the stamp"
echo "$err" | grep -q "no parseable" && ok || bad "garbage output should explain the abort"

# 4: fences and prose around valid JSON lines -> tolerated
new_state t4
MOCK_CLAUDE_OUT="$WORK/t4/claude_out"
cat > "$MOCK_CLAUDE_OUT" <<'EOF'
Here are the rescored issues:
```json
{"issue":"kubernetes/kubernetes#111","weighted_total":6.1,"route":"queue","reeval_count":1}
{"issue":"kubernetes-sigs/kueue#222","weighted_total":4.2,"route":"drop","reeval_count":2}
```
EOF
rc=0; run_rr >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok || bad "fenced output should exit 0 (got $rc)"
jq -e 'length == 1 and .[0].weighted_total == 6.1' "$STATE/queue.json" >/dev/null \
  && ok || bad "fenced output should still rewrite the queue"

# 5: partial results -> unscored issue stays queued untouched
new_state t5
MOCK_CLAUDE_OUT="$WORK/t5/claude_out"
printf '%s\n' \
  '{"issue":"kubernetes/kubernetes#111","weighted_total":6.1,"route":"queue","reeval_count":1}' \
  > "$MOCK_CLAUDE_OUT"
rc=0; run_rr >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok || bad "partial results should exit 0 (got $rc)"
jq -e 'length == 2' "$STATE/queue.json" >/dev/null && ok || bad "unscored issue must not be lost"
jq -e '.[] | select(.issue == "kubernetes-sigs/kueue#222") | .weighted_total == 4.4 and .reeval_count == 1' \
  "$STATE/queue.json" >/dev/null && ok || bad "unscored issue should keep its previous fields"

# 6: an object with no .issue is skipped rather than wedging the merge
new_state t6
MOCK_CLAUDE_OUT="$WORK/t6/claude_out"
printf '%s\n' \
  '{"route":"drop","weighted_total":1.0}' \
  '{"issue":"kubernetes-sigs/kueue#222","weighted_total":4.2,"route":"drop","reeval_count":2}' \
  > "$MOCK_CLAUDE_OUT"
rc=0; run_rr >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok || bad "issue-less object should not wedge the pass (got $rc)"
jq -e 'length == 1 and .[0].issue == "kubernetes/kubernetes#111"' "$STATE/queue.json" >/dev/null \
  && ok || bad "issue-less object must not corrupt the queue"

# 7: wrong CLAUDE_CONFIG_DIR -> abort before claude
new_state t7
rc=0; TEST_CONFIG_DIR="$WORK/t7/other" run_rr >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] && ok || bad "wrong config dir should exit 1 (got $rc)"
[ ! -e "$MOCK_LOG/claude_args" ] && ok || bad "wrong config dir must not invoke claude"

# 8: Todoist unreachable -> abort BEFORE the paid call, stamp intact
new_state t8
MOCK_CLAUDE_OUT="$WORK/t8/claude_out"; echo '{}' > "$MOCK_CLAUDE_OUT"
rc=0; err="$(env MOCK_TODOIST_DOWN=1 \
  PATH="$MOCKBIN:$PATH" OSS_LAB_STATE_DIR="$STATE" CLAUDE_CONFIG_DIR="$HOME/.claude" \
  MOCK_LOG="$MOCK_LOG" MOCK_CLAUDE_OUT="$MOCK_CLAUDE_OUT" "$RR" 2>&1 >/dev/null)" || rc=$?
[ "$rc" -eq 1 ] && ok || bad "unreachable todoist should exit 1 (got $rc)"
[ ! -e "$MOCK_LOG/claude_args" ] && ok || bad "unreachable todoist must abort before the paid call"
[ ! -e "$STATE/last_reeval" ] && ok || bad "unreachable todoist must not advance the stamp"

summary run_reeval
