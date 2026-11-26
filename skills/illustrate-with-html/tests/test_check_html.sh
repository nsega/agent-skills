#!/usr/bin/env bash
set -euo pipefail
# Zero-token checks for illustrate-with-html: check_html.py passes the shipped
# template and example, and fails small files that break the self-contained rule.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$HERE/.." && pwd)"
CHECK="$SKILL_DIR/scripts/check_html.py"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/check_html.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL: $1" >&2; }

# 1: SKILL.md points at the checker.
grep -q "scripts/check_html.py" "$SKILL_DIR/SKILL.md" && ok || bad "SKILL.md does not mention scripts/check_html.py"

# 2: the shipped template and the worked example are clean.
for f in assets/base-template.html references/flowchart-example.html; do
  out="$(python3 "$CHECK" "$SKILL_DIR/$f")" && ok || bad "$f fails check_html.py: $out"
  [ -z "$out" ] && ok || bad "$f: unexpected output: $out"
done

# Files that break one rule each. $1 = file, stdin = body.
page() {
  { echo '<!doctype html><html><head><meta charset="utf-8"></head><body>'; cat; echo '</body></html>'; } > "$1"
}
# $1 = file, $2 = label, $3 = text the report must contain.
expect_fail() {
  if python3 "$CHECK" "$1" > "$TMP/out"; then bad "$2 passed"; return; fi
  ok
  grep -qF -- "$3" "$TMP/out" && ok || bad "$2 not reported: $(cat "$TMP/out")"
}

# 3: a CDN script.
echo '<script src="https://cdn.jsdelivr.net/npm/d3@7"></script>' | page "$TMP/cdn.html"
expect_fail "$TMP/cdn.html" "CDN script" "external resource"

# 4: a Google Fonts stylesheet, linked and imported.
echo '<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter">' | page "$TMP/font-link.html"
expect_fail "$TMP/font-link.html" "Google Fonts link" "external resource"
echo '<style>@import url("https://fonts.googleapis.com/css2?family=Inter");</style>' | page "$TMP/font-import.html"
expect_fail "$TMP/font-import.html" "Google Fonts @import" "external resource"

# 5: a remote image.
echo '<img src="//example.com/diagram.png" alt="">' | page "$TMP/img.html"
expect_fail "$TMP/img.html" "remote image" "external resource"

# 6: a Mermaid block, with the runtime inlined so only the Mermaid rule fires.
cat <<'HTML' | page "$TMP/mermaid.html"
<pre class="mermaid">
graph LR; A --> B
</pre>
<script>mermaid.initialize({ startOnLoad: true });</script>
HTML
expect_fail "$TMP/mermaid.html" "Mermaid block" "uses Mermaid"
grep -q "mermaid.html:2: uses Mermaid" "$TMP/out" && ok || bad "Mermaid block reported without its line: $(cat "$TMP/out")"
[ "$(wc -l < "$TMP/out")" -eq 2 ] && ok || bad "expected one line per problem: $(cat "$TMP/out")"

# 7: a Markdown mermaid fence pasted into the page.
printf '<pre>\n```mermaid\ngraph LR; A --> B\n```\n</pre>\n' | page "$TMP/fence.html"
expect_fail "$TMP/fence.html" "mermaid fence" "uses Mermaid"

# 8: prose that only names Mermaid, and an inline SVG, stay clean.
cat <<'HTML' | page "$TMP/prose.html"
<p>We drew this by hand instead of using Mermaid.</p>
<svg viewBox="0 0 10 10"><defs><marker id="arrow"></marker></defs>
<path d="M0 0 L10 10" style="marker-end: url(#arrow)"/></svg>
HTML
python3 "$CHECK" "$TMP/prose.html" > "$TMP/out" && ok || bad "clean prose page failed: $(cat "$TMP/out")"

# 9: usage errors exit 2.
set +e
python3 "$CHECK" > /dev/null 2>&1; rc=$?
python3 "$CHECK" "$TMP/missing.html" > /dev/null 2>&1; rc2=$?
set -e
[ "$rc" -eq 2 ] && ok || bad "no argument exited $rc, want 2"
[ "$rc2" -eq 2 ] && ok || bad "missing file exited $rc2, want 2"

echo "illustrate-with-html: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
