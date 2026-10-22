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
OSS_LAB_WIP_CAP="${OSS_LAB_WIP_CAP:-8}"
# Routing thresholds (flow control #3). Both runners route by score with
# these, hourly and weekly. prompt.md repeats them for the model, and a test
# keeps the two in step.
OSS_LAB_PROMOTE_AT="${OSS_LAB_PROMOTE_AT:-7.0}"
OSS_LAB_DROP_BELOW="${OSS_LAB_DROP_BELOW:-5.0}"
# Rubric weights: the runner computes weighted_total from the axes itself.
# Not overridable (a weight change is a rubric change); a test keeps them in
# step with prompt.md.
OSS_LAB_WEIGHTS='{"okr_alignment":0.3,"consistency":0.3,"impact":0.2,"feasibility":0.2}'
# jq helper: show totals with one decimal ("7.0", not "7"); others as is.
OSS_LAB_JQ_FMT='def fmt1: if type == "number" and ((. * 10) - (. * 10 | round) | fabs) < 1e-9
  then (. * 10 | round) as $n | "\($n / 10 | floor).\($n % 10)" else tostring end;'

# --- diagnostics --------------------------------------------------------
# Print a bounded excerpt of a captured stream to stderr. Every paid call
# in this skill is wrapped in a command substitution, which swallows the
# child's stdout: a `claude` that fails and explains itself there leaves
# no trace in the log at all. That is how an expired credential cost five
# silent days in September 2026. The bound keeps a runaway response from
# filling the log file.
oss_lab_log_excerpt() {
  local what="$1" text="$2" max="${3:-500}"
  if [[ -z "$text" ]]; then
    echo "  $what produced no output" >&2
    return 0
  fi
  echo "  $what output (first $max chars): ${text:0:$max}" >&2
  if (( ${#text} > max )); then
    echo "  ... (${#text} chars total)" >&2
  fi
  return 0
}

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
# All pages of a Todoist listing as one JSON array (follows next_cursor).
# Fails rather than return a partial list.
# Usage: oss_lab_todoist_list <endpoint> [--data-urlencode key=value ...]
oss_lab_todoist_list() {
  local endpoint="$1"; shift
  local all='[]' page cursor="" pages=0 args
  while (( pages < 50 )); do
    args=("$@" --data-urlencode "limit=200")
    [[ -n "$cursor" ]] && args+=(--data-urlencode "cursor=$cursor")
    page="$(curl -sf --get "$TODOIST_API/$endpoint" "${args[@]}" \
              -H "Authorization: Bearer $TODOIST_TOKEN")" || return 1
    all="$(jq -c --argjson all "$all" '$all + .results' <<<"$page")" || return 1
    cursor="$(jq -r '.next_cursor // empty' <<<"$page")"
    [[ -z "$cursor" ]] && { echo "$all"; return 0; }
    pages=$((pages + 1))
  done
  return 1
}

# Active oss-lab tasks as JSONL: {id, content, issue}. `issue` is parsed
# back out of the task title, so a task the user renamed yields null and
# is left alone by revalidation rather than being closed on a guess.
# The optional bracket matches both title forms: the current markdown
# link, "Contribute: [owner/repo#1](url)", and the plain
# "Contribute: owner/repo#1" that earlier tasks still carry.
oss_lab_active_tasks() {
  oss_lab_todoist_list tasks --data-urlencode "project_id=$TODOIST_PROJECT_ID" |
    jq -c '.[]
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
  n="$(oss_lab_todoist_list tasks/filter --data-urlencode "query=@oss-lab & !@done" |
        jq -e 'length')" && { echo "$n"; return 0; }
  n="$(oss_lab_todoist_list tasks --data-urlencode "project_id=$TODOIST_PROJECT_ID" |
        jq -e '[.[] | select(.labels | index("oss-lab"))] | length')" && { echo "$n"; return 0; }
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
    "$OSS_LAB_JQ_FMT"'"Contribute: [\(.issue)](\($url)) (score \(.weighted_total | fmt1))"' <<<"$item")"
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

# --- per-run cache ------------------------------------------------------
# Lives outside the tracked state (sync commits by pathspec, and the state
# repo ignores .cache/). Holds the linked-PR search per repo and the raw
# copy of every issue whose status was checked this run, so the weekly pass
# can score from the issue as it stands today without a second fetch.
oss_lab_cache_dir() {
  echo "${OSS_LAB_CACHE_DIR:-${OSS_LAB_STATE_DIR:-$HOME/.local/share/oss-lab}/.cache}"
}

# Path of the cached upstream copy of an "owner/repo#123" issue.
oss_lab_issue_cache() {
  echo "$(oss_lab_cache_dir)/issue-${1//[\/#]/_}.json"
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
  local repo="$1" cache_dir; cache_dir="$(oss_lab_cache_dir)"
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
  # Keep the copy. The weekly pass scores from it, so the paid step reads
  # the issue as it stands today at no extra fetch. Best-effort: a cache
  # that cannot be written costs that issue its re-score, not the verdict.
  { mkdir -p "$(oss_lab_cache_dir)" &&
    printf '%s' "$json" > "$(oss_lab_issue_cache "$id")"; } 2>/dev/null || true

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
# The one invariant: this removes only entries it has POSITIVELY proven
# settled. It collects the settled ids and subtracts them, rather than
# collecting survivors and keeping those, so every way of failing to reach
# a verdict leaves the entry queued. That covers an unreachable GitHub
# ("unknown"), an id it cannot parse, and a read that fails outright.
#
# Only well-formed "owner/repo#123" ids are probed. Queue entries come from
# the scorer, which reads untrusted public issue text, so an id may be
# empty, carry an embedded newline, or be absent entirely; none of those is
# guessed at. Ids are deduplicated first, since nothing stops the same
# issue being queued twice and the probe costs a GitHub round-trip.
oss_lab_revalidate_queue() {
  local file="$1" id status ids stale='[]'
  ids="$(jq -r '[ .[] | .issue? // empty
                  | select(type == "string")
                  | select(test("^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+#[0-9]+$")) ]
                | unique | .[]' "$file")" || return 1

  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    status="$(oss_lab_issue_status "$id")"
    case "$status" in
      stale:*)
        echo "revalidate: dequeued $id (${status#stale:})"
        stale="$(jq -c --arg i "$id" '. + [$i]' <<<"$stale")"
        ;;
    esac
  done <<<"$ids"

  # append_json owns the temp-file dance and ends its success branch in the
  # mv, so a failed rewrite reaches the caller instead of being reported as
  # a clean pass over a queue that was never pruned.
  # SC2016: $settled and $i are jq bindings, not shell expansions. The
  # runners carry this as a file-wide directive; here it is one call, so
  # the exemption is scoped to it. shellcheck knows `jq` takes a program
  # but cannot see through the wrapper.
  # shellcheck disable=SC2016
  oss_lab_append_json "$file" --argjson settled "$stale" \
    'map(select(.issue as $i | ($settled | index($i)) == null))'
}

