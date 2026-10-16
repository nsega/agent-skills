#!/usr/bin/env bash
# The hourly pass routes by the runner's rules, not by the route the model
# wrote, the same way the weekly pass already does (SKILL.md "Queue decay"):
#   - a claim (claimed_by set) drops the issue whatever it scored,
#   - a model "drop" with no claimed_by drops it too: the threshold is the
#     only other reason to drop, so on a score above the bar it can only be a
#     claim, and the loop would rather lose a candidate than take announced
#     work,
#   - otherwise weighted_total decides: >= 7.0 task, 5.0-6.9 queue, < 5.0 drop,
#     with the WIP cap applied by the runner on top.
# Before this, the hourly loop read .route as given, so a claimed issue the
# model left at "todoist" became a task, and a 4.2 "todoist" did too.
# shellcheck disable=SC2015,SC1091
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
RS="$HERE/../scripts/run-scout.sh"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MOCKBIN="$WORK/bin"; build_mockbin "$MOCKBIN"

# The fetch mock serves this issue for every target repo, so the batch holds
# kubernetes/kubernetes#10, kubernetes-sigs/kueue#10 and
# kubernetes-sigs/gateway-api-inference-extension#10.
ISSUE='{"number":10,"title":"t","pull_request":null,"assignees":[],"labels":[],"comments":0,"created_at":"2026-09-01T10:00:00Z","html_url":"u","body":"b"}'
K8S='kubernetes/kubernetes#10'
KUEUE='kubernetes-sigs/kueue#10'
GAIE='kubernetes-sigs/gateway-api-inference-extension#10'

score() {  # $1 issue, $2 weighted_total, $3 route [, $4 claimed_by]
  printf '{"issue":"%s","scores":{"okr_alignment":8,"consistency":8,"impact":7,"feasibility":7},"weighted_total":%s,"rationale_consistency":"r","route":"%s"%s}' \
    "$1" "$2" "$3" "${4:+,\"claimed_by\":\"$4\"}"
}

new_case() {  # $1: name; sets STATE, MOCK_LOG, MOCK_CLAUDE_OUT, FETCH
  CASE="$WORK/$1"; STATE="$CASE/state"; MOCK_LOG="$CASE/log"
  mkdir -p "$MOCK_LOG"; build_state "$STATE"
  MOCK_CLAUDE_OUT="$CASE/claude_out"; FETCH="$CASE/raw.jsonl"
  printf '%s\n' "$ISSUE" > "$FETCH"
  date +%s > "$STATE/last_reeval"   # keep the weekly pass out of these cases
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

posts() { cat "$MOCK_LOG/todoist_posts" 2>/dev/null || true; }
tasked() { grep -q "$1" <<<"$(posts)"; }
queued() { jq -e --arg i "$1" 'map(.issue) | index($i) != null' "$STATE/queue.json" >/dev/null; }
seen_has() { jq -e --arg i "$1" 'index($i) != null' "$STATE/seen.json" >/dev/null; }

# 1: F1. A claim drops the issue even when the model routed it "todoist".
new_case claim_overrides_route
score "$KUEUE" 8.5 todoist someone-else > "$MOCK_CLAUDE_OUT"; echo >> "$MOCK_CLAUDE_OUT"
rc=0; out="$(run_scout 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "claim: run should complete (rc=$rc): $out"
tasked "$KUEUE" && bad "claim: a claimed issue must not become a task" || ok
queued "$KUEUE" && bad "claim: a claimed issue must not be queued" || ok
seen_has "$KUEUE" && ok || bad "claim: a claimed issue is still scored, so it is marked seen"
grep -q "claimed by someone-else" <<<"$out" && ok || bad "claim: the log must name the claim, got: $out"

# 2: F2. A low score the model routed "todoist" is dropped.
new_case low_score_routed_todoist
score "$KUEUE" 4.2 todoist > "$MOCK_CLAUDE_OUT"; echo >> "$MOCK_CLAUDE_OUT"
rc=0; out="$(run_scout 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "low: run should complete (rc=$rc): $out"
tasked "$KUEUE" && bad "low: a 4.2 must not become a task" || ok
queued "$KUEUE" && bad "low: a 4.2 must not be queued" || ok
seen_has "$KUEUE" && ok || bad "low: a dropped issue is marked seen"

# 3: F2. A mid score the model routed "todoist" is queued, recorded as "queue".
new_case mid_score_routed_todoist
score "$KUEUE" 6.2 todoist > "$MOCK_CLAUDE_OUT"; echo >> "$MOCK_CLAUDE_OUT"
rc=0; out="$(run_scout 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "mid: run should complete (rc=$rc): $out"
tasked "$KUEUE" && bad "mid: a 6.2 must not become a task" || ok
jq -e --arg i "$KUEUE" '.[] | select(.issue == $i) | .route == "queue"' "$STATE/queue.json" >/dev/null \
  && ok || bad "mid: a 6.2 must be queued with route \"queue\", got: $(cat "$STATE/queue.json")"

# 4: F2. A high score the model routed "queue" takes a free slot: the budget is
#    the runner's to spend, as in the weekly promotion.
new_case high_score_routed_queue
score "$KUEUE" 8.0 queue > "$MOCK_CLAUDE_OUT"; echo >> "$MOCK_CLAUDE_OUT"
rc=0; out="$(MOCK_WIP=2 run_scout 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "high: run should complete (rc=$rc): $out"
tasked "$KUEUE" && ok || bad "high: an 8.0 with a free slot must become a task, got posts: $(posts)"
queued "$KUEUE" && bad "high: a tasked issue must not also be queued" || ok

# 5: F5, hourly. A model "drop" on a score above the bar, with no claimed_by,
#    is treated as a claim. (This already held while the loop trusted the
#    route; it pins that routing by score never turns such a drop into a task.)
new_case model_drop_over_the_bar
score "$KUEUE" 7.6 drop > "$MOCK_CLAUDE_OUT"; echo >> "$MOCK_CLAUDE_OUT"
rc=0; out="$(run_scout 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "model_drop: run should complete (rc=$rc): $out"
tasked "$KUEUE" && bad "model_drop: a model drop at 7.6 must not become a task" || ok
queued "$KUEUE" && bad "model_drop: a model drop at 7.6 must not be queued" || ok

# 6: the thresholds themselves, with model routes that disagree: 7.0 is a
#    task, 5.0 is queued, 4.9 is dropped.
new_case boundaries
printf '%s\n' "$(score "$K8S" 7.0 queue)" "$(score "$KUEUE" 5.0 todoist)" "$(score "$GAIE" 4.9 queue)" > "$MOCK_CLAUDE_OUT"
rc=0; out="$(MOCK_WIP=0 run_scout 2>&1)" || rc=$?
[ "$rc" -eq 0 ] && ok || bad "boundaries: run should complete (rc=$rc): $out"
tasked "$K8S" && ok || bad "boundaries: 7.0 must become a task"
queued "$KUEUE" && ok || bad "boundaries: 5.0 must be queued"
tasked "$KUEUE" && bad "boundaries: 5.0 must not become a task" || ok
queued "$GAIE" && bad "boundaries: 4.9 must not be queued" || ok
tasked "$GAIE" && bad "boundaries: 4.9 must not become a task" || ok

summary "hourly routing"
