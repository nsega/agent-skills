#!/usr/bin/env bash
# Run ONE debate turn and append it to the transcript.
#
# Usage:
#   codex_turn.sh <ROLE_LABEL> <ROUND> <ROLE_KIND> <PACKET> <TRANSCRIPT>
#     ROLE_KIND: opening | rebuttal | forced
#
# The model argues from the piped packet + current transcript only, in the
# four-field format from references/protocol.md. Its final message is captured
# via `codex exec -o` (no stdout scraping) and appended under a
# "### <ROLE_LABEL> (round <ROUND>)" header.
#
# codex runs --ignore-user-config (so the caller's notify hooks, plugins, and
# personality do not perturb a reproducible turn; auth still resolves from
# CODEX_HOME), --skip-git-repo-check + --sandbox read-only in a throwaway -C dir,
# and --ephemeral (no session files on disk). NOTE: --sandbox read-only prevents
# writes/edits, not reads. The debater is told not to read files, but that is
# guidance, not a hard boundary; treat only what you place in the packet as
# exposed to the model (and to OpenAI).
#
# Env:
#   CODEX_MODEL   default gpt-5.6-sol
#   CODEX_EFFORT  default high            (low|medium|high|xhigh|max|ultra)
#   CODEX_FAKE    if set to a file path, use its contents as the model message
#                 instead of calling codex (free dry runs and tests).
set -euo pipefail

ROLE="${1:?need role label}"
ROUND="${2:?need round number}"
KIND="${3:?need role kind: opening|rebuttal|forced}"
PACKET="${4:?need packet path}"
TRANSCRIPT="${5:?need transcript path}"

case "$KIND" in opening|rebuttal|forced) ;; *) echo "bad role kind: '$KIND' (want opening|rebuttal|forced)" >&2; exit 2 ;; esac

CODEX_MODEL="${CODEX_MODEL:-gpt-5.6-sol}"
CODEX_EFFORT="${CODEX_EFFORT:-high}"
# Verified against `codex debug models`: every model in the catalog supports
# low|medium|high|xhigh, gpt-5.6-sol/terra add max|ultra, and NO model accepts
# "minimal" (the API rejects it with HTTP 400 after the turn has started).
case "$CODEX_EFFORT" in low|medium|high|xhigh|max|ultra) ;; *) echo "bad CODEX_EFFORT: '$CODEX_EFFORT' (want low|medium|high|xhigh|max|ultra)" >&2; exit 2 ;; esac

[ -f "$PACKET" ] || { echo "no such packet: $PACKET" >&2; exit 2; }
[ -s "$PACKET" ] || { echo "packet is empty: $PACKET" >&2; exit 2; }
touch "$TRANSCRIPT"   # may not exist on round 0
# Round 0 must be blind: a pre-existing non-empty transcript would let this
# debater see the other's opening. Defense-in-depth for the SKILL.md flow.
if [ "$ROUND" = 0 ] && [ -s "$TRANSCRIPT" ]; then
  echo "round 0 transcript must be empty for blindness: $TRANSCRIPT" >&2; exit 2
fi

MSG=""
if [ -n "${CODEX_FAKE:-}" ]; then
  [ -f "$CODEX_FAKE" ] || { echo "CODEX_FAKE set but no such file: $CODEX_FAKE" >&2; exit 2; }
  MSG="$(cat "$CODEX_FAKE")"
else
  command -v codex >/dev/null || { echo "codex not found on PATH" >&2; exit 127; }
  SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  PROTOCOL="$SKILL_DIR/references/protocol.md"
  [ -f "$PROTOCOL" ] || { echo "protocol not found: $PROTOCOL" >&2; exit 2; }
  case "$KIND" in
    opening)  DIRECTIVE="Use the 'Honest opening (round 0)' role. You have not seen the other debater." ;;
    rebuttal) DIRECTIVE="Use the 'Rebuttal' role. Respond specifically to the other debater's latest turn in the transcript." ;;
    forced)   DIRECTIVE="Use the 'Forced opposition' role. Both debaters agreed; argue the strongest good-faith case AGAINST that consensus." ;;
  esac
  PROTOCOL_TXT="$(cat "$PROTOCOL")"
  FULL_PROMPT="You are playing: $ROLE, round $ROUND.
$DIRECTIVE
Respond ONLY in the four-field markdown turn format (Position / Argument /
Concedes / Still unresolved). Do NOT print a heading; the harness adds it.
Argue only from the <stdin> block (the packet and the transcript so far); do not
run tools or read files.

## PROTOCOL
$PROTOCOL_TXT"

  D="${DMD_OUT_DIR:-/tmp}"; mkdir -p "$D"
  SCRATCH="$(mktemp -d "$D/dual-model-debate-scratch.XXXXXX")"
  OUTMSG="$(mktemp "$D/dual-model-debate-turn.XXXXXX.txt")"
  # EXIT alone is not enough: a shell killed by an untrapped SIGINT/SIGTERM
  # (Ctrl-C during the long paid turn) dies without running its EXIT trap, so the
  # signals are trapped into a normal exit, which then fires EXIT.
  trap 'rm -rf "$SCRATCH" "$OUTMSG" 2>/dev/null' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  echo "codex turn: $ROLE round $ROUND ($KIND), model=$CODEX_MODEL effort=$CODEX_EFFORT" >&2
  # stdin = packet + transcript so far; final message captured via -o.
  if ! cat "$PACKET" "$TRANSCRIPT" | codex exec \
        --ignore-user-config --skip-git-repo-check --ephemeral \
        --sandbox read-only -C "$SCRATCH" \
        -m "$CODEX_MODEL" -c model_reasoning_effort="$CODEX_EFFORT" \
        -o "$OUTMSG" "$FULL_PROMPT" >/dev/null; then
    echo "codex exec failed (its stderr is above)" >&2
    exit 1                                # trap cleans up SCRATCH/OUTMSG
  fi
  MSG="$(cat "$OUTMSG")"                  # trap cleans up SCRATCH/OUTMSG on exit
fi

[ -n "$MSG" ] || { echo "empty turn from $ROLE (round $ROUND)" >&2; exit 1; }

{
  echo "### $ROLE (round $ROUND)"
  echo
  printf '%s\n' "$MSG"
  echo
} >> "$TRANSCRIPT"

echo "$TRANSCRIPT"