# --- scorer input -------------------------------------------------------
# Shape raw GitHub issue objects (a stream on stdin) into what the scorer
# reads: the fields the rubric grades and nothing else, body capped so one
# essay cannot crowd a batch. Keeps .number and .repo for
# oss_lab_attach_comments, which strips them. Shared by the first score
# (fetch-issues.sh) and the weekly re-score (run-reeval.sh) so the model
# grades the same input either way.
oss_lab_shape_issue() {
  local repo="$1"
  jq -c --arg repo "$repo" '{
    # "issue", not "id": the scorer echoes this key back as its output
    # identifier (the output contract in prompt.md), and a mismatch here
    # makes the router dereference a missing field.
    issue: "\($repo)#\(.number)",
    number: .number,
    repo: $repo,
    title: (.title // ""),
    labels: [(.labels // [])[].name],
    comments: (.comments // 0),
    created_at: .created_at,
    url: .html_url,
    body: (.body // "" | .[0:1500])
  }'
}

# Add each issue's newest three comments, so the scorer can spot a soft
# claim ("I can take this"). Page 1 holds the OLDEST comments, so read the
# last page instead. Long bodies keep their start and end.
oss_lab_attach_comments() {
  local item n repo num recent last on_last
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    n="$(jq -r '.comments' <<<"$item")"
    if [[ "$n" == "0" ]]; then
      jq -c 'del(.number, .repo)' <<<"$item"
      continue
    fi
    repo="$(jq -r '.repo' <<<"$item")"
    num="$(jq -r '.number' <<<"$item")"
    last=$(( (n + 99) / 100 ))
    on_last=$(( n - (last - 1) * 100 ))
    recent="$( {
        if (( on_last < 3 && last > 1 )); then
          gh api "repos/$repo/issues/$num/comments?per_page=100&page=$((last - 1))"
        fi
        gh api "repos/$repo/issues/$num/comments?per_page=100&page=$last"
      } 2>/dev/null \
      | jq -cs 'add | .[-3:] | map({author: .user.login,
                                    body: (.body // "" | gsub("\\s+"; " ")
                                           | if length > 240 then .[0:120] + " … " + .[-120:] else . end)})' \
          2>/dev/null || echo '[]')"
    # Validate rather than trust: a nonzero exit is caught above, but a call
    # that exits 0 while printing anything other than an array would reach
    # --argjson as invalid JSON, and jq's usage error would kill the whole
    # batch under set -e. One odd comment thread must not cost the window.
    jq -e 'type == "array"' <<<"$recent" >/dev/null 2>&1 || recent='[]'
    jq -c --argjson rc "$recent" 'del(.number, .repo) | .recent_comments = $rc' <<<"$item"
  done
}

# --- model output -------------------------------------------------------
# Tolerant parse of a scoring reply on stdin: skip fences and prose rather
# than dying on them, and keep only objects that meet the prompt.md output
# contract on the fields the callers act on: a string .issue, a .route of
# todoist | queue | drop, and a numeric .weighted_total. A malformed object
# therefore cannot become a "Contribute: null" or "(score null)" task, a
# seen-entry for an issue nobody scored, or a string sort key that kills the
# routing and promotion sorts (in jq, -"7.5" is an error and "7.5" >= 7.0 is
# true). Whether .issue belongs to the batch is the caller's check.
# Axes must be numbers 0-10; weighted_total is recomputed from them, and a
# differing model total is kept as .model_weighted_total for logging.
oss_lab_parse_scores() {
  jq -cR --argjson w "$OSS_LAB_WEIGHTS" 'fromjson?
    | select(type == "object"
             and (.issue | type) == "string"
             and (.route | IN("todoist", "queue", "drop"))
             and (.weighted_total | type) == "number"
             and (.scores | type) == "object"
             and (. as $o | [$w | keys[] | $o.scores[.]
                             | type == "number" and . >= 0 and . <= 10] | all))
    | (. as $o | [$w | to_entries[] | $o.scores[.key] * .value] | add * 10 | round / 10) as $t
    | (if (.weighted_total - $t | fabs) >= 0.05 then .model_weighted_total = .weighted_total else . end)
    | .weighted_total = $t'
}

# Log where the model's total differed from its axes, then drop the field.
oss_lab_note_recomputed() {
  local results="$1"
  [[ -n "$results" ]] || return 0
  jq -r "$OSS_LAB_JQ_FMT"'select(.model_weighted_total != null)
         | "note: \(.issue) reported weighted_total \(.model_weighted_total); its axes give \(.weighted_total | fmt1), which is used"' \
    <<<"$results" >&2
  jq -c 'del(.model_weighted_total)' <<<"$results"
}

# Route one scored issue the way the weekly pass does. Prints "route<TAB>why".
#   - claimed: drop
#   - scorer said "drop" on a passing score: drop (only a claim explains it)
#   - otherwise by score: todoist at 7.0+, queue at 5.0+, else drop (defaults)
# The caller applies the WIP cap.
oss_lab_route_scored() {
  jq -r --argjson at "$OSS_LAB_PROMOTE_AT" --argjson below "$OSS_LAB_DROP_BELOW" "$OSS_LAB_JQ_FMT"'
    if .claimed_by != null then ["drop", "claimed by \(.claimed_by)"]
    elif .route == "drop" and .weighted_total >= $below then
      ["drop", "dropped by the scorer at \(.weighted_total | fmt1) with no claimed_by, treated as a claim"]
    elif .weighted_total >= $at then ["todoist", ""]
    elif .weighted_total >= $below then ["queue", ""]
    else ["drop", ""]
    end | @tsv'
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
