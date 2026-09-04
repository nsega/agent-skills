#!/bin/bash
# run-scout.sh: one Issue Scout iteration.
# Invoked hourly by launchd (weekdays 09:00-18:00).
#
# SC2016: jq programs are single-quoted on purpose ($item, $new are jq
# variables bound with --argjson/--rawfile, not shell expansions).
# SC1091: lib.sh resolves at runtime from SKILL_DIR.
# shellcheck disable=SC2016,SC1091
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${OSS_LAB_STATE_DIR:-$HOME/.local/share/oss-lab}"
# shellcheck source=lib.sh
source "$SKILL_DIR/scripts/lib.sh"

# Secrets (GitHub PAT, Todoist token, project ID) never live in the repo.
# Failing here leaves last_run untouched, so the window is re-fetched.
oss_lab_load_env "$STATE_DIR"
oss_lab_guard_account

# Resolve our GitHub login once. The memo inside oss_lab_github_login dies
# with the command substitution every caller invokes it from, so without
# this each issue status pays an extra `gh api user` round-trip: a handful
# per hour for the task check, but one per entry once the queue prune runs.
# Exported so the run-reeval.sh child inherits it instead of re-resolving.
export OSS_LAB_GITHUB_LOGIN="${OSS_LAB_GITHUB_LOGIN:-$(oss_lab_github_login)}"

# --- Revalidate open tasks (zero tokens) --------------------------------
# Routing is otherwise a one-way door: an issue can be assigned, PR'd, or
# closed the day after its task was created, and the dead task would hold
# a cap slot forever while live candidates pile up in the queue. This runs
# before the fetch guard on purpose, since freeing a stale slot is worth
# doing on a quiet hour too, and it costs no tokens either way. It also
# runs before the weekly pass below, which sizes its promotion budget from
# the WIP count: a dead task still holding a slot at that moment shrinks
# the budget for a whole week, because the stamp advances either way.
oss_lab_revalidate_tasks

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

# --- Guard R1: fetch next; if nothing new, never start Claude -----------
NEW_ISSUES="$("$SKILL_DIR/scripts/fetch-issues.sh")"
if [[ -z "$NEW_ISSUES" ]]; then
  # commit the pending timestamp so the window advances
  mv -f "$STATE_DIR/last_run.pending" "$STATE_DIR/last_run" 2>/dev/null || true
  echo "no new issues, claude not invoked"
  exit 0
fi

WIP_COUNT="$(oss_lab_wip_count)" || {
  echo "abort: todoist unreachable, WIP count unknown (window not advanced)" >&2
  exit 1
}

# --- Score with Claude (the only token-consuming step) ------------------
# `--tools ""` disables every tool: the scorer reads untrusted issue text
# from public repos, and its output is auto-POSTed to Todoist and pushed
# to the state repo, so a tool-less scorer has no way to act on an
# injected instruction. All input arrives on stdin, so no tool is needed;
# WIP_COUNT and WIP_CAP likewise reach the model as prompt text rather
# than as (invisible) environment variables.
RESULTS="$(echo "$NEW_ISSUES" | claude -p "$(cat "$SKILL_DIR/prompt.md")

WIP_COUNT=$WIP_COUNT
WIP_CAP=$OSS_LAB_WIP_CAP" \
  --tools "" \
  --max-turns 15 \
  --output-format text)"

# If NOTHING parses, abort without advancing the window so the batch is
# retried next hour instead of being silently lost.
VALID_RESULTS="$(echo "$RESULTS" | oss_lab_parse_scores)"
if [[ -z "$VALID_RESULTS" ]]; then
  echo "abort: no parseable scores in claude output (window not advanced)" >&2
  exit 1
fi

# --- Route results ------------------------------------------------------
# The cap is enforced here, not only in the prompt: the model is asked to
# demote past the budget, but a runner that trusted it would break the
# no-hoarding invariant the moment the model miscounted.
BUDGET=$(( OSS_LAB_WIP_CAP - WIP_COUNT ))
(( BUDGET < 0 )) && BUDGET=0
CREATED=0
QUEUED=0

# Highest scores first, so a batch larger than the budget spends it on the
# best candidates rather than on whichever line the model emitted first.
while IFS= read -r item; do
  [[ -n "$item" ]] || continue
  route="$(jq -r '.route' <<<"$item")"
  id="$(jq -r '.issue' <<<"$item")"

  if [[ "$route" == "todoist" ]] && (( CREATED >= BUDGET )); then
    route="queue"
    item="$(jq -c '.wip_capped = true' <<<"$item")"
  fi

  case "$route" in
    todoist)
      if oss_lab_create_task "$item"; then
        CREATED=$((CREATED + 1))
      else
        # A failed POST must not discard the paid score: queue it, tagged
        # so the weekly pass can promote it once a slot frees.
        echo "warn: todoist create failed for $id, routing to queue instead" >&2
        oss_lab_append_json "$STATE_DIR/queue.json" --argjson item "$item" '. + [$item]' || true
        QUEUED=$((QUEUED + 1))
      fi
      ;;
    queue)
      oss_lab_append_json "$STATE_DIR/queue.json" --argjson item "$item" '. + [$item]' || true
      QUEUED=$((QUEUED + 1))
      ;;
  esac
  # every scored issue becomes seen, regardless of route
  echo "$id"
done < <(echo "$VALID_RESULTS" | jq -c -s 'sort_by(-(.weighted_total // 0)) | .[]') > "$STATE_DIR/.seen.pending"

# One rewrite per batch rather than one per issue.
if [[ -s "$STATE_DIR/.seen.pending" ]]; then
  oss_lab_append_json "$STATE_DIR/seen.json" \
    --rawfile new "$STATE_DIR/.seen.pending" \
    '. + ($new | split("\n") | map(select(length > 0))) | unique'
fi
rm -f "$STATE_DIR/.seen.pending"

# --- Commit state -------------------------------------------------------
mv -f "$STATE_DIR/last_run.pending" "$STATE_DIR/last_run" 2>/dev/null || true

SCORED="$(echo "$VALID_RESULTS" | wc -l | tr -d ' ')"

oss_lab_sync_state "$STATE_DIR" \
  "scout: $(date +%Y-%m-%d) $SCORED scored, $CREATED tasked, $QUEUED queued" ||
  echo "warn: state sync incomplete (push failed?), continuing" >&2

echo "iteration complete: $SCORED scored, $CREATED tasked, $QUEUED queued, WIP=$WIP_COUNT"
