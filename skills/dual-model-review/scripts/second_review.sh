#!/usr/bin/env bash
# Reviewer #2: run an INDEPENDENT second model over a review bundle, capture
# structured findings as JSON, and ENFORCE the schema (incl. the
# Evidence/failure_case rules) before accepting the output.
#
# Usage:
#   second_review.sh <BUNDLE> <RUBRIC> <SCHEMA> <OUT_JSON> [--backend codex|glm|kimi]
#
# Backends. Reviewer #2 is pluggable: the packet, rubric, schema, prompt, and
# synthesis are identical whichever you pick; only the CLI underneath changes.
#   codex  GPT-5.6 Sol via the Codex CLI            (default)
#   glm    GLM-5.2 via opencode + OpenCode Zen      (alternate)
#   kimi   Kimi K3 via opencode + OpenCode Zen      (alternate)
#
# glm and kimi are ONE code path that differs only in default model, so they
# share the preflight, the argv message, and both guards. Pick on cost and
# behavior: glm-5.2 is $1.4/$4.4 per Mtok, kimi-k3 is $3/$15 (~3.4x on output).
#
# Env:
#   REVIEW2_BACKEND  backend used when --backend is omitted (default: codex)
#   CODEX_MODEL      codex model id                    (default: gpt-5.6-sol)
#   CODEX_EFFORT     model_reasoning_effort            (default: high)
#   CODEX_BIN        codex executable                  (default: codex)
#   ZEN_MODEL        opencode model id, overrides the backend's default
#                    (glm: opencode/glm-5.2, kimi: opencode/kimi-k3)
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
  echo "usage: second_review.sh <BUNDLE> <RUBRIC> <SCHEMA> <OUT_JSON> [--backend codex|glm|kimi]"
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
    # The union across the catalog (`codex debug models`): every model supports
    # low|medium|high|xhigh, several add max, and sol/terra add ultra. NO model
    # accepts "minimal" (the API rejects it with HTTP 400 after the run has
    # started). This catches typos; the codex preflight below then narrows it to
    # what THIS model actually supports.
    case "$R2_EFFORT" in
      low|medium|high|xhigh|max|ultra) ;;
      *) echo "bad CODEX_EFFORT: '$R2_EFFORT' (want low|medium|high|xhigh|max|ultra)" >&2; exit 2 ;;
    esac
    ;;
  glm|kimi)
    # Same opencode path, different default model. ZEN_MODEL overrides either, so
    # `ZEN_MODEL=opencode/deepseek-v4-flash --backend glm` still works, and a new
    # Zen model is a one-line default rather than another arm.
    case "$BACKEND" in
      glm)  ZEN_DEFAULT_MODEL="opencode/glm-5.2" ;;
      kimi) ZEN_DEFAULT_MODEL="opencode/kimi-k3" ;;
    esac
    R2_MODEL="${ZEN_MODEL:-$ZEN_DEFAULT_MODEL}"
    R2_EFFORT="${ZEN_VARIANT:-max}"
    # Provider-level, not per-model: opencode's variant names are the same across
    # Zen's reasoning models (both glm-5.2 and kimi-k3 are reasoning: true), and
    # `opencode models` exposes no per-model variant list to narrow against.
    case "$R2_EFFORT" in
      minimal|low|high|max) ;;
      *) echo "bad ZEN_VARIANT: '$R2_EFFORT' (want minimal|low|high|max)" >&2; exit 2 ;;
    esac
    ;;
  *)
    echo "bad --backend: '$BACKEND' (want codex|glm|kimi)" >&2; exit 2 ;;
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

# The OUTPUT path gets the same treatment as the inputs: a missing directory
# would otherwise surface as a raw Python traceback from the final json.dump,
# after the review has already been run and billed.
OUT_PARENT="$(dirname "$OUT")"
[ -d "$OUT_PARENT" ] || { echo "output directory does not exist: $OUT_PARENT" >&2; exit 2; }

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

    # Narrow the static union to what THIS model supports. The effort set is
    # per-model (gpt-5.5 tops out at xhigh, only sol/terra reach ultra), so a
    # valid-looking pair like CODEX_MODEL=gpt-5.5 CODEX_EFFORT=max would
    # otherwise pass the gate and 400 mid-run, which is exactly the paid failure
    # this validation exists to prevent. `codex debug models` is a local catalog
    # read (~50ms, no spend). If it is unavailable (older codex, unreadable
    # catalog) keep the union check rather than blocking an otherwise fine run.
    # `< /dev/null`: this preflight must never consume (or block on) the caller's
    # stdin, which is the packet stream for the review itself.
    if CATALOG="$("$CODEX_BIN" debug models </dev/null 2>/dev/null)"; then
      SUPPORTED="$(printf '%s' "$CATALOG" | python3 -c '
