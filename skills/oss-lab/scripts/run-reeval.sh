#!/bin/bash
# run-reeval.sh: one weekly queue re-evaluation pass (flow control #3).
# Re-scores every queued issue with the same rubric; two consecutive
# sub-threshold scores drop the issue. Invoked by run-scout.sh once the
# last_reeval stamp is 6+ days old, or manually for an ad-hoc pass.
set -euo pipefail

SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STATE_DIR="${OSS_LAB_STATE_DIR:-$HOME/.local/share/oss-lab}"
QUEUE_FILE="$STATE_DIR/queue.json"
STAMP_FILE="$STATE_DIR/last_reeval"

# --- Guard R3: verify we are on the PERSONAL Claude account -------------
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
if [[ "$CONFIG_DIR" != "$HOME/.claude" ]]; then
  echo "abort: CLAUDE_CONFIG_DIR points to $CONFIG_DIR (expected personal ~/.claude)" >&2
  exit 1
fi

# --- Guard R1: an empty queue never starts Claude -----------------------
mkdir -p "$STATE_DIR"
[[ -f "$QUEUE_FILE" ]] || echo '[]' > "$QUEUE_FILE"
if [[ "$(jq 'length' "$QUEUE_FILE")" -eq 0 ]]; then
  date +%s > "$STAMP_FILE"
  echo "queue empty, claude not invoked"
  exit 0
fi

# --- Re-score with Claude (the only token-consuming step) ---------------
# REEVAL=1 reaches Claude as prompt text for the same reason WIP_COUNT
# does in run-scout.sh: with --allowedTools "Read" the model has no shell,
# so an environment variable would be invisible to it.
RESULTS="$(jq -c '.[]' "$QUEUE_FILE" | claude -p "$(cat "$SKILL_DIR/prompt.md")

REEVAL=1" \
  --allowedTools "Read" \
  --max-turns 15 \
  --output-format text)"

# Tolerant parse: skip fences/prose lines instead of dying on them. If
# NOTHING parses, abort without advancing the stamp so the pass is retried
# next hour instead of being silently skipped for a week.
VALID_RESULTS="$(echo "$RESULTS" | jq -cR 'fromjson? | select(type == "object" and .route != null)')"
if [[ -z "$VALID_RESULTS" ]]; then
  echo "abort: no parseable scores in claude output (stamp not advanced)" >&2
  exit 1
fi

# --- Rewrite the queue --------------------------------------------------
# Keyed merge over the ORIGINAL queue: an issue Claude skipped stays queued
# untouched (rescored next week) rather than being silently lost, an issue
# routed "drop" is removed, and a hallucinated issue never enters.
ORIG_COUNT="$(jq 'length' "$QUEUE_FILE")"
tmp="$(mktemp)"
echo "$VALID_RESULTS" | jq -s --slurpfile orig "$QUEUE_FILE" '
  (map(select(.issue != null)) | map({key: .issue, value: .}) | from_entries) as $rescored
  | [ $orig[0][] | $rescored[.issue] // . ]
  | map(select(.route != "drop"))' > "$tmp" \
  && mv "$tmp" "$QUEUE_FILE"

date +%s > "$STAMP_FILE"

RESCORED="$(echo "$VALID_RESULTS" | wc -l | tr -d ' ')"
NEW_COUNT="$(jq 'length' "$QUEUE_FILE")"
DROPPED=$((ORIG_COUNT - NEW_COUNT))

# --- Sync state repo (best-effort, same contract as run-scout.sh) -------
sync_state() {
  git -C "$STATE_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  [[ -n "$(git -C "$STATE_DIR" status --porcelain -- seen.json queue.json)" ]] || return 0
  git -C "$STATE_DIR" commit --quiet \
    -m "reeval: $(date +%Y-%m-%d) $RESCORED rescored, $DROPPED dropped" \
    -- seen.json queue.json || return 1
  git -C "$STATE_DIR" pull --rebase --quiet || return 1
  git -C "$STATE_DIR" push --quiet || return 1
}
sync_state || echo "warn: state sync incomplete (push failed?), continuing" >&2

echo "reeval complete: $RESCORED rescored, $DROPPED dropped, $NEW_COUNT still queued"
