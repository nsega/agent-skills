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
# CODEX_HOME), --sandbox read-only in a throwaway -C dir (so it cannot edit or
# usefully crawl the repo), and --ephemeral (no session files on disk).
#
# Env:
#   CODEX_MODEL   default gpt-5.6-sol
#   CODEX_EFFORT  default high            (minimal|low|medium|high)
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
case "$CODEX_EFFORT" in minimal|low|medium|high) ;; *) echo "bad CODEX_EFFORT: '$CODEX_EFFORT' (want minimal|low|medium|high)" >&2; exit 2 ;; esac

[ -f "$PACKET" ] || { echo "no such packet: $PACKET" >&2; exit 2; }
[ -s "$PACKET" ] || { echo "packet is empty: $PACKET" >&2; exit 2; }
touch "$TRANSCRIPT"   # may not exist on round 0

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

  SCRATCH="$(mktemp -d /tmp/dual-model-debate-scratch.XXXXXX)"
  OUTMSG="$(mktemp /tmp/dual-model-debate-turn.XXXXXX.txt)"
  echo "codex turn: $ROLE round $ROUND ($KIND), model=$CODEX_MODEL effort=$CODEX_EFFORT" >&2
  # stdin = packet + transcript so far; final message captured via -o.
  if ! cat "$PACKET" "$TRANSCRIPT" | codex exec \
        --ignore-user-config --skip-git-repo-check --ephemeral \
        --sandbox read-only -C "$SCRATCH" \
        -m "$CODEX_MODEL" -c model_reasoning_effort="$CODEX_EFFORT" \
        -o "$OUTMSG" "$FULL_PROMPT" >/dev/null; then
    echo "codex exec failed (its stderr is above)" >&2
    rm -rf "$SCRATCH"
    exit 1
  fi
  MSG="$(cat "$OUTMSG")"
  rm -rf "$SCRATCH"
fi

[ -n "$MSG" ] || { echo "empty turn from $ROLE (round $ROUND)" >&2; exit 1; }

{
  echo "### $ROLE (round $ROUND)"
  echo
  echo "$MSG"
  echo
} >> "$TRANSCRIPT"

echo "$TRANSCRIPT"
