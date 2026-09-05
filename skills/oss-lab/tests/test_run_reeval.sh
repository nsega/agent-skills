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
      MOCK_ISSUES_JSON="${MOCK_ISSUES_JSON:-}" \
      MOCK_COMMENTS_JSON="${MOCK_COMMENTS_JSON:-}" \
      MOCK_LINKED="${MOCK_LINKED:-}" \
      MOCK_GH_DOWN="${MOCK_GH_DOWN:-}" \
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
git -C "$STATE" log -1 --pretty=%s | grep -q "^reeval: .* 2 rescored, 0 promoted, 0 stale-pruned, 1 dropped$" \
  && ok || bad "state commit message wrong (got: $(git -C "$STATE" log -1 --pretty=%s))"
[ "$(git -C "$STATE" show --name-only --pretty=format: HEAD | grep -v '^$')" = "queue.json" ] \
  && ok || bad "state commit should touch only queue.json"
[ "$(git -C "$REMOTE" log -1 --pretty=%s)" = "$(git -C "$STATE" log -1 --pretty=%s)" ] \
  && ok || bad "state commit should be pushed to the remote"

# 3: unparseable claude output -> exit 1, stamp NOT advanced, and not one
# re-scored field applied. The free revalidation that ran before the paid
# call is deliberately kept: it is correct whatever Claude returned, and
# re-deriving it next hour would re-pay the GitHub calls. The rewritten
# queue simply stays uncommitted until the next successful sync.
new_state t3
MOCK_CLAUDE_OUT="$WORK/t3/claude_out"
printf 'I could not score these issues today.\n' > "$MOCK_CLAUDE_OUT"
echo '{"kubernetes-sigs/kueue#222": {"state":"closed","assignees":[]}}' > "$WORK/t3/issues.json"
rc=0; err="$(MOCK_ISSUES_JSON="$WORK/t3/issues.json" run_rr 2>&1 >/dev/null)" || rc=$?
[ "$rc" -eq 1 ] && ok || bad "garbage output should exit 1 (got $rc)"
jq -e '[.[].issue] == ["kubernetes/kubernetes#111"]' "$STATE/queue.json" >/dev/null \
  && ok || bad "garbage output should keep the prune and lose nothing else"
jq -e '.[0].weighted_total == 5.6 and (.[0] | has("reeval_count") | not)' "$STATE/queue.json" >/dev/null \
  && ok || bad "garbage output must not apply a re-scored field"
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

# ---- queue revalidation (Guard R2) ------------------------------------
# The weekly pass used to re-score whatever sat in the queue, so an issue
# that closed, got assigned, or grew a linked PR after being queued was
# paid for every week and never left: a settled issue keeps scoring 5-7,
# so the two-strike drop never fires. These cases pin the zero-token prune
# that now runs before the paid call.

# 9: a closed queued issue is pruned, and never reaches the paid call
new_state t9
MOCK_CLAUDE_OUT="$WORK/t9/claude_out"
printf '%s\n' \
  '{"issue":"kubernetes/kubernetes#111","weighted_total":6.1,"route":"queue","reeval_count":1}' \
  > "$MOCK_CLAUDE_OUT"
echo '{"kubernetes-sigs/kueue#222": {"state":"closed","assignees":[]}}' > "$WORK/t9/issues.json"
rc=0; out="$(MOCK_ISSUES_JSON="$WORK/t9/issues.json" run_rr 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "prune closed: should exit 0 (got $rc)"
jq -e '[.[].issue] == ["kubernetes/kubernetes#111"]' "$STATE/queue.json" >/dev/null \
  && ok || bad "prune closed: settled issue should leave the queue, the live one stay"
grep -q "kueue#222" "$MOCK_LOG/claude_stdin" \
  && bad "prune closed: settled issue must not reach the paid call" || ok
[ "$(wc -l < "$MOCK_LOG/claude_stdin" | tr -d ' ')" -eq 1 ] \
  && ok || bad "prune closed: only the live issue should be re-scored"
