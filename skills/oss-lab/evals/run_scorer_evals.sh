#!/usr/bin/env bash
# run_scorer_evals.sh: run the oss-lab scorer fixtures through the real
# `claude -p` on the owner's Mac and grade the replies. PAID: one call per
# eval per repeat. Never run in CI (no claude, no credentials there).
#
#   bash run_scorer_evals.sh [<agent-skills-dir>] [--yes] [--only ID[,ID...]]
#                            [--repeat N] [--evals FILE] [--out DIR]
#
# The checkout defaults to the one this file is in. Each eval is sent exactly
# the way run-scout.sh sends a batch:
#   echo "<issue JSONL>" | claude -p "$(cat prompt.md)
#
#   WIP_COUNT=<eval wip_count>
#   WIP_CAP=$OSS_LAB_WIP_CAP
#   SCOUT_LOGIN=$SCOUT_LOGIN" --tools "" --max-turns 15 --output-format text
# with OSS_LAB_WIP_CAP taken from the checkout's scripts/lib.sh, SCOUT_LOGIN
# from OSS_LAB_GITHUB_LOGIN (default nsega; no gh call), and the same
# CLAUDE_CONFIG_DIR guard the runner enforces (oss_lab_guard_account).
#
# Each reply is graded by grade.jq against:
#   validity rules   prompt.md output contract and routing rules (JSONL only,
#                    one object per input issue, axes 0-10, weighted_total
#                    consistent with the axes, route consistent with the total,
#                    claim and WIP cap; no secret-like text)
#   expectations     the eval's assertions: per-axis bands, total range,
#                    route, claimed_by, wip_capped, WIP slot ordering
# Nothing else is touched: no gh, no Todoist, no state dir.
#
# Output (default ./scorer-eval-results/<UTC timestamp>/):
#   <id>.r<k>.reply.txt   raw reply      <id>.r<k>.grade.json   grade
#   results.jsonl         one grade per line; summary.txt
# Exit 0 if every graded reply passes, 1 if any fails, 2 on usage/setup error.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AS="$HERE/../../.." YES=0 ONLY="" REPEAT=1 EVALS="$HERE/evals.json" OUT=""
GRADER="$HERE/grade.jq"

usage() { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) YES=1 ;;
    --only) ONLY="${2:?}"; shift ;;
    --repeat) REPEAT="${2:?}"; shift ;;
    --evals) EVALS="${2:?}"; shift ;;
    --out) OUT="${2:?}"; shift ;;
    -h|--help) usage ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) AS="$1" ;;
  esac
  shift
done
[ -n "$AS" ] || usage
[[ "$REPEAT" =~ ^[1-9][0-9]*$ ]] || { echo "error: --repeat must be a positive integer" >&2; exit 2; }

SKILL_DIR="$(cd "$AS/skills/oss-lab" 2>/dev/null && pwd)" || {
  echo "error: $AS/skills/oss-lab not found (pass the agent-skills checkout root)" >&2; exit 2; }
for f in "$SKILL_DIR/prompt.md" "$SKILL_DIR/scripts/lib.sh" "$EVALS" "$GRADER"; do
  [ -f "$f" ] || { echo "error: missing $f" >&2; exit 2; }
done
for t in jq claude; do
  command -v "$t" >/dev/null || { echo "error: $t not found on PATH" >&2; exit 2; }
done

# Same cap and the same account guard as the runner. lib.sh only defines
# functions and defaults when sourced; nothing here calls gh or Todoist.
# shellcheck source=/dev/null
source "$SKILL_DIR/scripts/lib.sh"
oss_lab_guard_account || exit 2

# Select evals.
ids_json="$(jq -c '[.evals[].id]' "$EVALS")"
if [ -n "$ONLY" ]; then
  ids_json="$(jq -cn --arg only "$ONLY" --argjson all "$ids_json" \
    '[$only | split(",")[] | tonumber] | map(select(. as $i | $all | index($i)))')"
