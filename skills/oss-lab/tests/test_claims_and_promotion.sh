#!/usr/bin/env bash
# Mocked end-to-end tests for the three claim-awareness features:
#   1. revalidation closes tasks whose issue someone else now owns
#   2. the fetch filter drops issues that already have a linked PR, and
#      surfaces comment threads so the scorer can see a soft claim
#   3. the weekly pass promotes queued issues that now clear the bar,
#      within the WIP budget, skipping any that got taken meanwhile
# No paid calls, no network.
# shellcheck disable=SC2015,SC1091
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
RS="$HERE/../scripts/run-scout.sh"
RR="$HERE/../scripts/run-reeval.sh"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MOCKBIN="$WORK/bin"; build_mockbin "$MOCKBIN"

case_dir() { CASE="$WORK/$1"; STATE="$CASE/state"; MOCK_LOG="$CASE/log"; mkdir -p "$CASE" "$MOCK_LOG"; }

run_it() { # $1 script
  env PATH="$MOCKBIN:$PATH" OSS_LAB_STATE_DIR="$STATE" \
      CLAUDE_CONFIG_DIR="$HOME/.claude" MOCK_LOG="$MOCK_LOG" \
      MOCK_CLAUDE_OUT="${MOCK_CLAUDE_OUT:-/dev/null}" \
      MOCK_WIP="${MOCK_WIP:-0}" MOCK_LINKED="${MOCK_LINKED:-}" \
      MOCK_TASKS_JSON="${MOCK_TASKS_JSON:-}" MOCK_ISSUES_JSON="${MOCK_ISSUES_JSON:-}" \
      MOCK_TIMELINE_JSON="${MOCK_TIMELINE_JSON:-}" MOCK_COMMENTS_JSON="${MOCK_COMMENTS_JSON:-}" \
      MOCK_FETCH="${MOCK_FETCH:-}" MOCK_GH_LOGIN=nsega \
      "$1"
}

# ---- 1. revalidation ---------------------------------------------------
# Three tasks: one whose issue got assigned to someone else, one whose
# issue gained another contributor's open PR, one still genuinely free.
case_dir revalidate; build_state "$STATE"
cat > "$CASE/tasks.json" <<'EOF'
[{"id":"t1","content":"Contribute: k8s/k8s#1 (score 7.5)","labels":["oss-lab"]},
 {"id":"t2","content":"Contribute: k8s/k8s#2 (score 7.4)","labels":["oss-lab"]},
 {"id":"t3","content":"Contribute: k8s/k8s#3 (score 7.3)","labels":["oss-lab"]},
 {"id":"t9","content":"my own unrelated task","labels":[]}]
EOF
cat > "$CASE/issues.json" <<'EOF'
{"k8s/k8s#1": {"state":"open","assignees":[{"login":"someone-else"}]},
 "k8s/k8s#2": {"state":"open","assignees":[]},
 "k8s/k8s#3": {"state":"open","assignees":[]}}
EOF
MOCK_TASKS_JSON="$CASE/tasks.json" MOCK_ISSUES_JSON="$CASE/issues.json" \
MOCK_LINKED="2" MOCK_FETCH="" \
  out="$(run_it "$RS" 2>&1)" || true
closed="$(cat "$MOCK_LOG/todoist_closed" 2>/dev/null || true)"
grep -q "t1" <<<"$closed" && ok || bad "revalidate: assigned-to-other task should close"
grep -q "t2" <<<"$closed" && ok || bad "revalidate: task with another dev's open PR should close"
grep -q "t3" <<<"$closed" && bad "revalidate: free issue must NOT be closed" || ok
grep -q "t9" <<<"$closed" && bad "revalidate: non-oss-lab task must never be touched" || ok
grep -q "closed k8s/k8s#1 (assigned to someone-else)" <<<"$out" && ok || bad "revalidate: should log the reason"

# Assigned to US is claimed-but-undelivered work: the slot stays taken.
case_dir revalidate_self; build_state "$STATE"
cat > "$CASE/tasks.json" <<'EOF'
[{"id":"s1","content":"Contribute: k8s/k8s#5 (score 8.0)","labels":["oss-lab"]}]
EOF
echo '{"k8s/k8s#5": {"state":"open","assignees":[{"login":"nsega"}]}}' > "$CASE/issues.json"
MOCK_TASKS_JSON="$CASE/tasks.json" MOCK_ISSUES_JSON="$CASE/issues.json" \
  run_it "$RS" >/dev/null 2>&1 || true
[ ! -s "$MOCK_LOG/todoist_closed" ] && ok || bad "revalidate: an issue assigned to us must keep its task"

