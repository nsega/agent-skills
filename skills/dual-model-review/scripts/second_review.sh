#!/usr/bin/env bash
# Reviewer #2: run an INDEPENDENT second model over a review bundle, capture
# structured findings as JSON, and ENFORCE the schema (incl. the
# Evidence/failure_case rules) before accepting the output.
#
# Usage:
#   second_review.sh <BUNDLE> <RUBRIC> <SCHEMA> <OUT_JSON> [--backend codex|glm]
#
# Backends. Reviewer #2 is pluggable: the packet, rubric, schema, prompt, and
# synthesis are identical either way; only the CLI underneath changes.
#   codex  GPT-5.6 Sol via the Codex CLI            (default)
#   glm    GLM-5.2 via opencode + OpenCode Zen      (alternate)
#
# Env:
#   REVIEW2_BACKEND  backend used when --backend is omitted (default: codex)
#   CODEX_MODEL      codex model id                    (default: gpt-5.6-sol)
#   CODEX_EFFORT     model_reasoning_effort            (default: high)
#   CODEX_BIN        codex executable                  (default: codex)
#   ZEN_MODEL        opencode model id                 (default: opencode/glm-5.2)
#   ZEN_VARIANT      opencode reasoning-effort variant (default: max)
#   OPENCODE_BIN     opencode executable               (default: opencode)
#   OPENCODE_CONFIG  hardened opencode config          (default: <skill>/config/opencode.zen.json)
#
# Notes:
# - Review-only. We ask for findings, never for a patch, and run the CLI
#   non-interactively single-shot so it cannot edit the repo.
# - Reasoning effort is validated HERE, not trusted to the CLI. opencode ACCEPTS
#   AN UNKNOWN --variant SILENTLY (verified: a bogus value exits 0 and reviews
#   anyway), and codex's `-c` is a generic key=value override, so neither CLI can
#   be relied on to reject a typo that would quietly downgrade effort.
# - For a high-stakes review, run this two or three times into different OUT_JSON
#   files and union the findings by hand: one pass is a noisy detector.
set -euo pipefail

usage() {
  echo "usage: second_review.sh <BUNDLE> <RUBRIC> <SCHEMA> <OUT_JSON> [--backend codex|glm]"
}

BACKEND="${REVIEW2_BACKEND:-codex}"
# Scalars + a counter rather than a POS=() array: `${#arr[@]}` on an empty array
# is an unbound-variable error under `set -u` in the bash 3.2 that macOS still
# ships as /bin/bash, which would turn "no arguments" into a cryptic crash.
BUNDLE=""; RUBRIC=""; SCHEMA=""; OUT=""; NPOS=0
while [ $# -gt 0 ]; do
  case "$1" in
    # Not `shift 2 || true`: a trailing `--backend` with no value leaves $# at 1,
    # and the loop would spin forever.
    --backend) [ $# -ge 2 ] || { echo "--backend needs a value" >&2; exit 2; }
               BACKEND="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *)         NPOS=$((NPOS + 1))
               case "$NPOS" in
                 1) BUNDLE="$1";; 2) RUBRIC="$1";; 3) SCHEMA="$1";; 4) OUT="$1";;
                 *) echo "too many arguments" >&2; usage >&2; exit 2;;
               esac
               shift;;
  esac
done
[ "$NPOS" -eq 4 ] || { usage >&2; exit 2; }

# Resolve the backend's model + effort BEFORE touching files or the network, so a
# typo in either costs an exit code rather than a paid call.
case "$BACKEND" in
  codex)
    R2_MODEL="${CODEX_MODEL:-gpt-5.6-sol}"
    R2_EFFORT="${CODEX_EFFORT:-high}"
    # Verified against `codex debug models`: every model in the catalog supports
    # low|medium|high|xhigh, gpt-5.6-sol/terra add max|ultra, and NO model accepts
    # "minimal" (the API rejects it with HTTP 400 after the run has started).
    case "$R2_EFFORT" in
      low|medium|high|xhigh|max|ultra) ;;
      *) echo "bad CODEX_EFFORT: '$R2_EFFORT' (want low|medium|high|xhigh|max|ultra)" >&2; exit 2 ;;
    esac
    ;;
  glm)
    R2_MODEL="${ZEN_MODEL:-opencode/glm-5.2}"
    R2_EFFORT="${ZEN_VARIANT:-max}"
    case "$R2_EFFORT" in
      minimal|low|high|max) ;;
      *) echo "bad ZEN_VARIANT: '$R2_EFFORT' (want minimal|low|high|max)" >&2; exit 2 ;;
    esac
    ;;
  *)
    echo "bad --backend: '$BACKEND' (want codex|glm)" >&2; exit 2 ;;
esac

# The reviewer id the model must stamp on its output: the bare model name, with
# any provider prefix ("opencode/glm-5.2") stripped.
R2_ID="${R2_MODEL##*/}"

