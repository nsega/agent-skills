#!/bin/bash
# run-reeval.sh: one weekly queue re-evaluation pass (flow control #3).
# Revalidates the queue against upstream for free, re-scores what is left
# with the same rubric, promotes anything that now clears the threshold (as
# far as the WIP cap allows), and drops what has fallen sub-threshold
# twice. Invoked by run-scout.sh once the last_reeval stamp is 6+ days old,
# or manually for an ad-hoc pass.
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

# Inherited from run-scout.sh when it invokes this; resolved here for an
# ad-hoc pass. See the note there: without it every issue status pays an
# extra `gh api user`, once per queued entry during the prune below.
export OSS_LAB_GITHUB_LOGIN="${OSS_LAB_GITHUB_LOGIN:-$(oss_lab_github_login)}"

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

# --- WIP count ----------------------------------------------------------
# Read before anything is written, so every abort path leaves the state
# exactly as it found it.
WIP_COUNT="$(oss_lab_wip_count)" || {
  echo "abort: todoist unreachable, WIP count unknown (stamp not advanced)" >&2
  exit 1
}

# --- Guard R2: drop queued issues upstream has already settled ----------
# Zero tokens, and it runs before the paid call so the pass only ranks work
# that is still there to take. Without it, an issue that closed or was
# taken after being queued is re-scored every week forever: a settled issue
# still scores mid-band, so the two-strike drop never fires, and any
# promotion slot it wins is spent on work nobody can pick up.
oss_lab_revalidate_queue "$QUEUE_FILE" ||
  echo "warn: queue revalidation failed, re-scoring the queue as-is" >&2
LIVE_COUNT="$(jq 'length' "$QUEUE_FILE")"
PRUNED=$(( ORIG_COUNT - LIVE_COUNT ))

# Everything queued has been settled upstream: nothing left to rank.
if [[ "$LIVE_COUNT" -eq 0 ]]; then
  date +%s > "$STAMP_FILE"
  oss_lab_sync_state "$STATE_DIR" \
    "reeval: $(date +%Y-%m-%d) 0 rescored, 0 promoted, $PRUNED stale-pruned, 0 dropped" ||
    echo "warn: state sync incomplete (push failed?), continuing" >&2
  echo "queue empty after revalidation ($PRUNED stale pruned), claude not invoked"
  exit 0
fi

# --- Assemble the evidence (zero tokens) --------------------------------
# queue.json holds only the scoring object. Fed back as-is, the model would
# re-grade its own one-sentence rationale with no title, body, labels or
# comments, and scores would move on sampling noise rather than on anything
# that changed upstream. Guard R2 has just fetched every surviving issue to
# check its state, and kept the copy: that is the evidence, shaped exactly
# as fetch-issues.sh shapes a new issue, so the model grades the same input
# the first time and every time after. Only issues with comments cost one
# more call, as they did at the first score.
#
# The prior rationale and axis scores are deliberately NOT passed. They
# would anchor the model to its own past reasoning, which is the opposite
# of re-evaluating on new evidence. Only what the decay rule needs goes
# along: reeval_count and previous_total.
#
# An issue with no fresh copy (its fetch failed, so Guard R2 called it
# "unknown") is left out. The merge below keeps an unscored issue untouched,
# so it is simply retried next week.
# Only the shaped lines are appended to the file; the progress line for a
# skipped issue goes to the log like every other one, and must not end up
# as a line of scorer input.
EVIDENCE="$(mktemp)"
while IFS= read -r item; do
  [[ -n "$item" ]] || continue
  id="$(jq -r '.issue // empty' <<<"$item")"
  [[ -n "$id" ]] || continue
  cache="$(oss_lab_issue_cache "$id")"
  if [[ ! -f "$cache" ]] || [[ -n "$(find "$cache" -mmin +50 2>/dev/null)" ]]; then
    echo "reeval: no fresh upstream copy of $id, leaving it queued for next week"
    continue
  fi
  jq -c . "$cache" | oss_lab_shape_issue "${id%%#*}" | oss_lab_attach_comments |
    jq -c --argjson prior "$item" \
      '. + {reeval_count: ($prior.reeval_count // 0), previous_total: $prior.weighted_total}' \
    >> "$EVIDENCE"
done < <(jq -c '.[]' "$QUEUE_FILE")

# Nothing fetched means nothing to score on: re-grading last week's numbers
# is exactly the blind pass this step exists to avoid. Retry next hour.
if [[ ! -s "$EVIDENCE" ]]; then
  rm -f "$EVIDENCE"
  echo "abort: no fresh upstream copy of any queued issue, nothing to score (stamp not advanced)" >&2
  exit 1
fi

# --- Re-score with Claude (the only token-consuming step) ---------------
# `--tools ""` disables every tool, for the same reason as in run-scout.sh:
# queued items carry text that originated in untrusted public issues, and
# a tool-less scorer has nothing to exfiltrate secrets with. REEVAL=1 and
# WIP_COUNT reach the model as prompt text, since an env var is invisible.
RESULTS="$(claude -p "$(cat "$SKILL_DIR/prompt.md")

REEVAL=1
WIP_COUNT=$WIP_COUNT
WIP_CAP=$OSS_LAB_WIP_CAP" \
  --tools "" \
  --max-turns 15 \
  --output-format text < "$EVIDENCE")"
rm -f "$EVIDENCE"

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
#
# An entry with no .issue is also removed here: it can be neither re-scored
# nor promoted, so there is nothing to keep it for. Guard R2 leaves it
# alone (it proves nothing about it), which means the count below reports
# it under "dropped" rather than "stale-pruned".
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
    # Guard R2 already dropped what was settled before the paid call; this
    # re-check sits directly in front of the Todoist write and catches a
    # close or an assignment that landed during it. It does NOT catch a
    # linked PR opened during the call: oss_lab_linked_prs serves a 50
    # minute per-repo cache that Guard R2 populated minutes ago, so that
    # dimension is only as fresh as the prune was.
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
# Measured against the post-prune count, so "dropped" keeps meaning the
# two-strike rule and never absorbs the revalidation's removals.
DROPPED=$(( LIVE_COUNT - NEW_COUNT - PROMOTED ))

oss_lab_sync_state "$STATE_DIR" \
  "reeval: $(date +%Y-%m-%d) $RESCORED rescored, $PROMOTED promoted, $PRUNED stale-pruned, $DROPPED dropped" ||
  echo "warn: state sync incomplete (push failed?), continuing" >&2

echo "reeval complete: $RESCORED rescored, $PROMOTED promoted, $PRUNED stale-pruned, $DROPPED dropped, $NEW_COUNT still queued"
