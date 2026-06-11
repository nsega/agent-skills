#!/usr/bin/env bash
#
# new.sh — scaffold skills/<name>/SKILL.md from templates/SKILL.md.
#
# Usage: new.sh <name>
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE="$REPO_ROOT/templates/SKILL.md"

name="${1:-}"
if [ -z "$name" ]; then
  echo "usage: make new name=<skill-name>" >&2
  exit 2
fi

# Validate the name: lowercase letters, digits, hyphens (kebab-case).
case "$name" in
  *[!a-z0-9-]*|-*|*-|"")
    echo "error: invalid name '$name' (use kebab-case: a-z 0-9 -)" >&2
    exit 2 ;;
esac

[ -f "$TEMPLATE" ] || { echo "error: template not found at $TEMPLATE" >&2; exit 1; }

dest_dir="$REPO_ROOT/skills/$name"
dest="$dest_dir/SKILL.md"

if [ -e "$dest_dir" ]; then
  echo "error: skills/$name already exists" >&2
  exit 1
fi

mkdir -p "$dest_dir"
# Substitute the name placeholder; description is left as a TODO to fill in.
sed "s/__NAME__/$name/g" "$TEMPLATE" > "$dest"

echo "created skills/$name/SKILL.md"
echo "next: edit the description in $dest, then 'make install'"