echo "$out" | grep -q "revalidate: dequeued kubernetes-sigs/kueue#222 (closed)" \
  && ok || bad "prune closed: should log the issue and the reason"
git -C "$STATE" log -1 --pretty=%s | grep -q "^reeval: .* 1 rescored, 0 promoted, 1 stale-pruned, 0 dropped$" \
  && ok || bad "prune closed: commit message should report the prune (got: $(git -C "$STATE" log -1 --pretty=%s))"

# 10: an issue assigned to someone else is pruned
new_state t10
MOCK_CLAUDE_OUT="$WORK/t10/claude_out"
printf '%s\n' \
  '{"issue":"kubernetes/kubernetes#111","weighted_total":6.1,"route":"queue","reeval_count":1}' \
  > "$MOCK_CLAUDE_OUT"
echo '{"kubernetes-sigs/kueue#222": {"state":"open","assignees":[{"login":"someone-else"}]}}' \
  > "$WORK/t10/issues.json"
rc=0; out="$(MOCK_ISSUES_JSON="$WORK/t10/issues.json" run_rr 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "prune assigned: should exit 0 (got $rc)"
jq -e '[.[].issue] == ["kubernetes/kubernetes#111"]' "$STATE/queue.json" >/dev/null \
  && ok || bad "prune assigned: taken issue should leave the queue"
echo "$out" | grep -q "dequeued kubernetes-sigs/kueue#222 (assigned to someone-else)" \
  && ok || bad "prune assigned: should name who took it"

# 11: an issue that grew a linked PR is pruned
new_state t11
MOCK_CLAUDE_OUT="$WORK/t11/claude_out"
printf '%s\n' \
  '{"issue":"kubernetes-sigs/kueue#222","weighted_total":6.1,"route":"queue","reeval_count":1}' \
  > "$MOCK_CLAUDE_OUT"
rc=0; out="$(MOCK_LINKED="111" run_rr 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "prune linked: should exit 0 (got $rc)"
jq -e '[.[].issue] == ["kubernetes-sigs/kueue#222"]' "$STATE/queue.json" >/dev/null \
  && ok || bad "prune linked: issue with a linked PR should leave the queue"
echo "$out" | grep -q "dequeued kubernetes/kubernetes#111 (has a linked PR)" \
  && ok || bad "prune linked: should log the reason"

# 12: GitHub unreachable -> nothing is pruned, and nothing is re-scored.
# "unknown" must never read as settled, or one network blip empties the
# queue; and with no upstream copy of any issue the paid call would only be
# re-grading last week's score, so the pass aborts without advancing the
# stamp and retries next hour like every other abort.
new_state t12
MOCK_CLAUDE_OUT="$WORK/t12/claude_out"
printf '%s\n' \
  '{"issue":"kubernetes/kubernetes#111","weighted_total":6.1,"route":"queue","reeval_count":1}' \
  > "$MOCK_CLAUDE_OUT"
rc=0; err="$(MOCK_GH_DOWN=1 run_rr 2>&1 >/dev/null)" || rc=$?
[ "$rc" -eq 1 ] && ok || bad "gh down: should abort with exit 1 (got $rc)"
jq -e 'length == 2' "$STATE/queue.json" >/dev/null \
  && ok || bad "gh down: an unreachable GitHub must not empty the queue"
[ ! -e "$MOCK_LOG/claude_args" ] && ok || bad "gh down: with no upstream evidence the paid call must not run"
[ ! -e "$STATE/last_reeval" ] && ok || bad "gh down: stamp must not advance"
echo "$err" | grep -q "stamp not advanced" && ok || bad "gh down: should explain the abort"

# 13: pruning the whole queue skips the paid call entirely
new_state t13
MOCK_CLAUDE_OUT="$WORK/t13/claude_out"; echo '{}' > "$MOCK_CLAUDE_OUT"
cat > "$WORK/t13/issues.json" <<'JSON'
{"kubernetes/kubernetes#111": {"state":"closed","assignees":[]},
 "kubernetes-sigs/kueue#222": {"state":"closed","assignees":[]}}
