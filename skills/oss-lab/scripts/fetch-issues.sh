#!/bin/bash
# fetch-issues.sh — collect new issues from target repos, apply hard filters,
# and emit only unseen candidates as JSON lines on stdout.
# Token cost: zero. Claude is never invoked here.
set -euo pipefail

STATE_DIR="${OSS_LAB_STATE_DIR:-$HOME/.local/share/oss-lab}"
SEEN_FILE="$STATE_DIR/seen.json"
LAST_RUN_FILE="$STATE_DIR/last_run"

REPOS=(
  "kubernetes/kubernetes"
  "kubernetes-sigs/kueue"
  "kubernetes-sigs/gateway-api-inference-extension"
)

# Labels that disqualify an issue before scoring (hard filter #1)
EXCLUDE_LABELS=(
  "lifecycle/stale"
  "lifecycle/rotten"
  "triage/unresolved"
)

mkdir -p "$STATE_DIR"
[ -f "$SEEN_FILE" ] || echo '[]' > "$SEEN_FILE"
[ -f "$STATE_DIR/queue.json" ] || echo '[]' > "$STATE_DIR/queue.json"

# Default lookback: 24h on first run. BSD date (-v) vs GNU date (-d):
# coreutils' gnubin may shadow /bin/date, so try both.
SINCE=$(cat "$LAST_RUN_FILE" 2>/dev/null) ||
  SINCE=$(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
          date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ)

# Next window starts where this fetch STARTED: capturing the timestamp
# after the API calls would leave a blind gap for issues updated mid-fetch.
FETCH_START=$(date -u +%Y-%m-%dT%H:%M:%SZ)

exclude_jq=$(printf '"%s",' "${EXCLUDE_LABELS[@]}")
exclude_jq="[${exclude_jq%,}]"

for repo in "${REPOS[@]}"; do
  gh api -X GET --paginate "repos/$repo/issues" \
    -f state=open -f since="$SINCE" -f per_page=100 \
    --jq '.[] | select(.pull_request | not)' |
  jq -c \
    --arg repo "$repo" \
    --argjson excl "$exclude_jq" \
    --slurpfile seen "$SEEN_FILE" '
    # Hard filters: no assignee, no excluded labels, not already seen
    "\($repo)#\(.number)" as $id
    | select((.assignees // []) == [])
    | select(([.labels[].name] | map(IN($excl[])) | any) | not)
    | select(($seen[0] | index($id)) == null)
    | {
        id: $id,
        title: .title,
        labels: [.labels[].name],
        comments: .comments,
        created_at: .created_at,
        url: .html_url,
        body: (.body // "" | .[0:1500])
      }'
done

echo "$FETCH_START" > "$LAST_RUN_FILE.pending"