# Check inputs BEFORE spending anything. Without this a typo'd bundle path still
# reaches the CLI (which then reads empty stdin) and bills a full paid review of
# nothing.
for f in "$BUNDLE" "$RUBRIC" "$SCHEMA"; do
  [ -f "$f" ] || { echo "no such file: $f" >&2; exit 2; }
done
[ -s "$BUNDLE" ] || { echo "bundle is empty: $BUNDLE" >&2; exit 2; }

# The arguments are well-formed and the inputs exist, so THIS run now owns
# $OUT. Drop any previous run's findings here, before the CLI/auth preflight and
# before the call: a run that fails anywhere past this point must not leave a
# stale file behind. SKILL.md tells you to re-run this on just the fix diff, and
# Step 3 then reads $OUT as the fix review, so a survivor would be merged as if
# it were fresh. (Typo exits above this line destroy nothing.)
rm -f "$OUT"

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PROMPT=$(cat <<'EOF2'
You are an INDEPENDENT senior reviewer. You have not seen any other reviewer's
output. Review the artifact you have been handed (a PR diff or a system-design
document) strictly against the rubric below, and FOLLOW the rubric's "Output
discipline" section exactly.

Hard rules (these mirror the rubric and the schema, so obey them):
- Output ONLY a single valid JSON object. No prose, no markdown, no code fences.
- It MUST validate against the JSON schema below. reviewer = "__REVIEWER_ID__".
- Number your findings with an "R2-" prefix: "R2-001", "R2-002", ...
- Field names are exactly: id, severity, category, location, issue, evidence,
  failure_case, suggestion, confidence, recommendation, speculative.
- recommendation is REQUIRED on every finding: one of must_fix / should_fix /
  defer / nit. It is your recommended action, separate from severity (impact),
  and the synthesizer may overrule it. There is no "reject" value: you do not
  reject a finding you just raised. See the rubric's Recommendation section.
- Evidence is mandatory for every critical/high finding AND every
  correctness/security finding (any severity). For critical/high also give a
  failure_case. (The schema enforces this: a finding missing them is rejected.)
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
PROMPT="${PROMPT//__REVIEWER_ID__/$R2_ID}"

RUBRIC_TXT="$(cat "$RUBRIC")"
SCHEMA_TXT="$(cat "$SCHEMA")"

FULL_PROMPT="$PROMPT

## RUBRIC
$RUBRIC_TXT

## JSON SCHEMA (your output must validate against this)
$SCHEMA_TXT"

# Preflight: CLI present and authenticated, before anything is written or spent.
case "$BACKEND" in
  codex)
    CODEX_BIN="${CODEX_BIN:-codex}"
    command -v "$CODEX_BIN" >/dev/null || { echo "codex not found on PATH: $CODEX_BIN" >&2; exit 127; }
    CODEX_HOME_DIR="${CODEX_HOME:-$HOME/.codex}"
    if [ -z "${CODEX_API_KEY:-}" ] && [ -z "${OPENAI_API_KEY:-}" ] && [ ! -f "$CODEX_HOME_DIR/auth.json" ]; then
      echo "codex is not authenticated: run 'codex login' (expected $CODEX_HOME_DIR/auth.json), or set CODEX_API_KEY" >&2
      exit 3
    fi
    ;;
  glm)
    OPENCODE_BIN="${OPENCODE_BIN:-opencode}"
    command -v "$OPENCODE_BIN" >/dev/null || { echo "opencode not found on PATH: $OPENCODE_BIN" >&2; exit 127; }
    export OPENCODE_CONFIG="${OPENCODE_CONFIG:-$SKILL_DIR/config/opencode.zen.json}"

    # opencode reads its stored credential only in interactive sessions; a
    # non-interactive `run` needs the key in the env or it dies with "Missing API
    # key" despite auth.json being present and valid.
    AUTH_JSON="${OPENCODE_AUTH_JSON:-${XDG_DATA_HOME:-$HOME/.local/share}/opencode/auth.json}"
    if [ -z "${OPENCODE_API_KEY:-}" ] && [ -f "$AUTH_JSON" ]; then
      OPENCODE_API_KEY="$(python3 -c 'import json,sys
try: print(json.load(open(sys.argv[1]))["opencode"]["key"])
except Exception: pass' "$AUTH_JSON")" || true
      # An `[ -n .. ] && export ..` one-liner here is a `set -e` trap: when the
      # key is empty the list returns non-zero and kills the script before the
      # actionable "no OpenCode Zen key" message below can print.
      if [ -n "$OPENCODE_API_KEY" ]; then export OPENCODE_API_KEY; fi
    fi
    if [ -z "${OPENCODE_API_KEY:-}" ]; then
      echo "no OpenCode Zen key: set OPENCODE_API_KEY, or run 'opencode auth login' (expected at $AUTH_JSON)" >&2
      exit 3
    fi
    ;;
esac

RAW="$(mktemp /tmp/r2-review-raw.XXXXXX.txt)"
echo "reviewer #2: $BACKEND / $R2_MODEL, effort=$R2_EFFORT" >&2