JSON
rc=0; out="$(MOCK_ISSUES_JSON="$WORK/t13/issues.json" run_rr 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "prune all: should exit 0 (got $rc)"
[ ! -e "$MOCK_LOG/claude_args" ] && ok || bad "prune all: an all-settled queue must not invoke claude"
jq -e 'length == 0' "$STATE/queue.json" >/dev/null && ok || bad "prune all: queue should be empty"
grep -qE '^[0-9]+$' "$STATE/last_reeval" && ok || bad "prune all: stamp should still advance"
echo "$out" | grep -q "claude not invoked" && ok || bad "prune all: should report the skipped call"
git -C "$STATE" log -1 --pretty=%s | grep -q "^reeval: .* 0 rescored, 0 promoted, 2 stale-pruned, 0 dropped$" \
  && ok || bad "prune all: the empty queue should still be committed (got: $(git -C "$STATE" log -1 --pretty=%s))"

# 14: Todoist unreachable -> abort before the prune mutates anything.
# Every abort must come before the first write, so a failed pass leaves
# the state exactly as it found it.
new_state t14
cp "$STATE/queue.json" "$WORK/t14/queue.before"
echo '{"kubernetes-sigs/kueue#222": {"state":"closed","assignees":[]}}' > "$WORK/t14/issues.json"
rc=0; env MOCK_TODOIST_DOWN=1 MOCK_ISSUES_JSON="$WORK/t14/issues.json" \
  PATH="$MOCKBIN:$PATH" OSS_LAB_STATE_DIR="$STATE" CLAUDE_CONFIG_DIR="$HOME/.claude" \
  MOCK_LOG="$MOCK_LOG" MOCK_GH_LOGIN=nsega "$RR" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] && ok || bad "abort before prune: should exit 1 (got $rc)"
cmp -s "$STATE/queue.json" "$WORK/t14/queue.before" \
  && ok || bad "abort before prune: a failed pass must leave the queue untouched"

# 15: the promote-time staleness check still guards the Todoist write.
# The prune runs before the paid call, so an issue taken DURING that call
# is still live when it is pruned and stale by the time it is promoted.
new_state t15
MOCK_CLAUDE_OUT="$WORK/t15/claude_out"
printf '%s\n' \
  '{"issue":"kubernetes/kubernetes#111","weighted_total":8.0,"rationale_consistency":"r","route":"todoist"}' \
  '{"issue":"kubernetes-sigs/kueue#222","weighted_total":5.5,"route":"queue","reeval_count":1}' \
  > "$MOCK_CLAUDE_OUT"
echo '{}' > "$WORK/t15/issues.json"
echo '{"kubernetes/kubernetes#111": {"state":"open","assignees":[{"login":"someone-else"}]}}' \
  > "$WORK/t15/race.json"
rc=0; out="$(env MOCK_ISSUES_JSON="$WORK/t15/issues.json" MOCK_RACE_ISSUES="$WORK/t15/race.json" \
  PATH="$MOCKBIN:$PATH" OSS_LAB_STATE_DIR="$STATE" CLAUDE_CONFIG_DIR="$HOME/.claude" \
  MOCK_LOG="$MOCK_LOG" MOCK_CLAUDE_OUT="$MOCK_CLAUDE_OUT" MOCK_WIP=0 \
  MOCK_GH_LOGIN=nsega OSS_LAB_WIP_CAP=4 "$RR" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "promote race: should exit 0 (got $rc)"
[ ! -s "$MOCK_LOG/todoist_posts" ] \
  && ok || bad "promote race: an issue taken during the paid call must not become a task"
echo "$out" | grep -q "skipping kubernetes/kubernetes#111" \
  && ok || bad "promote race: should say why it skipped"

# ---- unit: oss_lab_revalidate_queue ------------------------------------
# The cases above drive the function through the runner, which can only
# reach it with well-formed input. These call it directly, because the
# inputs that matter here (a malformed id, a failing rewrite) come from the
# scorer reading untrusted public issue text and from the filesystem, and
# neither is reachable through run-reeval.sh.
#
# The invariant under test: this function may only ever remove an entry it
# has POSITIVELY proven settled. Anything it cannot parse or cannot reach
# stays queued.

