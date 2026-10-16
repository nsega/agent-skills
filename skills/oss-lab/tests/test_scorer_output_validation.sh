#!/usr/bin/env bash
# The scorer's reply is acted on without a human in the loop, so the runner
# must hold it to the output contract in prompt.md before routing anything.
# SKILL.md promises that "a malformed or hallucinated result cannot become a
# task or a seen.json entry". These cases pin that promise:
#   - an issue that was not in the batch is never acted on (a hallucinated id,
#     or one planted in an issue body for the scorer to echo),
#   - a route outside todoist | queue | drop, or a missing or non-numeric
#     weighted_total, is rejected rather than routed or marked seen,
#   - one malformed object never costs the rest of the batch. A string total
#     used to make the routing sort fail inside a process substitution, which
#     errexit cannot see: every valid score was lost and the window advanced.
# shellcheck disable=SC2015,SC1091
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
RS="$HERE/../scripts/run-scout.sh"
RR="$HERE/../scripts/run-reeval.sh"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MOCKBIN="$WORK/bin"; build_mockbin "$MOCKBIN"

# The fetch mock serves this issue for every target repo, so the batch holds
# kubernetes/kubernetes#10, kubernetes-sigs/kueue#10 and
# kubernetes-sigs/gateway-api-inference-extension#10.
ISSUE='{"number":10,"title":"t","pull_request":null,"assignees":[],"labels":[],"comments":0,"created_at":"2026-09-01T10:00:00Z","html_url":"u","body":"b"}'
K8S='kubernetes/kubernetes#10'
KUEUE='kubernetes-sigs/kueue#10'

score() {  # $1 issue, $2 weighted_total (raw JSON), $3 route
  printf '{"issue":"%s","scores":{"okr_alignment":8,"consistency":8,"impact":7,"feasibility":7},"weighted_total":%s,"rationale_consistency":"r","route":"%s"}' "$1" "$2" "$3"
}

new_case() {  # $1: name; sets STATE, MOCK_LOG, MOCK_CLAUDE_OUT, FETCH
  CASE="$WORK/$1"; STATE="$CASE/state"; MOCK_LOG="$CASE/log"
  mkdir -p "$MOCK_LOG"; build_state "$STATE"
  MOCK_CLAUDE_OUT="$CASE/claude_out"; FETCH="$CASE/raw.jsonl"
  printf '%s\n' "$ISSUE" > "$FETCH"
  date +%s > "$STATE/last_reeval"   # keep the weekly pass out of scout cases
}

run_scout() {
  env PATH="$MOCKBIN:$PATH" \
      OSS_LAB_STATE_DIR="$STATE" \
      CLAUDE_CONFIG_DIR="$HOME/.claude" \
      MOCK_LOG="$MOCK_LOG" \
      MOCK_CLAUDE_OUT="$MOCK_CLAUDE_OUT" \
      MOCK_FETCH="$FETCH" \
      MOCK_WIP="${MOCK_WIP:-2}" \
      MOCK_GH_LOGIN=nsega \
      "$RS"
}

seen_has() { jq -e --arg i "$1" 'index($i) != null' "$STATE/seen.json" >/dev/null; }
posts() { cat "$MOCK_LOG/todoist_posts" 2>/dev/null || true; }

# 1: an id the scorer was never given becomes neither a task nor a seen entry,
#    and the valid score beside it is still routed.
new_case hallucinated
printf '%s\n' "$(score "$KUEUE" 8.0 todoist)" "$(score 'kubernetes-sigs/kueue#999' 9.4 todoist)" > "$MOCK_CLAUDE_OUT"
rc=0; out="$(run_scout 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "hallucinated: run should complete (rc=$rc): $out"
grep -q '#999' <<<"$(posts)" && bad "hallucinated: an id outside the batch must not become a task" || ok
grep -q "$KUEUE" <<<"$(posts)" && ok || bad "hallucinated: the valid score beside it must still become a task"
seen_has 'kubernetes-sigs/kueue#999' && bad "hallucinated: an id outside the batch must not be marked seen" || ok
seen_has "$KUEUE" && ok || bad "hallucinated: the valid score must be marked seen"
grep -q 'kueue#999' <<<"$out" && ok || bad "hallucinated: the log must name what was ignored, got: $out"

# 2: a route outside the contract is not acted on and does not burn the issue.
new_case bad_route
printf '%s\n' "$(score "$KUEUE" 6.0 queue)" "$(score "$K8S" 7.2 maybe)" > "$MOCK_CLAUDE_OUT"
rc=0; out="$(run_scout 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "bad_route: run should complete (rc=$rc): $out"
seen_has "$K8S" && bad "bad_route: route \"maybe\" must not mark the issue seen" || ok
jq -e --arg i "$KUEUE" 'map(.issue) | index($i) != null' "$STATE/queue.json" >/dev/null \
  && ok || bad "bad_route: the valid score beside it must still be queued"

