#!/bin/bash
# lib.sh: helpers shared by the oss-lab runners. Sourced, never executed.
#
# Every function assumes the caller runs under `set -euo pipefail` and
# returns nonzero rather than exiting, so a caller can decide what is
# fatal. Todoist calls target API v1 (REST v2 was retired and answers
# 410): responses are {results: [...], next_cursor}.

TODOIST_API="${TODOIST_API:-https://api.todoist.com/api/v1}"
# Most active contributions to hold at once (flow control #2). This is
# the only place the cap is defined: the runners pass it to the scorer
# as $WIP_CAP, so prompt.md never hardcodes a number that could drift
# out of step with the budget the runner actually enforces.
OSS_LAB_WIP_CAP="${OSS_LAB_WIP_CAP:-5}"

# --- account guard ------------------------------------------------------
# The scout runs on the personal Claude account only.
oss_lab_guard_account() {
  local config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
  if [[ "$config_dir" != "$HOME/.claude" ]]; then
    echo "abort: CLAUDE_CONFIG_DIR points to $config_dir (expected personal ~/.claude)" >&2
    return 1
  fi
}

# --- secrets ------------------------------------------------------------
# allexport so plain VAR= lines reach child processes (gh, curl).
oss_lab_load_env() {
  local state_dir="$1"
  set -a
  # shellcheck disable=SC1091
  source "$state_dir/env"
  set +a
  if [[ -z "${TODOIST_TOKEN:-}" || -z "${TODOIST_PROJECT_ID:-}" ]]; then
    echo "abort: TODOIST_TOKEN / TODOIST_PROJECT_ID not set in $state_dir/env" >&2
    return 1
  fi
}

# The GitHub account whose claims are "ours": an issue assigned to us, or
# carrying our own open PR, is work in flight, not work someone else took.
oss_lab_github_login() {
  if [[ -z "${OSS_LAB_GITHUB_LOGIN:-}" ]]; then
    OSS_LAB_GITHUB_LOGIN="$(gh api user --jq .login 2>/dev/null || echo "")"
  fi
  echo "$OSS_LAB_GITHUB_LOGIN"
}

# --- Todoist ------------------------------------------------------------
# Active oss-lab tasks as JSONL: {id, content, issue}. `issue` is parsed
# back out of the task title, so a task the user renamed yields null and
# is left alone by revalidation rather than being closed on a guess.
# The optional bracket matches both title forms: the current markdown
# link, "Contribute: [owner/repo#1](url)", and the plain
# "Contribute: owner/repo#1" that earlier tasks still carry.
oss_lab_active_tasks() {
  curl -sf --get "$TODOIST_API/tasks" \
    --data-urlencode "project_id=$TODOIST_PROJECT_ID" \
    --data-urlencode "limit=200" \
    -H "Authorization: Bearer $TODOIST_TOKEN" |
    jq -c '.results[]
           | select(.labels | index("oss-lab"))
           | {id, content,
              issue: (.content | capture("Contribute: \\[?(?<i>[^\\[\\] ]+#[0-9]+)").i? // null)}'
}

# The web URL for an "owner/repo#123" id. GitHub redirects /issues/<n> to
# the pull request when the number is one, so this is right either way.
oss_lab_issue_url() {
  local id="$1"
  echo "https://github.com/${id%%#*}/issues/${id##*#}"
}

# Number of active oss-lab tasks. Filter query first; if Todoist rejects
# the filter, fall back to the project listing (label-scoped, because the
# project also holds unrelated tasks). A total failure returns nonzero:
# the caller must abort rather than fail open to 0, which would silently
# disable the cap.
oss_lab_wip_count() {
  local n
  n="$(curl -sf --get "$TODOIST_API/tasks/filter" \
        --data-urlencode "query=@oss-lab & !@done" \
        -H "Authorization: Bearer $TODOIST_TOKEN" |
        jq -e '.results | length')" && { echo "$n"; return 0; }
  n="$(curl -sf --get "$TODOIST_API/tasks" \
        --data-urlencode "project_id=$TODOIST_PROJECT_ID" \
        --data-urlencode "limit=200" \
        -H "Authorization: Bearer $TODOIST_TOKEN" |
        jq -e '[.results[] | select(.labels | index("oss-lab"))] | length')" && { echo "$n"; return 0; }
  return 1
}

