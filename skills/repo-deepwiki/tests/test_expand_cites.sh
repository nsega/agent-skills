#!/usr/bin/env bash
set -euo pipefail
# Zero-token checks for repo-deepwiki's citation expander/validator: a fixture
# repo with good and bad {{cite:...}} macros, expanded and compared with golden
# output made once from the code block that used to live in SKILL.md step 6.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/expand_cites.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1" >&2; }

SHA=0123456789abcdef0123456789abcdef01234567
REPO=acme/widget

# The embedded block from SKILL.md, with the placeholders filled in.
EMBEDDED="$TMP/embedded.py"
awk '/^   ```python$/ {f=1; next} /^   ```$/ {f=0} f' "$SKILL_DIR/SKILL.md" \
  | sed -e 's/^   //' -e "s|\"<full-sha>\", \"<owner>/<repo>\"|\"$SHA\", \"$REPO\"|" > "$EMBEDDED"
expand() { (cd "$1" && python3 "$EMBEDDED"); }

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

# 1: good citations expand to SHA-pinned links, and nothing is flagged.
R="$TMP/r1"; make_repo "$R"; cp "$R/good.md" "$R/wiki.md"
out="$(expand "$R")" && ok || bad "good wiki failed: $out"
[ "$out" = "UNRESOLVED: 0 PROBLEMS: none" ] && ok || bad "good wiki summary: $out"
cmp -s "$R/wiki.md" "$TMP/good.golden" && ok || bad "good wiki differs from golden: $(diff "$TMP/good.golden" "$R/wiki.md")"

# 2: a bad range, a missing path and an empty macro are reported; the links
# are still written, the same as the embedded code wrote them.
R="$TMP/r2"; make_repo "$R"; cp "$R/bad.md" "$R/wiki.md"
out="$(expand "$R" || true)"
[ "$out" = "UNRESOLVED: 1 PROBLEMS: ['range src/a.py:9-20 > 10', 'missing src/missing.py', 'missing docs/gone.md']" ] \
  && ok || bad "bad wiki summary: $out"
cmp -s "$R/wiki.md" "$TMP/bad.golden" && ok || bad "bad wiki differs from golden: $(diff "$TMP/bad.golden" "$R/wiki.md")"

echo "repo-deepwiki: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
