#!/bin/bash
# run-reeval.sh: one weekly queue re-evaluation pass (flow control #3).
# Re-scores every queued issue with the same rubric, promotes anything that
# now clears the threshold (as far as the WIP cap allows), and drops what
# has fallen sub-threshold twice. Invoked by run-scout.sh once the
# last_reeval stamp is 6+ days old, or manually for an ad-hoc pass.
#
# SC2016: jq programs are single-quoted on purpose (jq variables, not
# shell expansions). SC1091: lib.sh resolves at runtime from SKILL_DIR.
# shellcheck disable=SC2016,SC1091
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${OSS_LAB_STATE_DIR:-$HOME/.local/share/oss-lab}"
QUEUE_FILE="$STATE_DIR/queue.json"
STAMP_FILE="$STATE_DIR/last_reeval"
# shellcheck source=lib.sh
source "$SKILL_DIR/scripts/lib.sh"

oss_lab_load_env "$STATE_DIR"
oss_lab_guard_account

# --- Guard R1: an empty queue never starts Claude -----------------------
mkdir -p "$STATE_DIR"
[[ -f "$QUEUE_FILE" ]] || echo '[]' > "$QUEUE_FILE"
# jq -e so a corrupt queue.json is an error, not a silent "length 0" that
# would advance the stamp and skip the pass for another week.
if ! ORIG_COUNT="$(jq -e 'if type == "array" then length else error("not an array") end' "$QUEUE_FILE" 2>/dev/null)"; then
  echo "abort: $QUEUE_FILE is missing or not a JSON array (stamp not advanced)" >&2
  exit 1
fi
if [[ "$ORIG_COUNT" -eq 0 ]]; then
  date +%s > "$STAMP_FILE"
  echo "queue empty, claude not invoked"
  exit 0
fi

# --- Re-score with Claude (the only token-consuming step) ---------------
# `--tools ""` disables every tool, for the same reason as in run-scout.sh:
# queued items carry text that originated in untrusted public issues, and
# a tool-less scorer has nothing to exfiltrate secrets with. REEVAL=1 and
# WIP_COUNT reach the model as prompt text, since an env var is invisible.
WIP_COUNT="$(oss_lab_wip_count)" || {
  echo "abort: todoist unreachable, WIP count unknown (stamp not advanced)" >&2
  exit 1
}
RESULTS="$(jq -c '.[]' "$QUEUE_FILE" | claude -p "$(cat "$SKILL_DIR/prompt.md")

REEVAL=1
WIP_COUNT=$WIP_COUNT
WIP_CAP=$OSS_LAB_WIP_CAP" \
  --tools "" \
  --max-turns 15 \
  --output-format text)"

# If NOTHING parses, abort without advancing the stamp so the pass is
# retried next hour instead of being silently skipped for a week.
VALID_RESULTS="$(echo "$RESULTS" | oss_lab_parse_scores)"
if [[ -z "$VALID_RESULTS" ]]; then
  echo "abort: no parseable scores in claude output (stamp not advanced)" >&2
  exit 1
fi

# --- Rewrite the queue --------------------------------------------------
# Keyed merge over the ORIGINAL queue: an issue Claude skipped stays queued
# untouched (rescored next week) rather than being silently lost, an issue
# routed "drop" is removed, and a hallucinated issue never enters.
MERGED="$(mktemp)"
echo "$VALID_RESULTS" | jq -s --slurpfile orig "$QUEUE_FILE" '
  (map(select(.issue != null)) | map({key: .issue, value: .}) | from_entries) as $rescored
  | [ $orig[0][] | select(.issue != null) | $rescored[.issue] // . ]
  | map(select(.route != "drop"))' > "$MERGED"

# --- Promote what now clears the bar ------------------------------------
# Without this the queue has an entrance but no exit: an issue that rescored
# above the threshold would be written back as route "todoist" and re-scored
# (paid) every week forever without ever becoming a task.
BUDGET=$(( OSS_LAB_WIP_CAP - WIP_COUNT ))
(( BUDGET < 0 )) && BUDGET=0
PROMOTED_IDS="$(mktemp)"
PROMOTED=0
if (( BUDGET > 0 )); then
  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    id="$(jq -r '.issue' <<<"$item")"
    # Do not hand back work someone else picked up while it sat queued.
    status="$(oss_lab_issue_status "$id")"
    if [[ "$status" == stale:* ]]; then
      echo "promote: skipping $id (${status#stale:})"
      continue
    fi
    if oss_lab_create_task "$item"; then
      echo "$id" >> "$PROMOTED_IDS"
      PROMOTED=$((PROMOTED + 1))
      echo "promote: $id now a task"
    else
      echo "warn: todoist create failed for $id, leaving it queued" >&2
    fi
  done < <(jq -c --argjson n "$BUDGET" \
             '[.[] | select(.route == "todoist")] | sort_by(-(.weighted_total // 0)) | .[0:$n] | .[]' \
             "$MERGED")
fi

# Promoted issues leave the queue; anything still routed "todoist" that the
# budget could not cover stays, flagged, for the next pass.
tmp="$(mktemp)"
jq --rawfile promoted "$PROMOTED_IDS" '
  ($promoted | split("\n") | map(select(length > 0))) as $done
  | map(select(.issue as $i | ($done | index($i)) == null))
  | map(if .route == "todoist" then .wip_capped = true else . end)' "$MERGED" > "$tmp" \
  && mv "$tmp" "$QUEUE_FILE"
rm -f "$MERGED" "$PROMOTED_IDS"

date +%s > "$STAMP_FILE"

RESCORED="$(echo "$VALID_RESULTS" | wc -l | tr -d ' ')"
NEW_COUNT="$(jq 'length' "$QUEUE_FILE")"
DROPPED=$(( ORIG_COUNT - NEW_COUNT - PROMOTED ))

oss_lab_sync_state "$STATE_DIR" \
  "reeval: $(date +%Y-%m-%d) $RESCORED rescored, $PROMOTED promoted, $DROPPED dropped" ||
  echo "warn: state sync incomplete (push failed?), continuing" >&2

echo "reeval complete: $RESCORED rescored, $PROMOTED promoted, $DROPPED dropped, $NEW_COUNT still queued"
