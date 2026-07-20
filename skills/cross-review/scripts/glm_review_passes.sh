#!/usr/bin/env bash
# Reviewer #2 as N independent passes, unioned into one findings file.
#
# Drop-in for glm_review.sh: same first four args, plus an optional pass count.
# Each pass is a fresh glm_review.sh call (its own opencode session) into a
# private temp dir; a pass with no valid JSON is retried, then skipped. The
# passes are unioned by aggregate_passes.py, which scores each finding by how
# many passes raised it. A single flaky or unlucky pass no longer sinks a review.
#
# Usage:
#   glm_review_passes.sh <BUNDLE> <RUBRIC> <SCHEMA> <OUT_JSON> [N]
#
# Env:
#   GLM_PASSES        default pass count if [N] omitted   (default: 3)
#   GLM_PASS_RETRIES  extra attempts per failed pass       (default: 1)
#   GLM_REVIEW_BIN    single-pass reviewer to invoke       (default: <skill>/scripts/glm_review.sh)
#
# Passes run SERIALLY: concurrent opencode runs contend on a shared session DB
# (observed as "database is locked").
set -euo pipefail

BUNDLE="${1:?need bundle path}"
RUBRIC="${2:?need rubric path}"
SCHEMA="${3:?need schema path}"
OUT="${4:?need output json path}"
N="${5:-${GLM_PASSES:-3}}"
RETRIES="${GLM_PASS_RETRIES:-1}"

case "$N" in ''|*[!0-9]*) echo "bad N: '$N' (want a positive integer)" >&2; exit 2 ;; esac
[ "$N" -ge 1 ] || { echo "bad N: '$N' (must be >= 1)" >&2; exit 2; }

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GLM_REVIEW_BIN="${GLM_REVIEW_BIN:-$SKILL_DIR/scripts/glm_review.sh}"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
succeeded=0
for i in $(seq 1 "$N"); do
  attempt=0
  while :; do
    if "$GLM_REVIEW_BIN" "$BUNDLE" "$RUBRIC" "$SCHEMA" "$WORK/pass-$i.json" \
         > "$WORK/pass-$i.out" 2> "$WORK/pass-$i.err"; then
      succeeded=$((succeeded + 1)); break
    fi
    attempt=$((attempt + 1))
    if [ "$attempt" -gt "$RETRIES" ]; then
      echo "pass $i failed after $((RETRIES + 1)) attempt(s); skipping" >&2
      rm -f "$WORK/pass-$i.json"   # ensure a partial file is not aggregated
      break
    fi
  done
done

echo "reviewer #2: $succeeded/$N passes succeeded" >&2
[ "$succeeded" -ge 1 ] || { echo "all $N passes failed; no review produced" >&2; exit 3; }

python3 "$SKILL_DIR/scripts/aggregate_passes.py" "$WORK" "$SCHEMA" "$OUT"