unit_env() {  # prints a preamble that sources lib.sh with a stubbed status
  cat <<'PRE'
source "$LIB"
oss_lab_issue_status() { echo "${STUB_STATUS:-live}"; }
PRE
}

# 16: an id carrying an embedded newline is never probed and never removed
U="$WORK/unit"; mkdir -p "$U"
printf '%s\n' '[{"issue":"a/b#1\nc/d#2","n":1},{"issue":"a/b#5","n":2}]' > "$U/nl.json"
out="$(LIB="$HERE/../scripts/lib.sh" bash -c "$(unit_env)"'
  oss_lab_revalidate_queue "'"$U/nl.json"'"' 2>&1)"
jq -e '[.[].issue] | length == 2' "$U/nl.json" >/dev/null \
  && ok || bad "unit: an id with a newline must not be dropped (got $(jq -c '[.[].issue]' "$U/nl.json"))"
[ -z "$out" ] && ok || bad "unit: a malformed id must not be logged as dequeued (got: $out)"

# 17: an empty id is left alone too
echo '[{"issue":"","n":1},{"issue":"a/b#5","n":2}]' > "$U/empty.json"
LIB="$HERE/../scripts/lib.sh" bash -c "$(unit_env)"'
  oss_lab_revalidate_queue "'"$U/empty.json"'"' >/dev/null 2>&1
jq -e '[.[].issue] | length == 2' "$U/empty.json" >/dev/null \
  && ok || bad "unit: an empty id must not be dropped"

# 18: an entry with no .issue at all survives the prune
echo '[{"weighted_total":5.0,"route":"queue"},{"issue":"a/b#5"}]' > "$U/noissue.json"
LIB="$HERE/../scripts/lib.sh" bash -c "$(unit_env)"'
  oss_lab_revalidate_queue "'"$U/noissue.json"'"' >/dev/null 2>&1
jq -e 'length == 2' "$U/noissue.json" >/dev/null \
  && ok || bad "unit: an entry with no .issue must survive the prune"

# 19: a well-formed id that IS settled is still removed, and logged
echo '[{"issue":"a/b#1"},{"issue":"a/b#5"}]' > "$U/stale.json"
out="$(LIB="$HERE/../scripts/lib.sh" STUB_STATUS="stale:closed" bash -c "$(unit_env)"'
  oss_lab_revalidate_queue "'"$U/stale.json"'"' 2>&1)"
jq -e 'length == 0' "$U/stale.json" >/dev/null \
  && ok || bad "unit: proven-settled entries should still be removed"
[ "$(grep -c 'revalidate: dequeued' <<<"$out")" -eq 2 ] \
  && ok || bad "unit: every removal should be logged"

# 20: a failing rewrite must return nonzero, or the caller reports a clean
# pass over a queue it never actually pruned
echo '[{"issue":"a/b#1"}]' > "$U/mv.json"
rc=0
LIB="$HERE/../scripts/lib.sh" STUB_STATUS="stale:closed" bash -c "$(unit_env)"'
  mv() { return 1; }
  oss_lab_revalidate_queue "'"$U/mv.json"'"' >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] && ok || bad "unit: a failed rewrite must return nonzero (got $rc)"

# 21: each distinct id is probed once, however many entries carry it
echo '[{"issue":"a/b#1"},{"issue":"a/b#1"},{"issue":"a/b#9"}]' > "$U/dupes.json"
LIB="$HERE/../scripts/lib.sh" PROBES="$U/probes" bash -c '
  source "$LIB"
  oss_lab_issue_status() { echo "$1" >> "$PROBES"; echo live; }
  oss_lab_revalidate_queue "'"$U/dupes.json"'"' >/dev/null 2>&1
[ "$(wc -l < "$U/probes" | tr -d " ")" -eq 2 ] \
  && ok || bad "unit: duplicate ids should be probed once (got $(wc -l < "$U/probes") probes)"

