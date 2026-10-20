#!/usr/bin/env bash
# prompt.md tells the scorer that a comment from the scout's own account is
# not someone else's claim, but the scorer runs with no tools and used to be
# given no login, so the owner's own "I'll take this" read as a claim and
# dropped the issue. Both runners now pass the login as SCOUT_LOGIN.
# shellcheck disable=SC2015,SC1091
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
RS="$HERE/../scripts/run-scout.sh"
RR="$HERE/../scripts/run-reeval.sh"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MOCKBIN="$WORK/bin"; build_mockbin "$MOCKBIN"

scored() {
  jq -cn --arg i "$1" --argjson s "$(axes_for 6.2)" \
    '{issue: $i, scores: $s, weighted_total: 6.2, rationale_consistency: "r", route: "queue"}'
}

# 1: the hourly pass renders SCOUT_LOGIN into the scoring prompt.
STATE="$WORK/scout/state"; MOCK_LOG="$WORK/scout/log"; mkdir -p "$MOCK_LOG"; build_state "$STATE"
date +%s > "$STATE/last_reeval"
FETCH="$WORK/scout/raw.jsonl"
echo '{"number":10,"title":"t","pull_request":null,"assignees":[],"labels":[],"comments":0,"created_at":"x","html_url":"u","body":"b"}' > "$FETCH"
MOCK_CLAUDE_OUT="$WORK/scout/out"; scored 'kubernetes-sigs/kueue#10' > "$MOCK_CLAUDE_OUT"
env PATH="$MOCKBIN:$PATH" OSS_LAB_STATE_DIR="$STATE" CLAUDE_CONFIG_DIR="$HOME/.claude" MOCK_LOG="$MOCK_LOG" \
  MOCK_CLAUDE_OUT="$MOCK_CLAUDE_OUT" MOCK_FETCH="$FETCH" MOCK_WIP=0 MOCK_GH_LOGIN=fixture-scout "$RS" >/dev/null 2>&1 || true
grep -qx 'SCOUT_LOGIN=fixture-scout' "$MOCK_LOG/claude_args" 2>/dev/null \
  && ok || bad "scout: the prompt must carry SCOUT_LOGIN=fixture-scout, got: $(tail -3 "$MOCK_LOG/claude_args" 2>/dev/null)"

# 2: so does the weekly pass.
STATE="$WORK/reeval/state"; MOCK_LOG="$WORK/reeval/log"; mkdir -p "$MOCK_LOG"; build_state "$STATE" --git
printf '[%s]\n' '{"issue":"kubernetes/kubernetes#111","weighted_total":5.6,"rationale_consistency":"r","route":"queue"}' > "$STATE/queue.json"
git -C "$STATE" commit --quiet -am seed
MOCK_CLAUDE_OUT="$WORK/reeval/out"; scored 'kubernetes/kubernetes#111' > "$MOCK_CLAUDE_OUT"
env PATH="$MOCKBIN:$PATH" OSS_LAB_STATE_DIR="$STATE" CLAUDE_CONFIG_DIR="$HOME/.claude" MOCK_LOG="$MOCK_LOG" \
  MOCK_CLAUDE_OUT="$MOCK_CLAUDE_OUT" MOCK_WIP=0 MOCK_GH_LOGIN=fixture-scout "$RR" >/dev/null 2>&1 || true
grep -qx 'SCOUT_LOGIN=fixture-scout' "$MOCK_LOG/claude_args" 2>/dev/null \
  && ok || bad "reeval: the prompt must carry SCOUT_LOGIN=fixture-scout, got: $(tail -3 "$MOCK_LOG/claude_args" 2>/dev/null)"

# 3: prompt.md tells the scorer what SCOUT_LOGIN is.
grep -q 'SCOUT_LOGIN' "$HERE/../prompt.md" && ok || bad "prompt.md must say the scout's own account arrives as SCOUT_LOGIN"

summary "scout login"