import json, sys
raw = sys.stdin.read()
i = raw.find("{\"models\"")
if i < 0:
    sys.exit(0)                      # unrecognized shape: stay silent, keep the union check
try:
    cat, _ = json.JSONDecoder().raw_decode(raw, i)
except ValueError:
    sys.exit(0)
for m in cat.get("models") or []:
    if m.get("slug") == sys.argv[1]:
        print(" ".join(l["effort"] for l in m.get("supported_reasoning_levels") or []))
        break
' "$R2_MODEL" 2>/dev/null || true)"
      if [ -n "$SUPPORTED" ]; then
        case " $SUPPORTED " in
          *" $R2_EFFORT "*) ;;
          *) echo "bad CODEX_EFFORT for $R2_MODEL: '$R2_EFFORT' (that model supports: $SUPPORTED)" >&2; exit 2 ;;
        esac
      fi
    fi
    ;;
  glm|kimi)
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

# One EXIT trap for every temp file, installed BEFORE any of them exist, so a
# Ctrl-C during the (long, paid) call cannot leak reviewer #2's output for a
# sensitive packet. $RAW is deleted with the rest unless KEEP_RAW is set, which
# happens only around extraction/validation, where the error message tells the
# operator to go read it.
KEEP_RAW=""; RAW=""; SCRATCH=""; OUTMSG=""; CODEXERR=""
cleanup() {
  [ -n "$KEEP_RAW" ] || { [ -z "$RAW" ] || rm -f "$RAW"; }
  [ -z "$SCRATCH" ]  || rm -rf "$SCRATCH"
  [ -z "$OUTMSG" ]   || rm -f "$OUTMSG"
  [ -z "$CODEXERR" ] || rm -f "$CODEXERR"
}
# EXIT alone is not enough: a shell killed by an untrapped SIGINT/SIGTERM (Ctrl-C
# during the long paid call) dies without running the EXIT trap, leaking the raw
# output. Trapping the signals makes them exit normally, which then fires EXIT.
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

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
    #                         (auth still resolves from CODEX_HOME). Live web
    #                         search is opt-in in codex (the `--search` flag,
    #                         which we never pass), so dropping the caller's
    #                         config is what keeps the packet off the wire.
    #                         Deliberately NOT pinned with `-c web_search=...`:
    #                         codex silently accepts unknown `-c` keys, so an
    #                         unverified value would only look like a guarantee.
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
    CODEXERR="$(mktemp /tmp/r2-codex-err.XXXXXX.txt)"   # cleaned by the EXIT trap

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
  glm|kimi)
    # ONE argv message: the prompt, then the artifact under an explicit header —
    # the same shape as the codex arm's single stdin stream, for the same reason.
    #
    # Do NOT pipe the bundle on stdin. `opencode run --help` documents no stdin at
    # all (positional `message` is the whole input). Piping does deliver bytes on
    # 1.18.11, but undocumented and with no delimiter between the two, which is
    # the actual failure: told the artifact "follows on stdin", the model goes
    # looking for a channel it cannot name. Verified against real opencode
    # 1.18.11 — GLM-5.2 at --variant minimal quoted the piped sentinel back and in
    # the same breath answered "there's no artifact on stdin from my
    # perspective", then reviewed nothing. The bytes arrive; the framing breaks.
    # In argv the ordering and the header are ours, and the word never appears.
    # TRADE-OFF, deliberate: argv is world-readable (`ps auxww`, and on Linux
    # /proc/<pid>/cmdline) for the life of the call, so on a shared host the
    # packet is visible to other local users in a way the codex arm's stdin
    # stream is not. Accepted because the alternative is worse: stdin's
    # undocumented no-delimiter merge is the bug this arm exists to avoid, and
    # opencode's own `-f` attachment (verified to work even with tools.read
    # disabled) hands framing back to opencode, which is the same class of
    # unknown. Revisit `-f` if packets ever routinely exceed the cap below, but
    # re-verify the framing against a real reviewer model before switching.
    GLM_MSG="$FULL_PROMPT

## ARTIFACT TO REVIEW