# Create one Todoist task from a scored item. Best-effort by contract:
# the caller decides what a failure means for the batch.
oss_lab_create_task() {
  local item="$1" title body url
  # Markdown link so the task opens the issue in one click. Todoist keeps
  # the link text as the visible title, so the id still reads plainly.
  url="$(oss_lab_issue_url "$(jq -r '.issue' <<<"$item")")"
  title="$(jq -r --arg url "$url" \
    '"Contribute: [\(.issue)](\($url)) (score \(.weighted_total))"' <<<"$item")"
  body="$(jq -r '.rationale_consistency // ""' <<<"$item")"
  curl -sf -X POST "$TODOIST_API/tasks" \
    -H "Authorization: Bearer $TODOIST_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg c "$title" --arg d "$body" --arg p "$TODOIST_PROJECT_ID" \
          '{content:$c, description:$d, project_id:$p, labels:["oss-lab"]}')" >/dev/null
}

oss_lab_close_task() {
  curl -sf -X POST "$TODOIST_API/tasks/$1/close" \
    -H "Authorization: Bearer $TODOIST_TOKEN" >/dev/null
}

# --- linked pull requests ----------------------------------------------
# Issue numbers in a repo that already have a linked PR: someone is mid-
# implementation, so the issue is taken even with no assignee (the k8s norm
# is to open a PR without ever running /assign).
#
# This uses the search API rather than the per-issue timeline on purpose.
# A fine-grained PAT authenticates fine but returns ZERO cross-referenced
# timeline events for repos it does not own, which would silently report
# every taken issue as free; the search qualifier answers correctly under
# both fine-grained and classic tokens.
#
# The result is cached per repo for the run so the revalidation pass and
# the fetch filter share one computation instead of paying for it twice.
# Cache files live outside the tracked state (sync commits by pathspec).
oss_lab_linked_prs() {
  local repo="$1" cache_dir="${OSS_LAB_CACHE_DIR:-${OSS_LAB_STATE_DIR:-$HOME/.local/share/oss-lab}/.cache}"
  local cache="$cache_dir/linked-${repo//\//_}.json"
  mkdir -p "$cache_dir"
  # Fresh enough for one hourly iteration.
  if [[ -f "$cache" ]] && [[ -z "$(find "$cache" -mmin +50 2>/dev/null)" ]]; then
    cat "$cache"; return 0
  fi
  local out
  out="$(gh api -X GET search/issues --paginate \
           -f q="repo:$repo is:issue is:open linked:pr" -f per_page=100 \
           --jq '.items[].number' 2>/dev/null </dev/null |
         jq -R -s 'split("\n") | map(select(length > 0) | tonumber)' 2>/dev/null)" || out=""
  if [[ -z "$out" ]]; then
    echo "warn: linked-PR search failed for $repo, claim filter degraded" >&2
    echo '[]'
    return 0
  fi
  printf '%s' "$out" > "$cache"
  printf '%s' "$out"
}

# --- upstream issue state ----------------------------------------------
# Prints "live", "unknown", or "stale:<reason>" for an "owner/repo#123" id.
# Stale means the slot should be freed: the issue closed, another
# contributor was assigned, or the issue now carries a linked PR.
#
# A linked PR frees the slot whoever opened it. If it is someone else's,
# the work is taken; if it is ours, the contribution has been made and the
# cap should let the next candidate through while review runs. Assignment
# to us is different: that is claimed-but-undelivered work, so it stays.
oss_lab_issue_status() {
  local id="$1" repo num json me state others linked
  repo="${id%%#*}"; num="${id##*#}"
  me="$(oss_lab_github_login)"
  json="$(gh api "repos/$repo/issues/$num" </dev/null 2>/dev/null)" || { echo "unknown"; return 0; }

  state="$(jq -r '.state // "open"' <<<"$json")"
  [[ "$state" == "closed" ]] && { echo "stale:closed"; return 0; }

  others="$(jq -r --arg me "$me" '[.assignees[]?.login | select(. != $me)] | join(",")' <<<"$json")"
  [[ -n "$others" ]] && { echo "stale:assigned to $others"; return 0; }

  linked="$(oss_lab_linked_prs "$repo")"
  if jq -e --argjson n "$num" 'index($n) != null' <<<"$linked" >/dev/null 2>&1; then
    echo "stale:has a linked PR"
    return 0
  fi

  echo "live"
}

