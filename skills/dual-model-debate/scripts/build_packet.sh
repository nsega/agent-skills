#!/usr/bin/env bash
# Build a debate packet (single file) from a question + optional context files,
# and print its path on stdout. The mechanical assembly is done here; the author
# fills the framing (constraints / non-goals / what a good decision looks like)
# before the debate. Sibling to dual-model-review's gather_artifact.sh.
set -euo pipefail

QUESTION="${1:-}"
[ -n "$QUESTION" ] || { echo 'usage: build_packet.sh "<question>" [context_file ...]' >&2; exit 2; }
shift

# Validate context paths up front so a typo fails before we emit anything.
for f in "$@"; do
  [ -f "$f" ] || { echo "no such context file: $f" >&2; exit 2; }
done

OUT="$(mktemp /tmp/dual-model-debate-packet.XXXXXX.md)"
{
  echo "# Debate packet"
  echo
  echo "- generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "## Question"
  echo
  echo "$QUESTION"
  echo
  echo "## Framing (author fills before the debate)"
  echo
  echo "### Constraints"
  echo "<!-- fill: hard requirements the answer must respect -->"
  echo
  echo "### Non-goals"
  echo "<!-- fill: what is out of scope, to stop off-target arguments -->"
  echo
  echo "### What a good decision looks like"
  echo "<!-- fill: the bar the decision is judged against -->"
  echo
  echo "## Context"
  echo
  if [ "$#" -eq 0 ]; then
    echo "No context files attached."
  else
    for f in "$@"; do
      echo "### $(basename "$f")"
      echo '```'
      cat "$f"
      echo '```'
      echo
    done
  fi
} > "$OUT"

echo "$OUT"
