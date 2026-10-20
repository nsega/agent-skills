#!/usr/bin/env bash
# The runner computes weighted_total from the axes, not the model's number.
# Objects without four valid axis scores are rejected.
# shellcheck disable=SC2015,SC1091
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
RS="$HERE/../scripts/run-scout.sh"
RR="$HERE/../scripts/run-reeval.sh"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MOCKBIN="$WORK/bin"; build_mockbin "$MOCKBIN"

ISSUE='{"number":10,"title":"t","pull_request":null,"assignees":[],"labels":[],"comments":0,"created_at":"2026-09-01T10:00:00Z","html_url":"u","body":"b"}'
K8S='kubernetes/kubernetes#10'
KUEUE='kubernetes-sigs/kueue#10'

# obj <issue> <axes-total> <reported-total> <route>: axes summing to the first
# total, with the model reporting the second.
obj() {
  jq -cn --arg i "$1" --argjson s "$(axes_for "$2")" --argjson wt "$3" --arg r "$4" \
    '{issue: $i, scores: $s, weighted_total: $wt, rationale_consistency: "r", route: $r}'
}

new_case() {
  CASE="$WORK/$1"; STATE="$CASE/state"; MOCK_LOG="$CASE/log"
  mkdir -p "$MOCK_LOG"; build_state "$STATE"
  MOCK_CLAUDE_OUT="$CASE/claude_out"; FETCH="$CASE/raw.jsonl"
  printf '%s\n' "$ISSUE" > "$FETCH"
  date +%s > "$STATE/last_reeval"
}

run_scout() {
  env PATH="$MOCKBIN:$PATH" OSS_LAB_STATE_DIR="$STATE" CLAUDE_CONFIG_DIR="$HOME/.claude" \
      MOCK_LOG="$MOCK_LOG" MOCK_CLAUDE_OUT="$MOCK_CLAUDE_OUT" MOCK_FETCH="$FETCH" \
      MOCK_WIP="${MOCK_WIP:-0}" MOCK_GH_LOGIN=nsega "$RS"
}

posts() { cat "$MOCK_LOG/todoist_posts" 2>/dev/null || true; }
queued() { jq -e --arg i "$1" 'map(.issue) | index($i) != null' "$STATE/queue.json" >/dev/null; }
seen_has() { jq -e --arg i "$1" 'index($i) != null' "$STATE/seen.json" >/dev/null; }

# 1: the model reports 7.1 but its axes give 6.9: queued, not a task.
new_case reported_over_the_bar
obj "$KUEUE" 6.9 7.1 todoist > "$MOCK_CLAUDE_OUT"; echo >> "$MOCK_CLAUDE_OUT"
rc=0; out="$(run_scout 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "over: run should complete (rc=$rc): $out"
grep -q "$KUEUE" <<<"$(posts)" && bad "over: axes giving 6.9 must not become a task" || ok
queued "$KUEUE" && ok || bad "over: axes giving 6.9 must be queued"
jq -e --arg i "$KUEUE" '.[] | select(.issue == $i) | .weighted_total == 6.9' "$STATE/queue.json" >/dev/null \
  && ok || bad "over: the queued entry must carry the runner's 6.9, got: $(cat "$STATE/queue.json")"
grep -q "reported weighted_total 7.1" <<<"$out" && ok || bad "over: the log must note the disagreement, got: $out"

# 2: the model reports 6.9 but its axes give exactly 7.0: a task.
new_case reported_under_the_bar
obj "$KUEUE" 7.0 6.9 queue > "$MOCK_CLAUDE_OUT"; echo >> "$MOCK_CLAUDE_OUT"
rc=0; out="$(run_scout 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "under: run should complete (rc=$rc): $out"
grep -q "$KUEUE" <<<"$(posts)" && ok || bad "under: axes giving 7.0 must become a task, got posts: $(posts)"

# 3: totals that agree leave no note in the log.
new_case agreeing_totals
obj "$KUEUE" 7.6 7.6 todoist > "$MOCK_CLAUDE_OUT"; echo >> "$MOCK_CLAUDE_OUT"
rc=0; out="$(run_scout 2>&1)" || rc=$?
grep -q "reported weighted_total" <<<"$out" && bad "agree: matching totals must not be noted, got: $out" || ok

# 4: no scores block, an axis outside 0-10, or a string axis: rejected, and
#    the valid object beside it is still routed.
for variant in no_scores out_of_range string_axis; do
  new_case "$variant"
  case "$variant" in
    no_scores)    bad_obj="$(obj "$K8S" 8.0 8.0 todoist | jq -c 'del(.scores)')" ;;
    out_of_range) bad_obj="$(obj "$K8S" 8.0 8.0 todoist | jq -c '.scores.impact = 11')" ;;
    string_axis)  bad_obj="$(obj "$K8S" 8.0 8.0 todoist | jq -c '.scores.okr_alignment = "8"')" ;;
  esac
  printf '%s\n' "$(obj "$KUEUE" 6.2 6.2 queue)" "$bad_obj" > "$MOCK_CLAUDE_OUT"
  rc=0; out="$(run_scout 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] && ok || bad "$variant: run should complete (rc=$rc): $out"
  grep -q "$K8S" <<<"$(posts)" && bad "$variant: an object without valid axis scores must not become a task" || ok
  seen_has "$K8S" && bad "$variant: it must not be marked seen" || ok
  queued "$KUEUE" && ok || bad "$variant: the valid object beside it must still be queued"
done

# 5: weekly pass. A queued issue rescored with axes giving 7.6, while the model
#    reports 6.0, is promoted: promotion runs on the runner's total too.
CASE="$WORK/reeval_recompute"; STATE="$CASE/state"; MOCK_LOG="$CASE/log"
mkdir -p "$MOCK_LOG"; build_state "$STATE" --git
printf '[%s]\n' '{"issue":"kubernetes/kubernetes#111","weighted_total":5.6,"rationale_consistency":"r","route":"queue"}' > "$STATE/queue.json"
git -C "$STATE" commit --quiet -am seed
MOCK_CLAUDE_OUT="$CASE/claude_out"
obj 'kubernetes/kubernetes#111' 7.6 6.0 queue > "$MOCK_CLAUDE_OUT"; echo >> "$MOCK_CLAUDE_OUT"
rc=0; out="$(env PATH="$MOCKBIN:$PATH" OSS_LAB_STATE_DIR="$STATE" CLAUDE_CONFIG_DIR="$HOME/.claude" \
  MOCK_LOG="$MOCK_LOG" MOCK_CLAUDE_OUT="$MOCK_CLAUDE_OUT" MOCK_WIP=0 MOCK_GH_LOGIN=nsega "$RR" 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "reeval: pass should complete (rc=$rc): $out"
grep -q 'kubernetes/kubernetes#111' <<<"$(posts)" && ok || bad "reeval: axes giving 7.6 must be promoted, got posts: $(posts)"
grep -q "reported weighted_total 6" <<<"$out" && ok || bad "reeval: the log must note the disagreement, got: $out"

# 6: the weights the runner uses are the ones prompt.md gives the model.
source "$HERE/../scripts/lib.sh"
for axis in okr_alignment consistency impact feasibility; do
  doc="$(sed -nE "s/^\*\*$axis \(weight ([0-9.]+)\)\*\*.*/\1/p" "$HERE/../prompt.md")"
  code="$(jq -r --arg a "$axis" '.[$a]' <<<"${OSS_LAB_WEIGHTS:-{\}}")"
  [ -n "$doc" ] && [ "$doc" = "$code" ] && ok || bad "weights: $axis is $code in lib.sh but '$doc' in prompt.md"
done

summary "weighted total"
