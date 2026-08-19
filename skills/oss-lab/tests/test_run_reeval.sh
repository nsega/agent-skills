#!/usr/bin/env bash
# `X && ok || bad` is the house test idiom; ok never fails.
# shellcheck disable=SC2015
set -euo pipefail
# Mocked end-to-end tests for run-reeval.sh: a fake `claude` on PATH records
# its argv/stdin and replays canned output; each case gets a throwaway state
# dir (a git repo with a local bare remote, so the sync path is exercised for
# real). No paid calls, no network.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RR="$HERE/../scripts/run-reeval.sh"
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

# Two queued issues: A scored 5.6 last time, B already sub-threshold once.
QA='{"issue":"kubernetes/kubernetes#111","weighted_total":5.6,"rationale_consistency":"anchor overlap","route":"queue"}'
QB='{"issue":"kubernetes-sigs/kueue#222","weighted_total":4.4,"rationale_consistency":"weak","route":"queue","reeval_count":1}'

new_state() {  # $1: case name; sets STATE, REMOTE, MOCK_LOG; queue = [QA, QB]
  STATE="$WORK/$1/state"; REMOTE="$WORK/$1/remote.git"; MOCK_LOG="$WORK/$1/log"
  mkdir -p "$STATE" "$MOCK_LOG"
  git init --quiet "$STATE"
  git -C "$STATE" config user.email test@example.com
  git -C "$STATE" config user.name test
  echo '[]' > "$STATE/seen.json"
  printf '[%s,%s]\n' "$QA" "$QB" > "$STATE/queue.json"
  git -C "$STATE" add seen.json queue.json
  git -C "$STATE" commit --quiet -m init
  git init --bare --quiet "$REMOTE"
  git -C "$STATE" remote add origin "$REMOTE"
  git -C "$STATE" push --quiet -u origin HEAD
}

run_rr() {
  env PATH="$MOCKBIN:$PATH" \
      OSS_LAB_STATE_DIR="$STATE" \
      CLAUDE_CONFIG_DIR="${TEST_CONFIG_DIR:-$HOME/.claude}" \
      MOCK_LOG="$MOCK_LOG" \
      MOCK_CLAUDE_OUT="${MOCK_CLAUDE_OUT:-/dev/null}" \
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

# 2: missing queue.json -> bootstrapped to [], exit 0, claude never invoked
new_state t2
rm "$STATE/queue.json"
rc=0; run_rr >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok || bad "missing queue should exit 0 (got $rc)"
[ "$(cat "$STATE/queue.json")" = "[]" ] && ok || bad "missing queue should be bootstrapped to []"
[ ! -e "$MOCK_LOG/claude_args" ] && ok || bad "missing queue must not invoke claude"

# 3: happy path -> drop removed, survivor updated, stamp + commit + push
new_state t3
MOCK_CLAUDE_OUT="$WORK/t3/claude_out"
printf '%s\n%s\n' \
  '{"issue":"kubernetes/kubernetes#111","weighted_total":6.1,"route":"queue","reeval_count":1}' \
  '{"issue":"kubernetes-sigs/kueue#222","weighted_total":4.2,"route":"drop","reeval_count":2}' \
  > "$MOCK_CLAUDE_OUT"
rc=0; run_rr >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok || bad "happy path should exit 0 (got $rc)"
jq -e 'length == 1' "$STATE/queue.json" >/dev/null && ok || bad "dropped issue should leave the queue"
jq -e '.[0].issue == "kubernetes/kubernetes#111" and .[0].weighted_total == 6.1 and .[0].reeval_count == 1' \
  "$STATE/queue.json" >/dev/null && ok || bad "survivor should carry the rescored fields"
grep -qE '^[0-9]+$' "$STATE/last_reeval" && ok || bad "happy path should advance the stamp"
grep -q "REEVAL=1" "$MOCK_LOG/claude_args" && ok || bad "claude prompt should carry REEVAL=1"
grep -q "okr_alignment" "$MOCK_LOG/claude_args" && ok || bad "claude prompt should carry the rubric"
grep -qx -- "--tools" "$MOCK_LOG/claude_args" && ok || bad "claude should run with --tools"
# The scorer must hold NO tools: it reads text that originated in untrusted
# public issues, so any tool is an exfiltration path for the state repo env.
[ -z "$(grep -A1 -x -- "--tools" "$MOCK_LOG/claude_args" | tail -1)" ] \
  && ok || bad "--tools must be empty so every tool is disabled"
grep -qx -- "--allowedTools" "$MOCK_LOG/claude_args" \
  && bad "claude must not be granted tools via --allowedTools" || ok
[ "$(wc -l < "$MOCK_LOG/claude_stdin" | tr -d ' ')" -eq 2 ] && ok || bad "claude stdin should carry both queue items as JSONL"
grep -q "kubernetes/kubernetes#111" "$MOCK_LOG/claude_stdin" && ok || bad "claude stdin missing queue item A"
[ "$(git -C "$STATE" log -1 --pretty=%s)" = "reeval: $(date +%Y-%m-%d) 2 rescored, 1 dropped" ] \
  && ok || bad "state commit message wrong (got: $(git -C "$STATE" log -1 --pretty=%s))"
[ "$(git -C "$STATE" show --name-only --pretty=format: HEAD | grep -v '^$')" = "queue.json" ] \
  && ok || bad "state commit should touch only queue.json"
[ "$(git -C "$REMOTE" log -1 --pretty=%s)" = "$(git -C "$STATE" log -1 --pretty=%s)" ] \
  && ok || bad "state commit should be pushed to the remote"

# 4: unparseable claude output -> exit 1, queue untouched, stamp NOT advanced
new_state t4
MOCK_CLAUDE_OUT="$WORK/t4/claude_out"
printf 'I could not score these issues today.\n' > "$MOCK_CLAUDE_OUT"
cp "$STATE/queue.json" "$WORK/t4/queue.before"
rc=0; err="$(run_rr 2>&1 >/dev/null)" || rc=$?
[ "$rc" -eq 1 ] && ok || bad "garbage output should exit 1 (got $rc)"
cmp -s "$STATE/queue.json" "$WORK/t4/queue.before" && ok || bad "garbage output must leave the queue untouched"
[ ! -e "$STATE/last_reeval" ] && ok || bad "garbage output must not advance the stamp"
echo "$err" | grep -q "no parseable" && ok || bad "garbage output should explain the abort"

# 5: fences and prose around valid JSON lines -> tolerated
new_state t5
MOCK_CLAUDE_OUT="$WORK/t5/claude_out"
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

# 6: partial results -> unscored issue stays queued untouched
new_state t6
MOCK_CLAUDE_OUT="$WORK/t6/claude_out"
printf '%s\n' \
  '{"issue":"kubernetes/kubernetes#111","weighted_total":6.1,"route":"queue","reeval_count":1}' \
  > "$MOCK_CLAUDE_OUT"
rc=0; run_rr >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok || bad "partial results should exit 0 (got $rc)"
jq -e 'length == 2' "$STATE/queue.json" >/dev/null && ok || bad "unscored issue must not be lost"
jq -e '.[] | select(.issue == "kubernetes-sigs/kueue#222") | .weighted_total == 4.4 and .reeval_count == 1' \
  "$STATE/queue.json" >/dev/null && ok || bad "unscored issue should keep its previous fields"

# 7: wrong CLAUDE_CONFIG_DIR -> abort before claude
new_state t7
rc=0; TEST_CONFIG_DIR="$WORK/t7/other" run_rr >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] && ok || bad "wrong config dir should exit 1 (got $rc)"
[ ! -e "$MOCK_LOG/claude_args" ] && ok || bad "wrong config dir must not invoke claude"
[ ! -e "$STATE/last_reeval" ] && ok || bad "wrong config dir must not advance the stamp"