# A closed issue frees its slot too.
case_dir revalidate_closed; build_state "$STATE"
cat > "$CASE/tasks.json" <<'EOF'
[{"id":"c1","content":"Contribute: k8s/k8s#6 (score 8.0)","labels":["oss-lab"]}]
EOF
echo '{"k8s/k8s#6": {"state":"closed","assignees":[]}}' > "$CASE/issues.json"
MOCK_TASKS_JSON="$CASE/tasks.json" MOCK_ISSUES_JSON="$CASE/issues.json" \
  out="$(run_it "$RS" 2>&1)" || true
grep -q "c1" "$MOCK_LOG/todoist_closed" 2>/dev/null && ok || bad "revalidate: closed issue should free its slot"

# Titles written as a markdown link must still parse back to their issue,
# and so must the plain titles that pre-link tasks still carry.
case_dir revalidate_linktitle; build_state "$STATE"
cat > "$CASE/tasks.json" <<'EOF'
[{"id":"L1","content":"Contribute: [k8s/k8s#7](https://github.com/k8s/k8s/issues/7) (score 7.9)","labels":["oss-lab"]},
 {"id":"L2","content":"Contribute: k8s/k8s#8 (score 7.2)","labels":["oss-lab"]}]
EOF
cat > "$CASE/issues.json" <<'EOF'
{"k8s/k8s#7": {"state":"closed","assignees":[]},
 "k8s/k8s#8": {"state":"closed","assignees":[]}}
EOF
MOCK_TASKS_JSON="$CASE/tasks.json" MOCK_ISSUES_JSON="$CASE/issues.json" \
  run_it "$RS" >/dev/null 2>&1 || true
grep -q "L1" "$MOCK_LOG/todoist_closed" 2>/dev/null && ok || bad "revalidate: markdown-link title should parse back to its issue"
grep -q "L2" "$MOCK_LOG/todoist_closed" 2>/dev/null && ok || bad "revalidate: legacy plain title must still parse"

# A task the human renamed no longer names an issue: never guess at it.
case_dir revalidate_renamed; build_state "$STATE"
echo '[{"id":"r1","content":"look at the scheduler thing","labels":["oss-lab"]}]' > "$CASE/tasks.json"
MOCK_TASKS_JSON="$CASE/tasks.json" run_it "$RS" >/dev/null 2>&1 || true
[ ! -s "$MOCK_LOG/todoist_closed" ] && ok || bad "revalidate: renamed task must be left alone"

# ---- 2. fetch-side claim filtering -------------------------------------
case_dir fetch; build_state "$STATE"
cat > "$CASE/raw.jsonl" <<'EOF'
{"number":10,"title":"free one","pull_request":null,"assignees":[],"labels":[],"comments":0,"created_at":"2026-08-15T10:00:00Z","html_url":"u","body":"b"}
{"number":11,"title":"has a PR","pull_request":null,"assignees":[],"labels":[],"comments":0,"created_at":"2026-08-15T10:00:00Z","html_url":"u","body":"b"}
{"number":12,"title":"soft claim","pull_request":null,"assignees":[],"labels":[],"comments":2,"created_at":"2026-08-15T10:00:00Z","html_url":"u","body":"b"}
EOF
cat > "$CASE/comments.json" <<'EOF'
{"kubernetes/kubernetes#12": [{"user":{"login":"abdel"},"body":"Hey! I can take this one."}]}
EOF
FETCH_OUT="$(env PATH="$MOCKBIN:$PATH" OSS_LAB_STATE_DIR="$STATE" \
  MOCK_FETCH="$CASE/raw.jsonl" MOCK_LINKED="11" \
  MOCK_COMMENTS_JSON="$CASE/comments.json" MOCK_GH_LOGIN=nsega \
  "$HERE/../scripts/fetch-issues.sh" 2>/dev/null)" || true
ids="$(jq -r '.issue' <<<"$FETCH_OUT" | sort | tr '\n' ' ')"
grep -q "kubernetes/kubernetes#10" <<<"$ids" && ok || bad "fetch: free issue should survive"
grep -q "kubernetes/kubernetes#11" <<<"$ids" && bad "fetch: linked-PR issue must be dropped" || ok
grep -q "kubernetes/kubernetes#12" <<<"$ids" && ok || bad "fetch: soft-claim issue should still reach the scorer"
jq -e 'select(.issue == "kubernetes/kubernetes#12") | .recent_comments[0].author == "abdel"' <<<"$FETCH_OUT" >/dev/null \
  && ok || bad "fetch: commented issue should carry recent_comments"
jq -e 'select(.issue == "kubernetes/kubernetes#10") | has("recent_comments") | not' <<<"$FETCH_OUT" >/dev/null \
  && ok || bad "fetch: comment-free issue should skip the extra call"