# 22: a malformed entry is removed by the MERGE, not the prune, and the
# summary counts it as dropped. Pinned because the two removals are counted
# separately and an operator reads the difference.
new_state t22
MOCK_CLAUDE_OUT="$WORK/t22/claude_out"
printf '[%s,%s]\n' "$QA" '{"weighted_total":5.0,"route":"queue","note":"no issue key"}' \
  > "$STATE/queue.json"
git -C "$STATE" commit --quiet -am seed22
printf '%s\n' \
  '{"issue":"kubernetes/kubernetes#111","weighted_total":6.1,"route":"queue","reeval_count":1}' \
  > "$MOCK_CLAUDE_OUT"
rc=0; out="$(run_rr 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "malformed entry: should exit 0 (got $rc)"
echo "$out" | grep -q "0 stale-pruned, 1 dropped" \
  && ok || bad "malformed entry: the prune should not claim it (got: $(echo "$out" | tail -1))"
jq -e '[.[].issue] == ["kubernetes/kubernetes#111"]' "$STATE/queue.json" >/dev/null \
  && ok || bad "malformed entry: the merge should remove it, leaving the live one"

# 23: the GitHub login is resolved once per run, not once per queued entry.
# oss_lab_github_login memoizes into a variable that dies with the command
# substitution its only caller uses, so the runner has to hold the value.
new_state t23
MOCK_CLAUDE_OUT="$WORK/t23/claude_out"
printf '[%s,%s,%s]\n' "$QA" "$QB" \
  '{"issue":"kubernetes-sigs/kueue#333","weighted_total":5.0,"route":"queue"}' \
  > "$STATE/queue.json"
git -C "$STATE" commit --quiet -am seed23
printf '%s\n' \
  '{"issue":"kubernetes/kubernetes#111","weighted_total":6.1,"route":"queue","reeval_count":1}' \
  > "$MOCK_CLAUDE_OUT"
run_rr >/dev/null 2>&1 || true
[ "$(wc -l < "$MOCK_LOG/gh_user_calls" 2>/dev/null | tr -d ' ')" -eq 1 ] \
  && ok || bad "login memo: 3 queued entries should cost 1 'gh api user', not one each (got $(wc -l < "$MOCK_LOG/gh_user_calls" 2>/dev/null | tr -d ' '))"

# ---- the paid pass scores current upstream evidence -------------------
# queue.json holds only the scoring object. Before this, the weekly pass fed
# that object back to the model, which then re-graded its own one-sentence
# rationale with no title, body, labels or comments: scores drifted on
# sampling noise, not on anything that had changed. Guard R2 already fetches
# every queued issue to check its state; these cases pin that the fetched
# copy now reaches the paid call.

ISSUE_111='{"state":"open","assignees":[],
  "title":"scheduler_perf flakes on arm64",
  "body":"Fails roughly 1 in 20 runs since the metrics refactor.",
  "labels":[{"name":"kind/flake"},{"name":"sig/scheduling"}],
  "comments":0,"html_url":"https://github.com/kubernetes/kubernetes/issues/111",
  "created_at":"2026-08-01T00:00:00Z"}'

# 24: stdin carries the issue as it stands upstream, not the prior score
new_state t24
MOCK_CLAUDE_OUT="$WORK/t24/claude_out"
printf '%s\n' \
  '{"issue":"kubernetes/kubernetes#111","weighted_total":6.1,"route":"queue","reeval_count":1}' \
  > "$MOCK_CLAUDE_OUT"
printf '{"kubernetes/kubernetes#111": %s}\n' "$ISSUE_111" > "$WORK/t24/issues.json"
rc=0; MOCK_ISSUES_JSON="$WORK/t24/issues.json" run_rr >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 0 ] && ok || bad "evidence: should exit 0 (got $rc)"
line="$(grep 'kubernetes/kubernetes#111' "$MOCK_LOG/claude_stdin" 2>/dev/null || true)"
jq -e '.title == "scheduler_perf flakes on arm64" and (.body | startswith("Fails roughly"))' <<<"$line" >/dev/null \
  && ok || bad "evidence: stdin should carry the current title and body (got: ${line:0:120})"
