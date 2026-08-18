#!/bin/bash
# run-scout.sh — one Issue Scout iteration.
# Invoked hourly by launchd (weekdays 09:00–18:00).
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${OSS_LAB_STATE_DIR:-$HOME/.local/share/oss-lab}"
TODOIST_API="${TODOIST_API:-https://api.todoist.com/api/v1}"

# Load secrets (GitHub PAT, Todoist token, project ID) — never in the repo.
# allexport so plain VAR= lines reach child processes (gh in fetch-issues.sh).
set -a
# shellcheck disable=SC1091
source "$STATE_DIR/env"
set +a

# --- Guard: secrets present (fail fast before any paid step) ------------
# Without last_run advancing, the missed window is re-fetched next run.
if [[ -z "${TODOIST_TOKEN:-}" || -z "${TODOIST_PROJECT_ID:-}" ]]; then
  echo "abort: TODOIST_TOKEN / TODOIST_PROJECT_ID not set in $STATE_DIR/env" >&2
  exit 1
fi

# --- Guard R3: verify we are on the PERSONAL Claude account -------------
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [[ "$CONFIG_DIR" != "$HOME/.claude" ]]; then
  echo "abort: CLAUDE_CONFIG_DIR points to $CONFIG_DIR (expected personal ~/.claude)" >&2
  exit 1
fi

# --- Weekly queue re-evaluation (flow control #3) -----------------------
# Stamp-gated rather than Monday-gated so a slept-through Monday self-heals
# on the next hourly run. run-reeval.sh advances the stamp only after a
# successful pass, so a failed pass retries next hour. Best-effort: a
# reeval failure must never cost the hourly scout iteration.
LAST_REEVAL="$(cat "$STATE_DIR/last_reeval" 2>/dev/null || true)"
[[ "$LAST_REEVAL" =~ ^[0-9]+$ ]] || LAST_REEVAL=0
if (( $(date +%s) - LAST_REEVAL >= 6 * 86400 )); then
  "$SKILL_DIR/scripts/run-reeval.sh" || echo "warn: reeval pass failed, continuing" >&2
fi

# --- Guard R1: fetch first; if nothing new, never start Claude ----------
NEW_ISSUES="$("$SKILL_DIR/scripts/fetch-issues.sh")"
if [[ -z "$NEW_ISSUES" ]]; then
  # commit the pending timestamp so the window advances
  mv -f "$STATE_DIR/last_run.pending" "$STATE_DIR/last_run" 2>/dev/null || true
  echo "no new issues — claude not invoked"
  exit 0
fi

# --- Guard: WIP cap (flow control #2) -----------------------------------
# Todoist API v1 (REST v2 was retired and answers 410). Responses are
# {results:[...], next_cursor}, and filters have their own endpoint.
#
# Filter query first; if Todoist rejects the filter, fall back to the
# project's own tasks counting only oss-lab-labelled ones — the project
# also holds unrelated tasks, so a bare project count would pin WIP above
# the cap forever. If Todoist is unreachable entirely, abort rather than
# fail open to 0 (last_run has not advanced, so nothing is lost).
WIP_COUNT="$(curl -sf --get "$TODOIST_API/tasks/filter" \
  --data-urlencode "query=@oss-lab & !@done" \
  -H "Authorization: Bearer $TODOIST_TOKEN" | jq '.results | length')" ||
WIP_COUNT="$(curl -sf --get "$TODOIST_API/tasks" \
  --data-urlencode "project_id=$TODOIST_PROJECT_ID" --data-urlencode "limit=200" \
  -H "Authorization: Bearer $TODOIST_TOKEN" |
  jq '[.results[] | select(.labels | index("oss-lab"))] | length')" || {
  echo "abort: todoist unreachable, WIP count unknown (window not advanced)" >&2
  exit 1
}

# --- Score with Claude (the only token-consuming step) ------------------
# WIP_COUNT reaches Claude as prompt text: with --allowedTools "Read" the
# model has no shell, so an environment variable would be invisible to it.
RESULTS="$(echo "$NEW_ISSUES" | claude -p "$(cat "$SKILL_DIR/prompt.md")