jq -e 'select(.issue == "kubernetes/kubernetes#10") | has("number") | not' <<<"$FETCH_OUT" >/dev/null \
  && ok || bad "fetch: internal plumbing fields should not reach the scorer"

# ---- 3. promotion out of the queue -------------------------------------
# Two queued issues rescore above the bar, budget allows one.
case_dir promote; build_state "$STATE" --git
cat > "$STATE/queue.json" <<'EOF'
[{"issue":"k8s/k8s#20","weighted_total":5.5,"route":"queue"},
 {"issue":"k8s/k8s#21","weighted_total":5.4,"route":"queue"}]
EOF
git -C "$STATE" commit --quiet -am seed
MOCK_CLAUDE_OUT="$CASE/out"; printf '%s\n' \
  '{"issue":"k8s/k8s#20","weighted_total":7.1,"rationale_consistency":"r","route":"todoist"}' \
  '{"issue":"k8s/k8s#21","weighted_total":7.6,"rationale_consistency":"r","route":"todoist"}' \
  > "$MOCK_CLAUDE_OUT"
MOCK_WIP=2 out="$(run_it "$RR" 2>&1)" || bad "promote: reeval should exit 0"
posts="$(cat "$MOCK_LOG/todoist_posts" 2>/dev/null || true)"
grep -q "k8s/k8s#21" <<<"$posts" && ok || bad "promote: highest scorer should become a task"
grep -q 'Contribute: \[k8s/k8s#21\](https://github.com/k8s/k8s/issues/21) (score 7.6)' <<<"$posts" \
  && ok || bad "promote: task title should link the issue"
grep -q "k8s/k8s#20" <<<"$posts" && bad "promote: budget of 1 must not create 2 tasks" || ok
jq -e '[.[].issue] == ["k8s/k8s#20"]' "$STATE/queue.json" >/dev/null \
  && ok || bad "promote: promoted issue should leave the queue, the other stay"
jq -e '.[0].wip_capped == true' "$STATE/queue.json" >/dev/null \
  && ok || bad "promote: the one the budget could not cover should be flagged"
grep -q "promoted" <<<"$out" && ok || bad "promote: summary should report promotions"

# A queued issue that someone else picked up meanwhile is never handed back.
case_dir promote_taken; build_state "$STATE" --git
echo '[{"issue":"k8s/k8s#30","weighted_total":5.5,"route":"queue"}]' > "$STATE/queue.json"
git -C "$STATE" commit --quiet -am seed
MOCK_CLAUDE_OUT="$CASE/out"
echo '{"issue":"k8s/k8s#30","weighted_total":8.0,"rationale_consistency":"r","route":"todoist"}' > "$MOCK_CLAUDE_OUT"
echo '{"k8s/k8s#30": {"state":"open","assignees":[{"login":"someone-else"}]}}' > "$CASE/issues.json"
MOCK_WIP=0 MOCK_ISSUES_JSON="$CASE/issues.json" out="$(run_it "$RR" 2>&1)" || true
[ ! -s "$MOCK_LOG/todoist_posts" ] && ok || bad "promote: must not task an issue someone else took"
grep -q "skipping k8s/k8s#30" <<<"$out" && ok || bad "promote: should say why it skipped"

# Full WIP means no promotion at all, and nothing leaves the queue.
case_dir promote_full; build_state "$STATE" --git
echo '[{"issue":"k8s/k8s#40","weighted_total":5.5,"route":"queue"}]' > "$STATE/queue.json"
git -C "$STATE" commit --quiet -am seed
MOCK_CLAUDE_OUT="$CASE/out"
echo '{"issue":"k8s/k8s#40","weighted_total":9.0,"rationale_consistency":"r","route":"todoist"}' > "$MOCK_CLAUDE_OUT"
MOCK_WIP=3 run_it "$RR" >/dev/null 2>&1 || true
[ ! -s "$MOCK_LOG/todoist_posts" ] && ok || bad "promote: a full cap should create nothing"
jq -e 'length == 1 and .[0].wip_capped == true' "$STATE/queue.json" >/dev/null \
  && ok || bad "promote: capped item stays queued and flagged"

# ---- 4. corrupt queue no longer reads as empty -------------------------
case_dir corrupt; build_state "$STATE"
echo 'not json' > "$STATE/queue.json"
rc=0; out="$(run_it "$RR" 2>&1)" || rc=$?
[ "$rc" -eq 1 ] && ok || bad "corrupt queue should abort (got $rc)"
grep -q "not a JSON array" <<<"$out" && ok || bad "corrupt queue should say so"
[ ! -e "$STATE/last_reeval" ] && ok || bad "corrupt queue must NOT advance the weekly stamp"

summary claims_and_promotion
