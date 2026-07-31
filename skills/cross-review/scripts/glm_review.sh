#!/usr/bin/env bash
# Reviewer #2: run GLM-5.2 through opencode (OpenCode Zen) on a review bundle,
# capture structured findings as JSON, and ENFORCE the schema (incl. the
# Evidence/failure_case rules) before accepting the output.
#
# Usage:
#   glm_review.sh <BUNDLE> <RUBRIC> <SCHEMA> <OUT_JSON>
#
# Env:
#   ZEN_MODEL       opencode model id            (default: opencode/glm-5.2)
#   OPENCODE_CONFIG path to hardened config       (default: <skill>/config/opencode.zen.json)
#   ZEN_VARIANT     reasoning-effort variant     (default: max)
#
# Effort is always max. The lite/full stakes tier is NOT wired to effort: an A/B
# over one identical packet (see README "Effort and run-to-run variance") found
# run-to-run variance at least as large as any high-vs-max difference, so tiering
# effort bought nothing measurable. ZEN_VARIANT remains only to re-run that
# experiment. The tier still drives packet level and report scope, elsewhere.
#
# Notes:
# - Review-only. We ask GLM for findings, never for a patch, and run opencode in
#   a non-interactive single-shot ("run") so it does not edit the repo.
# - opencode ACCEPTS AN UNKNOWN --variant SILENTLY (verified: a bogus value exits
#   0 and reviews anyway), so a typo would quietly downgrade effort with no
#   signal. That is why ZEN_VARIANT is validated here rather than trusted to the CLI.
set -euo pipefail

BUNDLE="${1:?need bundle path}"
RUBRIC="${2:?need rubric path}"
SCHEMA="${3:?need schema path}"
OUT="${4:?need output json path}"

ZEN_VARIANT="${ZEN_VARIANT:-max}"
case "$ZEN_VARIANT" in
  minimal|low|high|max) ;;
  *) echo "bad ZEN_VARIANT: '$ZEN_VARIANT' (want minimal|low|high|max)" >&2; exit 2 ;;
esac

# Check inputs BEFORE spending anything. Without this a typo'd bundle path still
# reaches opencode (`cat missing | opencode` leaves opencode reading empty stdin)
# and bills a full paid review of nothing.
for f in "$BUNDLE" "$RUBRIC" "$SCHEMA"; do
  [ -f "$f" ] || { echo "no such file: $f" >&2; exit 2; }
done
[ -s "$BUNDLE" ] || { echo "bundle is empty: $BUNDLE" >&2; exit 2; }

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ZEN_MODEL="${ZEN_MODEL:-opencode/glm-5.2}"
export OPENCODE_CONFIG="${OPENCODE_CONFIG:-$SKILL_DIR/config/opencode.zen.json}"

command -v opencode >/dev/null || { echo "opencode not found on PATH" >&2; exit 127; }

# opencode reads its stored credential only in interactive sessions; a
# non-interactive `run` needs the key in the env or it dies with "Missing API key"
# despite auth.json being present and valid.
AUTH_JSON="${OPENCODE_AUTH_JSON:-${XDG_DATA_HOME:-$HOME/.local/share}/opencode/auth.json}"
if [ -z "${OPENCODE_API_KEY:-}" ] && [ -f "$AUTH_JSON" ]; then
  OPENCODE_API_KEY="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1]))["opencode"]["key"])
except Exception: pass' "$AUTH_JSON")" || true
  [ -n "$OPENCODE_API_KEY" ] && export OPENCODE_API_KEY
fi
if [ -z "${OPENCODE_API_KEY:-}" ]; then
  echo "no OpenCode Zen key: set OPENCODE_API_KEY, or run 'opencode auth login' (expected at $AUTH_JSON)" >&2
  exit 3
fi

