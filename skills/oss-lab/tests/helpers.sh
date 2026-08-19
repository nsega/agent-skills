#!/usr/bin/env bash
# helpers.sh: shared scaffolding for the oss-lab test suites. Sourced.
#
# Provides a counter pair (ok/bad), a mock bin dir holding fake `claude`,
# `gh`, and `curl`, and a throwaway state dir. The mocks are driven by
# environment variables so each case can pick the upstream state it wants
# without a network or a paid call.
#
# `X && ok || bad` is the house test idiom; ok never fails.
# shellcheck disable=SC2015

pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1" >&2; }
summary() { echo "$1: $pass passed, $fail failed"; [ "$fail" -eq 0 ]; }

# build_mockbin <dir>
# claude : records argv and stdin, replays $MOCK_CLAUDE_OUT
# gh     : serves canned GitHub responses, honouring --jq like the real gh
# curl   : serves the Todoist API v1 surface, recording writes
build_mockbin() {
  local d="$1"; mkdir -p "$d"

  cat > "$d/claude" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" > "$MOCK_LOG/claude_args"
cat > "$MOCK_LOG/claude_stdin"
cat "${MOCK_CLAUDE_OUT:-/dev/null}"
EOF

  # MOCK_GH_LOGIN     : our login (default nsega)
  # MOCK_LINKED       : space-separated issue numbers that have a linked PR
  # MOCK_ISSUES_JSON  : file of {"<owner/repo#n>": {state, assignees}} overrides
  # MOCK_TIMELINE_JSON: file of {"<owner/repo#n>": [PR objects]} overrides
  # MOCK_COMMENTS_JSON: file of {"<owner/repo#n>": [comment objects]} overrides
  # MOCK_FETCH        : file of raw issue JSONL returned by the issues list
  cat > "$d/gh" <<'EOF'
#!/bin/bash
args=("$@"); filter=""; raw=""
for ((i=0; i<${#args[@]}; i++)); do
  [ "${args[$i]}" = "--jq" ] && filter="${args[$((i+1))]}"
done
# Flatten newlines: a --jq filter may span lines, and the sed dispatch
# below is line-oriented, which would otherwise mangle the endpoint match.
all="$(printf '%s' "$*" | tr '\n' ' ')"
lookup() { # $1 file, $2 key, $3 default
  [ -n "${1:-}" ] && [ -f "$1" ] && jq -c --arg k "$2" --argjson d "$3" '.[$k] // $d' "$1" || echo "$3"
}
case "$all" in
  *"api user"*)
    raw="{\"login\":\"${MOCK_GH_LOGIN:-nsega}\"}" ;;
  *search/issues*)
    items="[]"
    for n in ${MOCK_LINKED:-}; do items="$(jq -c --argjson n "$n" '. + [{number:$n}]' <<<"$items")"; done
    raw="{\"total_count\":$(jq length <<<"$items"),\"items\":$items}" ;;
  *"/timeline"*)
    key="$(sed -E 's#.*repos/([^ ]+)/issues/([0-9]+)/timeline.*#\1#' <<<"$all")"
    num="$(sed -E 's#.*repos/[^ ]+/issues/([0-9]+)/timeline.*#\1#' <<<"$all")"
    prs="$(lookup "${MOCK_TIMELINE_JSON:-}" "$key#$num" '[]')"
    raw="$(jq -c '[.[] | {event:"cross-referenced", source:{issue:.}}]' <<<"$prs")" ;;
  *"/comments"*)
    key="$(sed -E 's#.*repos/([^ ]+)/issues/([0-9]+)/comments.*#\1#' <<<"$all")"
    num="$(sed -E 's#.*repos/[^ ]+/issues/([0-9]+)/comments.*#\1#' <<<"$all")"
    raw="$(lookup "${MOCK_COMMENTS_JSON:-}" "$key#$num" '[]')" ;;
  *"repos/"*"/issues/"*)
    key="$(sed -E 's#.*repos/([^ ]+)/issues/([0-9]+).*#\1#' <<<"$all")"
    num="$(sed -E 's#.*repos/[^ ]+/issues/([0-9]+).*#\1#' <<<"$all")"
    raw="$(lookup "${MOCK_ISSUES_JSON:-}" "$key#$num" '{"state":"open","assignees":[]}')" ;;
  *"repos/"*"/issues"*)   # the issues LIST endpoint
    if [ -n "${MOCK_FETCH:-}" ] && [ -f "$MOCK_FETCH" ]; then
      raw="$(jq -s -c '.' "$MOCK_FETCH")"
    else raw="[]"; fi ;;
  *) raw="{}" ;;
