#!/usr/bin/env bash
# Stale-config sweep for pr-review (SKILL.md, check 2): grep the fixed list of
# config, docs and manifest files for a removed name and print each hit.
#
# Usage: stale_refs.sh <name> [<dir>]
#   <name>  the deleted path, package, workflow or task, matched as a fixed
#           string (not a regex)
#   <dir>   the repo root to sweep (default: .)
#
# Output: one `file:line: text` per hit, paths relative to <dir>, then one
# summary line. Exit 0 whether or not anything matched; exit 2 on a usage
# error. Binary files are skipped, and so are .git and node_modules.
#
# Files swept (at any depth unless marked "root"):
#   IDE configs        .idea/*, .vscode/*
#   ignore / editor    .gitignore, .editorconfig
#   make               Makefile, makefile
#   GitHub (root)      .github/dependabot.yml|yaml, every file under .github/workflows/
#   docs               README.md, ARCHITECTURE.md (any case)
#   task runners       justfile, Justfile, .justfile, dodo.py, package.json (npm scripts)
#   manifests          pyproject.toml, package.json, Cargo.toml
#   deployment         helm values*.yaml|yml, kustomization.yaml|yml, Kustomization,
#                      compose.yaml|yml, docker-compose*.yaml|yml
#   agent instructions AGENTS.md, CLAUDE.md, GEMINI.md, .cursorrules, .cursor/rules/*,
#                      .github/copilot-instructions.md (root)
set -u

usage() {
  echo "usage: stale_refs.sh <name> [<dir>]" >&2
  exit 2
}

case "${1:-}" in
  -h|--help) echo "usage: stale_refs.sh <name> [<dir>]"; exit 0 ;;
esac
[ $# -ge 1 ] && [ $# -le 2 ] || usage
name="$1"
dir="${2:-.}"
[ -n "$name" ] || { echo "stale_refs.sh: <name> is empty" >&2; usage; }
[ -d "$dir" ] || { echo "stale_refs.sh: not a directory: $dir" >&2; usage; }
cd "$dir" || usage

files="$(find . \( -name .git -o -name node_modules \) -prune -o -type f \( \
    -path '*/.idea/*' -o -path '*/.vscode/*' \
    -o -name .gitignore -o -name .editorconfig \
    -o -name Makefile -o -name makefile \
    -o -path ./.github/dependabot.yml -o -path ./.github/dependabot.yaml \
    -o -path './.github/workflows/*' \
    -o -iname README.md -o -iname ARCHITECTURE.md \
    -o -name justfile -o -name Justfile -o -name .justfile -o -name dodo.py \
    -o -name package.json -o -name pyproject.toml -o -name Cargo.toml \
    -o -name 'values*.yaml' -o -name 'values*.yml' \
    -o -name kustomization.yaml -o -name kustomization.yml -o -name Kustomization \
    -o -name compose.yaml -o -name compose.yml \
    -o -name 'docker-compose*.yaml' -o -name 'docker-compose*.yml' \
    -o -name AGENTS.md -o -name CLAUDE.md -o -name GEMINI.md -o -name .cursorrules \
    -o -path '*/.cursor/rules/*' -o -path ./.github/copilot-instructions.md \
  \) -print | sed 's|^\./||' | LC_ALL=C sort -u)"

checked=0; hits=0; hit_files=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  checked=$((checked + 1))
  out="$(grep -nIF -- "$name" "$f")" || continue
  hit_files=$((hit_files + 1))
  while IFS= read -r hit; do
    hits=$((hits + 1))
    printf '%s:%s: %s\n' "$f" "${hit%%:*}" "${hit#*:}"
  done <<EOF
$out
EOF
done <<EOF
$files
EOF

if [ "$hits" -eq 0 ]; then
  echo "no stale references to '$name' in $checked files checked"
else
  echo "$hits stale references to '$name' in $hit_files of $checked files checked"
fi
exit 0