PROMPT=$(cat <<'EOF2'
You are an INDEPENDENT senior reviewer. You have not seen any other reviewer's
output. Review the artifact piped to you (a PR diff or a system-design document)
strictly against the rubric below, and FOLLOW the rubric's "Output discipline"
section exactly.

Hard rules (these mirror the rubric and the schema — obey them):
- Output ONLY a single valid JSON object. No prose, no markdown, no code fences.
- It MUST validate against the JSON schema below. reviewer = "glm-5.2".
- Number your findings with a "G-" prefix: "G-001", "G-002", ...
- Field names are exactly: id, severity, category, location, issue, evidence,
  failure_case, suggestion, confidence, recommendation, speculative.
- recommendation is REQUIRED on every finding: one of must_fix / should_fix /
  defer / nit. It is your recommended action, separate from severity (impact),
  and the synthesizer may overrule it. There is no "reject" value: you do not
  reject a finding you just raised. See the rubric's Recommendation section.
- Evidence is mandatory for every critical/high finding AND every
  correctness/security finding (any severity). For critical/high also give a
  failure_case. (The schema enforces this — a finding missing them is rejected.)
- location format: PR => "path/to/file.ext:line" (or file + hunk/function);
  design => section heading / diagram name / requirement id. No coarse locations.
- suggestion must be concrete enough to act on. No vague advice.
- If evidence is weak but the concern is important, set "speculative": true and
  state in `issue` what would verify or falsify it.
- NO FINDINGS IS A VALID RESULT. If you find nothing worth flagging, return an
  empty "findings" array, set "overall": "approve", and use "summary" to list
  residual risk, unverified assumptions, and tests not run. Do NOT invent
  low-severity findings to fill the report.
- Findings first by severity; do not pad with style-only nits.
EOF2
)

RUBRIC_TXT="$(cat "$RUBRIC")"
SCHEMA_TXT="$(cat "$SCHEMA")"

FULL_PROMPT="$PROMPT

## RUBRIC
$RUBRIC_TXT

## JSON SCHEMA (your output must validate against this)
$SCHEMA_TXT

The artifact to review follows on stdin."

RAW="$(mktemp /tmp/glm-raw.XXXXXX.txt)"
echo "reviewer #2: $ZEN_MODEL, effort=$ZEN_VARIANT" >&2
# Send opencode's stderr to THIS script's stderr, not a shared /tmp file, so a
# multi-pass wrapper's per-pass `2> pass-i.err` captures it in full (on success
# and failure) and concurrent runs never clobber a shared log.
cat "$BUNDLE" | opencode run --variant "$ZEN_VARIANT" --model "$ZEN_MODEL" "$FULL_PROMPT" > "$RAW" || {
  echo "opencode run failed (its stderr is above)" >&2; exit 1;
}

# Extract the JSON object, then ENFORCE the schema (Evidence/failure_case rules).
python3 - "$RAW" "$OUT" "$SCHEMA" <<'PY'
import sys, json, re
raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
raw = re.sub(r"```(?:json)?", "", raw)

# Do NOT use first-"{" to last-"}": reviewers narrate before the JSON, and that
# prose contains braces (observed in the wild: a review citing the config path
# `provider.{p}.models.{m}` made the slice start at "{p}" and fail to parse).
# Instead try to decode an object at every "{" and keep the largest complete one
# that looks like a findings document.
dec = json.JSONDecoder()
obj = None
for i, ch in enumerate(raw):
    if ch != "{":
        continue
    try:
        cand, _ = dec.raw_decode(raw, i)
    except ValueError:
        continue
    if isinstance(cand, dict) and "findings" in cand and "reviewer" in cand:
        if obj is None or len(json.dumps(cand)) > len(json.dumps(obj)):
            obj = cand
if obj is None:
    sys.exit("could not locate a findings JSON object in GLM output "
             f"(kept at {sys.argv[1]} for inspection)")
schema = json.load(open(sys.argv[3]))
try:
    import jsonschema
except ImportError:
    # Not advisory: `recommendation`, Evidence and failure_case are only REQUIRED
    # insofar as this validates. Warning and continuing would emit a green run
    # whose findings silently lack the fields Step 4's triggers read.
    sys.exit("jsonschema not installed, so the findings contract cannot be "
             "enforced and a review would pass with unchecked output. "
             "Run: pip install jsonschema")
try:
    jsonschema.validate(obj, schema)              # enforces Evidence/failure_case rules
except jsonschema.ValidationError as ex:
    path = "/".join(str(p) for p in ex.absolute_path) or "<root>"
    sys.exit(f"GLM output violates findings.schema.json at {path}: {ex.message}")
json.dump(obj, open(sys.argv[2], "w", encoding="utf-8"), indent=2, ensure_ascii=False)
print(sys.argv[2])
PY