# 3: a todoist route with no weighted_total must not become a task titled
#    "(score null)".
new_case missing_total
printf '%s\n' "$(score "$KUEUE" 6.0 queue)" \
  "$(score "$K8S" 7.9 todoist | jq -c 'del(.weighted_total)')" > "$MOCK_CLAUDE_OUT"
rc=0; out="$(run_scout 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "missing_total: run should complete (rc=$rc): $out"
[ -z "$(posts)" ] && ok || bad "missing_total: a score without weighted_total must not become a task, got: $(posts)"
seen_has "$K8S" && bad "missing_total: it must not be marked seen" || ok

# 4: F4. A string total next to a valid score: the valid one must survive.
#    Before the fix the routing sort died on "7.5", nothing was routed or
#    marked seen, the window advanced, and the run reported success.
new_case string_total
printf '%s\n' "$(score "$KUEUE" 8.0 todoist)" "$(score "$K8S" '"7.5"' todoist)" > "$MOCK_CLAUDE_OUT"
rc=0; out="$(run_scout 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "string_total: run should complete (rc=$rc): $out"
grep -q "$KUEUE" <<<"$(posts)" && ok || bad "string_total: the valid score must still become a task, got posts: $(posts)"
seen_has "$KUEUE" && ok || bad "string_total: the valid score must be marked seen"
seen_has "$K8S" && bad "string_total: the malformed score must not be marked seen" || ok

# 5: if every object breaks the contract, nothing was really scored: abort
#    without advancing the window, the same as an unparseable reply.
new_case all_invalid
printf '%s\n' "$(score "$K8S" '"7.5"' todoist)" > "$MOCK_CLAUDE_OUT"
rc=0; out="$(run_scout 2>&1)" || rc=$?
[ "$rc" -ne 0 ] && ok || bad "all_invalid: scout must abort when no object is usable"
[ ! -e "$STATE/last_run" ] && ok || bad "all_invalid: window must not advance"
[ -z "$(posts)" ] && ok || bad "all_invalid: nothing may become a task"

# 6: F4 in the weekly pass. A string total used to clear the promote filter
#    (in jq a string sorts above any number) and then kill the promotion sort,
#    so no issue was promoted. The valid rescore must still be promoted, and
#    the malformed one is treated as skipped: left queued, untouched.
CASE="$WORK/reeval_string_total"; STATE="$CASE/state"; MOCK_LOG="$CASE/log"
mkdir -p "$MOCK_LOG"; build_state "$STATE" --git
QA='{"issue":"kubernetes/kubernetes#111","weighted_total":5.6,"rationale_consistency":"anchor overlap","route":"queue"}'
QB='{"issue":"kubernetes-sigs/kueue#222","weighted_total":4.4,"rationale_consistency":"weak","route":"queue","reeval_count":1}'
printf '[%s,%s]\n' "$QA" "$QB" > "$STATE/queue.json"
git -C "$STATE" commit --quiet -am seed
MOCK_CLAUDE_OUT="$CASE/claude_out"
printf '%s\n' "$(score 'kubernetes/kubernetes#111' 7.6 todoist)" "$(score 'kubernetes-sigs/kueue#222' '"7.5"' queue)" > "$MOCK_CLAUDE_OUT"
rc=0; out="$(env PATH="$MOCKBIN:$PATH" OSS_LAB_STATE_DIR="$STATE" CLAUDE_CONFIG_DIR="$HOME/.claude" \
  MOCK_LOG="$MOCK_LOG" MOCK_CLAUDE_OUT="$MOCK_CLAUDE_OUT" MOCK_WIP=3 MOCK_GH_LOGIN=nsega \
  OSS_LAB_WIP_CAP=4 "$RR" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "reeval_string_total: pass should complete (rc=$rc): $out"
grep -q 'kubernetes/kubernetes#111' <<<"$(posts)" && ok \
  || bad "reeval_string_total: the valid 7.6 must be promoted, got posts: $(posts); log: $out"
jq -e '.[] | select(.issue == "kubernetes-sigs/kueue#222") | .weighted_total == 4.4 and .reeval_count == 1' \
  "$STATE/queue.json" >/dev/null && ok || bad "reeval_string_total: the malformed rescore must leave the queued entry untouched, got: $(cat "$STATE/queue.json")"

summary "scorer output validation"