fi
# Plain read loop rather than mapfile: macOS /bin/bash is 3.2.
IDS=()
while IFS= read -r i; do IDS+=("$i"); done < <(jq -r '.[]' <<<"$ids_json")
[ "${#IDS[@]}" -gt 0 ] || { echo "error: no evals selected" >&2; exit 2; }
CALLS=$(( ${#IDS[@]} * REPEAT ))

echo "oss-lab scorer evals: ${#IDS[@]} eval(s) x $REPEAT repeat(s) = $CALLS paid claude call(s)"
echo "  skill:  $SKILL_DIR ($(git -C "$AS" rev-parse --short HEAD 2>/dev/null || echo 'not a git checkout'))"
SCOUT_LOGIN="${OSS_LAB_GITHUB_LOGIN:-nsega}"
echo "  claude: $(claude --version 2>/dev/null || echo unknown)   WIP_CAP=$OSS_LAB_WIP_CAP   SCOUT_LOGIN=$SCOUT_LOGIN"
if (( ! YES )); then
  echo "Re-run with --yes to spend these calls." >&2
  exit 2
fi

OUT="${OUT:-$PWD/scorer-eval-results/$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"
: > "$OUT/results.jsonl"
PROMPT_MD="$(cat "$SKILL_DIR/prompt.md")"

pass=0 fail=0
for id in "${IDS[@]}"; do
  ev="$(jq -c --argjson id "$id" '.evals[] | select(.id == $id)' "$EVALS")"
  name="$(jq -r '.name' <<<"$ev")"
  issues="$(jq -r '.prompt' <<<"$ev")"
  wip_count="$(jq -r '.wip_count // 0' <<<"$ev")"
  for ((k=1; k<=REPEAT; k++)); do
    reply="$OUT/$id.r$k.reply.txt"
    rc=0
    # Identical to run-scout.sh: stdin carries the JSONL, the prompt is
    # prompt.md plus the runner lines (WIP_COUNT, WIP_CAP, SCOUT_LOGIN), and
    # the scorer holds no tools.
    echo "$issues" | claude -p "$PROMPT_MD

WIP_COUNT=$wip_count
WIP_CAP=$OSS_LAB_WIP_CAP
SCOUT_LOGIN=$SCOUT_LOGIN" \
      --tools "" \
      --max-turns 15 \
      --output-format text > "$reply" 2> "$OUT/$id.r$k.stderr.txt" || rc=$?
    jq -nc --argjson eval "$ev" --rawfile out "$reply" --argjson wip_cap "$OSS_LAB_WIP_CAP" -f "$GRADER" \
       | jq -c --argjson rc "$rc" --argjson rep "$k" \
           '. + {repeat: $rep, claude_rc: $rc}
            | if $rc != 0 then .pass = false | .validity_failures += ["claude exited \($rc)"] else . end' \
       > "$OUT/$id.r$k.grade.json"
    cat "$OUT/$id.r$k.grade.json" >> "$OUT/results.jsonl"
    if jq -e '.pass' "$OUT/$id.r$k.grade.json" >/dev/null; then
      pass=$((pass + 1)); status=PASS
    else
      fail=$((fail + 1)); status=FAIL
    fi
    detail="$(jq -r '[.validity_failures[], .expectation_failures[]] | join("; ")' "$OUT/$id.r$k.grade.json")"
    routes="$(jq -r '[.objects[] | "\(.weighted_total) \(.route)"] | join(", ")' "$OUT/$id.r$k.grade.json")"
    printf '%s  %2s %-32s r%s  [%s]  %s\n' "$status" "$id" "$name" "$k" "$routes" "$detail" | tee -a "$OUT/summary.txt"
  done
done

{
  echo "summary: $((pass + fail)) graded replies, $pass passed, $fail failed"
  echo "validity failures: $(jq -s '[.[] | select(.valid | not)] | length' "$OUT/results.jsonl")"
  echo "results: $OUT"
} | tee -a "$OUT/summary.txt"
(( fail == 0 ))