$(cat "$BUNDLE")"
    # argv is bounded (ARG_MAX covers args + environment), so an oversized packet
    # would die with E2BIG mid-call, after the preflight and before any output.
    # Fail here instead, and say which lever to pull. Half of ARG_MAX is ample:
    # real packets run 40-80KB against a 1MB cap. Measured in BYTES (`wc -c`, not
    # `${#var}`, which counts characters and undercounts any non-ASCII diff).
    GLM_BYTES="$(printf '%s' "$GLM_MSG" | wc -c | tr -d ' ')"
    ARG_CAP=$(( $(getconf ARG_MAX 2>/dev/null || echo 262144) / 2 ))
    # ARG_MAX is not the only ceiling. Linux also caps any SINGLE argv string at
    # MAX_ARG_STRLEN = 32 * PAGE_SIZE (128KB on 4K pages), independent of
    # ARG_MAX, and the whole packet is one string here. Checking only ARG_MAX
    # would let a 200KB packet through to die at execve with a bare "Argument
    # list too long" — precisely the failure this guard exists to replace.
    # Benign on macOS (16K pages puts the formula at ~516KB, just under the
    # ARG_MAX/2 cap it is being min'd with).
    PER_ARG_CAP=$(( 32 * $(getconf PAGE_SIZE 2>/dev/null || echo 4096) - 8192 ))
    [ "$PER_ARG_CAP" -lt "$ARG_CAP" ] && ARG_CAP="$PER_ARG_CAP"
    if [ "$GLM_BYTES" -gt "$ARG_CAP" ]; then
      echo "packet too large for the glm backend: $GLM_BYTES bytes > $ARG_CAP (argv limit)." >&2
      echo "Trim the bundle, or use --backend codex, which streams the packet on stdin and has no such cap." >&2
      exit 2
    fi
    # `< /dev/null` is load-bearing, not hygiene. opencode reads stdin and merges
    # it into the message with NO delimiter (see above), so an inherited stdin —
    # `gather_artifact ... | second_review.sh ...`, a heredoc, a CI step whose
    # stdin is a live pipe — silently appends those bytes to the packet. The
    # prompt no longer mentions stdin, so the model cannot notice the
    # contamination either: the run returns schema-valid findings over a corrupt
    # artifact and exits 0. Same reason the codex preflight pins its stdin.
    "$OPENCODE_BIN" run --variant "$R2_EFFORT" --model "$R2_MODEL" "$GLM_MSG" \
      < /dev/null > "$RAW" || {
      echo "opencode run failed (its stderr is above)" >&2; exit 1;
    }
    ;;
esac

# An EMPTY answer is a failed review, not a formatting problem. Both CLIs can
# exit 0 having written nothing: opencode does it on a large packet at max effort
# (two 0-byte /tmp/r2-review-raw.* files on this machine, days apart). Without
# this guard the run fell through to the JSON extractor below, which blamed the
# model's formatting — "could not locate a findings JSON object" — for a file
# that had no bytes in it at all. Catch it here, where the message can name the
# real cause and the lever to pull. Deliberately BEFORE `KEEP_RAW=1`: an empty
# file is nothing to inspect, so let the trap take it.
if [ ! -s "$RAW" ]; then
  echo "reviewer #2 ($BACKEND / $R2_MODEL, effort=$R2_EFFORT) exited 0 but produced EMPTY output." >&2
  echo "Nothing was reviewed. This is usually the packet being too big for the model at this effort:" >&2
  echo "trim the bundle, lower the effort, or switch --backend." >&2
  exit 4
fi

# Extract the JSON object, then ENFORCE the schema (Evidence/failure_case rules).
# From here to the end of the block, a failure means "the model answered but we
# could not use it", so keep $RAW: the error messages tell the operator to read
# it. Cleared again on success, where it is just an untracked copy of a
# sensitive packet's review.
KEEP_RAW=1
python3 - "$RAW" "$OUT" "$SCHEMA" <<'PY'
import sys, json, re
raw = open(sys.argv[1], encoding="utf-8", errors="replace").read()
raw = re.sub(r"```(?:json)?", "", raw)

# Do NOT use first-"{" to last-"}": reviewers narrate before the JSON, and that
# prose contains braces (observed in the wild: a review citing the config path
# `provider.{p}.models.{m}` made the slice start at "{p}" and fail to parse).
# Instead try to decode an object at every "{" and keep the ones that look like a
# findings document.
#
# Two rules, both load-bearing:
#  - Check TYPES, not just key presence. The JSON schema we hand the reviewer has
#    a `properties` object whose keys are exactly reviewer/summary/overall/
#    findings, so a reviewer that quotes the schema back at us produces a decoy
#    that passes a presence-only test. Its `findings`/`reviewer` are schema
#    fragments (dicts), not a list and a string, so the types tell them apart.
#  - Keep the LAST match, not the biggest. The real answer comes after any
#    narration, and "no findings is a valid result" (which the prompt actively
#    encourages) is a ~80-byte document that loses every size contest against a
#    ~1.5KB quoted schema.
dec = json.JSONDecoder()
obj = None
for i, ch in enumerate(raw):
    if ch != "{":
        continue
    try:
        cand, _ = dec.raw_decode(raw, i)
    except ValueError:
        continue
    if (isinstance(cand, dict)
            and isinstance(cand.get("findings"), list)
            and isinstance(cand.get("reviewer"), str)):
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

# Parsed and validated: the EXIT trap may now delete $RAW with everything else.
KEEP_RAW=""
