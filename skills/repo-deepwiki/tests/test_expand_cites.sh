#!/usr/bin/env bash
set -euo pipefail
# Zero-token checks for repo-deepwiki's scripts/expand_cites.py: a fixture repo
# with good and bad {{cite:...}} macros, expanded and compared with golden
# output made once from the code block that used to live in SKILL.md step 6.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
SCRIPT="$SKILL_DIR/scripts/expand_cites.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/expand_cites.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1" >&2; }

SHA=0123456789abcdef0123456789abcdef01234567
REPO=acme/widget

# Stdout to stdout, stderr to $1/err.
expand() { (cd "$1" && python3 "$SCRIPT" --repo "$REPO" --sha "$SHA" wiki.md 2> err); }

# 0: the script is there, and SKILL.md runs it instead of carrying a copy.
[ -x "$SCRIPT" ] && ok || bad "scripts/expand_cites.py missing or not executable"
grep -q "scripts/expand_cites.py" "$SKILL_DIR/SKILL.md" && ok || bad "SKILL.md does not mention scripts/expand_cites.py"
! grep -q '^ *```python' "$SKILL_DIR/SKILL.md" && ok || bad "SKILL.md still embeds a Python block"

# Fixture repo: a 10-line file, a 3-line file, and two wikis.
make_repo() {
  mkdir -p "$1/src"
  seq 1 10 | sed 's/^/line /' > "$1/src/a.py"
  printf 'package b\n\nfunc B() {}\n' > "$1/src/b.go"
  cat > "$1/good.md" <<'MD'
# Wiki

- range {{cite:src/a.py:2-5}}
- single {{cite:src/a.py:7}}
- same start and end {{cite:src/a.py:3-3}}
- last line {{cite:src/a.py:10}}
- whole file {{cite:src/b.go}}
- untouched [plain](https://example.com) and `{not a cite}`
MD
  cat > "$1/bad.md" <<'MD'
# Wiki

- ok {{cite:src/b.go:1-3}}
- past the end {{cite:src/a.py:9-20}}
- missing with line {{cite:src/missing.py:4}}
- missing file {{cite:docs/gone.md}}
- empty {{cite:}}
MD
}

cat > "$TMP/good.golden" <<'MD'
# Wiki

- range [src/a.py:2-5](https://github.com/acme/widget/blob/0123456789abcdef0123456789abcdef01234567/src/a.py#L2-L5)
- single [src/a.py:7](https://github.com/acme/widget/blob/0123456789abcdef0123456789abcdef01234567/src/a.py#L7)
- same start and end [src/a.py:3-3](https://github.com/acme/widget/blob/0123456789abcdef0123456789abcdef01234567/src/a.py#L3)
- last line [src/a.py:10](https://github.com/acme/widget/blob/0123456789abcdef0123456789abcdef01234567/src/a.py#L10)
- whole file [src/b.go](https://github.com/acme/widget/blob/0123456789abcdef0123456789abcdef01234567/src/b.go)
- untouched [plain](https://example.com) and `{not a cite}`
MD

cat > "$TMP/bad.golden" <<'MD'
# Wiki

- ok [src/b.go:1-3](https://github.com/acme/widget/blob/0123456789abcdef0123456789abcdef01234567/src/b.go#L1-L3)
- past the end [src/a.py:9-20](https://github.com/acme/widget/blob/0123456789abcdef0123456789abcdef01234567/src/a.py#L9-L20)
- missing with line [src/missing.py:4](https://github.com/acme/widget/blob/0123456789abcdef0123456789abcdef01234567/src/missing.py#L4)
- missing file [docs/gone.md](https://github.com/acme/widget/blob/0123456789abcdef0123456789abcdef01234567/docs/gone.md)
- empty {{cite:}}
MD

# 1: good citations expand to SHA-pinned links, nothing is flagged, exit 0.
R="$TMP/r1"; make_repo "$R"; cp "$R/good.md" "$R/wiki.md"
out="$(expand "$R")" && ok || bad "good wiki exited non-zero: $out $(cat "$R/err")"
[ "$out" = "UNRESOLVED: 0 PROBLEMS: none" ] && ok || bad "good wiki summary: $out"
[ ! -s "$R/err" ] && ok || bad "good wiki wrote to stderr: $(cat "$R/err")"
cmp -s "$R/wiki.md" "$TMP/good.golden" && ok || bad "good wiki differs from golden: $(diff "$TMP/good.golden" "$R/wiki.md")"

# 2: a bad range, a missing path and an empty macro fail the run with one
# stderr line each; the links are still written, as the embedded code wrote them.
R="$TMP/r2"; make_repo "$R"; cp "$R/bad.md" "$R/wiki.md"
if out="$(expand "$R")"; then bad "bad wiki exited 0"; else ok; fi
[ "$out" = "UNRESOLVED: 1 PROBLEMS: ['range src/a.py:9-20 > 10', 'missing src/missing.py', 'missing docs/gone.md']" ] \
  && ok || bad "bad wiki summary: $out"
cmp -s "$R/wiki.md" "$TMP/bad.golden" && ok || bad "bad wiki differs from golden: $(diff "$TMP/bad.golden" "$R/wiki.md")"
cat > "$TMP/bad.err" <<'ERR'
wiki.md: range src/a.py:9-20 > 10
wiki.md: missing src/missing.py
wiki.md: missing docs/gone.md
wiki.md: unresolved {{cite:}}
ERR
cmp -s "$R/err" "$TMP/bad.err" && ok || bad "bad wiki stderr: $(cat "$R/err")"

# 3: with no --repo or --sha, the facts come from git: the origin remote in
# git@, ssh:// or https:// form, and HEAD.
R="$TMP/r3"; make_repo "$R"; cp "$R/good.md" "$R/wiki.md"
git -C "$R" init -q
git -C "$R" add src
git -C "$R" -c user.name=t -c user.email=t@example.com commit -q -m fixture
head_sha="$(git -C "$R" rev-parse HEAD)"
git -C "$R" remote add origin git@github.com:acme/widget.git
for url in git@github.com:acme/widget.git ssh://git@github.com/acme/widget.git https://github.com/acme/widget; do
  git -C "$R" remote set-url origin "$url"
  cp "$R/good.md" "$R/wiki.md"
  (cd "$R" && python3 "$SCRIPT" > /dev/null) && ok || bad "fact resolution failed for $url"
  sed "s/$SHA/$head_sha/" "$TMP/good.golden" > "$TMP/head.golden"
  cmp -s "$R/wiki.md" "$TMP/head.golden" && ok || bad "links not pinned to HEAD of acme/widget for $url: $(diff "$TMP/head.golden" "$R/wiki.md")"
done

# 4: no remote and no --repo is a clear error, not a guess.
R="$TMP/r4"; make_repo "$R"; cp "$R/good.md" "$R/wiki.md"
git -C "$R" init -q
if (cd "$R" && python3 "$SCRIPT" --sha "$SHA" 2> err); then bad "no remote exited 0"; else ok; fi
grep -q "no origin remote" "$R/err" && ok || bad "no remote not reported: $(cat "$R/err")"

echo "repo-deepwiki: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
