#!/usr/bin/env bash
# A queued entry should say what it is. prompt.md demotes over-budget issues
# to "queue" with wip_capped, and run-scout.sh promises to tag an issue it
# queues after a failed Todoist POST, but both used to be stored with
# route "todoist" (and the failed POST with no tag at all).
# shellcheck disable=SC2015,SC1091
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
RS="$HERE/../scripts/run-scout.sh"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MOCKBIN="$WORK/bin"; build_mockbin "$MOCKBIN"

scored() {  # $1 number, $2 total
  jq -cn --arg i "kubernetes/kubernetes#$1" --argjson s "$(axes_for "$2")" --argjson wt "$2" \
    '{issue: $i, scores: $s, weighted_total: $wt, rationale_consistency: "r", route: "todoist"}'
}

run_case() {  # $1 name; uses MOCK_WIP, MOCK_POST_FAIL from the caller
  STATE="$WORK/$1/state"; MOCK_LOG="$WORK/$1/log"; mkdir -p "$MOCK_LOG"; build_state "$STATE"
  date +%s > "$STATE/last_reeval"
  for n in 41 42; do
    echo '{"number":'"$n"',"title":"t","pull_request":null,"assignees":[],"labels":[],"comments":0,"created_at":"x","html_url":"u","body":"b"}'
  done > "$WORK/$1/raw.jsonl"
  printf '%s\n' "$(scored 41 8.0)" "$(scored 42 9.0)" > "$WORK/$1/out"
  env PATH="$MOCKBIN:$PATH" OSS_LAB_STATE_DIR="$STATE" CLAUDE_CONFIG_DIR="$HOME/.claude" MOCK_LOG="$MOCK_LOG" \
    MOCK_CLAUDE_OUT="$WORK/$1/out" MOCK_FETCH="$WORK/$1/raw.jsonl" MOCK_GH_LOGIN=nsega \
    OSS_LAB_WIP_CAP=3 "$RS" >/dev/null 2>&1 || true
}

# 1: one slot for two task-worthy scores: the 9.0 takes it, and the 8.0 is
#    stored as a queue entry with wip_capped.
MOCK_WIP=2 run_case capped
jq -e '.[] | select(.issue == "kubernetes/kubernetes#41") | .route == "queue" and .wip_capped == true' \
  "$STATE/queue.json" >/dev/null && ok || bad "capped: the demoted entry must read route queue with wip_capped, got: $(cat "$STATE/queue.json")"

# 2: a failed POST queues the issue as a queue entry, tagged so the weekly
#    pass knows it was meant to be a task.
MOCK_WIP=0 MOCK_POST_FAIL=1 run_case post_failed
jq -e 'length == 2 and all(.[]; .route == "queue" and .todoist_failed == true)' "$STATE/queue.json" >/dev/null \
  && ok || bad "post_failed: both entries must read route queue with todoist_failed, got: $(cat "$STATE/queue.json")"

summary "queue entries"
