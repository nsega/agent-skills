#!/usr/bin/env bash
# Todoist listings follow next_cursor, so tasks past the first page are
# revalidated and counted (F13).
# shellcheck disable=SC2015,SC1091
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/helpers.sh"
source "$HERE/../scripts/lib.sh"   # only defines functions and defaults

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
MOCKBIN="$WORK/bin"; build_mockbin "$MOCKBIN"
mkdir -p "$WORK/log"

# 450 tasks in the project; only three carry the oss-lab label, all past the
# first page of 200.
jq -n '[range(0; 450) | {id: "t\(.)", content: "chore \(.)", labels: []}]
       | .[210] = {id: "t210", content: "Contribute: kubernetes/kubernetes#1 (score 8.0)", labels: ["oss-lab"]}
       | .[330] = {id: "t330", content: "Contribute: kubernetes/kubernetes#2 (score 7.5)", labels: ["oss-lab"]}
       | .[449] = {id: "t449", content: "Contribute: kubernetes/kubernetes#3 (score 7.1)", labels: ["oss-lab"]}' \
  > "$WORK/tasks.json"

# Point the lib functions at the mocks. Called inside $( ), so the exports
# stay in that subshell.
mocks() {
  export PATH="$MOCKBIN:$PATH" MOCK_LOG="$WORK/log" MOCK_TASKS_JSON="$WORK/tasks.json" \
         TODOIST_API="https://todoist.invalid/api/v1" TODOIST_PROJECT_ID=p TODOIST_TOKEN=t
}

# 1: the active-task listing finds all three, across three pages.
got="$(mocks; oss_lab_active_tasks | jq -sc 'map(.id)')"
[ "$got" = '["t210","t330","t449"]' ] && ok || bad "active tasks: must list every oss-lab task past page one, got: $got"

# 2: the WIP fallback (filter query rejected) counts them too.
got="$(mocks; export MOCK_FILTER_FAIL=1; oss_lab_wip_count)"
[ "$got" = 3 ] && ok || bad "wip fallback: must count 3 oss-lab tasks across pages, got: $got"

summary "todoist paging"
