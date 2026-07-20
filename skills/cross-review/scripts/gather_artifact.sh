#!/usr/bin/env bash
# Build a review packet (single file) and print its path on stdout.
#
# Usage:
#   gather_artifact.sh pr     [BASE] [HEAD] [--level full|minimal] [--tests FILE]
#   gather_artifact.sh design <DOC>        [--level full|minimal] [--tests FILE]
#
# Mechanical fields (changed files, diff/doc, test results) are filled in here.
# Author fields (background/purpose/non-goals/key decisions/known worries/review
# focus) are emitted as placeholders for Claude Code to fill BEFORE sending to
# reviewers. Even 'minimal' keeps purpose + non-goals + diff + test results, since
# those alone sharply improve review quality.
set -euo pipefail

MODE="${1:-}"; shift || true
LEVEL="full"; TESTS=""
POS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --level) LEVEL="${2:-full}"; shift 2;;
    --tests) TESTS="${2:-}";     shift 2;;
    *)       POS+=("$1");        shift;;
  esac
done
case "$LEVEL" in full|minimal) ;; *) echo "bad --level: $LEVEL" >&2; exit 2;; esac

OUT="$(mktemp /tmp/cross-review-packet.XXXXXX.md)"

emit_tests() {
  echo "## Test results"
  if [ -n "$TESTS" ] && [ -f "$TESTS" ]; then echo '```'; cat "$TESTS"; echo '```'
  else echo "<!-- paste test output, or 'pass (CI link)' -->"; fi
  echo
}

case "$MODE" in
  pr)
    BASE="${POS[0]:-origin/main}"; HEAD="${POS[1]:-}"
    RANGE="$BASE${HEAD:+...$HEAD}"
    {
      echo "# Review packet: PULL REQUEST ($LEVEL)"
      echo
      echo "- repo: $(git rev-parse --show-toplevel 2>/dev/null || echo '?')"
      echo "- branch: $(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
      echo "- base: $BASE"
      echo "- generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo
      if [ "$LEVEL" = "full" ]; then
        echo "## Background"; echo "<!-- fill -->"; echo
      fi
      echo "## Purpose"; echo "<!-- fill -->"; echo
      echo "## Non-goals"; echo "<!-- fill: prevents out-of-scope findings -->"; echo
      if [ "$LEVEL" = "full" ]; then
        echo "## Key design decisions"; echo "<!-- fill -->"; echo
        echo "## Known worries"; echo "<!-- fill: aims the review -->"; echo
      fi
      echo "## Changed files"; echo '```'
      git diff --stat "$RANGE" 2>/dev/null || git diff --stat "$BASE"; echo '```'; echo
      echo "## Diff"; echo '```diff'
      git diff -U3 "$RANGE" 2>/dev/null || git diff -U3 "$BASE"; echo '```'; echo
      emit_tests
      if [ "$LEVEL" = "full" ]; then
        echo "## What to review"; echo "<!-- fill -->"
      fi
    } > "$OUT"
    ;;
  design)
    DOC="${POS[0]:?design mode needs a document path}"
    [ -f "$DOC" ] || { echo "no such file: $DOC" >&2; exit 1; }
    {
      echo "# Review packet: SYSTEM DESIGN ($LEVEL)"
      echo
      echo "- document: $DOC"
      echo "- generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo
      echo "## Purpose"; echo "<!-- fill -->"; echo
      echo "## Non-goals"; echo "<!-- fill -->"; echo
      if [ "$LEVEL" = "full" ]; then
        echo "## Known worries"; echo "<!-- fill -->"; echo
        echo "## What to review"; echo "<!-- fill -->"; echo
      fi
      echo "## Document"; echo; cat "$DOC"; echo
      emit_tests
    } > "$OUT"
    ;;
  *)
    echo "usage: gather_artifact.sh {pr [BASE] [HEAD] | design DOC} [--level full|minimal] [--tests FILE]" >&2
    exit 2
    ;;
esac

echo "$OUT"
