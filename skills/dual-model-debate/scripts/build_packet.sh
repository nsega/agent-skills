#!/usr/bin/env bash
# Build a debate packet (single file) from a question + optional context files,
# and print its path on stdout. The mechanical assembly is done here; the author
# fills the framing (constraints / non-goals / what a good decision looks like)
# before the debate. Sibling to dual-model-review's gather_artifact.sh.
#
# Env: DMD_OUT_DIR   optional output directory for the packet (created if
#                    missing); default /tmp. The transcript is saved to the same
#                    directory by the SKILL.md playbook.
set -euo pipefail

QUESTION="${1:-}"
[ -n "$QUESTION" ] || { echo 'usage: build_packet.sh "<question>" [context_file ...]' >&2; exit 2; }
shift

# Validate context paths up front so a typo fails before we emit anything.
for f in "$@"; do
  [ -f "$f" ] || { echo "no such context file: $f" >&2; exit 2; }
done

# Wrap a file in a backtick fence long enough that no backtick run inside it can
# close the fence early (CommonMark: the opening fence must exceed the longest
# run of backticks in the content). $1 = info string (may be empty), $2 = file.
emit_fenced() {
  local info="$1" file="$2" maxrun len fence
  maxrun=$( { grep -oE '`+' "$file" || true; } | awk 'length>m{m=length} END{print m+0}' )
  len=$(( maxrun + 1 )); [ "$len" -lt 3 ] && len=3
  fence="$(printf '%*s' "$len" '' | tr ' ' '`')"
  printf '%s%s\n' "$fence" "$info"
  cat "$file"; echo          # trailing newline keeps the close fence on its own line
  printf '%s\n' "$fence"
}

# Deliverables land in $DMD_OUT_DIR when set (created if missing); default /tmp.
OUT_DIR="${DMD_OUT_DIR:-/tmp}"
mkdir -p "$OUT_DIR" || { echo "cannot create output dir: $OUT_DIR" >&2; exit 2; }
OUT="$(mktemp "$OUT_DIR/dual-model-debate-packet.XXXXXX.md")"
{
  echo "# Debate packet"
  echo
  echo "- generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo
  echo "## Question"
  echo
  printf '%s\n' "$QUESTION"
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
      emit_fenced "" "$f"
      echo
    done
  fi
} > "$OUT"

echo "$OUT"