jq -e '.labels == ["kind/flake","sig/scheduling"]' <<<"$line" >/dev/null \
  && ok || bad "evidence: stdin should carry the current labels"
jq -e '.reeval_count == 0 and .previous_total == 5.6' <<<"$line" >/dev/null \
  && ok || bad "evidence: stdin should carry reeval_count and previous_total from the prior pass"
jq -e '(has("rationale_consistency") or has("scores") or has("route")) | not' <<<"$line" >/dev/null \
  && ok || bad "evidence: the prior rationale, axis scores and route must not anchor the re-score"
jq -e '(has("number") or has("repo")) | not' <<<"$line" >/dev/null \
  && ok || bad "evidence: internal plumbing fields should not reach the scorer"
line2="$(grep 'kubernetes-sigs/kueue#222' "$MOCK_LOG/claude_stdin" 2>/dev/null || true)"
jq -e '.reeval_count == 1 and .previous_total == 4.4' <<<"$line2" >/dev/null \
  && ok || bad "evidence: a once-struck issue should carry its count and its sub-threshold total"

# 25: a commented issue carries the tail of its thread, so a soft claim that
# arrived while it sat queued is visible to the re-score, as it is to the
# first score
new_state t25
MOCK_CLAUDE_OUT="$WORK/t25/claude_out"; echo '{}' > "$MOCK_CLAUDE_OUT"
printf '{"kubernetes/kubernetes#111": %s}\n' "$(jq -c '.comments = 2' <<<"$ISSUE_111")" > "$WORK/t25/issues.json"
echo '{"kubernetes/kubernetes#111": [{"user":{"login":"abdel"},"body":"I can take this one."}]}' > "$WORK/t25/comments.json"
MOCK_ISSUES_JSON="$WORK/t25/issues.json" MOCK_COMMENTS_JSON="$WORK/t25/comments.json" run_rr >/dev/null 2>&1 || true
line="$(grep 'kubernetes/kubernetes#111' "$MOCK_LOG/claude_stdin" 2>/dev/null || true)"
jq -e '.recent_comments[0].author == "abdel"' <<<"$line" >/dev/null \
  && ok || bad "evidence: a commented issue should carry recent_comments"
line2="$(grep 'kubernetes-sigs/kueue#222' "$MOCK_LOG/claude_stdin" 2>/dev/null || true)"
jq -e 'has("recent_comments") | not' <<<"$line2" >/dev/null \
  && ok || bad "evidence: a comment-free issue should not pay for the comments call"

# 26: an issue whose upstream copy could not be fetched is left out of the
# paid call and stays queued untouched, to be retried next week
new_state t26
MOCK_CLAUDE_OUT="$WORK/t26/claude_out"
printf '%s\n' \
  '{"issue":"kubernetes/kubernetes#111","weighted_total":6.1,"route":"queue","reeval_count":1}' \
  > "$MOCK_CLAUDE_OUT"
echo '{"kubernetes-sigs/kueue#222": "unreachable"}' > "$WORK/t26/issues.json"
rc=0; out="$(MOCK_ISSUES_JSON="$WORK/t26/issues.json" run_rr 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "unfetched: one unreachable issue must not fail the pass (got $rc)"
[ "$(wc -l < "$MOCK_LOG/claude_stdin" | tr -d ' ')" -eq 1 ] \
  && ok || bad "unfetched: only the fetched issue should reach the paid call"
grep -q "kueue#222" "$MOCK_LOG/claude_stdin" \
  && bad "unfetched: an issue with no upstream copy must not be re-scored blind" || ok
jq -e '.[] | select(.issue == "kubernetes-sigs/kueue#222") | .weighted_total == 4.4 and .reeval_count == 1' \
  "$STATE/queue.json" >/dev/null && ok || bad "unfetched: the issue should stay queued with its prior fields"
echo "$out" | grep -q "kubernetes-sigs/kueue#222" \
  && ok || bad "unfetched: should say which issue was left for next week"

summary run_reeval