esac
if [ -n "$filter" ]; then jq -r "$filter" <<<"$raw"; else echo "$raw"; fi
EOF

  # MOCK_WIP        : number reported by the filter endpoint (default 0)
  # MOCK_FILTER_FAIL: non-empty makes /tasks/filter fail (fallback path)
  # MOCK_TASKS_JSON : file with the project task list for the fallback and
  #                   for revalidation
  # MOCK_POST_FAIL  : non-empty makes task creation fail
  cat > "$d/curl" <<'EOF'
#!/bin/bash
# MOCK_TODOIST_DOWN: every call fails, i.e. Todoist unreachable entirely
# (distinct from MOCK_FILTER_FAIL, where only the filter endpoint rejects
# the query and the project-listing fallback still answers).
[ -n "${MOCK_TODOIST_DOWN:-}" ] && exit 22
all="$*"
case "$all" in
  *"/tasks/filter"*)
    [ -n "${MOCK_FILTER_FAIL:-}" ] && exit 22
    items="[]"
    i=0; while [ "$i" -lt "${MOCK_WIP:-0}" ]; do
      items="$(jq -c '. + [{"id":"w'"$i"'"}]' <<<"$items")"; i=$((i+1)); done
    echo "{\"results\":$items,\"next_cursor\":null}" ;;
  *POST*"/close"*)
    echo "$all" | sed -E 's#.*/tasks/([^/]+)/close.*#\1#' >> "$MOCK_LOG/todoist_closed"
    echo '{}' ;;
  *POST*"/tasks"*)
    [ -n "${MOCK_POST_FAIL:-}" ] && exit 22
    for ((i=1; i<=$#; i++)); do
      [ "${!i}" = "-d" ] && { j=$((i+1)); printf '%s\n' "${!j}" >> "$MOCK_LOG/todoist_posts"; }
    done
    echo '{"id":"new"}' ;;
  *"/tasks"*)
    if [ -n "${MOCK_TASKS_JSON:-}" ] && [ -f "$MOCK_TASKS_JSON" ]; then
      echo "{\"results\":$(cat "$MOCK_TASKS_JSON"),\"next_cursor\":null}"
    else echo '{"results":[],"next_cursor":null}'; fi ;;
  *) echo '{}' ;;
esac
EOF
  chmod +x "$d"/claude "$d"/gh "$d"/curl
}

# build_state <dir> [--git]: state dir with env; --git makes it a repo
# with a local bare remote so the sync path is exercised for real.
build_state() {
  local s="$1" git_mode="${2:-}"
  mkdir -p "$s"
  printf 'TODOIST_TOKEN=x\nTODOIST_PROJECT_ID=y\n' > "$s/env"
  echo '[]' > "$s/seen.json"
  echo '[]' > "$s/queue.json"
  if [ "$git_mode" = "--git" ]; then
    git init --quiet "$s"
    git -C "$s" config user.email test@example.com
    git -C "$s" config user.name test
    git -C "$s" add seen.json queue.json
    git -C "$s" commit --quiet -m init
    git init --bare --quiet "$s.remote.git"
    git -C "$s" remote add origin "$s.remote.git"
    git -C "$s" push --quiet -u origin HEAD
  fi
}