WIP_COUNT=$WIP_COUNT" \
  --allowedTools "Read" \
  --max-turns 15 \
  --output-format text)"

# Tolerant parse: skip fences/prose lines instead of dying on them. If
# NOTHING parses, abort without advancing the window so the batch is
# retried next hour instead of being silently lost.
VALID_RESULTS="$(echo "$RESULTS" | jq -cR 'fromjson? | select(type == "object" and .route != null)')"
if [[ -z "$VALID_RESULTS" ]]; then
  echo "abort: no parseable scores in claude output (window not advanced)" >&2
  exit 1
fi

# --- Route results ------------------------------------------------------
echo "$VALID_RESULTS" | while read -r item; do
  route="$(jq -r '.route' <<<"$item")"
  id="$(jq -r '.issue' <<<"$item")"
  case "$route" in
    todoist)
      title="$(jq -r '"Contribute: \(.issue) (score \(.weighted_total))"' <<<"$item")"
      # Best-effort: a failed POST must not kill the loop and discard the
      # rest of the paid batch. Fall back to the queue so the score survives.
      if ! curl -sf -X POST "$TODOIST_API/tasks" \
        -H "Authorization: Bearer $TODOIST_TOKEN" \
        -H "Content-Type: application/json" \
        -d "$(jq -n --arg c "$title" --arg d "$(jq -r '.rationale_consistency' <<<"$item")" \
              --arg p "$TODOIST_PROJECT_ID" \
              '{content:$c, description:$d, project_id:$p, labels:["oss-lab"]}')" >/dev/null; then
        echo "warn: todoist create failed for $id; routing to queue instead" >&2
        tmp="$(mktemp)"
        jq --argjson item "$item" '. + [$item]' "$STATE_DIR/queue.json" > "$tmp" \
          && mv "$tmp" "$STATE_DIR/queue.json"
      fi
      ;;
    queue)
      tmp="$(mktemp)"
      jq --argjson item "$item" '. + [$item]' "$STATE_DIR/queue.json" > "$tmp" \
        && mv "$tmp" "$STATE_DIR/queue.json"
      ;;
  esac
  # every scored issue becomes seen, regardless of route
  tmp="$(mktemp)"
  jq --arg id "$id" '. + [$id] | unique' "$STATE_DIR/seen.json" > "$tmp" \
    && mv "$tmp" "$STATE_DIR/seen.json"
done

# --- Commit state -------------------------------------------------------
mv -f "$STATE_DIR/last_run.pending" "$STATE_DIR/last_run" 2>/dev/null || true

SCORED="$(echo "$VALID_RESULTS" | wc -l | tr -d ' ')"
QUEUED="$(echo "$VALID_RESULTS" | jq -c 'select(.route == "queue")' | wc -l | tr -d ' ')"

# --- Sync state repo (best-effort) --------------------------------------
# Only seen.json and queue.json are ever staged; last_run(.pending) and
# logs stay out (also .gitignored in the state repo). A failed push must
# never fail the iteration (the network may be down): the commit rides
# along with a later push.
sync_state() {
  git -C "$STATE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  [[ -n "$(git -C "$STATE_DIR" status --porcelain -- seen.json queue.json)" ]] || return 0
  # Pathspec commit: never sweep unrelated pre-staged files into the
  # scout commit. Rebase first so a diverged remote self-heals.
  git -C "$STATE_DIR" commit --quiet \
    -m "scout: $(date +%Y-%m-%d) $SCORED scored, $QUEUED queued" \
    -- seen.json queue.json || return 1
  git -C "$STATE_DIR" pull --rebase --quiet || return 1
  git -C "$STATE_DIR" push --quiet || return 1
}
sync_state || echo "warn: state sync incomplete (push failed?) — continuing" >&2

echo "iteration complete: $SCORED issues scored, $QUEUED queued, WIP=$WIP_COUNT"