# 8: push failure -> warn but exit 0; queue and stamp still updated
new_state t8
git -C "$STATE" remote set-url origin "$WORK/t8/no-such-remote.git"
MOCK_CLAUDE_OUT="$WORK/t8/claude_out"
printf '%s\n%s\n' \
  '{"issue":"kubernetes/kubernetes#111","weighted_total":6.1,"route":"queue","reeval_count":1}' \
  '{"issue":"kubernetes-sigs/kueue#222","weighted_total":4.2,"route":"drop","reeval_count":2}' \
  > "$MOCK_CLAUDE_OUT"
rc=0; err="$(run_rr 2>&1 >/dev/null)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "push failure should not fail the pass (got $rc)"
echo "$err" | grep -q "state sync incomplete" && ok || bad "push failure should warn"
jq -e 'length == 1' "$STATE/queue.json" >/dev/null && ok || bad "queue should still be rewritten on push failure"
grep -qE '^[0-9]+$' "$STATE/last_reeval" && ok || bad "stamp should still advance on push failure"

# 9: state dir that is not a git repo -> sync silently skipped
STATE="$WORK/t9/state"; MOCK_LOG="$WORK/t9/log"
mkdir -p "$STATE" "$MOCK_LOG"
printf '[%s,%s]\n' "$QA" "$QB" > "$STATE/queue.json"
MOCK_CLAUDE_OUT="$WORK/t9/claude_out"
printf '%s\n%s\n' \
  '{"issue":"kubernetes/kubernetes#111","weighted_total":6.1,"route":"queue","reeval_count":1}' \
  '{"issue":"kubernetes-sigs/kueue#222","weighted_total":4.2,"route":"drop","reeval_count":2}' \
  > "$MOCK_CLAUDE_OUT"
rc=0; run_rr >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok || bad "non-git state dir should exit 0 (got $rc)"
jq -e 'length == 1' "$STATE/queue.json" >/dev/null && ok || bad "non-git state dir should still rewrite the queue"

echo "run_reeval: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