# Close every oss-lab task whose issue someone else now owns, so the WIP
# cap counts live work instead of tasks that were merely created once.
# Prints one line per closed task. Never fatal: an unreachable GitHub or
# Todoist just leaves the task in place for the next run to reconsider.
oss_lab_revalidate_tasks() {
  local tasks task id tid status freed=0
  tasks="$(oss_lab_active_tasks)" || return 0
  [[ -n "$tasks" ]] || return 0
  while IFS= read -r task; do
    [[ -n "$task" ]] || continue
    id="$(jq -r '.issue // ""' <<<"$task")"
    tid="$(jq -r '.id' <<<"$task")"
    # A renamed task no longer names an issue: leave it to the human.
    [[ -n "$id" ]] || continue
    status="$(oss_lab_issue_status "$id")"
    case "$status" in
      stale:*)
        if oss_lab_close_task "$tid"; then
          freed=$((freed + 1))
          echo "revalidate: closed $id (${status#stale:})"
        else
          echo "warn: could not close todoist task for $id" >&2
        fi
        ;;
    esac
  done <<<"$tasks"
  return 0
}

# Drop queued issues that upstream has already settled, rewriting the
# queue file in place and printing one line per issue removed.
#
# The queue is otherwise write-only until a re-score promotes something:
# an issue that closed, was assigned, or grew a linked PR after it was
# queued stays there and is re-scored (paid) every week forever, because a
# settled issue still scores mid-band and so never trips the two-strike
# drop. Running this before the paid call makes the weekly pass rank only
# work that is still there to take.
#
# "unknown" keeps the issue. An unreachable GitHub must not read as
# "settled", or a single network blip empties the queue permanently.
# Entries carrying no .issue are kept for the merge to decide on, which is
# the one place that knows what a malformed entry means.
oss_lab_revalidate_queue() {
  local file="$1" id status ids live tmp
  # Read the ids up front and bail if that fails. Callers invoke this in an
  # `||` list, which suspends errexit for the whole body, so a read failure
  # inside the loop would otherwise fall through to a rewrite with an empty
  # keep-list: the one outcome this function must never produce.
  ids="$(jq -r '.[] | .issue // empty' "$file")" || return 1

  live="$(mktemp)"
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    status="$(oss_lab_issue_status "$id")"
    case "$status" in
      stale:*) echo "revalidate: dequeued $id (${status#stale:})" ;;
      *)       echo "$id" >> "$live" ;;
    esac
  done <<<"$ids"

  tmp="$(mktemp)"
  if jq --rawfile kept "$live" '
        ($kept | split("\n") | map(select(length > 0))) as $k
        | map(select(.issue == null or (.issue as $i | $k | index($i))))' "$file" > "$tmp"; then
    mv "$tmp" "$file"
    rm -f "$live"
  else
    rm -f "$tmp" "$live"
    return 1
  fi
}

# --- model output -------------------------------------------------------
# Tolerant parse of a scoring reply on stdin: skip fences and prose rather
# than dying on them, and require the fields the callers dereference, so a
# malformed object cannot become a "Contribute: null" task or a "null"
# seen-entry.
oss_lab_parse_scores() {
  jq -cR 'fromjson?
    | select(type == "object" and .route != null and (.issue | type) == "string")'
}

# --- state files --------------------------------------------------------
# append_json <file> <jq-filter> [jq args...]: rewrite a JSON state file
# through a filter via a temp file, cleaning up if jq fails.
oss_lab_append_json() {
  local file="$1"; shift
  local tmp; tmp="$(mktemp)"
  if jq "$@" "$file" > "$tmp"; then
    mv "$tmp" "$file"
  else
    rm -f "$tmp"
    return 1
  fi
}

# Commit and push seen.json/queue.json. Staging first because a pathspec
# commit rejects paths git does not yet track, which is the state of a
# freshly cloned state repo; the pathspec still keeps unrelated staged
# files out. A conflicted rebase is aborted rather than left in place,
# where it would wedge every later sync and corrupt queue.json.
oss_lab_sync_state() {
  local state_dir="$1" msg="$2"
  git -C "$state_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  if [[ -z "$(git -C "$state_dir" status --porcelain -- seen.json queue.json)" ]]; then
    # Nothing new to commit, but an earlier push may still be stranded.
    git -C "$state_dir" push --quiet 2>/dev/null || true
    return 0
  fi
  git -C "$state_dir" add -- seen.json queue.json || return 1
  git -C "$state_dir" commit --quiet -m "$msg" -- seen.json queue.json || return 1
  git -C "$state_dir" pull --rebase --quiet || {
    git -C "$state_dir" rebase --abort 2>/dev/null || true
    return 1
  }
  git -C "$state_dir" push --quiet || return 1
}