# The CLI's stderr goes to THIS script's stderr (not a shared /tmp file), so the
# caller sees it in full and concurrent runs never clobber a shared log.
case "$BACKEND" in
  codex)
    # Flags match the sibling dual-model-debate skill's codex_turn.sh, which is
    # smoke-tested against real codex:
    #   --ignore-user-config  the caller's notify hooks, plugins, personality, and
    #                         any `web_search = "live"` must not perturb a review
    #                         (auth still resolves from CODEX_HOME).
    #   --ephemeral           no session file on disk; review packets are sensitive.
    #   -C <empty scratch>    the working root is where codex discovers AGENTS.md,
    #                         project config, and repo context, so an empty one is
    #                         what keeps reviewer #2 blind to the tree it reviews.
    #   -o <file>             take the final message from a file instead of
    #                         scraping stdout.
    # NOTE --sandbox read-only blocks writes, NOT reads. What actually stops
    # reviewer #2 wandering into the working tree is features.shell_tool=false
    # plus the empty -C root. Treat only what you put in the bundle as exposed.
    SCRATCH="$(mktemp -d /tmp/r2-codex-cwd.XXXXXX)"
    OUTMSG="$(mktemp /tmp/r2-codex-msg.XXXXXX.txt)"
    # codex echoes its banner AND the whole prompt (which is now prompt + rubric +
    # schema + the entire bundle) back on stderr. Letting that reach our stderr
    # dumps the full diff into the orchestrating agent's transcript and CI logs,
    # so capture it and surface only the tail, and only when the call fails.
    CODEXERR="$(mktemp /tmp/r2-codex-err.XXXXXX.txt)"
    trap 'rm -rf "$SCRATCH" "$OUTMSG" "$CODEXERR" 2>/dev/null' EXIT   # cleanup even on Ctrl-C

    # ONE stdin stream (prompt, then artifact), read via the `-` placeholder.
    # Do NOT put the prompt in argv and pipe the bundle separately: codex's
    # documented flag behavior is that a positional prompt takes precedence over
    # stdin, which would review NOTHING and bill the call anyway. (The sibling
    # skill splits them and works, so this build does deliver piped stdin as an
    # <stdin> block, but one stream is correct under both readings, and a codex
    # that rejects `-` fails loudly instead of silently reviewing an empty diff.)
    {
      printf '%s\n\n## ARTIFACT TO REVIEW\n\n' "$FULL_PROMPT"
      cat "$BUNDLE"
    } | "$CODEX_BIN" exec \
          --ignore-user-config \
          --skip-git-repo-check \
          --ephemeral \
          --sandbox read-only \
          -C "$SCRATCH" \
          -m "$R2_MODEL" \
          -c model_reasoning_effort="$R2_EFFORT" \
          -c features.shell_tool=false \
          -o "$OUTMSG" \
          - > "$RAW" 2>"$CODEXERR" || {
      echo "codex exec failed; last 20 lines of its stderr:" >&2
      tail -20 "$CODEXERR" >&2
      exit 1;
    }
    # Prefer the captured final message; fall back to stdout if -o wrote nothing.
    if [ -s "$OUTMSG" ]; then cat "$OUTMSG" > "$RAW"; fi
    ;;
  glm)
    # opencode takes the prompt as an argument and the artifact on stdin.
    cat "$BUNDLE" | "$OPENCODE_BIN" run --variant "$R2_EFFORT" --model "$R2_MODEL" \
      "$FULL_PROMPT

The artifact to review follows on stdin." > "$RAW" || {
      echo "opencode run failed (its stderr is above)" >&2; exit 1;
    }
    ;;
esac

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
    sys.exit("could not locate a findings JSON object in reviewer #2's output "
             f"(kept at {sys.argv[1]} for inspection)")
schema = json.load(open(sys.argv[3]))
try:
    import jsonschema
except ImportError:
    # Not advisory: recommendation, Evidence and failure_case are only REQUIRED
    # insofar as this validates. Warning and continuing would emit a green run
    # whose findings silently lack the fields the synthesis step reads.
    sys.exit("jsonschema not installed, so the findings contract cannot be "
             "enforced and a review would pass with unchecked output. "
             "Run: pip install jsonschema")
try:
    jsonschema.validate(obj, schema)              # enforces Evidence/failure_case rules
except jsonschema.ValidationError as ex:
    path = "/".join(str(p) for p in ex.absolute_path) or "<root>"
    sys.exit(f"reviewer #2 output violates findings.schema.json at {path}: {ex.message}")
json.dump(obj, open(sys.argv[2], "w", encoding="utf-8"), indent=2, ensure_ascii=False)
print(sys.argv[2])
PY

# Success only: under `set -e` a parse/validate failure exits above, which keeps
# $RAW on disk for the inspection the error message points at. On success it is
# reviewer #2's full output for a sensitive packet, so do not leave it in /tmp.
rm -f "$RAW"
