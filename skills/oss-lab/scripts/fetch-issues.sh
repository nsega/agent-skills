#!/bin/bash
# fetch-issues.sh: collect new issues from target repos, apply hard filters,
# and emit only unseen, unclaimed candidates as JSON lines on stdout.
# Token cost: zero. Claude is never invoked here.
#
# SC1091: lib.sh resolves at runtime from SKILL_DIR.
# shellcheck disable=SC1091
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${OSS_LAB_STATE_DIR:-$HOME/.local/share/oss-lab}"
SEEN_FILE="$STATE_DIR/seen.json"
LAST_RUN_FILE="$STATE_DIR/last_run"
# shellcheck source=lib.sh
source "$SKILL_DIR/scripts/lib.sh"

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
  # Issues someone is already implementing (see oss_lab_linked_prs; cached
  # per run and shared with the revalidation pass). Fails soft: a degraded
  # search must not cost the whole window, and the scorer still sees the
  # comment thread.
  claimed="$(oss_lab_linked_prs "$repo")"
  gh api -X GET --paginate "repos/$repo/issues" \
    -f state=open -f since="$SINCE" -f per_page=100 \
    --jq '.[] | select(.pull_request | not)' |
  jq -c \
    --arg repo "$repo" \
    --argjson excl "$exclude_jq" \
    --argjson claimed "$claimed" \
    --slurpfile seen "$SEEN_FILE" '
    # Hard filters: no assignee, no excluded labels, no linked PR, unseen.
    # $num is bound before the pipe on purpose: inside `$claimed | index(x)`
    # the input to index() is $claimed, so a bare .number would index the
    # array instead of the issue.
    "\($repo)#\(.number)" as $id
    | .number as $num
    | select((.assignees // []) == [])
    | select(([.labels[].name] | map(IN($excl[])) | any) | not)
    | select(($claimed | index($num)) == null)
    | select(($seen[0] | index($id)) == null)
    | {
        # "issue", not "id": the scorer echoes this key back as its output
        # identifier (the output contract in prompt.md), and a mismatch
        # here makes the router dereference a missing field.
        issue: $id,
        number: .number,
        repo: $repo,
        title: .title,
        labels: [.labels[].name],
        comments: .comments,
        created_at: .created_at,
        url: .html_url,
        body: (.body // "" | .[0:1500])
      }'
done |
# Attach the tail of the comment thread for issues that have one, so the
# scorer can see a soft claim ("I can take this") that leaves no assignee
# and no PR. Only issues with comments cost an extra call.
while IFS= read -r item; do
  [[ -n "$item" ]] || continue
  n="$(jq -r '.comments' <<<"$item")"
  if [[ "$n" == "0" ]]; then
    jq -c 'del(.number, .repo)' <<<"$item"
    continue
  fi
  repo="$(jq -r '.repo' <<<"$item")"
  num="$(jq -r '.number' <<<"$item")"
  recent="$(gh api "repos/$repo/issues/$num/comments" \
              --jq '[.[-3:][] | {author: .user.login,
                                 body: (.body // "" | gsub("\\s+"; " ") | .[0:240])}]' \
            2>/dev/null || echo '[]')"
  jq -c --argjson rc "${recent:-[]}" 'del(.number, .repo) | .recent_comments = $rc' <<<"$item"
done

echo "$FETCH_START" > "$LAST_RUN_FILE.pending"
