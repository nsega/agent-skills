#!/usr/bin/env bash
set -euo pipefail
# Zero-token checks for pr-review's scripts/stale_refs.sh: a hit in each kind
# of file SKILL.md check 2 lists, files it must skip, no hits, usage errors.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
SCRIPT="$SKILL_DIR/scripts/stale_refs.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/stale_refs.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1" >&2; }

# 0: SKILL.md points at the script.
grep -q "scripts/stale_refs.sh" "$SKILL_DIR/SKILL.md" && ok || bad "SKILL.md does not mention scripts/stale_refs.sh"

# 1: a fixture repo with the removed name `oldpkg` in one file of every listed kind.
R="$TMP/repo"
put() { mkdir -p "$(dirname "$R/$1")"; printf '%s\n' "$2" > "$R/$1"; }
LISTED="
.idea/modules.xml
.vscode/settings.json
.gitignore
Makefile
svc/makefile
.github/dependabot.yml
.github/workflows/ci.yml
README.md
docs/ARCHITECTURE.md
justfile
dodo.py
web/package.json
pyproject.toml
crates/core/Cargo.toml
.editorconfig
deploy/helm/values.yaml
deploy/overlays/prod/kustomization.yaml
docker-compose.yml
AGENTS.md
CLAUDE.md
"
for f in $LISTED; do put "$f" "line one
uses oldpkg here"; done
# Files outside the list, or in pruned dirs, that also mention it.
put src/main.py "import oldpkg"
put node_modules/x/package.json '"oldpkg"'
put docs/notes.md "oldpkg was removed"
put svc/.github/workflows/ci.yml "oldpkg"
# A listed file without the name.
put other/pyproject.toml "name = 'fine'"

out="$(bash "$SCRIPT" oldpkg "$R")" && ok || bad "exit non-zero with hits"
for f in $LISTED; do
  echo "$out" | grep -qxF "$f:2: uses oldpkg here" && ok || bad "no hit reported for $f"
done
for f in src/main.py node_modules/x/package.json docs/notes.md svc/.github/workflows/ci.yml; do
  ! echo "$out" | grep -q "^$f:" && ok || bad "reported $f, which is not in the list"
done
n="$(echo "$LISTED" | grep -c .)"
echo "$out" | tail -n 1 | grep -qx "$n stale references to 'oldpkg' in $n of $((n + 1)) files checked" \
  && ok || bad "summary line wrong: $(echo "$out" | tail -n 1)"

# 2: the name is a fixed string, not a regex.
put pyproject.toml 'dep = "old.pkg"'
put Cargo.toml 'dep = "oldxpkg"'
out="$(bash "$SCRIPT" old.pkg "$R")"
echo "$out" | grep -qxF 'pyproject.toml:1: dep = "old.pkg"' && ok || bad "fixed-string hit missing"
! echo "$out" | grep -q '^Cargo.toml:' && ok || bad "name was treated as a regex"

# 3: no hits is exit 0 with a clear line, and the default dir is the cwd.
out="$(cd "$R" && bash "$SCRIPT" nothing-mentions-this)" && ok || bad "exit non-zero with no hits"
echo "$out" | grep -qx "no stale references to 'nothing-mentions-this' in [0-9]* files checked" \
  && ok || bad "no-hit line wrong: $out"
[ "$(echo "$out" | wc -l | tr -d ' ')" = 1 ] && ok || bad "no-hit output has extra lines: $out"

# 4: usage errors exit 2 with a usage line on stderr.
for args in "" "''" "oldpkg $TMP/missing" "a b c"; do
  set +e; eval "bash \"\$SCRIPT\" $args" > "$TMP/out" 2> "$TMP/err"; rc=$?; set -e
  [ "$rc" = 2 ] && ok || bad "args [$args]: exit $rc, want 2"
  grep -q "^usage: stale_refs.sh" "$TMP/err" && ok || bad "args [$args]: no usage line"
  [ ! -s "$TMP/out" ] && ok || bad "args [$args]: wrote to stdout"
done
bash "$SCRIPT" --help | grep -q "^usage:" && ok || bad "--help prints no usage"

echo "pr-review: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
